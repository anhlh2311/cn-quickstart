#!/bin/bash
# Allocates a trader party on the trading-partner participant, creates a
# TransferPreapproval, and faucets Amulet (CC) to the party.
#
# Steps:
#   1. Allocate party <PARTY_HINT_PREFIX>-0 on the trading-partner node
#   2. Create Canton user + grant ActAs/ReadAs rights
#   3. Create TransferPreapprovalProposal and wait for validator acceptance
#   4. Faucet FAUCET_AMOUNT Amulet via AmuletRules_DevNet_Tap (DevNet only)
#   5. Write internal-trader.json
#
# The output file (internal-trader.json) has the same shape as
# setup-internal-parties/internal-parties.json so other scripts can consume it
# as a drop-in replacement.
#
# Prerequisites:
#   - Quickstart localnet running (DevNet, trading-partner profile enabled)
#   - 01-setup-trading-partner.sh completed (DARs uploaded)
#   - .env configured (copy from .env.example)
#
# Environment variables (can be set in .env or inline):
#   PARTY_HINT_PREFIX   — Prefix for the party hint (default: trader)
#   FAUCET_AMOUNT       — Amulet amount to faucet (default: 1000000)
#
# Usage:
#   ./02-allocate-and-fund-trader.sh
#   PARTY_HINT_PREFIX=mytrader ./02-allocate-and-fund-trader.sh
#   FAUCET_AMOUNT=500000 ./02-allocate-and-fund-trader.sh

set -eo pipefail

RUN_ID=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[trader-setup] ERROR: $SCRIPT_DIR/.env not found. Copy .env.example to .env first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

TRADING_PARTNER_JSON_API="${TRADING_PARTNER_JSON_API:-http://localhost:1975}"
TRADING_PARTNER_VALIDATOR_API="${TRADING_PARTNER_VALIDATOR_API:-http://localhost:1903}"

PARTY_HINT_PREFIX="${PARTY_HINT_PREFIX:-trader}"
FAUCET_AMOUNT="${FAUCET_AMOUNT:-1000000}"
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"

OUTPUT_FILE="$SCRIPT_DIR/internal-trader.json"

AMULET_RULES_TEMPLATE="#splice-amulet:Splice.AmuletRules:AmuletRules"
PREAPPROVAL_PROPOSAL_TEMPLATE="#splice-wallet:Splice.Wallet.TransferPreapproval:TransferPreapprovalProposal"

# Source shared auth helpers
# shellcheck disable=SC1091
source "$SCRIPT_DIR/auth.sh"

##############################################################################
# Helper functions
##############################################################################

log() { echo "[trader-setup] $*"; }
log_error() { echo "[trader-setup] ERROR: $*" >&2; }

curl_check() {
  local url=$1 token=$2 content_type=${3:-application/json}
  shift 3
  local curl_args=(-s -S -w "\n%{http_code}" "$url")
  [ -n "$token" ] && curl_args+=(-H "Authorization: Bearer $token")
  curl_args+=(-H "Content-Type: $content_type")
  curl_args+=("$@")
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

curl_status_code() {
  local url=$1 token=$2
  curl -s -o /dev/null -w "%{http_code}" "$url" -H "Authorization: Bearer $token"
}

##############################################################################
# Pre-flight
##############################################################################

log "=========================================="
log "Allocate and Fund Trader"
log "=========================================="
log "  Party hint prefix: $PARTY_HINT_PREFIX"
log "  Faucet amount:     $FAUCET_AMOUNT CC"
log "  Participant:       $TRADING_PARTNER_JSON_API"
log "  Validator:         $TRADING_PARTNER_VALIDATOR_API"
log "  Auth mode:         ${AUTH_MODE:-shared-secret}"
log ""

ADMIN_TOKEN=$(get_participant_token)

VERSION=$(curl_check "$TRADING_PARTNER_JSON_API/v2/version" "" "application/json" 2>/dev/null \
  | jq -r '.version // empty') || VERSION=""
if [ -z "$VERSION" ]; then
  log_error "Cannot reach trading-partner participant at $TRADING_PARTNER_JSON_API"
  exit 1
fi
log "  Canton version: $VERSION"

# Resolve participant namespace
PARTICIPANT_ID=$(curl_check "$TRADING_PARTNER_JSON_API/v2/parties/participant-id" "$ADMIN_TOKEN" "application/json" \
  | jq -r '.participantId // empty')
if [ -z "$PARTICIPANT_ID" ]; then
  log_error "Could not get participant ID"
  exit 1
fi
NAMESPACE="${PARTICIPANT_ID#participant::}"
log "  Participant ID: $PARTICIPANT_ID"
log "  Namespace: ${NAMESPACE:0:40}..."

VALIDATOR_TOKEN=$(get_validator_token)

##############################################################################
# Step 1: Allocate party
##############################################################################

log ""
log "Step 1: Allocating party ${PARTY_HINT_PREFIX}-0..."

PARTY_HINT="${PARTY_HINT_PREFIX}-0"
EXPECTED_PARTY="${PARTY_HINT}::${NAMESPACE}"
USER_ID="${PARTY_HINT}"
DISPLAY_NAME="${PARTY_HINT_PREFIX} 0"

EXISTING_PARTY=$(curl_check "$TRADING_PARTNER_JSON_API/v2/parties/party?parties=$EXPECTED_PARTY" \
  "$ADMIN_TOKEN" "application/json" \
  | jq -r '.partyDetails[0].party // empty' 2>/dev/null || echo "")

if [ -n "$EXISTING_PARTY" ] && [ "$EXISTING_PARTY" != "null" ]; then
  PARTY_ID="$EXISTING_PARTY"
  log "  Party already exists: ${PARTY_ID:0:60}..."
else
  ALLOC_RESULT=$(curl_check "$TRADING_PARTNER_JSON_API/v2/parties" "$ADMIN_TOKEN" "application/json" \
    --data-raw "$(jq -n \
      --arg hint "$PARTY_HINT" \
      --arg name "$DISPLAY_NAME" \
      '{partyIdHint: $hint, displayName: $name, identityProviderId: ""}')") || {
    log_error "Failed to allocate party $PARTY_HINT"
    exit 1
  }
  PARTY_ID=$(echo "$ALLOC_RESULT" | jq -r '.partyDetails.party // empty')
  if [ -z "$PARTY_ID" ]; then
    log_error "Allocate succeeded but no partyId in response"
    log_error "Response: $(echo "$ALLOC_RESULT" | head -c 300)"
    exit 1
  fi
  log "  Allocated: ${PARTY_ID:0:60}..."
fi

##############################################################################
# Step 2: Create Canton user + grant rights
##############################################################################

log ""
log "Step 2: Creating Canton user and granting rights..."

# Grant admin user ActAs/ReadAs over this party
curl_check "$TRADING_PARTNER_JSON_API/v2/users/$ADMIN_USER/rights" "$ADMIN_TOKEN" "application/json" \
  --data-raw "$(jq -n \
    --arg userId "$ADMIN_USER" \
    --arg party "$PARTY_ID" \
    '{
      userId: $userId,
      identityProviderId: "",
      rights: [
        {kind: {CanActAs: {value: {party: $party}}}},
        {kind: {CanReadAs: {value: {party: $party}}}}
      ]
    }')" > /dev/null 2>&1 || true

USER_STATUS=$(curl_status_code "$TRADING_PARTNER_JSON_API/v2/users/$USER_ID" "$ADMIN_TOKEN")
if [ "$USER_STATUS" != "200" ]; then
  curl_check "$TRADING_PARTNER_JSON_API/v2/users" "$ADMIN_TOKEN" "application/json" \
    --data-raw "$(jq -n \
      --arg userId "$USER_ID" \
      --arg party "$PARTY_ID" \
      '{
        user: {
          id: $userId,
          isDeactivated: false,
          primaryParty: $party,
          identityProviderId: "",
          metadata: {resourceVersion: "", annotations: {username: $userId}}
        },
        rights: []
      }')" > /dev/null
  log "  User $USER_ID created"
else
  log "  User $USER_ID already exists"
fi

curl_check "$TRADING_PARTNER_JSON_API/v2/users/$USER_ID/rights" "$ADMIN_TOKEN" "application/json" \
  --data-raw "$(jq -n \
    --arg userId "$USER_ID" \
    --arg party "$PARTY_ID" \
    '{
      userId: $userId,
      identityProviderId: "",
      rights: [
        {kind: {CanActAs: {value: {party: $party}}}},
        {kind: {CanReadAs: {value: {party: $party}}}}
      ]
    }')" > /dev/null 2>&1 || true

log "  Rights granted for $USER_ID"

##############################################################################
# Step 3: Create TransferPreapproval
##############################################################################

log ""
log "Step 3: Creating TransferPreapproval for $PARTY_HINT..."

# Resolve provider party (primary party of admin user)
PROVIDER_PARTY=$(curl_check "$TRADING_PARTNER_JSON_API/v2/users/$ADMIN_USER" "$ADMIN_TOKEN" "application/json" \
  | jq -r '.user.primaryParty // empty')
if [ -z "$PROVIDER_PARTY" ]; then
  log_error "Could not resolve provider party from user $ADMIN_USER"
  exit 1
fi
log "  Provider (validator) party: ${PROVIDER_PARTY:0:50}..."

# Resolve DSO party
DSO_PARTY=$(curl_check "$TRADING_PARTNER_VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" \
  "$VALIDATOR_TOKEN" "application/json" \
  | jq -r '.dso_party_id // empty')
if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party from validator API"
  exit 1
fi
log "  DSO party: ${DSO_PARTY:0:50}..."

# Check if preapproval already exists
EXISTING_PA=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $VALIDATOR_TOKEN" \
  "$TRADING_PARTNER_VALIDATOR_API/api/validator/v0/admin/transfer-preapprovals/by-party/$PARTY_ID" \
  2>/dev/null || echo "")
EXISTING_PA_HTTP=$(echo "$EXISTING_PA" | tail -n1 | tr -d '\r')
EXISTING_PA_BODY=$(echo "$EXISTING_PA" | sed '$d')

PREAPPROVAL_CID=""
if [ "$EXISTING_PA_HTTP" = "200" ] && \
   echo "$EXISTING_PA_BODY" | jq -e '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id' > /dev/null 2>&1; then
  PREAPPROVAL_CID=$(echo "$EXISTING_PA_BODY" | jq -r \
    '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id')
  log "  TransferPreapproval already exists: ${PREAPPROVAL_CID:0:40}..."
else
  USER_TOKEN=$(get_user_token "$USER_ID")
  CMD_ID="transfer-preapproval-proposal-${PARTY_HINT}-${RUN_ID}"

  PROPOSAL_BODY=$(jq -n \
    --arg cmdId "$CMD_ID" \
    --arg party "$PARTY_ID" \
    --arg provider "$PROVIDER_PARTY" \
    --arg dso "$DSO_PARTY" \
    --arg templateId "$PREAPPROVAL_PROPOSAL_TEMPLATE" \
    '{
      commands: {
        commands: [{
          CreateCommand: {
            templateId: $templateId,
            createArguments: {
              receiver: $party,
              provider: $provider,
              expectedDso: $dso
            }
          }
        }],
        workflowId: "setup-trader",
        applicationId: "setup-trading-partner",
        commandId: $cmdId,
        deduplicationPeriod: { Empty: {} },
        actAs: [$party],
        readAs: [],
        submissionId: $cmdId,
        disclosedContracts: [],
        domainId: "",
        packageIdSelectionPreference: []
      }
    }')

  PROPOSAL_RESULT=$(curl_check "$TRADING_PARTNER_JSON_API/v2/commands/submit-and-wait-for-transaction" \
    "$USER_TOKEN" "application/json" --data-raw "$PROPOSAL_BODY") || {
    log_error "Failed to create TransferPreapprovalProposal for $PARTY_HINT"
    exit 1
  }

  PROPOSAL_CID=$(echo "$PROPOSAL_RESULT" | jq -r '
    [.transaction.events[] | select(.CreatedEvent) | .CreatedEvent.contractId][0] // empty')
  if [ -z "$PROPOSAL_CID" ]; then
    log_error "No contract ID in proposal creation response"
    exit 1
  fi
  log "  Proposal created: ${PROPOSAL_CID:0:40}..."

  log "  Waiting for validator to accept (timeout: ${POLL_TIMEOUT}s)..."
  ELAPSED=0
  POLL_INTERVAL=5
  while [ $ELAPSED -lt $POLL_TIMEOUT ]; do
    POLL_RESP=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $VALIDATOR_TOKEN" \
      "$TRADING_PARTNER_VALIDATOR_API/api/validator/v0/admin/transfer-preapprovals/by-party/$PARTY_ID" \
      2>/dev/null || echo "")
    POLL_HTTP=$(echo "$POLL_RESP" | tail -n1 | tr -d '\r')
    POLL_BODY=$(echo "$POLL_RESP" | sed '$d')

    if [ "$POLL_HTTP" = "200" ] && \
       echo "$POLL_BODY" | jq -e '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id' > /dev/null 2>&1; then
      PREAPPROVAL_CID=$(echo "$POLL_BODY" | jq -r \
        '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id')
      break
    fi

    # Fallback: query ledger directly
    LEDGER_OFFSET=$(curl -s "$TRADING_PARTNER_JSON_API/v2/state/ledger-end" \
      -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.offset // empty' 2>/dev/null || echo "")
    if [ -n "$LEDGER_OFFSET" ]; then
      LEDGER_RESP=$(curl -s "$TRADING_PARTNER_JSON_API/v2/state/active-contracts" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg party "$PARTY_ID" --argjson offset "$LEDGER_OFFSET" '{
          filter: { filtersByParty: { ($party): { cumulative: [{ identifierFilter: { TemplateFilter: { value: {
            templateId: "#splice-amulet:Splice.AmuletRules:TransferPreapproval",
            includeCreatedEventBlob: false }}}}]}}},
          verbose: false, activeAtOffset: $offset }')" 2>/dev/null || echo "")
      PREAPPROVAL_CID=$(echo "$LEDGER_RESP" | jq -r '
        [.[] | select(.contractEntry.JsActiveContract)
         | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty' 2>/dev/null || echo "")
      [ -n "$PREAPPROVAL_CID" ] && break
    fi

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ] && \
      log "  Still waiting... (${ELAPSED}s / ${POLL_TIMEOUT}s)"
  done

  if [ -z "$PREAPPROVAL_CID" ]; then
    log_error "Timeout after ${POLL_TIMEOUT}s waiting for TransferPreapproval acceptance"
    exit 1
  fi
  log "  TransferPreapproval accepted: ${PREAPPROVAL_CID:0:40}..."
fi

##############################################################################
# Step 4: Faucet Amulet
##############################################################################

log ""
log "Step 4: Fauceting $FAUCET_AMOUNT CC to $PARTY_HINT via DevNet tap..."

SCAN_RESPONSE=$(curl_check \
  "$TRADING_PARTNER_VALIDATOR_API/api/validator/v0/scan-proxy/registry/allocation-instruction/v1/allocation-factory" \
  "$VALIDATOR_TOKEN" "application/json" \
  --data-raw '{"choiceArguments":{},"excludeDebugFields":true}') || {
  log_error "Failed to fetch Amulet factory from scan-proxy"
  exit 1
}

AMULET_RULES_CID=$(echo "$SCAN_RESPONSE" | jq -r '
  .choiceContext.choiceContextData.values["amulet-rules"].value //
  .choiceContextData.values["amulet-rules"].value // empty')
OPEN_ROUND_CID=$(echo "$SCAN_RESPONSE" | jq -r '
  .choiceContext.choiceContextData.values["open-round"].value //
  .choiceContextData.values["open-round"].value // empty')
DISCLOSED_CONTRACTS=$(echo "$SCAN_RESPONSE" | jq -c '
  (.choiceContext.disclosedContracts // .disclosedContracts // [])
  | [.[] | {contractId, templateId, createdEventBlob, synchronizerId}]')

if [ -z "$AMULET_RULES_CID" ] || [ -z "$OPEN_ROUND_CID" ]; then
  log_error "Could not extract AmuletRules or OpenMiningRound CID from scan-proxy"
  log_error "Response: $(echo "$SCAN_RESPONSE" | head -c 500)"
  exit 1
fi
log "  AmuletRules CID: ${AMULET_RULES_CID:0:40}..."
log "  OpenMiningRound CID: ${OPEN_ROUND_CID:0:40}..."

USER_TOKEN=$(get_user_token "$USER_ID")
CMD_ID="faucet-amulet-${USER_ID}-${RUN_ID}"

TAP_BODY=$(jq -n \
  --arg templateId "$AMULET_RULES_TEMPLATE" \
  --arg contractId "$AMULET_RULES_CID" \
  --arg receiver "$PARTY_ID" \
  --arg amount "$FAUCET_AMOUNT" \
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

TAP_RESULT=$(curl_check "$TRADING_PARTNER_JSON_API/v2/commands/submit-and-wait-for-transaction" \
  "$USER_TOKEN" "application/json" --data-raw "$TAP_BODY") || {
  log_error "Failed to tap Amulet for $USER_ID"
  exit 1
}

AMULET_CID=$(echo "$TAP_RESULT" | jq -r '
  [.transaction.events[] | (.CreatedEvent // .created // empty)
   | select(.templateId | tostring | test("Splice\\.Amulet:Amulet$"))
   | .contractId][0] // empty' 2>/dev/null || echo "")

# Fallback: any Amulet-like contract (not AmuletRules/Allocation/Transfer)
if [ -z "$AMULET_CID" ]; then
  AMULET_CID=$(echo "$TAP_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | contains("Amulet"))
     | select(.templateId | tostring | contains("AmuletRules") | not)
     | select(.templateId | tostring | contains("AmuletAllocation") | not)
     | select(.templateId | tostring | contains("AmuletTransfer") | not)
     | .contractId][0] // empty' 2>/dev/null || echo "")
fi

if [ -z "$AMULET_CID" ]; then
  log_error "Could not extract Amulet CID from tap result"
  log_error "Events: $(echo "$TAP_RESULT" | jq -c \
    '[.transaction.events[] | (.CreatedEvent // .created // empty) | .templateId]' \
    2>/dev/null | head -c 300)"
  exit 1
fi
log "  Amulet CID: ${AMULET_CID:0:40}..."

##############################################################################
# Step 5: Write internal-trader.json
##############################################################################

log ""
log "Step 5: Writing $OUTPUT_FILE..."

jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg participantId "$PARTICIPANT_ID" \
  --arg participantJsonApi "$TRADING_PARTNER_JSON_API" \
  --arg validatorApi "$TRADING_PARTNER_VALIDATOR_API" \
  --arg partyHintPrefix "$PARTY_HINT_PREFIX" \
  --arg partyHint "$PARTY_HINT" \
  --arg partyId "$PARTY_ID" \
  --arg userId "$USER_ID" \
  --arg displayName "$DISPLAY_NAME" \
  --arg transferPreapprovalCid "$PREAPPROVAL_CID" \
  --arg faucetedAmount "$FAUCET_AMOUNT" \
  --arg faucetedAmuletCid "$AMULET_CID" \
  '{
    generatedAt: $generatedAt,
    participantId: $participantId,
    participantJsonApi: $participantJsonApi,
    validatorApi: $validatorApi,
    partyHintPrefix: $partyHintPrefix,
    parties: [{
      index: 0,
      partyHint: $partyHint,
      partyId: $partyId,
      userId: $userId,
      displayName: $displayName,
      transferPreapprovalCid: $transferPreapprovalCid,
      faucetedAmount: $faucetedAmount,
      faucetedAmuletCid: $faucetedAmuletCid
    }]
  }' > "$OUTPUT_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Trader Allocation and Funding Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Party:               $PARTY_ID"
log "  User:                $USER_ID"
log "  TransferPreapproval: ${PREAPPROVAL_CID:0:40}..."
log "  Fauceted:            $FAUCET_AMOUNT CC"
log "  Amulet CID:          ${AMULET_CID:0:40}..."
log "  Output:              $OUTPUT_FILE"
log ""
log "Next steps:"
log "  ./03-request-partner-api-key.sh"
