#!/bin/bash
# Withdraws orphan TradeProposal and AmuletAllocation contracts after a failed
# or incomplete trade request.
#
# Run this when test-trade-request.sh fails and leaves lingering contracts,
# or when you want to cancel a pending trade proposal before retrying.
#
# This script runs three cleanup steps in order:
#   1. TradeProposal_Withdraw  — trader exercises on each TradeProposal,
#                                atomically withdrawing the senderAllocation
#                                and archiving the proposal in one shot.
#   2. TradeProposal_Archive   — executor archives any TradeProposals that
#                                remain after step 1 (allocation already gone).
#   3. Allocation_Withdraw     — direct fallback for orphan AmuletAllocations
#                                that have no associated TradeProposal.
#
# Prerequisites:
#   - 01-setup-trading-partner.sh completed (trading-partner-config.json exists)
#   - Trader party set in trade-request-config.json or TRADER_PARTY_ID env var
#
# Usage:
#   ./04-withdraw-allocation.sh
#   TRADER_PARTY_ID="trader-0::1220..." TRADER_USER_ID="trader-0" ./04-withdraw-allocation.sh

set -eo pipefail

RUN_ID=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_EXCHANGE_DIR="$SCRIPT_DIR/../setup-exchange"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[withdraw] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
if [ ! -f "$SETUP_EXCHANGE_DIR/.env" ]; then
  echo "[withdraw] ERROR: $SETUP_EXCHANGE_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
# shellcheck disable=SC1091
source "$SETUP_EXCHANGE_DIR/.env"

TRADING_PARTNER_JSON_API="${TRADING_PARTNER_JSON_API:-http://localhost:1975}"
TRADING_PARTNER_VALIDATOR_API="${TRADING_PARTNER_VALIDATOR_API:-http://localhost:1903}"
APP_USER_JSON_API="${APP_USER_JSON_API:-http://localhost:2975}"

TRADE_PROPOSAL_TEMPLATE_ID="${TRADE_PROPOSAL_TEMPLATE_ID:-#kairo-dex-simple-escrow-v4:Kairo.Escrow.TradeProposal:TradeProposal}"

# Load trader party from trade-request-config.json
TRADE_CONFIG_FILE="$SCRIPT_DIR/trade-request-config.json"
if [ -z "$TRADER_PARTY_ID" ] && [ -f "$TRADE_CONFIG_FILE" ]; then
  TRADER_PARTY_ID=$(jq -r '.traderPartyId // empty' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "")
  TRADER_USER_ID=$(jq -r '.traderUserId // empty' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "")
fi

if [ -z "$TRADER_PARTY_ID" ]; then
  # Prefer internal-trader.json (local), fall back to setup-internal-parties
  for _parties_file in \
      "$SCRIPT_DIR/internal-trader.json" \
      "$SCRIPT_DIR/../setup-internal-parties/internal-parties.json"; do
    if [ -f "$_parties_file" ]; then
      TRADER_PARTY_ID=$(jq -r '.parties[0].partyId // empty' "$_parties_file" 2>/dev/null || echo "")
      TRADER_USER_ID=$(jq -r '.parties[0].userId // empty' "$_parties_file" 2>/dev/null || echo "")
      [ -n "$TRADER_PARTY_ID" ] && break
    fi
  done
fi

TRADER_USER_ID="${TRADER_USER_ID:-trading-partner-0}"

# Load executor party from exchange backend .env.local / .env
EXECUTOR_PARTY_ID="${EXECUTOR_PARTY_ID:-}"
if [ -z "$EXECUTOR_PARTY_ID" ] && [ -n "$EXCHANGE_BACKEND_DIR" ]; then
  for env_file in "$EXCHANGE_BACKEND_DIR/.env.local" "$EXCHANGE_BACKEND_DIR/.env"; do
    if [ -f "$env_file" ]; then
      EXECUTOR_PARTY_ID=$(grep -E '^EXECUTOR_PARTY_ID=' "$env_file" | cut -d= -f2- | tr -d '"' | head -1 || echo "")
      [ -n "$EXECUTOR_PARTY_ID" ] && break
    fi
  done
fi

APP_USER_USER_ID="${SHARED_SECRET_APP_USER_USER:-ledger-api-user}"

##############################################################################
# Helper Functions
##############################################################################

log() { echo "[withdraw] $*"; }
log_error() { echo "[withdraw] ERROR: $*" >&2; }

generate_canton_jwt() {
  local sub="$1" aud="$2"
  local now; now=$(date +%s)
  local exp=$((now + 86400))
  b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
  local header; header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  local payload; payload=$(printf '{"sub":"%s","aud":"%s","iat":%d,"exp":%d,"iss":"unsafe-auth"}' "$sub" "$aud" "$now" "$exp" | b64url)
  local signature; signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$SHARED_SECRET" -binary | b64url)
  echo "${header}.${payload}.${signature}"
}

curl_check() {
  local url=$1 token=$2 content_type=${3:-application/json}
  local curl_args=(-s -S -w "\n%{http_code}" "$url")
  [ -n "$token" ] && curl_args+=(-H "Authorization: Bearer $token")
  curl_args+=(-H "Content-Type: $content_type")
  curl_args+=("${@:4}")
  local response; response=$(curl "${curl_args[@]}")
  local http_code; http_code=$(echo "$response" | tail -n1 | tr -d '\r')
  local body; body=$(echo "$response" | sed '$d')
  if [ "$http_code" -ne "200" ] && [ "$http_code" -ne "201" ] && [ "$http_code" -ne "204" ]; then
    log_error "Request to $url failed with HTTP $http_code"
    log_error "Response: $body"
    return 1
  fi
  echo "$body"
}

query_active_contracts() {
  local json_api="$1" token="$2" party="$3" template_id="$4"
  local offset; offset=$(curl_check "$json_api/v2/state/ledger-end" "$token" | jq -r '.offset')
  local body; body=$(jq -n \
    --arg party "$party" --arg templateId "$template_id" \
    --argjson offset "$offset" \
    '{
      filter: { filtersByParty: { ($party): { cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId: $templateId, includeCreatedEventBlob: true } } } }] } } },
      verbose: false, activeAtOffset: $offset
    }')
  curl_check "$json_api/v2/state/active-contracts" "$token" "application/json" --data-raw "$body" 2>/dev/null || echo ""
}

exercise_choice() {
  local json_api="$1" token="$2" party="$3" user_id="$4" template_id="$5" contract_id="$6" choice="$7" choice_arg="$8"
  local disclosed="${9:-[]}"
  local cmd_id="withdraw-${RUN_ID}-${RANDOM}"
  local body; body=$(jq -n \
    --arg templateId "$template_id" \
    --arg contractId "$contract_id" \
    --arg choice "$choice" \
    --argjson choiceArg "$choice_arg" \
    --arg cmdId "$cmd_id" \
    --arg userId "$user_id" \
    --arg party "$party" \
    --argjson disclosed "$disclosed" \
    '{
      commands: [{
        ExerciseCommand: {
          templateId: $templateId,
          contractId: $contractId,
          choice: $choice,
          choiceArgument: $choiceArg
        }
      }],
      commandId: $cmdId,
      applicationId: $userId,
      actAs: [$party],
      readAs: [],
      deduplicationPeriod: { Empty: {} },
      submissionId: $cmdId,
      disclosedContracts: $disclosed,
      domainId: "",
      packageIdSelectionPreference: []
    }')
  curl_check "$json_api/v2/commands/submit-and-wait" "$token" "application/json" \
    --data-raw "$body"
}

##############################################################################
# Pre-flight
##############################################################################

log "=========================================="
log "Withdraw Orphan TradeProposals / Allocations"
log "=========================================="

[ -n "$TRADER_PARTY_ID" ] || { log_error "TRADER_PARTY_ID not set"; exit 1; }

log "  Trader:   $TRADER_PARTY_ID"
log "  Executor: ${EXECUTOR_PARTY_ID:-(not set, skipping TradeProposal_Archive)}"
log "  Ledger:   $TRADING_PARTNER_JSON_API"
log ""

TRADER_TOKEN=$(generate_canton_jwt "$TRADER_USER_ID" "$SHARED_SECRET_AUDIENCE")
TP_TOKEN=$(generate_canton_jwt "${SHARED_SECRET_TRADING_PARTNER_USER:-ledger-api-user}" "$SHARED_SECRET_AUDIENCE")
APP_USER_TOKEN=$(generate_canton_jwt "$APP_USER_USER_ID" "$SHARED_SECRET_AUDIENCE")

##############################################################################
# Step 0: Fetch OpenMiningRound via scan-proxy (needed for Amulet unlock)
##############################################################################

log "Step 0: Fetching OpenMiningRound from scan-proxy..."

SCAN_RESPONSE=$(curl_check \
  "$TRADING_PARTNER_VALIDATOR_API/api/validator/v0/scan-proxy/registry/allocation-instruction/v1/allocation-factory" \
  "$TP_TOKEN" "application/json" \
  --data-raw '{"choiceArguments":{},"excludeDebugFields":true}') || {
  log_error "Failed to fetch allocation factory from scan-proxy at $TRADING_PARTNER_VALIDATOR_API"
  exit 1
}

OPEN_ROUND_ANY_VALUE=$(echo "$SCAN_RESPONSE" | jq -c \
  '(.choiceContext.choiceContextData // .choiceContextData // {values: {}}).values["open-round"] // empty')
OPEN_ROUND_CID=$(echo "$OPEN_ROUND_ANY_VALUE" | jq -r '.value // empty' 2>/dev/null || echo "")

if [ -z "$OPEN_ROUND_CID" ]; then
  log_error "Could not extract open-round CID from scan-proxy response"
  exit 1
fi
log "  OpenMiningRound CID: ${OPEN_ROUND_CID:0:40}..."

OMR_DISCLOSED=$(echo "$SCAN_RESPONSE" | jq -c \
  '(.choiceContext.disclosedContracts // .disclosedContracts // [])
   | [.[] | {contractId, templateId, createdEventBlob, synchronizerId}]
   | map(select(.templateId | contains("OpenMiningRound")))
   | .[0] // empty' 2>/dev/null || echo "")

if [ -z "$OMR_DISCLOSED" ] || [ "$OMR_DISCLOSED" = "null" ]; then
  log_error "Could not find OpenMiningRound in scan-proxy disclosed contracts"
  exit 1
fi
log "  OpenMiningRound blob: $(echo "$OMR_DISCLOSED" | jq -r '.createdEventBlob | length') chars"

# Build extraArgs for Amulet allocation withdrawal (used in steps 1 and 3)
AMULET_EXTRA_ARGS=$(jq -n \
  --arg openRoundCid "$OPEN_ROUND_CID" \
  '{
    context: {
      values: {
        "expire-lock": {"tag": "AV_Bool", "value": true},
        "open-round": {"tag": "AV_ContractId", "value": $openRoundCid}
      }
    },
    meta: {values: {}}
  }')

##############################################################################
# Step 1: Withdraw TradeProposals via TradeProposal_Withdraw (sender=trader)
#
# TradeProposal_Withdraw atomically:
#   - Exercises Allocation_Withdraw on senderAllocationCid
#   - Archives the TradeProposal
##############################################################################

log ""
log "Step 1: Querying active TradeProposals for trader (as sender)..."

TP_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
  "$TRADER_PARTY_ID" "$TRADE_PROPOSAL_TEMPLATE_ID")

TRADE_PROPOSALS=$(echo "$TP_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent |
   {contractId, templateId}]
' 2>/dev/null || echo "[]")

NUM_TP=$(echo "$TRADE_PROPOSALS" | jq 'length')
log "  Found $NUM_TP TradeProposal(s)"

WITHDRAWN_TP=0
SKIPPED_TP=0
for i in $(seq 0 $((NUM_TP - 1))); do
  TP_CID=$(echo "$TRADE_PROPOSALS" | jq -r ".[$i].contractId")
  log "  [$((i+1))/$NUM_TP] TradeProposal_Withdraw: ${TP_CID:0:40}..."

  CHOICE_ARG=$(jq -n --argjson extraArgs "$AMULET_EXTRA_ARGS" '{extraArgs: $extraArgs}')

  WITHDRAW_RESULT=$(exercise_choice "$TRADING_PARTNER_JSON_API" \
    "$TRADER_TOKEN" "$TRADER_PARTY_ID" "$TRADER_USER_ID" \
    "$TRADE_PROPOSAL_TEMPLATE_ID" "$TP_CID" \
    "TradeProposal_Withdraw" "$CHOICE_ARG" "[$OMR_DISCLOSED]" 2>&1) && {
    log "    Withdrawn OK"
    WITHDRAWN_TP=$((WITHDRAWN_TP + 1))
  } || {
    if echo "$WITHDRAW_RESULT" | grep -q "CONTRACT_NOT_FOUND"; then
      log "    Skipped: senderAllocation already gone — no assets locked (executor will archive in step 2)"
      SKIPPED_TP=$((SKIPPED_TP + 1))
    else
      log_error "    Failed: $WITHDRAW_RESULT"
    fi
  }
done

##############################################################################
# Step 2: Archive orphan TradeProposals via TradeProposal_Archive (executor)
#
# Handles TradeProposals where the senderAllocation was already withdrawn
# independently, so TradeProposal_Withdraw would fail. The executor archives
# these orphan proposals from the app-user participant.
##############################################################################

log ""
log "Step 2: Querying remaining TradeProposals for executor cleanup..."

if [ -z "$EXECUTOR_PARTY_ID" ]; then
  log "  EXECUTOR_PARTY_ID not set — skipping TradeProposal_Archive"
else
  # Re-query from app-user node (executor's participant) to find any remaining proposals
  APP_USER_TP_RESPONSE=$(query_active_contracts "$APP_USER_JSON_API" "$APP_USER_TOKEN" \
    "$EXECUTOR_PARTY_ID" "$TRADE_PROPOSAL_TEMPLATE_ID")

  # Filter to proposals whose sender matches our trader
  ORPHAN_TPS=$(echo "$APP_USER_TP_RESPONSE" | jq -c \
    --arg trader "$TRADER_PARTY_ID" '
    [.[] | select(.contractEntry.JsActiveContract) |
     .contractEntry.JsActiveContract.createdEvent |
     select(.createArgument.sender == $trader) |
     {contractId, templateId}]
  ' 2>/dev/null || echo "[]")

  NUM_ORPHAN=$(echo "$ORPHAN_TPS" | jq 'length')
  log "  Found $NUM_ORPHAN orphan TradeProposal(s) (sender=$TRADER_PARTY_ID)"

  ARCHIVED_TP=0
  for i in $(seq 0 $((NUM_ORPHAN - 1))); do
    ORPHAN_CID=$(echo "$ORPHAN_TPS" | jq -r ".[$i].contractId")
    log "  [$((i+1))/$NUM_ORPHAN] TradeProposal_Archive: ${ORPHAN_CID:0:40}..."

    ARCHIVE_RESULT=$(exercise_choice "$APP_USER_JSON_API" \
      "$APP_USER_TOKEN" "$EXECUTOR_PARTY_ID" "$APP_USER_USER_ID" \
      "$TRADE_PROPOSAL_TEMPLATE_ID" "$ORPHAN_CID" \
      "TradeProposal_Archive" '{}' '[]' 2>&1) && {
      log "    Archived OK"
      ARCHIVED_TP=$((ARCHIVED_TP + 1))
    } || {
      if echo "$ARCHIVE_RESULT" | grep -q "Invalid template"; then
        log "    Skipped: TradeProposal_Archive not available on this contract version (pre-v4 orphan — no assets locked)"
      else
        log_error "    Failed: $ARCHIVE_RESULT"
      fi
    }
  done
fi

##############################################################################
# Step 3: Withdraw orphan AmuletAllocations (fallback — no TradeProposal)
##############################################################################

log ""
log "Step 3: Querying orphan AmuletAllocation contracts (fallback)..."

ALLOC_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
  "$TRADER_PARTY_ID" "#splice-amulet:Splice.AmuletAllocation:AmuletAllocation")

ALLOCATIONS=$(echo "$ALLOC_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent |
   {contractId, templateId}]
' 2>/dev/null || echo "[]")

NUM_ALLOC=$(echo "$ALLOCATIONS" | jq 'length')
log "  Found $NUM_ALLOC orphan AmuletAllocation(s)"

WITHDRAWN_ALLOC=0
for i in $(seq 0 $((NUM_ALLOC - 1))); do
  ALLOC_CID=$(echo "$ALLOCATIONS" | jq -r ".[$i].contractId")
  log "  [$((i+1))/$NUM_ALLOC] Allocation_Withdraw: ${ALLOC_CID:0:40}..."

  CHOICE_ARG=$(jq -n --argjson extraArgs "$AMULET_EXTRA_ARGS" '{extraArgs: $extraArgs}')

  exercise_choice "$TRADING_PARTNER_JSON_API" \
    "$TRADER_TOKEN" "$TRADER_PARTY_ID" "$TRADER_USER_ID" \
    "#splice-api-token-allocation-v1:Splice.Api.Token.AllocationV1:Allocation" "$ALLOC_CID" \
    "Allocation_Withdraw" "$CHOICE_ARG" "[$OMR_DISCLOSED]" > /dev/null && {
    log "    Withdrawn OK"
    WITHDRAWN_ALLOC=$((WITHDRAWN_ALLOC + 1))
  } || \
    log_error "    Failed to withdraw AmuletAllocation $ALLOC_CID"
done

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Withdraw complete"
log "=========================================="
log ""
log "Summary:"
log "  TradeProposals withdrawn (TradeProposal_Withdraw): $WITHDRAWN_TP / $NUM_TP"
if [ "${SKIPPED_TP:-0}" -gt 0 ]; then
  log "  TradeProposals skipped   (allocation already gone): $SKIPPED_TP (no assets locked)"
fi
if [ -n "$EXECUTOR_PARTY_ID" ]; then
  log "  TradeProposals archived  (TradeProposal_Archive):  ${ARCHIVED_TP:-0} / ${NUM_ORPHAN:-0}"
fi
log "  AmuletAllocations withdrawn (Allocation_Withdraw):  $WITHDRAWN_ALLOC / $NUM_ALLOC"
log ""
log "The trader's Amulet holdings should now be unlocked."
log "Re-run ./test-trade-request.sh to start a fresh trade."
