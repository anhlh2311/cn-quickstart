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

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

PARTICIPANT_JSON_API="${PARTICIPANT_JSON_API:-http://localhost:2975}"
VALIDATOR_API="${VALIDATOR_API:-http://localhost:2903}"
AUTH_MODE="${AUTH_MODE:-shared-secret}"
TRANSFERS_FILE="${TRANSFERS_FILE:-$SCRIPT_DIR/transfers.json}"
PREAPPROVALS_FILE="${PREAPPROVALS_FILE:-$SCRIPT_DIR/transfer-preapprovals.json}"

# Source shared auth helpers
source "$SCRIPT_DIR/auth.sh"

OUTPUT_FILE="$SCRIPT_DIR/distributed-amulet.json"

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

curl_check() {
  local url=$1
  local token=$2
  local content_type=${3:-application/json}
  shift 3
  local args=("$@")

  local curl_args=(-s -S -w "\n%{http_code}" "$url")
  if [ -n "$token" ]; then
    curl_args+=(-H "Authorization: Bearer $token")
  fi
  curl_args+=(-H "Content-Type: $content_type")
  curl_args+=("${args[@]}")

  local response
  response=$(curl "${curl_args[@]}")

  local http_code
  http_code=$(echo "$response" | tail -n1 | tr -d '\r')
  local response_body
  response_body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne "200" ] && [ "$http_code" -ne "201" ] && [ "$http_code" -ne "204" ]; then
    log_error "Request to $url failed with HTTP $http_code"
    log_error "Response: $response_body"
    return 1
  fi

  echo "$response_body"
}

# Query active contracts with includeCreatedEventBlob
query_active_contracts() {
  local json_api=$1
  local token=$2
  local party=$3
  local template_id=$4
  local verbose=${5:-false}

  local offset
  offset=$(curl_check "$json_api/v2/state/ledger-end" "$token" "application/json" | jq -r '.offset')

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

  curl_check "$json_api/v2/state/active-contracts" "$token" "application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
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
SENDER_PARTY=$(curl_check "$PARTICIPANT_JSON_API/v2/users/$ADMIN_USER" "$TOKEN" "application/json" \
  | jq -r '.user.primaryParty // empty')

if [ -z "$SENDER_PARTY" ]; then
  log_error "Could not resolve sender party from user $ADMIN_USER"
  exit 1
fi
log "  Sender: ${SENDER_PARTY:0:50}..."

# Resolve DSO party
DSO_PARTY=$(curl_check "$VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" "$VALIDATOR_TOKEN" "application/json" \
  | jq -r '.dso_party_id // empty')

if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party"
  exit 1
fi
log "  DSO: ${DSO_PARTY:0:50}..."

# Get synchronizer ID
SYNCHRONIZER_ID=$(curl_check "$PARTICIPANT_JSON_API/v2/state/connected-synchronizers" "$TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
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
AMULET_RULES_RESPONSE=$(curl_check "$VALIDATOR_API/api/validator/v0/scan-proxy/amulet-rules" "$VALIDATOR_TOKEN" "application/json")

AMULET_RULES_CID=$(echo "$AMULET_RULES_RESPONSE" | jq -r '.amulet_rules.contract_id // .amulet_rules.contractId // empty' 2>/dev/null || echo "")
AMULET_RULES_TEMPLATE_HASH=$(echo "$AMULET_RULES_RESPONSE" | jq -r '.amulet_rules.template_id // .amulet_rules.templateId // empty' 2>/dev/null || echo "")
AMULET_RULES_BLOB=$(echo "$AMULET_RULES_RESPONSE" | jq -r '.amulet_rules.created_event_blob // .amulet_rules.createdEventBlob // empty' 2>/dev/null || echo "")

if [ -z "$AMULET_RULES_CID" ] || [ -z "$AMULET_RULES_BLOB" ]; then
  log_error "Could not fetch AmuletRules from scan-proxy"
  log_error "Response: $(echo "$AMULET_RULES_RESPONSE" | head -c 500)"
  exit 1
fi
log "  AmuletRules: ${AMULET_RULES_CID:0:40}..."

# Fetch OpenMiningRound via scan-proxy on the validator API
OPEN_ROUNDS_RESPONSE=$(curl_check "$VALIDATOR_API/api/validator/v0/scan-proxy/open-and-issuing-mining-rounds" "$VALIDATOR_TOKEN" "application/json")

# Pick the lowest (earliest/already-open) round
OPEN_ROUND_CID=$(echo "$OPEN_ROUNDS_RESPONSE" | jq -r '
  [.open_mining_rounds[]
   | { contract_id, round: (.payload.round // .round // 0) }]
  | sort_by(.round) | first | .contract_id // empty
' 2>/dev/null || echo "")

OPEN_ROUND_TEMPLATE_HASH=$(echo "$OPEN_ROUNDS_RESPONSE" | jq -r '
  .open_mining_rounds[0].template_id // .open_mining_rounds[0].templateId // empty
' 2>/dev/null || echo "")

OPEN_ROUND_BLOB=$(echo "$OPEN_ROUNDS_RESPONSE" | jq -r '
  [.open_mining_rounds[]
   | { created_event_blob, round: (.payload.round // .round // 0) }]
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

  TX_RESULT=$(curl_check "$PARTICIPANT_JSON_API/v2/commands/submit-and-wait-for-transaction" \
    "$TOKEN" "application/json" --data-raw "$SUBMIT_BODY") || {
    log_error "Failed to transfer $AMOUNT CC to $RECIPIENT_SHORT (transfer #$((i+1)))"
    exit 1
  }

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
    exit 1
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
      rm -f "$HOLDINGS_TRACKER"
      exit 1
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
log "Summary:"
log "  Transfers completed: $TOTAL_TRANSFERS"
log "  Total distributed: $(jq '[.transfers[].amount | tonumber] | add // 0' "$OUTPUT_FILE") CC"
log "  Output file: $OUTPUT_FILE"
log ""
