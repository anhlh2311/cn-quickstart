#!/bin/bash
# Merges CBTC token holdings for each user wallet into a single Holding per wallet.
#
# Reads holdings from user-wallet-holdings-cbtc.json (produced by 07-query-holdings-cbtc.sh)
# and uses MergeDelegation_Merge to exercise a self-transfer via the Utility package's
# AllocationFactory (TransferFactory interface). The operator submits via regular submission.
#
# For each wallet with >1 holding:
#   1. Validates that a MergeDelegation contract exists
#   2. Exercises MergeDelegation_Merge (operator submits, single regular submission)
#   3. Records the merged Holding
#
# Prerequisites:
#   - quickstart must be running
#   - 07-query-holdings-cbtc.sh must have been run (creates user-wallet-holdings-cbtc.json)
#   - 03-register-cbtc-token.sh (setup-exchange) must have been run (creates cbtc-factories.json)
#   - 02-register-featured-app-right.sh must have been run (creates featured-app-right.json)
#   - 04-create-merge-delegation.sh must have been run (MergeDelegation contracts)
#
# Usage: ./09-merge-holdings-cbtc.sh

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

# Exchange backend (required for EXECUTOR_PARTY_ID)
EXCHANGE_BACKEND_DIR="${EXCHANGE_BACKEND_DIR:-}"
RUN_ID=$(date +%s%N 2>/dev/null || date +%s)

# Load CBTC config
CBTC_CONFIG_FILE="$SETUP_EXCHANGE_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[merge-cbtc] ERROR: CBTC config not found: $CBTC_CONFIG_FILE" >&2
  exit 1
fi
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")

# Load CBTC-NETWORK keypair
CBTC_KEYPAIR_FILE="$SETUP_EXCHANGE_DIR/cbtc-network-keypair.json"
if [ ! -f "$CBTC_KEYPAIR_FILE" ]; then
  echo "[merge-cbtc] ERROR: CBTC-NETWORK keypair not found: $CBTC_KEYPAIR_FILE" >&2
  exit 1
fi
CBTC_NETWORK_PARTY=$(jq -r '.partyId' "$CBTC_KEYPAIR_FILE")

# Get OPERATOR_PARTY (executor) from backend .env
BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
if [ ! -f "$BACKEND_ENV" ]; then
  echo "[merge-cbtc] ERROR: Backend .env not found: $BACKEND_ENV" >&2
  exit 1
fi
OPERATOR_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)
if [ -z "$OPERATOR_PARTY" ]; then
  echo "[merge-cbtc] ERROR: EXECUTOR_PARTY_ID not found in $BACKEND_ENV" >&2
  exit 1
fi

# Load user wallet data
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"
DELEGATIONS_FILE="$SCRIPT_DIR/user-wallet-merge-delegation.json"
HOLDINGS_INPUT_FILE="$SCRIPT_DIR/user-wallet-holdings-cbtc.json"

for f in "$KEYPAIRS_FILE" "$DELEGATIONS_FILE" "$HOLDINGS_INPUT_FILE"; do
  if [ ! -f "$f" ]; then
    echo "[merge-cbtc] ERROR: Required file not found: $f" >&2
    exit 1
  fi
done

NUM_WALLETS=$(jq '.wallets | length' "$KEYPAIRS_FILE")

# Load factory data from cbtc-factories.json
FACTORIES_FILE="$SETUP_EXCHANGE_DIR/cbtc-factories.json"
if [ ! -f "$FACTORIES_FILE" ]; then
  echo "[merge-cbtc] ERROR: Factories file not found: $FACTORIES_FILE" >&2
  exit 1
fi

# AllocationFactory implements TransferFactory interface
FACTORY_CID=$(jq -r '.factories.allocationFactory.contractId // empty' "$FACTORIES_FILE")
INSTRUMENT_CONFIG_CID=$(jq -r '.instrumentConfiguration.contractId // empty' "$FACTORIES_FILE")

if [ -z "$FACTORY_CID" ] || [ "$FACTORY_CID" = "null" ]; then
  echo "[merge-cbtc] ERROR: AllocationFactory contractId not found in $FACTORIES_FILE" >&2
  exit 1
fi
if [ -z "$INSTRUMENT_CONFIG_CID" ] || [ "$INSTRUMENT_CONFIG_CID" = "null" ]; then
  echo "[merge-cbtc] ERROR: InstrumentConfiguration contractId not found in $FACTORIES_FILE" >&2
  exit 1
fi

# Build disclosed contracts from cbtc-factories.json (AllocationFactory + InstrumentConfiguration)
DISCLOSED_CONTRACTS=$(jq -c '[
  {
    contractId: .factories.allocationFactory.disclosure.contractId,
    templateId: .factories.allocationFactory.disclosure.templateId,
    createdEventBlob: .factories.allocationFactory.disclosure.createdEventBlob,
    synchronizerId: .factories.allocationFactory.disclosure.synchronizerId
  },
  {
    contractId: .instrumentConfiguration.disclosure.contractId,
    templateId: .instrumentConfiguration.disclosure.templateId,
    createdEventBlob: .instrumentConfiguration.disclosure.createdEventBlob,
    synchronizerId: .instrumentConfiguration.disclosure.synchronizerId
  }
]' "$FACTORIES_FILE")

# Load FeaturedAppRight from featured-app-right.json
FAR_FILE="$SETUP_EXCHANGE_DIR/featured-app-right.json"
if [ ! -f "$FAR_FILE" ]; then
  echo "[merge-cbtc] ERROR: FeaturedAppRight file not found: $FAR_FILE" >&2
  echo "[merge-cbtc] Run 02-register-featured-app-right.sh first." >&2
  exit 1
fi

FAR_CID=$(jq -r '.featuredAppRight.contractId // empty' "$FAR_FILE")
if [ -z "$FAR_CID" ] || [ "$FAR_CID" = "null" ]; then
  echo "[merge-cbtc] ERROR: FeaturedAppRight contractId not found in $FAR_FILE" >&2
  exit 1
fi

# Add FeaturedAppRight to disclosed contracts
DISCLOSED_CONTRACTS=$(echo "$DISCLOSED_CONTRACTS" | jq -c \
  --arg cid "$(jq -r '.featuredAppRight.disclosure.contractId' "$FAR_FILE")" \
  --arg tmpl "$(jq -r '.featuredAppRight.disclosure.templateId' "$FAR_FILE")" \
  --arg blob "$(jq -r '.featuredAppRight.disclosure.createdEventBlob' "$FAR_FILE")" \
  --arg sync "$(jq -r '.featuredAppRight.disclosure.synchronizerId' "$FAR_FILE")" \
  '. + [{ contractId: $cid, templateId: $tmpl, createdEventBlob: $blob, synchronizerId: $sync }]')

# Template IDs
HOLDING_TEMPLATE="#utility-registry-holding-v0:Utility.Registry.Holding.V0.Holding:Holding"
DELEGATION_TEMPLATE="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegation"

# Output file
MERGED_HOLDINGS_FILE="$SCRIPT_DIR/user-wallet-merged-holdings-cbtc.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[merge-cbtc] $*"
}

log_error() {
  echo "[merge-cbtc] ERROR: $*" >&2
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

# Query active contracts for MergeDelegation check
query_active_contracts() {
  local party="$1"
  local template_id="$2"
  local include_blob="${3:-false}"
  local verbose="${4:-false}"

  local ledger_end
  ledger_end=$(curl_check "$PARTICIPANT_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

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

  curl_check "$PARTICIPANT_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
}

##############################################################################
# Pre-flight
##############################################################################

log "=========================================="
log "Merge CBTC Holdings (from JSON)"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Input file: $HOLDINGS_INPUT_FILE"
log "  Operator: ${OPERATOR_PARTY:0:50}..."
log "  CBTC-NETWORK: ${CBTC_NETWORK_PARTY:0:50}..."
log "  AllocationFactory: ${FACTORY_CID:0:40}..."
log "  FeaturedAppRight: ${FAR_CID:0:40}..."
log ""

CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

##############################################################################
# Step 1: Merge holdings for each wallet (from JSON input)
##############################################################################

log ""
log "Step 1: Merging CBTC holdings for $NUM_WALLETS wallets..."

# Timestamps for self-transfer (requestedAt must be in the past)
NOW_EPOCH=$(date +%s)
PAST_EPOCH=$((NOW_EPOCH - 300))  # 5 minutes ago
EXPIRE_EPOCH=$((NOW_EPOCH + 86400))
REQUEST_TIME=$(python3 -c "from datetime import datetime;print(datetime.utcfromtimestamp($PAST_EPOCH).strftime('%Y-%m-%dT%H:%M:%S.000000Z'))" 2>/dev/null)
EXPIRE_TIME=$(python3 -c "from datetime import datetime;print(datetime.utcfromtimestamp($EXPIRE_EPOCH).strftime('%Y-%m-%dT%H:%M:%S.000000Z'))" 2>/dev/null)
if [ -z "$REQUEST_TIME" ]; then
  # Fallback for systems without python3
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

  # 1a. Verify MergeDelegation exists
  DELEG_RESPONSE=$(query_active_contracts "$WALLET_PARTY" "$DELEGATION_TEMPLATE" "false" "false")
  DELEG_CID=$(echo "$DELEG_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$DELEG_CID" ] || [ "$DELEG_CID" = "null" ]; then
    log_error "No MergeDelegation found for $WALLET_NAME"
    exit 1
  fi
  log "    MergeDelegation verified: ${DELEG_CID:0:30}..."

  # 1b. Read holdings from JSON file
  HOLDINGS_DATA=$(jq -c --arg user "$WALLET_NAME" '
    .wallets[] | select(.userId == $user) | .holdings
  ' "$HOLDINGS_INPUT_FILE" 2>/dev/null || echo "[]")

  HOLDING_COUNT=$(echo "$HOLDINGS_DATA" | jq 'length')
  log "    Holdings from JSON: $HOLDING_COUNT"

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

  log "    Total amount: $TOTAL_AMOUNT (from $HOLDING_COUNT holdings)"

  # 1c. Exercise MergeDelegation_Merge (operator submits via regular submission)
  MERGE_CMD=$(jq -n \
    --arg delegTemplateId "$DELEGATION_TEMPLATE" \
    --arg delegCid "$DELEG_CID" \
    --arg factoryCid "$FACTORY_CID" \
    --arg admin "$CBTC_NETWORK_PARTY" \
    --arg tokenId "$CBTC_TOKEN_ID" \
    --arg party "$WALLET_PARTY" \
    --arg amount "$TOTAL_AMOUNT" \
    --arg requestedAt "$REQUEST_TIME" \
    --arg executeBefore "$EXPIRE_TIME" \
    --argjson holdingCids "$HOLDING_CIDS" \
    --arg icCid "$INSTRUMENT_CONFIG_CID" \
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
                instrumentId: { admin: $admin, id: $tokenId },
                requestedAt: $requestedAt,
                executeBefore: $executeBefore,
                inputHoldingCids: $holdingCids,
                meta: { values: {} }
              },
              extraArgs: {
                context: {
                  values: {
                    "utility.digitalasset.com/instrument-configuration": { tag: "AV_ContractId", value: $icCid },
                    "utility.digitalasset.com/sender-credentials": { tag: "AV_List", value: [] },
                    "utility.digitalasset.com/receiver-credentials": { tag: "AV_List", value: [] }
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
    "merge-cbtc-$WALLET_NAME" "$DISCLOSED_CONTRACTS") || {
    log_error "MergeDelegation_Merge failed for $WALLET_NAME"
    exit 1
  }

  # Extract the merged Holding CID from response
  MERGED_CID=$(echo "$MERGE_TX" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | contains("Holding:Holding") or contains("Holding.V0.Holding:Holding"))
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$MERGED_CID" ]; then
    log_error "Could not extract merged Holding CID for $WALLET_NAME"
    log_error "Events: $(echo "$MERGE_TX" | jq -c '[.transaction.events[] | (.CreatedEvent // .created // empty) | {templateId, contractId}]' 2>/dev/null | head -c 500)"
    exit 1
  fi

  MERGED_RESULTS+=("${i}|${MERGED_CID}|${TOTAL_AMOUNT}")
  log "    Merged into single holding: ${MERGED_CID:0:30}... (amount: $TOTAL_AMOUNT)"
done

log ""
log "  All wallets processed. Merged: ${#MERGED_RESULTS[@]}"

##############################################################################
# Step 2: Write merged holdings report
##############################################################################

log ""
log "Step 2: Writing merged holdings report..."

PARTY_HINT_VALUE=$(jq -r '.partyHint' "$KEYPAIRS_FILE")

REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg partyHint "$PARTY_HINT_VALUE" \
  --arg cbtcNetworkParty "$CBTC_NETWORK_PARTY" \
  --arg tokenId "$CBTC_TOKEN_ID" \
  --argjson totalHoldings "${#MERGED_RESULTS[@]}" \
  '{
    generatedAt: $generatedAt,
    partyHint: $partyHint,
    cbtcNetworkParty: $cbtcNetworkParty,
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
# Step 3: Verify balances match input holdings
##############################################################################

log ""
log "Step 3: Verifying balances..."

VERIFICATION_PASSED=true
MISMATCHES=0

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_USER=$(jq -r ".wallets[$i].userId" "$HOLDINGS_INPUT_FILE")

  ORIGINAL_TOTAL=$(jq -r ".wallets[$i].totalAmount" "$HOLDINGS_INPUT_FILE")

  MERGED_TOTAL=$(jq -r --arg user "$WALLET_USER" '
    .wallets[] | select(.userId == $user) | .totalAmount
  ' "$MERGED_HOLDINGS_FILE" 2>/dev/null || echo "0")

  # Compare as integers (truncate decimals) to avoid formatting differences like 1151 vs 1151.0000000000
  ORIG_NORMALIZED=$(echo "$ORIGINAL_TOTAL" | jq 'tonumber | floor')
  MERGED_NORMALIZED=$(echo "$MERGED_TOTAL" | jq 'tonumber | floor')

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
fi

##############################################################################
# Done
##############################################################################

GRAND_TOTAL=$(jq '[.wallets[].totalAmount] | add' "$MERGED_HOLDINGS_FILE")

log ""
log "=========================================="
log "CBTC Holdings Merge Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets merged: ${#MERGED_RESULTS[@]} / $NUM_WALLETS"
log "  Holdings per wallet: 1 (merged)"
log "  Total CBTC: $GRAND_TOTAL"
log "  Input file: $HOLDINGS_INPUT_FILE"
log "  Output file: $MERGED_HOLDINGS_FILE"
log "  Verification: $([ "$VERIFICATION_PASSED" = true ] && echo "PASSED" || echo "FAILED ($MISMATCHES mismatches)")"
log ""
