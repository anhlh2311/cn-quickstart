#!/bin/bash
# Merges CBTC token holdings for each farming wallet into a single holding per wallet.
#
# Steps:
#   1. Loads TokenTransferFactory from cbtc-factories.json (created by 03-register-cbtc-token.sh)
#   2. For each wallet:
#      a. Validates that a MergeDelegation contract exists
#      b. Queries all active TokenHolding contracts
#      c. Performs a two-step self-transfer merge via TokenTransferFactory
#      d. Records the merged holding
#   3. Writes farming-wallet-merged-holdings.json
#   4. Verifies balances match the original farming-wallet-holdings.json
#
# Prerequisites:
#   - quickstart must be running
#   - 03-register-cbtc-token.sh must have been run (creates cbtc-factories.json)
#   - generate-farming-wallets.sh must have been run (wallets + CBTC holdings)
#   - create-merge-delegations.sh must have been run (MergeDelegation contracts)
#
# Usage: ./farming-wallet-utxo-merging.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-exchange" && pwd)"

# Load shared configuration
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[utxo-merge] ERROR: $SETUP_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# Load CBTC config
CBTC_CONFIG_FILE="$SETUP_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[utxo-merge] ERROR: CBTC config not found: $CBTC_CONFIG_FILE" >&2
  exit 1
fi
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")

# Load CBTC-NETWORK keypair
CBTC_KEYPAIR_FILE="$SETUP_DIR/cbtc-network-keypair.json"
if [ ! -f "$CBTC_KEYPAIR_FILE" ]; then
  echo "[utxo-merge] ERROR: CBTC-NETWORK keypair not found: $CBTC_KEYPAIR_FILE" >&2
  exit 1
fi
CBTC_NETWORK_PARTY=$(jq -r '.partyId' "$CBTC_KEYPAIR_FILE")
CBTC_PRIV_KEY=$(jq -r '.privateKey' "$CBTC_KEYPAIR_FILE")
CBTC_FP=$(jq -r '.fingerprint' "$CBTC_KEYPAIR_FILE")

# Load farming wallet data
KEYPAIRS_FILE="$SCRIPT_DIR/farming-wallet-keypairs.json"
DELEGATIONS_FILE="$SCRIPT_DIR/farming-wallet-merge-delegation.json"
ORIGINAL_HOLDINGS_FILE="$SCRIPT_DIR/farming-wallet-holdings.json"

for f in "$KEYPAIRS_FILE" "$DELEGATIONS_FILE" "$ORIGINAL_HOLDINGS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "[utxo-merge] ERROR: Required file not found: $f" >&2
    exit 1
  fi
done

NUM_WALLETS=$(jq 'length' "$KEYPAIRS_FILE")

# Template IDs
TRANSFER_FACTORY_TEMPLATE="#fungible-token:Fungible.TokenTransferFactory:TokenTransferFactory"
TRANSFER_INSTRUCTION_TEMPLATE="#fungible-token:Fungible.TokenTransferInstruction:TokenTransferInstruction"
HOLDING_TEMPLATE="#fungible-token:Fungible.TokenHolding:TokenHolding"
DELEGATION_TEMPLATE="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegation"

# Interface IDs (choices are defined on interfaces, not concrete templates)
TRANSFER_FACTORY_INTERFACE="55ba4deb0ad4662c4168b39859738a0e91388d252286480c7331b3f71a517281:Splice.Api.Token.TransferInstructionV1:TransferFactory"
TRANSFER_INSTRUCTION_INTERFACE="55ba4deb0ad4662c4168b39859738a0e91388d252286480c7331b3f71a517281:Splice.Api.Token.TransferInstructionV1:TransferInstruction"

# Output file
MERGED_HOLDINGS_FILE="$SCRIPT_DIR/farming-wallet-merged-holdings.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[utxo-merge] $*"
}

log_error() {
  echo "[utxo-merge] ERROR: $*" >&2
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

# Interactive submission with optional disclosed contracts
# Usage: interactive_submit <actAs_party> <priv_key> <fingerprint> <command_json> <cmd_id_prefix> [disclosed_contracts_json]
interactive_submit() {
  local party="$1"
  local priv_key="$2"
  local fp="$3"
  local command_json="$4"
  local cmd_id_prefix="$5"
  local disclosed_json="${6:-[]}"

  local cmd_id="${cmd_id_prefix}-$(date +%s%N)"

  local prepare_body
  prepare_body=$(jq -n \
    --arg party "$party" \
    --arg cmdId "$cmd_id" \
    --arg userId "$SHARED_SECRET_USER" \
    --arg syncId "$SYNCHRONIZER_ID" \
    --argjson commands "$command_json" \
    --argjson disclosed "$disclosed_json" \
    '{
      commands: $commands,
      commandId: $cmdId,
      userId: $userId,
      actAs: [$party],
      readAs: [],
      disclosedContracts: $disclosed,
      synchronizerId: $syncId,
      verboseHashing: true,
      packageIdSelectionPreference: []
    }')

  local prepare_result
  prepare_result=$(curl_check "$APP_USER_JSON_API/v2/interactive-submission/prepare" "$CANTON_TOKEN" "application/json" \
    --data-raw "$prepare_body") || return 1

  local prepared_tx
  prepared_tx=$(echo "$prepare_result" | jq -r '.preparedTransaction // empty')
  local prepared_hash
  prepared_hash=$(echo "$prepare_result" | jq -r '.preparedTransactionHash // empty')
  local hashing_version
  hashing_version=$(echo "$prepare_result" | jq -r '.hashingSchemeVersion // empty')

  if [ -z "$prepared_tx" ] || [ -z "$prepared_hash" ]; then
    log_error "Prepare response missing required fields"
    return 1
  fi

  local signature
  signature=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { signTransactionHash } = require('@canton-network/core-signing-lib');
    const signature = signTransactionHash('$prepared_hash', '$priv_key');
    process.stdout.write(signature);
  " 2>/dev/null) || signature=""

  if [ -z "$signature" ]; then
    log_error "Failed to sign prepared transaction"
    return 1
  fi

  local execute_body
  execute_body=$(jq -n \
    --arg userId "$SHARED_SECRET_USER" \
    --arg submissionId "utxo-merge-$cmd_id" \
    --arg preparedTx "$prepared_tx" \
    --arg hashVersion "$hashing_version" \
    --arg party "$party" \
    --arg sig "$signature" \
    --arg signedBy "$fp" \
    '{
      userId: $userId,
      submissionId: $submissionId,
      preparedTransaction: $preparedTx,
      hashingSchemeVersion: $hashVersion,
      partySignatures: {
        signatures: [{
          party: $party,
          signatures: [{
            signature: $sig,
            signedBy: $signedBy,
            format: "SIGNATURE_FORMAT_RAW",
            signingAlgorithmSpec: "SIGNING_ALGORITHM_SPEC_ED25519"
          }]
        }]
      },
      deduplicationPeriod: {Empty: {}}
    }')

  curl_check "$APP_USER_JSON_API/v2/interactive-submission/executeAndWaitForTransaction" "$CANTON_TOKEN" "application/json" \
    --data-raw "$execute_body" || return 1
}

# Query active contracts for a given party and template, return NDJSON response
query_active_contracts() {
  local party="$1"
  local template_id="$2"
  local include_blob="${3:-false}"

  local ledger_end
  ledger_end=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

  local query_body
  query_body=$(jq -n \
    --arg party "$party" \
    --arg templateId "$template_id" \
    --argjson includeBlob "$include_blob" \
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
      verbose: true,
      activeAtOffset: $offset
    }')

  curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
}

##############################################################################
# Step 0: Pre-flight
##############################################################################

log "=========================================="
log "UTXO Merging — Merge CBTC Holdings"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  CBTC-NETWORK: ${CBTC_NETWORK_PARTY:0:50}..."
log ""

CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

##############################################################################
# Step 1: Load TokenTransferFactory from cbtc-factories.json
##############################################################################

log ""
log "Step 1: Loading TokenTransferFactory from cbtc-factories.json..."

FACTORIES_FILE="$SETUP_DIR/cbtc-factories.json"
if [ ! -f "$FACTORIES_FILE" ]; then
  log_error "Factories file not found: $FACTORIES_FILE"
  log_error "Run 03-register-cbtc-token.sh first."
  exit 1
fi

FACTORY_CID=$(jq -r '.factories.transferFactory.contractId // empty' "$FACTORIES_FILE")
FACTORY_DISCLOSURE=$(jq -c '.factories.transferFactory.disclosure // empty' "$FACTORIES_FILE")

if [ -z "$FACTORY_CID" ] || [ "$FACTORY_CID" = "null" ]; then
  log_error "TransferFactory contractId not found in $FACTORIES_FILE"
  exit 1
fi

if [ -z "$FACTORY_DISCLOSURE" ] || [ "$FACTORY_DISCLOSURE" = "null" ]; then
  log_error "TransferFactory disclosure not found in $FACTORIES_FILE"
  exit 1
fi

FACTORY_BLOB=$(echo "$FACTORY_DISCLOSURE" | jq -r '.createdEventBlob // empty')
if [ -z "$FACTORY_BLOB" ]; then
  log_error "TransferFactory disclosure missing createdEventBlob"
  exit 1
fi

log "  TransferFactory CID: ${FACTORY_CID:0:40}..."
log "  Disclosure blob length: ${#FACTORY_BLOB}"

# Build disclosed contracts array for interactive submissions
DISCLOSED_CONTRACTS=$(echo "$FACTORY_DISCLOSURE" | jq -c '[.]')

##############################################################################
# Step 2: Merge holdings for each wallet
##############################################################################

log ""
log "Step 2: Merging holdings for $NUM_WALLETS wallets..."

# Timestamps for self-transfer
NOW_EPOCH=$(date +%s)
EXPIRE_EPOCH=$((NOW_EPOCH + 86400))
# macOS date -r takes epoch, GNU date uses -d @epoch
if date -r 0 +%s > /dev/null 2>&1; then
  REQUEST_TIME=$(date -u -r "$NOW_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
  EXPIRE_TIME=$(date -u -r "$EXPIRE_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
else
  REQUEST_TIME=$(date -u -d "@$NOW_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
  EXPIRE_TIME=$(date -u -d "@$EXPIRE_EPOCH" +"%Y-%m-%dT%H:%M:%S.000000Z")
fi

# Collect merged results: "walletIndex|holdingCid|amount"
MERGED_RESULTS=()

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".[$i].fingerprint" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT..."

  # 3a. Verify MergeDelegation exists
  DELEG_RESPONSE=$(query_active_contracts "$WALLET_PARTY" "$DELEGATION_TEMPLATE" "false")
  DELEG_CID=$(echo "$DELEG_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$DELEG_CID" ] || [ "$DELEG_CID" = "null" ]; then
    log_error "No MergeDelegation found for $WALLET_HINT"
    exit 1
  fi
  log "    MergeDelegation verified: ${DELEG_CID:0:30}..."

  # 3b. Query all TokenHolding contracts for this wallet
  HOLDINGS_RESPONSE=$(query_active_contracts "$WALLET_PARTY" "$HOLDING_TEMPLATE" "false")
  HOLDINGS_DATA=$(echo "$HOLDINGS_RESPONSE" | jq -c '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
     | { contractId: .contractId, amount: (.createArgument.amount // .createArguments.amount) }]
  ' 2>/dev/null || echo "[]")

  HOLDING_COUNT=$(echo "$HOLDINGS_DATA" | jq 'length')
  log "    Active holdings: $HOLDING_COUNT"

  if [ "$HOLDING_COUNT" -le 1 ]; then
    # Already merged or single holding
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

  # Compute total amount and collect CIDs
  TOTAL_AMOUNT=$(echo "$HOLDINGS_DATA" | jq -r '[.[].amount | tonumber] | add | tostring')
  HOLDING_CIDS=$(echo "$HOLDINGS_DATA" | jq -c '[.[].contractId]')

  log "    Total amount: $TOTAL_AMOUNT (from $HOLDING_COUNT holdings)"

  # 3c. Step 1: Exercise TransferFactory_Transfer (self-transfer)
  TRANSFER_CMD=$(jq -n \
    --arg templateId "$TRANSFER_FACTORY_TEMPLATE" \
    --arg interfaceId "$TRANSFER_FACTORY_INTERFACE" \
    --arg factoryCid "$FACTORY_CID" \
    --arg admin "$CBTC_NETWORK_PARTY" \
    --arg tokenId "$CBTC_TOKEN_ID" \
    --arg party "$WALLET_PARTY" \
    --arg amount "$TOTAL_AMOUNT" \
    --arg requestedAt "$REQUEST_TIME" \
    --arg executeBefore "$EXPIRE_TIME" \
    --argjson holdingCids "$HOLDING_CIDS" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
        interfaceId: $interfaceId,
        contractId: $factoryCid,
        choice: "TransferFactory_Transfer",
        choiceArgument: {
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
          extraArgs: { meta: { values: {} } }
        }
      }
    }]')

  TRANSFER_TX=$(interactive_submit "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" "$TRANSFER_CMD" "merge-transfer-$WALLET_HINT" "$DISCLOSED_CONTRACTS") || {
    log_error "TransferFactory_Transfer failed for $WALLET_HINT"
    exit 1
  }

  # Extract TokenTransferInstruction CID from created events
  INSTRUCTION_CID=$(echo "$TRANSFER_TX" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | contains("TokenTransferInstruction"))
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$INSTRUCTION_CID" ]; then
    log_error "Could not extract TokenTransferInstruction CID for $WALLET_HINT"
    log_error "Response: $(echo "$TRANSFER_TX" | jq -c '.transaction.events[:3]' 2>/dev/null | head -c 500)"
    exit 1
  fi
  log "    Transfer instruction created: ${INSTRUCTION_CID:0:30}..."

  # 3d. Step 2: Exercise TransferInstruction_Accept (completes merge)
  ACCEPT_CMD=$(jq -n \
    --arg templateId "$TRANSFER_INSTRUCTION_TEMPLATE" \
    --arg interfaceId "$TRANSFER_INSTRUCTION_INTERFACE" \
    --arg contractId "$INSTRUCTION_CID" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
        interfaceId: $interfaceId,
        contractId: $contractId,
        choice: "TransferInstruction_Accept",
        choiceArgument: {
          extraArgs: { meta: { values: {} } }
        }
      }
    }]')

  ACCEPT_TX=$(interactive_submit "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" "$ACCEPT_CMD" "merge-accept-$WALLET_HINT") || {
    log_error "TransferInstruction_Accept failed for $WALLET_HINT"
    exit 1
  }

  # Extract the merged TokenHolding CID from created events
  MERGED_CID=$(echo "$ACCEPT_TX" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | contains("TokenHolding"))
     | select(.templateId | tostring | contains("TokenTransfer") | not)
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$MERGED_CID" ]; then
    log_error "Could not extract merged TokenHolding CID for $WALLET_HINT"
    log_error "Response: $(echo "$ACCEPT_TX" | jq -c '.transaction.events[:5]' 2>/dev/null | head -c 500)"
    exit 1
  fi

  MERGED_RESULTS+=("${i}|${MERGED_CID}|${TOTAL_AMOUNT}")
  log "    Merged into single holding: ${MERGED_CID:0:30}... (amount: $TOTAL_AMOUNT)"
done

log ""
log "  All wallets processed. Merged: ${#MERGED_RESULTS[@]}"

##############################################################################
# Step 3: Write merged holdings report
##############################################################################

log ""
log "Step 3: Writing merged holdings report..."

REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cbtcNetworkParty "$CBTC_NETWORK_PARTY" \
  --arg tokenId "$CBTC_TOKEN_ID" \
  --argjson totalHoldings "${#MERGED_RESULTS[@]}" \
  '{
    generatedAt: $generatedAt,
    cbtcNetworkParty: $cbtcNetworkParty,
    tokenId: $tokenId,
    totalHoldings: $totalHoldings,
    wallets: []
  }')

for entry in "${MERGED_RESULTS[@]}"; do
  IFS='|' read -r WALLET_IDX HOLDING_CID AMOUNT <<< "$entry"

  WALLET_HINT=$(jq -r ".[$WALLET_IDX].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$WALLET_IDX].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".[$WALLET_IDX].userId" "$KEYPAIRS_FILE")

  REPORT_JSON=$(echo "$REPORT_JSON" | jq \
    --arg hint "$WALLET_HINT" \
    --arg partyId "$WALLET_PARTY" \
    --arg userId "$WALLET_USER" \
    --arg holdingCid "$HOLDING_CID" \
    --arg amount "$AMOUNT" \
    '.wallets += [{
      partyHint: $hint,
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
  WALLET_HINT=$(jq -r ".wallets[$i].partyHint" "$ORIGINAL_HOLDINGS_FILE")

  ORIGINAL_TOTAL=$(jq -r ".wallets[$i].totalAmount" "$ORIGINAL_HOLDINGS_FILE")
  ORIGINAL_COUNT=$(jq -r ".wallets[$i].holdings | length" "$ORIGINAL_HOLDINGS_FILE")

  # Find this wallet in merged results
  MERGED_TOTAL=$(jq -r --arg hint "$WALLET_HINT" '
    .wallets[] | select(.partyHint == $hint) | .totalAmount
  ' "$MERGED_HOLDINGS_FILE" 2>/dev/null || echo "0")

  MERGED_COUNT=$(jq -r --arg hint "$WALLET_HINT" '
    .wallets[] | select(.partyHint == $hint) | .holdings | length
  ' "$MERGED_HOLDINGS_FILE" 2>/dev/null || echo "0")

  # Compare (handle decimal vs integer: strip trailing .0 for comparison)
  ORIG_NORMALIZED=$(echo "$ORIGINAL_TOTAL" | jq 'tonumber')
  MERGED_NORMALIZED=$(echo "$MERGED_TOTAL" | jq 'tonumber')

  if [ "$ORIG_NORMALIZED" != "$MERGED_NORMALIZED" ]; then
    log_error "MISMATCH: $WALLET_HINT — original: $ORIGINAL_TOTAL, merged: $MERGED_TOTAL"
    VERIFICATION_PASSED=false
    MISMATCHES=$((MISMATCHES + 1))
  else
    if [ "$MERGED_COUNT" -ne 1 ]; then
      log "  WARN: $WALLET_HINT has $MERGED_COUNT holdings after merge (expected 1)"
    fi
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
log "UTXO Merging Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets merged: ${#MERGED_RESULTS[@]} / $NUM_WALLETS"
log "  Holdings per wallet: 1 (merged from 20)"
log "  Total CBTC: $GRAND_TOTAL"
log "  Merged holdings file: $MERGED_HOLDINGS_FILE"
log "  Verification: $([ "$VERIFICATION_PASSED" = true ] && echo "PASSED" || echo "FAILED ($MISMATCHES mismatches)")"
log ""
