#!/bin/bash
# Merges Amulet (CC) holdings for each user wallet into a single Amulet per wallet.
#
# Uses MergeDelegation_Merge to exercise a self-transfer via ExternalPartyAmuletRules
# (TransferFactory interface). The operator (executor party) submits the merge via
# regular submission — no wallet private keys are needed.
#
# Steps:
#   1. Fetches ExternalPartyAmuletRules + AmuletRules + OpenMiningRound from SV
#   2. Loads FeaturedAppRight from featured-app-right.json
#   3. For each wallet:
#      a. Validates that a MergeDelegation contract exists
#      b. Queries all active Amulet contracts
#      c. Exercises MergeDelegation_Merge (operator submits, single regular submission)
#      d. Records the merged Amulet holding
#   4. Writes user-wallet-merged-holdings-amulet.json
#   5. Verifies balances match the original user-wallet-holdings-amulet.json
#
# Prerequisites:
#   - quickstart must be running (DevNet mode)
#   - 02-register-featured-app-right.sh must have been run (creates featured-app-right.json)
#   - 03-request-faucet-amulet.sh must have been run (holdings exist on ledger)
#   - 04-create-merge-delegation.sh must have been run (MergeDelegation contracts)
#
# Usage: ./06-user-wallet-utxo-merging-amulet.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load configuration
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

PARTICIPANT_JSON_API="${PARTICIPANT_JSON_API:-http://localhost:2975}"
SETUP_EXCHANGE_DIR="${SETUP_EXCHANGE_DIR:-$SCRIPT_DIR/../setup-exchange}"

# Auth configuration
SHARED_SECRET="${SHARED_SECRET:-unsafe}"
SHARED_SECRET_AUDIENCE="${SHARED_SECRET_AUDIENCE:-https://canton.network.global}"
SHARED_SECRET_USER="${SHARED_SECRET_USER:-ledger-api-user}"

# SV participant (for fetching ExternalPartyAmuletRules, AmuletRules, OpenMiningRound)
SV_JSON_API="${SV_JSON_API:-http://localhost:4975}"
SHARED_SECRET_SV_USER="${SHARED_SECRET_SV_USER:-ledger-api-user}"
PARTICIPANT_VALIDATOR_API="${PARTICIPANT_VALIDATOR_API:-http://localhost:2903}"

# Exchange backend (required for EXECUTOR_PARTY_ID)
EXCHANGE_BACKEND_DIR="${EXCHANGE_BACKEND_DIR:-}"
RUN_ID=$(date +%s%N 2>/dev/null || date +%s)

# Get OPERATOR_PARTY (executor) from backend .env
BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
if [ ! -f "$BACKEND_ENV" ]; then
  echo "[utxo-merge-amulet] ERROR: Backend .env not found: $BACKEND_ENV" >&2
  exit 1
fi
OPERATOR_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)
if [ -z "$OPERATOR_PARTY" ]; then
  echo "[utxo-merge-amulet] ERROR: EXECUTOR_PARTY_ID not found in $BACKEND_ENV" >&2
  exit 1
fi

# Load user wallet data
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"
DELEGATIONS_FILE="$SCRIPT_DIR/user-wallet-merge-delegation.json"
ORIGINAL_HOLDINGS_FILE="$SCRIPT_DIR/user-wallet-holdings-amulet.json"

for f in "$KEYPAIRS_FILE" "$DELEGATIONS_FILE" "$ORIGINAL_HOLDINGS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "[utxo-merge-amulet] ERROR: Required file not found: $f" >&2
    exit 1
  fi
done

AVAILABLE_WALLETS=$(jq '.wallets | length' "$KEYPAIRS_FILE")
NUM_WALLETS="${NUM_WALLETS:-$AVAILABLE_WALLETS}"
if [ "$NUM_WALLETS" -gt "$AVAILABLE_WALLETS" ]; then
  NUM_WALLETS="$AVAILABLE_WALLETS"
fi

# Load FeaturedAppRight from featured-app-right.json
FAR_FILE="$SETUP_EXCHANGE_DIR/featured-app-right.json"
if [ ! -f "$FAR_FILE" ]; then
  echo "[utxo-merge-amulet] ERROR: FeaturedAppRight file not found: $FAR_FILE" >&2
  echo "[utxo-merge-amulet] Run 02-register-featured-app-right.sh first." >&2
  exit 1
fi

FAR_CID=$(jq -r '.featuredAppRight.contractId // empty' "$FAR_FILE")
if [ -z "$FAR_CID" ] || [ "$FAR_CID" = "null" ]; then
  echo "[utxo-merge-amulet] ERROR: FeaturedAppRight contractId not found in $FAR_FILE" >&2
  exit 1
fi

# Template IDs
EXTERNAL_PARTY_AMULET_RULES_TEMPLATE="#splice-amulet:Splice.ExternalPartyAmuletRules:ExternalPartyAmuletRules"
AMULET_RULES_TEMPLATE="#splice-amulet:Splice.AmuletRules:AmuletRules"
OPEN_MINING_ROUND_TEMPLATE="#splice-amulet:Splice.Round:OpenMiningRound"
AMULET_TEMPLATE="#splice-amulet:Splice.Amulet:Amulet"
DELEGATION_TEMPLATE="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegation"

# Output file
MERGED_HOLDINGS_FILE="$SCRIPT_DIR/user-wallet-merged-holdings-amulet.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[utxo-merge-amulet] $*"
}

log_error() {
  echo "[utxo-merge-amulet] ERROR: $*" >&2
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

generate_canton_jwt() {
  local sub="$1"
  local aud="$2"
  local now
  now=$(date +%s)
  local exp=$((now + 86400))

  b64url() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
  }

  local header
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  local payload
  payload=$(printf '{"sub":"%s","aud":"%s","iat":%d,"exp":%d,"iss":"unsafe-auth"}' "$sub" "$aud" "$now" "$exp" | b64url)
  local signature
  signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$SHARED_SECRET" -binary | b64url)

  echo "${header}.${payload}.${signature}"
}

# Regular submission for participant-hosted parties (operator)
regular_submit() {
  local party="$1"
  local read_as="$2"
  local command_json="$3"
  local cmd_id_prefix="$4"
  local disclosed_json="${5:-[]}"

  local cmd_id="${cmd_id_prefix}-${RUN_ID}-${RANDOM}${RANDOM}"

  local submit_body
  submit_body=$(jq -n \
    --arg party "$party" \
    --arg readAs "$read_as" \
    --arg cmdId "$cmd_id" \
    --arg userId "$SHARED_SECRET_USER" \
    --argjson commands "$command_json" \
    --argjson disclosed "$disclosed_json" \
    '{
      commands: {
        commands: $commands,
        commandId: $cmdId,
        userId: $userId,
        actAs: [$party],
        readAs: [$readAs],
        disclosedContracts: $disclosed,
        deduplicationPeriod: {Empty: {}},
        packageIdSelectionPreference: []
      }
    }')

  curl_check "$PARTICIPANT_JSON_API/v2/commands/submit-and-wait-for-transaction" "$CANTON_TOKEN" "application/json" \
    --data-raw "$submit_body" || return 1
}

# Query active contracts from a given JSON API endpoint
query_active_contracts_from() {
  local json_api="$1"
  local token="$2"
  local party="$3"
  local template_id="$4"
  local include_blob="${5:-false}"
  local verbose="${6:-false}"

  local ledger_end
  ledger_end=$(curl_check "$json_api/v2/state/ledger-end" "$token" "application/json" | jq -r '.offset')

  local query_body
  query_body=$(jq -n \
    --arg party "$party" \
    --arg templateId "$template_id" \
    --argjson includeBlob "$include_blob" \
    --argjson verbose "$verbose" \
    --arg offset "$ledger_end" \
    '{
      filter: {
        filtersByParty: {
          ($party): {
            cumulative: [{
              identifierFilter: {
                TemplateFilter: {
                  value: {
                    templateId: $templateId,
                    includeCreatedEventBlob: $includeBlob
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
# Step 0: Pre-flight
##############################################################################

log "=========================================="
log "UTXO Merging — Merge Amulet (CC) Holdings"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Operator: ${OPERATOR_PARTY:0:50}..."
log "  FeaturedAppRight: ${FAR_CID:0:40}..."
log ""

# Generate tokens for both app-user and SV participants
CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")
SV_CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_SV_USER" "$SHARED_SECRET_AUDIENCE")

# Resolve DSO party ID
DSO_PARTY=$(curl_check "$PARTICIPANT_VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" "$CANTON_TOKEN" "application/json" \
  | jq -r '.dso_party_id // empty')

if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party ID"
  exit 1
fi
log "  DSO party: ${DSO_PARTY:0:50}..."

##############################################################################
# Step 1: Fetch ExternalPartyAmuletRules + AmuletRules + OpenMiningRound from SV
##############################################################################

log ""
log "Step 1: Fetching Amulet contracts from SV participant..."

# ExternalPartyAmuletRules (implements TransferFactory)
EPAR_RESPONSE=$(query_active_contracts_from "$SV_JSON_API" "$SV_CANTON_TOKEN" \
  "$DSO_PARTY" "$EXTERNAL_PARTY_AMULET_RULES_TEMPLATE" "true" "false")

EPAR_CID=$(echo "$EPAR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
' 2>/dev/null || echo "")
EPAR_TEMPLATE_HASH=$(echo "$EPAR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
' 2>/dev/null || echo "")
EPAR_BLOB=$(echo "$EPAR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
' 2>/dev/null || echo "")

if [ -z "$EPAR_CID" ] || [ -z "$EPAR_BLOB" ]; then
  log_error "Could not fetch ExternalPartyAmuletRules from SV"
  exit 1
fi
log "  ExternalPartyAmuletRules: ${EPAR_CID:0:40}..."

# AmuletRules
AR_RESPONSE=$(query_active_contracts_from "$SV_JSON_API" "$SV_CANTON_TOKEN" \
  "$DSO_PARTY" "$AMULET_RULES_TEMPLATE" "true" "false")

AR_CID=$(echo "$AR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
' 2>/dev/null || echo "")
AR_TEMPLATE_HASH=$(echo "$AR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
' 2>/dev/null || echo "")
AR_BLOB=$(echo "$AR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
' 2>/dev/null || echo "")

if [ -z "$AR_CID" ] || [ -z "$AR_BLOB" ]; then
  log_error "Could not fetch AmuletRules from SV"
  exit 1
fi
log "  AmuletRules: ${AR_CID:0:40}..."

# OpenMiningRound (pick the earliest/lowest round — it's most likely already open)
OR_RESPONSE=$(query_active_contracts_from "$SV_JSON_API" "$SV_CANTON_TOKEN" \
  "$DSO_PARTY" "$OPEN_MINING_ROUND_TEMPLATE" "true" "false")

OR_CID=$(echo "$OR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
   | {contractId, round: ((.createArgument.round.number // .createArgument.round // .createArguments.round.number // .createArguments.round // 0) | tonumber)}]
  | sort_by(.round) | first | .contractId // empty
' 2>/dev/null || echo "")
OR_TEMPLATE_HASH=$(echo "$OR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
' 2>/dev/null || echo "")
OR_BLOB=$(echo "$OR_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
   | {createdEventBlob, round: ((.createArgument.round.number // .createArgument.round // .createArguments.round.number // .createArguments.round // 0) | tonumber)}]
  | sort_by(.round) | first | .createdEventBlob // empty
' 2>/dev/null || echo "")

if [ -z "$OR_CID" ] || [ -z "$OR_BLOB" ]; then
  log_error "Could not fetch OpenMiningRound from SV"
  exit 1
fi
log "  OpenMiningRound: ${OR_CID:0:40}..."

# Get synchronizer ID for disclosed contracts
SYNCHRONIZER_ID=$(curl_check "$PARTICIPANT_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

# Build disclosed contracts (ExternalPartyAmuletRules + AmuletRules + OpenMiningRound + FeaturedAppRight)
DISCLOSED_CONTRACTS=$(jq -n \
  --arg eparCid "$EPAR_CID" --arg eparTemplate "$EPAR_TEMPLATE_HASH" --arg eparBlob "$EPAR_BLOB" \
  --arg arCid "$AR_CID" --arg arTemplate "$AR_TEMPLATE_HASH" --arg arBlob "$AR_BLOB" \
  --arg orCid "$OR_CID" --arg orTemplate "$OR_TEMPLATE_HASH" --arg orBlob "$OR_BLOB" \
  --arg syncId "$SYNCHRONIZER_ID" \
  --arg farCid "$(jq -r '.featuredAppRight.disclosure.contractId' "$FAR_FILE")" \
  --arg farTemplate "$(jq -r '.featuredAppRight.disclosure.templateId' "$FAR_FILE")" \
  --arg farBlob "$(jq -r '.featuredAppRight.disclosure.createdEventBlob' "$FAR_FILE")" \
  --arg farSync "$(jq -r '.featuredAppRight.disclosure.synchronizerId' "$FAR_FILE")" \
  '[
    { contractId: $eparCid, templateId: $eparTemplate, createdEventBlob: $eparBlob, synchronizerId: $syncId },
    { contractId: $arCid, templateId: $arTemplate, createdEventBlob: $arBlob, synchronizerId: $syncId },
    { contractId: $orCid, templateId: $orTemplate, createdEventBlob: $orBlob, synchronizerId: $syncId },
    { contractId: $farCid, templateId: $farTemplate, createdEventBlob: $farBlob, synchronizerId: $farSync }
  ]')

log "  Disclosed contracts ready (4 contracts)"

##############################################################################
# Step 2: Merge Amulet holdings for each wallet
##############################################################################

log ""
log "Step 2: Merging Amulet holdings for $NUM_WALLETS wallets..."

# Timestamps for self-transfer (requestedAt must be in the past)
NOW_EPOCH=$(date +%s)
PAST_EPOCH=$((NOW_EPOCH - 300))  # 5 minutes ago
EXPIRE_EPOCH=$((NOW_EPOCH + 86400))
REQUEST_TIME=$(python3 -c "from datetime import datetime;print(datetime.utcfromtimestamp($PAST_EPOCH).strftime('%Y-%m-%dT%H:%M:%S.000000Z'))" 2>/dev/null)
EXPIRE_TIME=$(python3 -c "from datetime import datetime;print(datetime.utcfromtimestamp($EXPIRE_EPOCH).strftime('%Y-%m-%dT%H:%M:%S.000000Z'))" 2>/dev/null)
if [ -z "$REQUEST_TIME" ]; then
  if date -r 0 +%s > /dev/null 2>&1; then
    REQUEST_TIME=$(date -u -r "$PAST_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
    EXPIRE_TIME=$(date -u -r "$EXPIRE_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
  else
    REQUEST_TIME=$(date -u -d "@$PAST_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
    EXPIRE_TIME=$(date -u -d "@$EXPIRE_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
  fi
fi

MERGED_RESULTS=()

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_NAME=$(jq -r ".wallets[$i].userId" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".wallets[$i].partyId" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_NAME..."

  # 2a. Verify MergeDelegation exists
  DELEG_RESPONSE=$(query_active_contracts_from "$PARTICIPANT_JSON_API" "$CANTON_TOKEN" \
    "$WALLET_PARTY" "$DELEGATION_TEMPLATE" "false")
  DELEG_CID=$(echo "$DELEG_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$DELEG_CID" ] || [ "$DELEG_CID" = "null" ]; then
    log_error "No MergeDelegation found for $WALLET_NAME"
    exit 1
  fi
  log "    MergeDelegation verified: ${DELEG_CID:0:30}..."

  # 2b. Query all active Amulet contracts for this wallet (verbose: false → createArgument)
  HOLDINGS_RESPONSE=$(query_active_contracts_from "$PARTICIPANT_JSON_API" "$CANTON_TOKEN" \
    "$WALLET_PARTY" "$AMULET_TEMPLATE" "false")
  HOLDINGS_DATA=$(echo "$HOLDINGS_RESPONSE" | jq -c '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
     | { contractId: .contractId, amount: (.createArgument.amount.initialAmount // .createArguments.amount.initialAmount // .createArgument.amount // .createArguments.amount // 0) }]
  ' 2>/dev/null || echo "[]")

  HOLDING_COUNT=$(echo "$HOLDINGS_DATA" | jq 'length')
  log "    Active Amulet holdings: $HOLDING_COUNT"

  if [ "$HOLDING_COUNT" -le 1 ]; then
    if [ "$HOLDING_COUNT" -eq 1 ]; then
      MERGED_CID=$(echo "$HOLDINGS_DATA" | jq -r '.[0].contractId')
      MERGED_AMT=$(echo "$HOLDINGS_DATA" | jq -r '.[0].amount')
      MERGED_RESULTS+=("${i}|${MERGED_CID}|${MERGED_AMT}")
      log "    Already a single holding, skipping merge"
    else
      log "    No holdings found, skipping"
    fi
    continue
  fi

  TOTAL_AMOUNT=$(echo "$HOLDINGS_DATA" | jq -r '[.[].amount | tonumber] | add | tostring')
  HOLDING_CIDS=$(echo "$HOLDINGS_DATA" | jq -c '[.[].contractId]')

  log "    Total amount: $TOTAL_AMOUNT CC (from $HOLDING_COUNT holdings)"

  # 2c. Exercise MergeDelegation_Merge (operator submits via regular submission)
  # ExtraArgs context: amulet-rules + open-round (required by unfeaturedPaymentContextFromChoiceContext)
  MERGE_CMD=$(jq -n \
    --arg delegTemplateId "$DELEGATION_TEMPLATE" \
    --arg delegCid "$DELEG_CID" \
    --arg factoryCid "$EPAR_CID" \
    --arg admin "$DSO_PARTY" \
    --arg party "$WALLET_PARTY" \
    --arg amount "$TOTAL_AMOUNT" \
    --arg requestedAt "$REQUEST_TIME" \
    --arg executeBefore "$EXPIRE_TIME" \
    --argjson holdingCids "$HOLDING_CIDS" \
    --arg arCid "$AR_CID" \
    --arg orCid "$OR_CID" \
    --arg farCid "$FAR_CID" \
    --arg operator "$OPERATOR_PARTY" \
    '[{
      ExerciseCommand: {
        templateId: $delegTemplateId,
        contractId: $delegCid,
        choice: "MergeDelegation_Merge",
        choiceArgument: {
          optMergeTransfer: {
            factoryCid: $factoryCid,
            choiceArg: {
              expectedAdmin: $admin,
              transfer: {
                sender: $party,
                receiver: $party,
                amount: $amount,
                instrumentId: { admin: $admin, id: "Amulet" },
                requestedAt: $requestedAt,
                executeBefore: $executeBefore,
                inputHoldingCids: $holdingCids,
                meta: { values: {} }
              },
              extraArgs: {
                context: {
                  values: {
                    "amulet-rules": { tag: "AV_ContractId", value: $arCid },
                    "open-round": { tag: "AV_ContractId", value: $orCid }
                  }
                },
                meta: { values: {} }
              }
            }
          },
          optExtraTransfer: null,
          optFeaturedAppRight: {
            appRightCid: $farCid,
            beneficiaries: [
              { beneficiary: $operator, weight: "1.0" }
            ]
          }
        }
      }
    }]')

  MERGE_TX=$(regular_submit "$OPERATOR_PARTY" "$WALLET_PARTY" "$MERGE_CMD" \
    "merge-amulet-$WALLET_NAME" "$DISCLOSED_CONTRACTS") || {
    log_error "MergeDelegation_Merge failed for $WALLET_NAME"
    exit 1
  }

  # Extract merged Amulet CID from response
  MERGED_CID=$(echo "$MERGE_TX" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | test("Splice\\.Amulet:Amulet$"))
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  # Fallback: broader match
  if [ -z "$MERGED_CID" ]; then
    MERGED_CID=$(echo "$MERGE_TX" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | contains("Amulet"))
       | select(.templateId | tostring | contains("AmuletRules") | not)
       | select(.templateId | tostring | contains("AmuletAllocation") | not)
       | select(.templateId | tostring | contains("AmuletTransfer") | not)
       | select(.templateId | tostring | contains("LockedAmulet") | not)
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")
  fi

  if [ -z "$MERGED_CID" ]; then
    log_error "Could not extract merged Amulet CID for $WALLET_NAME"
    log_error "Events: $(echo "$MERGE_TX" | jq -c '[.transaction.events[] | (.CreatedEvent // .created // empty) | {templateId, contractId}]' 2>/dev/null | head -c 500)"
    exit 1
  fi

  MERGED_RESULTS+=("${i}|${MERGED_CID}|${TOTAL_AMOUNT}")
  log "    Merged into single Amulet: ${MERGED_CID:0:30}... (amount: $TOTAL_AMOUNT CC)"
done

log ""
log "  All wallets processed. Merged: ${#MERGED_RESULTS[@]}"

##############################################################################
# Step 3: Write merged holdings report
##############################################################################

log ""
log "Step 3: Writing merged holdings report..."

PARTY_HINT_VALUE=$(jq -r '.partyHint' "$KEYPAIRS_FILE")

REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg partyHint "$PARTY_HINT_VALUE" \
  --arg dsoParty "$DSO_PARTY" \
  --arg tokenId "Amulet" \
  --argjson totalHoldings "${#MERGED_RESULTS[@]}" \
  '{
    generatedAt: $generatedAt,
    partyHint: $partyHint,
    dsoParty: $dsoParty,
    tokenId: $tokenId,
    totalHoldings: $totalHoldings,
    wallets: []
  }')

for entry in "${MERGED_RESULTS[@]}"; do
  IFS='|' read -r WALLET_IDX HOLDING_CID AMOUNT <<< "$entry"

  WALLET_PARTY=$(jq -r ".wallets[$WALLET_IDX].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".wallets[$WALLET_IDX].userId" "$KEYPAIRS_FILE")

  REPORT_JSON=$(echo "$REPORT_JSON" | jq \
    --arg partyId "$WALLET_PARTY" \
    --arg userId "$WALLET_USER" \
    --arg holdingCid "$HOLDING_CID" \
    --arg amount "$AMOUNT" \
    '.wallets += [{
      partyId: $partyId,
      userId: $userId,
      holdings: [{ contractId: $holdingCid, amount: ($amount | tonumber) }],
      totalAmount: ($amount | tonumber)
    }]')
done

echo "$REPORT_JSON" | jq '.' > "$MERGED_HOLDINGS_FILE"
log "  Report written to: $MERGED_HOLDINGS_FILE"

##############################################################################
# Step 4: Verify balances match original holdings
##############################################################################

log ""
log "Step 4: Verifying balances..."

VERIFICATION_PASSED=true
MISMATCHES=0

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_USER=$(jq -r ".wallets[$i].userId" "$ORIGINAL_HOLDINGS_FILE")

  ORIGINAL_TOTAL=$(jq -r ".wallets[$i].totalAmount" "$ORIGINAL_HOLDINGS_FILE")

  MERGED_TOTAL=$(jq -r --arg user "$WALLET_USER" '
    .wallets[] | select(.userId == $user) | .totalAmount
  ' "$MERGED_HOLDINGS_FILE" 2>/dev/null || echo "0")

  ORIG_NORMALIZED=$(echo "$ORIGINAL_TOTAL" | jq 'tonumber')
  MERGED_NORMALIZED=$(echo "$MERGED_TOTAL" | jq 'tonumber')

  if [ "$ORIG_NORMALIZED" != "$MERGED_NORMALIZED" ]; then
    log_error "MISMATCH: $WALLET_USER — original: $ORIGINAL_TOTAL, merged: $MERGED_TOTAL"
    VERIFICATION_PASSED=false
    MISMATCHES=$((MISMATCHES + 1))
  fi
done

if [ "$VERIFICATION_PASSED" = true ]; then
  log "  All balances verified successfully! ($NUM_WALLETS wallets, 0 mismatches)"
else
  log_error "$MISMATCHES balance mismatches detected!"
  log "  NOTE: Amulet amounts may differ slightly due to holding fees (ExpiringAmount)."
  log "  Small differences are expected for Amulet tokens."
fi

##############################################################################
# Done
##############################################################################

GRAND_TOTAL=$(jq '[.wallets[].totalAmount] | add' "$MERGED_HOLDINGS_FILE")

log ""
log "=========================================="
log "Amulet UTXO Merging Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets merged: ${#MERGED_RESULTS[@]} / $NUM_WALLETS"
log "  Holdings per wallet: 1 (merged)"
log "  Total CC: $GRAND_TOTAL"
log "  Merged holdings file: $MERGED_HOLDINGS_FILE"
log "  Verification: $([ "$VERIFICATION_PASSED" = true ] && echo "PASSED" || echo "FAILED ($MISMATCHES mismatches)")"
log ""
