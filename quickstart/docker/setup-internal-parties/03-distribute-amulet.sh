#!/bin/bash
# Transfers Amulet (CC) from the node's participant party to a list of recipients.
#
# Uses TransferPreapproval_Send to transfer Amulet from the sender (participant's
# validator party) to each recipient. Recipients must have TransferPreapproval
# contracts (created by 02-create-transfer-preapprovals.sh).
#
# The sender's Amulet holdings are consumed as inputs, and change Amulet is
# tracked across transfers to minimize re-querying.
#
# Input JSON format (default: transfers.json):
#   [
#     { "recipient": "trader-0::1220...", "amount": "100.0" },
#     { "recipient": "trader-0::1220...", "amount": "50.0" },
#     { "recipient": "trader-1::1220...", "amount": "200.0" }
#   ]
#
# A recipient can appear multiple times (creates multiple Amulet holdings).
#
# Prerequisites:
#   - Quickstart must be running
#   - 02-create-transfer-preapprovals.sh must have been run (TransferPreapprovals exist)
#   - The sender (participant validator party) must have sufficient Amulet holdings
#
# Environment variables:
#   PARTICIPANT_JSON_API  — Canton JSON API URL (default: http://localhost:2975)
#   VALIDATOR_API         — Validator Admin API (default: http://localhost:2903)
#   TRANSFERS_FILE        — Path to input JSON file (default: ./transfers.json)
#   PREAPPROVALS_FILE     — Path to transfer-preapprovals.json (default: ./transfer-preapprovals.json)
#
# Usage:
#   ./03-distribute-amulet.sh
#   TRANSFERS_FILE=my-transfers.json ./03-distribute-amulet.sh
#   PREAPPROVALS_FILE=./transfer-preapprovals.mainnet.json ./03-distribute-amulet.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Save caller-provided env vars before sourcing .env (CLI overrides take precedence)
_cli_PARTICIPANT_JSON_API="${PARTICIPANT_JSON_API:-}"
_cli_VALIDATOR_API="${VALIDATOR_API:-}"
_cli_AUTH_MODE="${AUTH_MODE:-}"
_cli_TRANSFERS_FILE="${TRANSFERS_FILE:-}"
_cli_PREAPPROVALS_FILE="${PREAPPROVALS_FILE:-}"
_cli_OUTPUT_FILE="${OUTPUT_FILE:-}"

if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

# CLI overrides > .env > defaults
PARTICIPANT_JSON_API="${_cli_PARTICIPANT_JSON_API:-${PARTICIPANT_JSON_API:-http://localhost:2975}}"
VALIDATOR_API="${_cli_VALIDATOR_API:-${VALIDATOR_API:-http://localhost:2903}}"
AUTH_MODE="${_cli_AUTH_MODE:-${AUTH_MODE:-shared-secret}}"
TRANSFERS_FILE="${_cli_TRANSFERS_FILE:-${TRANSFERS_FILE:-$SCRIPT_DIR/transfers.json}}"
PREAPPROVALS_FILE="${_cli_PREAPPROVALS_FILE:-${PREAPPROVALS_FILE:-$SCRIPT_DIR/transfer-preapprovals.json}}"

# Source shared auth helpers
source "$SCRIPT_DIR/auth.sh"

OUTPUT_FILE="${_cli_OUTPUT_FILE:-${OUTPUT_FILE:-$SCRIPT_DIR/distributed-amulet.json}}"

# Daml template IDs
AMULET_TEMPLATE="#splice-amulet:Splice.Amulet:Amulet"
TRANSFER_PREAPPROVAL_TEMPLATE="#splice-amulet:Splice.AmuletRules:TransferPreapproval"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[distribute-amulet] $*"
}

log_error() {
  echo "[distribute-amulet] ERROR: $*" >&2
}

# Query active contracts with includeCreatedEventBlob
query_active_contracts() {
  local json_api=$1
  local token=$2
  local party=$3
  local template_id=$4
  local verbose=${5:-false}

  local offset_resp
  offset_resp=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "$json_api/v2/state/ledger-end" 2>/dev/null || echo "")
  local offset_http
  offset_http=$(echo "$offset_resp" | tail -n1 | tr -d '\r')
  if [ "$offset_http" != "200" ]; then
    log_error "Failed to get ledger end (HTTP $offset_http)"
    echo ""
    return
  fi
  local offset
  offset=$(echo "$offset_resp" | sed '$d' | jq -r '.offset')

  local query_body
  query_body=$(jq -n \
    --arg party "$party" \
    --arg offset "$offset" \
    --arg templateId "$template_id" \
    --argjson verbose "$verbose" \
    '{
      filter: {
        filtersByParty: {
          ($party): {
            cumulative: [{
              identifierFilter: {
                TemplateFilter: {
                  value: {
                    templateId: $templateId,
                    includeCreatedEventBlob: true
                  }
                }
              }
            }]
          }
        }
      },
      verbose: $verbose,
      activeAtOffset: $offset
    }')

  local acs_resp
  acs_resp=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "$json_api/v2/state/active-contracts" \
    --data-raw "$query_body" 2>/dev/null || echo "")
  local acs_http
  acs_http=$(echo "$acs_resp" | tail -n1 | tr -d '\r')
  if [ "$acs_http" != "200" ]; then
    log_error "Failed to query active contracts (HTTP $acs_http)"
    echo ""
    return
  fi
  echo "$acs_resp" | sed '$d'
}

##############################################################################
# Pre-flight checks
##############################################################################

log "=========================================="
log "Distribute Amulet (TransferPreapproval_Send)"
log "=========================================="

if [ ! -f "$TRANSFERS_FILE" ]; then
  log_error "Transfers file not found: $TRANSFERS_FILE"
  log_error "Create a JSON file with: [{\"recipient\": \"party-id\", \"amount\": \"100.0\"}, ...]"
  exit 1
fi

if [ ! -f "$PREAPPROVALS_FILE" ]; then
  log_error "Preapprovals file not found: $PREAPPROVALS_FILE"
  log_error "Run 02-create-transfer-preapprovals.sh first."
  exit 1
fi

TOTAL_TRANSFERS=$(jq 'length' "$TRANSFERS_FILE")
if [ "$TOTAL_TRANSFERS" -eq 0 ]; then
  log_error "Transfers file is empty"
  exit 1
fi

log "  Transfers: $TOTAL_TRANSFERS"
log "  Input file: $TRANSFERS_FILE"
log "  Participant: $PARTICIPANT_JSON_API"
log "  Auth mode: $AUTH_MODE"
log ""

TOKEN=$(get_participant_token)
VALIDATOR_TOKEN=$(get_validator_token)

# Resolve sender party (participant's validator party)
ADMIN_USER="${ADMIN_USER:-${SHARED_SECRET_USER:-ledger-api-user}}"
SENDER_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$PARTICIPANT_JSON_API/v2/users/$ADMIN_USER" 2>/dev/null || echo "")
SENDER_HTTP=$(echo "$SENDER_RESP" | tail -n1 | tr -d '\r')
SENDER_BODY=$(echo "$SENDER_RESP" | sed '$d')

if [ "$SENDER_HTTP" != "200" ]; then
  log_error "Could not resolve sender party from user $ADMIN_USER (HTTP $SENDER_HTTP)"
  log_error "Response: $(echo "$SENDER_BODY" | head -c 300)"
  exit 1
fi
SENDER_PARTY=$(echo "$SENDER_BODY" | jq -r '.user.primaryParty // empty')
if [ -z "$SENDER_PARTY" ]; then
  log_error "User $ADMIN_USER has no primaryParty set"
  exit 1
fi
log "  Sender: ${SENDER_PARTY:0:50}..."

# Resolve DSO party
DSO_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $VALIDATOR_TOKEN" \
  -H "Content-Type: application/json" \
  "$VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" 2>/dev/null || echo "")
DSO_HTTP=$(echo "$DSO_RESP" | tail -n1 | tr -d '\r')
DSO_BODY=$(echo "$DSO_RESP" | sed '$d')

if [ "$DSO_HTTP" != "200" ]; then
  log_error "Could not resolve DSO party (HTTP $DSO_HTTP)"
  log_error "Response: $(echo "$DSO_BODY" | head -c 300)"
  exit 1
fi
DSO_PARTY=$(echo "$DSO_BODY" | jq -r '.dso_party_id // empty')
if [ -z "$DSO_PARTY" ]; then
  log_error "DSO party ID not found in validator response"
  exit 1
fi
log "  DSO: ${DSO_PARTY:0:50}..."

# Get synchronizer ID
SYNC_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$PARTICIPANT_JSON_API/v2/state/connected-synchronizers" 2>/dev/null || echo "")
SYNC_HTTP=$(echo "$SYNC_RESP" | tail -n1 | tr -d '\r')
SYNC_BODY=$(echo "$SYNC_RESP" | sed '$d')

if [ "$SYNC_HTTP" != "200" ]; then
  log_error "Could not get connected synchronizers (HTTP $SYNC_HTTP)"
  log_error "Response: $(echo "$SYNC_BODY" | head -c 300)"
  exit 1
fi
SYNCHRONIZER_ID=$(echo "$SYNC_BODY" | jq -r '.connectedSynchronizers[0].synchronizerId // empty')
if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "No connected synchronizers found"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

# Build preapproval lookup map from file: { partyId -> transferPreapprovalCid }
PREAPPROVAL_MAP=$(jq -c '[.preapprovals[] | {key: .partyId, value: .transferPreapprovalCid}] | from_entries' "$PREAPPROVALS_FILE")

# Validate all recipients have preapprovals
for i in $(seq 0 $((TOTAL_TRANSFERS - 1))); do
  RECIPIENT=$(jq -r ".[$i].recipient" "$TRANSFERS_FILE")
  PREAPPROVAL_CID=$(echo "$PREAPPROVAL_MAP" | jq -r --arg r "$RECIPIENT" '.[$r] // empty')
  if [ -z "$PREAPPROVAL_CID" ]; then
    log_error "No TransferPreapproval found for recipient: $RECIPIENT"
    log_error "Run 02-create-transfer-preapprovals.sh first, or check $PREAPPROVALS_FILE"
    exit 1
  fi
done
log "  All recipients have TransferPreapprovals."

##############################################################################
# Step 1: Fetch AmuletRules + OpenMiningRound via scan-proxy
##############################################################################

log ""
log "Step 1: Fetching AmuletRules + OpenMiningRound from scan-proxy..."

# Fetch AmuletRules via scan-proxy on the validator API
AR_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $VALIDATOR_TOKEN" \
  -H "Content-Type: application/json" \
  "$VALIDATOR_API/api/validator/v0/scan-proxy/amulet-rules" 2>/dev/null || echo "")
AR_HTTP=$(echo "$AR_RESP" | tail -n1 | tr -d '\r')
AMULET_RULES_RESPONSE=$(echo "$AR_RESP" | sed '$d')

if [ "$AR_HTTP" != "200" ]; then
  log_error "Could not fetch AmuletRules from scan-proxy (HTTP $AR_HTTP)"
  log_error "Response: $(echo "$AMULET_RULES_RESPONSE" | head -c 300)"
  exit 1
fi

# Response format: { amulet_rules: { contract: { contract_id, template_id, created_event_blob, payload } } }
AMULET_RULES_CID=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  .amulet_rules.contract.contract_id // .amulet_rules.contract_id // .amulet_rules.contractId // empty
' 2>/dev/null || echo "")
AMULET_RULES_TEMPLATE_HASH=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  .amulet_rules.contract.template_id // .amulet_rules.template_id // .amulet_rules.templateId // empty
' 2>/dev/null || echo "")
AMULET_RULES_BLOB=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  .amulet_rules.contract.created_event_blob // .amulet_rules.created_event_blob // .amulet_rules.createdEventBlob // empty
' 2>/dev/null || echo "")

if [ -z "$AMULET_RULES_CID" ] || [ -z "$AMULET_RULES_BLOB" ]; then
  log_error "Could not fetch AmuletRules from scan-proxy"
  log_error "Response: $(echo "$AMULET_RULES_RESPONSE" | head -c 500)"
  exit 1
fi
log "  AmuletRules: ${AMULET_RULES_CID:0:40}..."

# Fetch OpenMiningRound via scan-proxy on the validator API
OR_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $VALIDATOR_TOKEN" \
  -H "Content-Type: application/json" \
  "$VALIDATOR_API/api/validator/v0/scan-proxy/open-and-issuing-mining-rounds" 2>/dev/null || echo "")
OR_HTTP=$(echo "$OR_RESP" | tail -n1 | tr -d '\r')
OPEN_ROUNDS_RESPONSE=$(echo "$OR_RESP" | sed '$d')

if [ "$OR_HTTP" != "200" ]; then
  log_error "Could not fetch OpenMiningRound from scan-proxy (HTTP $OR_HTTP)"
  log_error "Response: $(echo "$OPEN_ROUNDS_RESPONSE" | head -c 300)"
  exit 1
fi

# Response format: { open_mining_rounds: [{ contract: { contract_id, template_id, created_event_blob, payload } }] }
# Pick the lowest (earliest/already-open) round
OPEN_ROUND_CID=$(echo "$OPEN_ROUNDS_RESPONSE" | jq -r '
  [.open_mining_rounds[]
   | { contract_id: (.contract.contract_id // .contract_id),
       round: (.contract.payload.round // .payload.round // .round // 0) }]
  | sort_by(.round) | first | .contract_id // empty
' 2>/dev/null || echo "")

OPEN_ROUND_TEMPLATE_HASH=$(echo "$OPEN_ROUNDS_RESPONSE" | jq -r '
  [.open_mining_rounds[]
   | { template_id: (.contract.template_id // .template_id),
       round: (.contract.payload.round // .payload.round // .round // 0) }]
  | sort_by(.round) | first | .template_id // empty
' 2>/dev/null || echo "")

OPEN_ROUND_BLOB=$(echo "$OPEN_ROUNDS_RESPONSE" | jq -r '
  [.open_mining_rounds[]
   | { created_event_blob: (.contract.created_event_blob // .created_event_blob),
       round: (.contract.payload.round // .payload.round // .round // 0) }]
  | sort_by(.round) | first | .created_event_blob // empty
' 2>/dev/null || echo "")

if [ -z "$OPEN_ROUND_CID" ] || [ -z "$OPEN_ROUND_BLOB" ]; then
  log_error "Could not fetch OpenMiningRound from scan-proxy"
  log_error "Response: $(echo "$OPEN_ROUNDS_RESPONSE" | head -c 500)"
  exit 1
fi
log "  OpenMiningRound: ${OPEN_ROUND_CID:0:40}..."

DISCLOSED_CONTRACTS=$(jq -n \
  --arg arCid "$AMULET_RULES_CID" \
  --arg arTemplate "$AMULET_RULES_TEMPLATE_HASH" \
  --arg arBlob "$AMULET_RULES_BLOB" \
  --arg orCid "$OPEN_ROUND_CID" \
  --arg orTemplate "$OPEN_ROUND_TEMPLATE_HASH" \
  --arg orBlob "$OPEN_ROUND_BLOB" \
  --arg syncId "$SYNCHRONIZER_ID" \
  '[
    { contractId: $arCid, templateId: $arTemplate, createdEventBlob: $arBlob, synchronizerId: $syncId },
    { contractId: $orCid, templateId: $orTemplate, createdEventBlob: $orBlob, synchronizerId: $syncId }
  ]')

##############################################################################
# Step 2: Verify sender has Amulet holdings
##############################################################################

log ""
log "Step 2: Checking sender's Amulet holdings..."

# Helper: query sender's current Amulet holdings (re-queried before each transfer)
query_sender_holdings() {
  local resp
  resp=$(query_active_contracts "$PARTICIPANT_JSON_API" "$TOKEN" \
    "$SENDER_PARTY" "$AMULET_TEMPLATE" false)
  echo "$resp" | jq -c '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
     | { contractId: .contractId, amount: (.createArgument.amount.initialAmount // .createArgument.amount // "0" | tostring) }]
    | sort_by(-(.amount | tonumber))
  ' 2>/dev/null || echo "[]"
}

INITIAL_HOLDINGS=$(query_sender_holdings)
HOLDING_COUNT=$(echo "$INITIAL_HOLDINGS" | jq 'length')
TOTAL_BALANCE=$(echo "$INITIAL_HOLDINGS" | jq '[.[].amount | tonumber] | add // 0')

if [ "$HOLDING_COUNT" -eq 0 ]; then
  log_error "Sender has no Amulet holdings"
  log_error "Tap Amulet first: exercise AmuletRules_DevNet_Tap for the sender party"
  exit 1
fi

TOTAL_REQUESTED=$(jq '[.[].amount | tonumber] | add // 0' "$TRANSFERS_FILE")
log "  Holdings: $HOLDING_COUNT"
log "  Sender balance: $TOTAL_BALANCE CC"
log "  Total requested: $TOTAL_REQUESTED CC (+ fees)"

##############################################################################
# Step 3: Execute transfers via TransferPreapproval_Send
##############################################################################

log ""
log "Step 3: Transferring Amulet to $TOTAL_TRANSFERS recipients..."

jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg participant "$PARTICIPANT_JSON_API" \
  --arg sender "$SENDER_PARTY" \
  --arg dso "$DSO_PARTY" \
  --arg inputFile "$TRANSFERS_FILE" \
  '{
    generatedAt: $generatedAt,
    participantJsonApi: $participant,
    senderParty: $sender,
    dsoParty: $dso,
    inputFile: $inputFile,
    transfers: []
  }' > "$OUTPUT_FILE"

for i in $(seq 0 $((TOTAL_TRANSFERS - 1))); do
  RECIPIENT=$(jq -r ".[$i].recipient" "$TRANSFERS_FILE")
  AMOUNT=$(jq -r ".[$i].amount" "$TRANSFERS_FILE")
  RECIPIENT_SHORT="${RECIPIENT%%::*}"

  # Ensure amount has decimal point
  if ! echo "$AMOUNT" | grep -q '\.'; then
    AMOUNT="${AMOUNT}.0"
  fi

  # Look up TransferPreapproval CID for this recipient
  PREAPPROVAL_CID=$(echo "$PREAPPROVAL_MAP" | jq -r --arg r "$RECIPIENT" '.[$r]')

  # Query sender's current holdings fresh before each transfer
  CURRENT_HOLDINGS=$(query_sender_holdings)

  # Find the best holding: first one with enough balance
  AMOUNT_NUM=$(echo "$AMOUNT" | awk '{printf "%.0f", $1}')
  INPUT_CID=$(echo "$CURRENT_HOLDINGS" | jq -r --argjson needed "$AMOUNT_NUM" '
    [.[] | select((.amount | tonumber | floor) >= $needed)][0].contractId // empty
  ')

  if [ -z "$INPUT_CID" ]; then
    # No single holding is large enough — try the largest available
    INPUT_CID=$(echo "$CURRENT_HOLDINGS" | jq -r '.[0].contractId // empty')
    if [ -z "$INPUT_CID" ]; then
      log_error "No Amulet holdings available for transfer #$((i+1)) ($AMOUNT CC to $RECIPIENT_SHORT)"
      log_error "Sender may have run out of Amulet."
      exit 1
    fi
    INPUT_AMOUNT=$(echo "$CURRENT_HOLDINGS" | jq -r '.[0].amount')
    log_error "Largest holding ($INPUT_AMOUNT CC) may not cover $AMOUNT CC + fees for transfer #$((i+1))"
    log_error "Attempting anyway..."
  fi

  CMD_ID="transfer-amulet-${i}-$(date +%s)-$RANDOM"

  SUBMIT_BODY=$(jq -n \
    --arg cmdId "$CMD_ID" \
    --arg sender "$SENDER_PARTY" \
    --arg preapprovalCid "$PREAPPROVAL_CID" \
    --arg preapprovalTemplate "$TRANSFER_PREAPPROVAL_TEMPLATE" \
    --arg amuletRulesCid "$AMULET_RULES_CID" \
    --arg openRoundCid "$OPEN_ROUND_CID" \
    --arg inputCid "$INPUT_CID" \
    --arg amount "$AMOUNT" \
    --argjson disclosedContracts "$DISCLOSED_CONTRACTS" \
    '{
      commands: {
        commands: [{
          ExerciseCommand: {
            templateId: $preapprovalTemplate,
            contractId: $preapprovalCid,
            choice: "TransferPreapproval_Send",
            choiceArgument: {
              sender: $sender,
              context: {
                amuletRules: $amuletRulesCid,
                context: {
                  openMiningRound: $openRoundCid,
                  issuingMiningRounds: [],
                  validatorRights: [],
                  featuredAppRight: null
                }
              },
              inputs: [{ tag: "InputAmulet", value: $inputCid }],
              amount: $amount,
              description: "distribute-amulet"
            }
          }
        }],
        workflowId: "distribute-amulet",
        applicationId: "setup-internal-parties",
        commandId: $cmdId,
        deduplicationPeriod: { Empty: {} },
        actAs: [$sender],
        readAs: [],
        submissionId: $cmdId,
        disclosedContracts: $disclosedContracts,
        domainId: "",
        packageIdSelectionPreference: []
      }
    }')

  TX_RESP=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$PARTICIPANT_JSON_API/v2/commands/submit-and-wait-for-transaction" \
    --data-raw "$SUBMIT_BODY" 2>/dev/null || echo "")
  TX_HTTP=$(echo "$TX_RESP" | tail -n1 | tr -d '\r')
  TX_RESULT=$(echo "$TX_RESP" | sed '$d')

  if [ "$TX_HTTP" != "200" ] && [ "$TX_HTTP" != "201" ]; then
    log_error "Failed to transfer $AMOUNT CC to $RECIPIENT_SHORT (transfer #$((i+1)), HTTP $TX_HTTP)"
    log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
    SKIPPED=$((${SKIPPED:-0} + 1))
    continue
  fi

  # Extract all created Amulet contracts from the transaction
  # submit-and-wait-for-transaction returns verbose format: createArguments (not createArgument)
  # Amulet.owner is a plain string party ID
  CREATED_AMULETS=$(echo "$TX_RESULT" | jq -c '
    [.transaction.events[]
     | (.CreatedEvent // empty)
     | select(.templateId | tostring | test("Splice[./]Amulet:Amulet$"))
     | { contractId, owner: (.createArguments.owner // .createArgument.owner // ""),
         amount: (.createArguments.amount.initialAmount // .createArgument.amount.initialAmount // "0") }]
  ' 2>/dev/null || echo "[]")

  NUM_CREATED=$(echo "$CREATED_AMULETS" | jq 'length')

  if [ "$NUM_CREATED" -eq 0 ]; then
    log_error "No Amulet contracts created in transfer #$((i+1))"
    log_error "Response events: $(echo "$TX_RESULT" | jq -c '[.transaction.events[] | keys]' 2>/dev/null | head -c 500)"
    SKIPPED=$((${SKIPPED:-0} + 1))
    continue
  fi

  # Identify receiver's Amulet vs sender's change Amulet
  if [ "$NUM_CREATED" -eq 1 ]; then
    # Only one Amulet created — it's the receiver's (no change returned)
    RECEIVER_AMULET_CID=$(echo "$CREATED_AMULETS" | jq -r '.[0].contractId')
    CHANGE_CID=""
    CHANGE_AMOUNT=""
  else
    # Multiple Amulets: match receiver by owner, the other is change
    RECEIVER_AMULET_CID=$(echo "$CREATED_AMULETS" | jq -r --arg receiver "$RECIPIENT" '
      [.[] | select(.owner == $receiver) | .contractId][0] // empty
    ')
    # Fallback: pick the one NOT owned by sender
    if [ -z "$RECEIVER_AMULET_CID" ]; then
      RECEIVER_AMULET_CID=$(echo "$CREATED_AMULETS" | jq -r --arg sender "$SENDER_PARTY" '
        [.[] | select(.owner != $sender) | .contractId][0] // empty
      ')
    fi
    if [ -z "$RECEIVER_AMULET_CID" ]; then
      log_error "Could not identify receiver's Amulet from transfer #$((i+1))"
      SKIPPED=$((${SKIPPED:-0} + 1))
      continue
    fi

    # Change is the other Amulet (owned by sender)
    CHANGE_CID=$(echo "$CREATED_AMULETS" | jq -r --arg rcid "$RECEIVER_AMULET_CID" '
      [.[] | select(.contractId != $rcid)][0].contractId // empty
    ')
    CHANGE_AMOUNT=$(echo "$CREATED_AMULETS" | jq -r --arg rcid "$RECEIVER_AMULET_CID" '
      [.[] | select(.contractId != $rcid)][0].amount // "0"
    ')
  fi

  # Record in output
  jq --arg recipient "$RECIPIENT" \
    --arg amount "$AMOUNT" \
    --arg receiverCid "$RECEIVER_AMULET_CID" \
    --arg inputCid "$INPUT_CID" \
    --arg changeCid "$CHANGE_CID" \
    --arg changeAmount "$CHANGE_AMOUNT" \
    --argjson index "$i" \
    '.transfers += [{
      index: $index,
      recipient: $recipient,
      amount: $amount,
      amuletContractId: $receiverCid,
      inputHoldingCid: $inputCid,
      changeCid: (if $changeCid == "" then null else $changeCid end),
      changeAmount: (if $changeAmount == "" then null else $changeAmount end)
    }]' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp" \
    && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

  CHANGE_INFO=""
  if [ -n "$CHANGE_CID" ]; then
    CHANGE_INFO=" (change: ${CHANGE_AMOUNT} CC)"
  fi
  log "  [$((i+1))/$TOTAL_TRANSFERS] $RECIPIENT_SHORT: $AMOUNT CC -> ${RECEIVER_AMULET_CID:0:30}...${CHANGE_INFO}"
done

##############################################################################
# Done
##############################################################################

REMAINING_COUNT=$(jq '[.transfers[].changeCid | select(. != null)] | last // empty' "$OUTPUT_FILE" 2>/dev/null || echo "")

log ""
log "=========================================="
log "Amulet Distribution Complete!"
log "=========================================="
log ""
COMPLETED=$(jq '.transfers | length' "$OUTPUT_FILE")
log "Summary:"
log "  Transfers completed: $COMPLETED / $TOTAL_TRANSFERS"
if [ "${SKIPPED:-0}" -gt 0 ]; then
  log "  Skipped (errors): $SKIPPED — re-run the script to retry failed transfers"
fi
log "  Total distributed: $(jq '[.transfers[].amount | tonumber] | add // 0' "$OUTPUT_FILE") CC"
log "  Output file: $OUTPUT_FILE"
log ""
