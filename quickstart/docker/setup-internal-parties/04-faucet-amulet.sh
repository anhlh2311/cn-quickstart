#!/bin/bash
# Faucets Amulet (CC) tokens to internal parties listed in transfers.json.
#
# Unlike the utxo-handling external-party faucet, internal parties are hosted
# on the participant, so regular submit-and-wait is used (no interactive
# submission or Ed25519 signing required).
#
# This script:
#   1. Reads recipients and amounts from transfers.json
#   2. Fetches AmuletRules + OpenMiningRound via the validator scan-proxy
#   3. For each recipient, submits AmuletRules_DevNet_Tap via submit-and-wait
#   4. Writes results to fauceted-amulet.json
#
# Prerequisites:
#   - Quickstart must be running (DevNet mode — AmuletRules_DevNet_Tap only works on DevNet)
#   - 01-allocate-internal-parties.sh must have been run (parties onboarded)
#   - transfers.json must exist with recipient party IDs and amounts
#
# Environment variables:
#   TRANSFERS_FILE — path to transfers JSON (default: transfers.json in script dir)
#
# Usage:
#   ./04-faucet-amulet.sh
#   TRANSFERS_FILE=my-transfers.json ./04-faucet-amulet.sh
#   PARTIES_FILE=./internal-parties.mainnet.json ./04-faucet-amulet.sh

set -eo pipefail

RUN_ID=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Save caller-provided env vars before sourcing .env (CLI overrides take precedence)
_cli_PARTICIPANT_JSON_API="${PARTICIPANT_JSON_API:-}"
_cli_VALIDATOR_API="${VALIDATOR_API:-}"
_cli_AUTH_MODE="${AUTH_MODE:-}"
_cli_TRANSFERS_FILE="${TRANSFERS_FILE:-}"
_cli_PARTIES_FILE="${PARTIES_FILE:-}"
_cli_OUTPUT_FILE="${OUTPUT_FILE:-}"

# Load configuration from .env
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

# Source shared auth helpers (get_participant_token, get_user_token, etc.)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/auth.sh"

# CLI overrides > .env > defaults
PARTICIPANT_JSON_API="${_cli_PARTICIPANT_JSON_API:-${PARTICIPANT_JSON_API:-http://localhost:1975}}"
VALIDATOR_API="${_cli_VALIDATOR_API:-${VALIDATOR_API:-http://localhost:1903}}"

# Read parties JSON API from internal-parties.json if available
PARTIES_FILE="${_cli_PARTIES_FILE:-${PARTIES_FILE:-$SCRIPT_DIR/internal-parties.json}}"
if [ -z "$_cli_PARTICIPANT_JSON_API" ] && [ -f "$PARTIES_FILE" ]; then
  STORED_JSON_API=$(jq -r '.participantJsonApi // empty' "$PARTIES_FILE" 2>/dev/null || echo "")
  if [ -n "$STORED_JSON_API" ]; then
    PARTICIPANT_JSON_API="$STORED_JSON_API"
  fi
fi

TRANSFERS_FILE="${_cli_TRANSFERS_FILE:-${TRANSFERS_FILE:-$SCRIPT_DIR/transfers.json}}"

OUTPUT_FILE="${_cli_OUTPUT_FILE:-${OUTPUT_FILE:-$SCRIPT_DIR/fauceted-amulet.json}}"

AMULET_RULES_TEMPLATE="#splice-amulet:Splice.AmuletRules:AmuletRules"

##############################################################################
# Helper Functions
##############################################################################

log() { echo "[faucet-amulet] $*"; }
log_error() { echo "[faucet-amulet] ERROR: $*" >&2; }

##############################################################################
# Pre-flight checks
##############################################################################

log "=========================================="
log "Faucet Amulet (CC) to Internal Parties"
log "=========================================="

if [ ! -f "$TRANSFERS_FILE" ]; then
  log_error "transfers file not found: $TRANSFERS_FILE"
  exit 1
fi

NUM_TRANSFERS=$(jq 'length' "$TRANSFERS_FILE")
log "  Transfers file: $TRANSFERS_FILE ($NUM_TRANSFERS entries)"
log "  Participant JSON API: $PARTICIPANT_JSON_API"
log "  Validator API: $VALIDATOR_API"
log ""

ADMIN_TOKEN=$(get_participant_token)
VALIDATOR_TOKEN=$(get_validator_token)

##############################################################################
# Step 1: Fetch AmuletRules + OpenMiningRound via scan-proxy
##############################################################################

log "Step 1: Fetching AmuletRules + OpenMiningRound via scan-proxy..."

SCAN_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $VALIDATOR_TOKEN" \
  -H "Content-Type: application/json" \
  "$VALIDATOR_API/api/validator/v0/scan-proxy/registry/allocation-instruction/v1/allocation-factory" \
  --data-raw '{"choiceArguments":{},"excludeDebugFields":true}' 2>/dev/null || echo "")
SCAN_HTTP=$(echo "$SCAN_RESP" | tail -n1 | tr -d '\r')
SCAN_RESPONSE=$(echo "$SCAN_RESP" | sed '$d')

if [ "$SCAN_HTTP" != "200" ]; then
  log_error "Failed to fetch Amulet factory from scan-proxy (HTTP $SCAN_HTTP). Is the validator running?"
  log_error "Response: $(echo "$SCAN_RESPONSE" | head -c 300)"
  exit 1
fi

# AmuletRules CID from choiceContext.choiceContextData["amulet-rules"]
AMULET_RULES_CID=$(echo "$SCAN_RESPONSE" | jq -r '
  .choiceContext.choiceContextData.values["amulet-rules"].value //
  .choiceContextData.values["amulet-rules"].value // empty')
# OpenMiningRound CID from choiceContext.choiceContextData["open-round"]
OPEN_ROUND_CID=$(echo "$SCAN_RESPONSE" | jq -r '
  .choiceContext.choiceContextData.values["open-round"].value //
  .choiceContextData.values["open-round"].value // empty')

if [ -z "$AMULET_RULES_CID" ] || [ -z "$OPEN_ROUND_CID" ]; then
  log_error "Could not extract AmuletRules or OpenMiningRound CID from scan-proxy response"
  log_error "Response: $(echo "$SCAN_RESPONSE" | head -c 500)"
  exit 1
fi

# Disclosed contracts — try both top-level and nested under choiceContext
DISCLOSED_CONTRACTS=$(echo "$SCAN_RESPONSE" | jq -c '
  (.choiceContext.disclosedContracts // .disclosedContracts // [])
  | [.[] | {contractId, templateId, createdEventBlob, synchronizerId}]')

log "  AmuletRules CID: ${AMULET_RULES_CID:0:40}..."
log "  OpenMiningRound CID: ${OPEN_ROUND_CID:0:40}..."
log "  Disclosed contracts: $(echo "$DISCLOSED_CONTRACTS" | jq 'length')"

##############################################################################
# Step 2: Tap Amulet for each recipient in transfers.json
##############################################################################

log ""
log "Step 2: Tapping Amulet for $NUM_TRANSFERS recipients..."

RESULTS=()

for i in $(seq 0 $((NUM_TRANSFERS - 1))); do
  RECIPIENT=$(jq -r ".[$i].recipient" "$TRANSFERS_FILE")
  AMOUNT=$(jq -r ".[$i].amount" "$TRANSFERS_FILE")

  # Derive user ID from party ID (hint portion before ::)
  USER_ID=$(echo "$RECIPIENT" | cut -d: -f1)

  log "  [$((i+1))/$NUM_TRANSFERS] $USER_ID: tapping $AMOUNT CC..."

  USER_TOKEN=$(get_user_token "$USER_ID")

  CMD_ID="faucet-amulet-${i}-${RUN_ID}-${RANDOM}"

  SUBMIT_BODY=$(jq -n \
    --arg templateId "$AMULET_RULES_TEMPLATE" \
    --arg contractId "$AMULET_RULES_CID" \
    --arg receiver "$RECIPIENT" \
    --arg amount "$AMOUNT" \
    --arg openRound "$OPEN_ROUND_CID" \
    --arg cmdId "$CMD_ID" \
    --arg userId "$USER_ID" \
    --argjson disclosed "$DISCLOSED_CONTRACTS" \
    '{
      commands: {
        commands: [{
          ExerciseCommand: {
            templateId: $templateId,
            contractId: $contractId,
            choice: "AmuletRules_DevNet_Tap",
            choiceArgument: {
              receiver: $receiver,
              amount: $amount,
              openRound: $openRound
            }
          }
        }],
        commandId: $cmdId,
        applicationId: $userId,
        actAs: [$receiver],
        readAs: [],
        deduplicationPeriod: { Empty: {} },
        submissionId: $cmdId,
        disclosedContracts: $disclosed,
        domainId: "",
        packageIdSelectionPreference: []
      }
    }')

  TX_RESP=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json" \
    "$PARTICIPANT_JSON_API/v2/commands/submit-and-wait-for-transaction" \
    --data-raw "$SUBMIT_BODY" 2>/dev/null || echo "")
  TX_HTTP=$(echo "$TX_RESP" | tail -n1 | tr -d '\r')
  TX_RESULT=$(echo "$TX_RESP" | sed '$d')

  if [ "$TX_HTTP" != "200" ] && [ "$TX_HTTP" != "201" ]; then
    log_error "Failed to tap Amulet for $USER_ID (HTTP $TX_HTTP)"
    log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
    SKIPPED=$((${SKIPPED:-0} + 1))
    continue
  fi

  AMULET_CID=$(echo "$TX_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | test("Splice\\.Amulet:Amulet$"))
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  # Fallback: any Amulet contract that is not AmuletRules/Allocation/Transfer
  if [ -z "$AMULET_CID" ]; then
    AMULET_CID=$(echo "$TX_RESULT" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | contains("Amulet"))
       | select(.templateId | tostring | contains("AmuletRules") | not)
       | select(.templateId | tostring | contains("AmuletAllocation") | not)
       | select(.templateId | tostring | contains("AmuletTransfer") | not)
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")
  fi

  if [ -z "$AMULET_CID" ]; then
    log_error "Could not extract Amulet CID for $USER_ID"
    log_error "Events: $(echo "$TX_RESULT" | jq -c '[.transaction.events[] | (.CreatedEvent // .created // empty) | .templateId]' 2>/dev/null | head -c 300)"
    SKIPPED=$((${SKIPPED:-0} + 1))
    continue
  fi

  log "    Amulet CID: ${AMULET_CID:0:40}..."
  RESULTS+=("${RECIPIENT}|${USER_ID}|${AMOUNT}|${AMULET_CID}")
done

if [ "${SKIPPED:-0}" -gt 0 ]; then
  log "  WARNING: $SKIPPED/$NUM_TRANSFERS taps failed (see errors above)"
else
  log "  All $NUM_TRANSFERS taps succeeded"
fi

##############################################################################
# Step 3: Write results to fauceted-amulet.json
##############################################################################

log ""
log "Step 3: Writing results to $OUTPUT_FILE..."

REPORT=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg transfersFile "$TRANSFERS_FILE" \
  --argjson totalRecipients "$NUM_TRANSFERS" \
  '{
    generatedAt: $generatedAt,
    transfersFile: $transfersFile,
    totalRecipients: $totalRecipients,
    recipients: []
  }')

for entry in "${RESULTS[@]}"; do
  IFS='|' read -r PARTY_ID USER_ID AMOUNT AMULET_CID <<< "$entry"
  REPORT=$(echo "$REPORT" | jq \
    --arg partyId "$PARTY_ID" \
    --arg userId "$USER_ID" \
    --arg amount "$AMOUNT" \
    --arg amuletCid "$AMULET_CID" \
    '.recipients += [{ partyId: $partyId, userId: $userId, amount: $amount, amuletCid: $amuletCid }]')
done

GRAND_TOTAL=$(echo "$REPORT" | jq '[.recipients[].amount | tonumber] | add')
REPORT=$(echo "$REPORT" | jq --argjson total "$GRAND_TOTAL" '. + {totalAmountCC: $total}')

echo "$REPORT" | jq '.' > "$OUTPUT_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Amulet Faucet Complete!"
log "=========================================="
log ""
SUCCEEDED=${#RESULTS[@]}
log "Summary:"
log "  Recipients:     $SUCCEEDED / $NUM_TRANSFERS"
if [ "${SKIPPED:-0}" -gt 0 ]; then
  log "  Skipped (errors): $SKIPPED — re-run the script to retry"
fi
log "  Total CC:       $GRAND_TOTAL"
log "  Output:         $OUTPUT_FILE"
log ""
log "Verify:"
log "  jq '.' $OUTPUT_FILE"
