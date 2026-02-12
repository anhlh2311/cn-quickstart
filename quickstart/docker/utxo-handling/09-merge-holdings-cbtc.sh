#!/bin/bash
# Merges CBTC token holdings for each user wallet into a single Holding per wallet.
#
# Reads holdings from user-wallet-holdings-cbtc.json (produced by 07-query-holdings-cbtc.sh)
# and uses the Utility package's AllocationFactory (TransferFactory interface) to perform
# a self-transfer merge: all holdings of a wallet are combined into one.
#
# For each wallet with >1 holding:
#   1. Validates that a MergeDelegation contract exists
#   2. Exercises TransferFactory_Transfer (self-transfer with all input holdings)
#   3. If a TransferInstruction is created, exercises TransferInstruction_Accept
#   4. Records the merged Holding
#
# Prerequisites:
#   - quickstart must be running
#   - 07-query-holdings-cbtc.sh must have been run (creates user-wallet-holdings-cbtc.json)
#   - 03-register-cbtc-token.sh (setup-exchange) must have been run (creates cbtc-factories.json)
#   - 04-create-merge-delegation.sh must have been run (MergeDelegation contracts)
#
# Usage: ./09-merge-holdings-cbtc.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-exchange" && pwd)"

# Load shared configuration
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[merge-cbtc] ERROR: $SETUP_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

# Load local utxo-handling .env (overridable params)
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"
RUN_ID=$(date +%s%N 2>/dev/null || date +%s)

# Load CBTC config
CBTC_CONFIG_FILE="$SETUP_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[merge-cbtc] ERROR: CBTC config not found: $CBTC_CONFIG_FILE" >&2
  exit 1
fi
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")

# Load CBTC-NETWORK keypair
CBTC_KEYPAIR_FILE="$SETUP_DIR/cbtc-network-keypair.json"
if [ ! -f "$CBTC_KEYPAIR_FILE" ]; then
  echo "[merge-cbtc] ERROR: CBTC-NETWORK keypair not found: $CBTC_KEYPAIR_FILE" >&2
  exit 1
fi
CBTC_NETWORK_PARTY=$(jq -r '.partyId' "$CBTC_KEYPAIR_FILE")

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

NUM_WALLETS=$(jq 'length' "$KEYPAIRS_FILE")

# Load factory data from cbtc-factories.json
FACTORIES_FILE="$SETUP_DIR/cbtc-factories.json"
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

# Template IDs (utility packages)
ALLOCATION_FACTORY_TEMPLATE="#utility-registry-app-v0:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory"
TRANSFER_OFFER_TEMPLATE="#utility-registry-app-v0:Utility.Registry.App.V0.Model.Transfer:TransferOffer"
HOLDING_TEMPLATE="#utility-registry-holding-v0:Utility.Registry.Holding.V0.Holding:Holding"
DELEGATION_TEMPLATE="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegation"

# Interface IDs (Splice standard — for exercising interface choices, put in templateId field)
# Canton JSON API v2 interactive-submission/prepare requires interface ID in templateId, NOT in interfaceId
TRANSFER_FACTORY_INTERFACE="55ba4deb0ad4662c4168b39859738a0e91388d252286480c7331b3f71a517281:Splice.Api.Token.TransferInstructionV1:TransferFactory"
TRANSFER_INSTRUCTION_INTERFACE="55ba4deb0ad4662c4168b39859738a0e91388d252286480c7331b3f71a517281:Splice.Api.Token.TransferInstructionV1:TransferInstruction"

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

# Interactive submission: prepare -> sign -> execute (with retry for transient errors)
# Uses temp files to avoid shell variable corruption with large base64 payloads.
interactive_submit() {
  local commands_json="$1"
  local act_as_party="$2"
  local private_key="$3"
  local fingerprint="$4"
  local cmd_id_prefix="$5"
  local disclosed_json="${6:-[]}"
  local json_api="${7:-$APP_USER_JSON_API}"
  local auth_token="${8:-$CANTON_TOKEN}"
  local user_id="${9:-$SHARED_SECRET_USER}"

  local tmp_prepare="/tmp/canton-is-prepare-$$-${RANDOM}.json"
  local tmp_execute_body="/tmp/canton-is-exec-body-$$-${RANDOM}.json"
  local tmp_execute_resp="/tmp/canton-is-exec-resp-$$-${RANDOM}.json"

  local attempt
  for attempt in 1 2 3; do
    local cmd_id="${cmd_id_prefix}-${RUN_ID}-${RANDOM}${RANDOM}"

    local prepare_body
    prepare_body=$(jq -n \
      --argjson commands "$commands_json" \
      --arg cmdId "$cmd_id" \
      --arg userId "$user_id" \
      --arg syncId "$SYNCHRONIZER_ID" \
      --arg party "$act_as_party" \
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

    local prepare_http
    prepare_http=$(curl -s -S -w "%{http_code}" -o "$tmp_prepare" \
      "$json_api/v2/interactive-submission/prepare" \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      --data-raw "$prepare_body")

    if [ "$prepare_http" = "503" ] || [ "$prepare_http" = "429" ] || [ "$prepare_http" = "409" ]; then
      log "  (prepare returned $prepare_http, attempt $attempt/3, retrying in 3s...)" >&2
      sleep 3
      continue
    fi

    if [ "$prepare_http" != "200" ] && [ "$prepare_http" != "201" ]; then
      log_error "Prepare failed with HTTP $prepare_http"
      log_error "Response: $(head -c 500 "$tmp_prepare" 2>/dev/null)"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 1
    fi

    local prepared_hash
    prepared_hash=$(jq -r '.preparedTransactionHash // empty' "$tmp_prepare")
    local hashing_version
    hashing_version=$(jq -r '.hashingSchemeVersion // empty' "$tmp_prepare")

    if [ -z "$prepared_hash" ]; then
      log_error "Prepare response missing preparedTransactionHash"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 1
    fi

    local sig
    sig=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
      const { signTransactionHash } = require('@canton-network/core-signing-lib');
      const signature = signTransactionHash('$prepared_hash', '$private_key');
      process.stdout.write(signature);
    " 2>/dev/null) || sig=""

    if [ -z "$sig" ]; then
      log_error "Failed to sign prepared transaction"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 1
    fi

    jq -n \
      --arg userId "$user_id" \
      --arg submissionId "merge-cbtc-${cmd_id}" \
      --arg preparedTx "$(jq -r '.preparedTransaction' "$tmp_prepare")" \
      --arg hashVersion "$hashing_version" \
      --arg party "$act_as_party" \
      --arg sig "$sig" \
      --arg signedBy "$fingerprint" \
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
      }' > "$tmp_execute_body"

    local execute_http
    execute_http=$(curl -s -S -w "%{http_code}" -o "$tmp_execute_resp" \
      "$json_api/v2/interactive-submission/executeAndWaitForTransaction" \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      -d @"$tmp_execute_body")

    if [ "$execute_http" = "503" ] || [ "$execute_http" = "429" ] || [ "$execute_http" = "409" ]; then
      log "  (execute returned $execute_http, attempt $attempt/3, retrying in 3s...)" >&2
      sleep 3
      continue
    fi

    if [ "$execute_http" != "200" ] && [ "$execute_http" != "201" ]; then
      log_error "Execute failed with HTTP $execute_http"
      log_error "Response: $(head -c 500 "$tmp_execute_resp" 2>/dev/null)"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 1
    fi

    cat "$tmp_execute_resp"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 0
  done

  log_error "All 3 attempts failed for $cmd_id_prefix"
  rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
  return 1
}

# Query active contracts for MergeDelegation check
query_active_contracts() {
  local party="$1"
  local template_id="$2"
  local include_blob="${3:-false}"
  local verbose="${4:-false}"

  local ledger_end
  ledger_end=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

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

  curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
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
log "  CBTC-NETWORK: ${CBTC_NETWORK_PARTY:0:50}..."
log "  AllocationFactory (as TransferFactory): ${FACTORY_CID:0:40}..."
log "  InstrumentConfiguration: ${INSTRUMENT_CONFIG_CID:0:40}..."
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
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".[$i].fingerprint" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT..."

  # 1a. Verify MergeDelegation exists
  DELEG_RESPONSE=$(query_active_contracts "$WALLET_PARTY" "$DELEGATION_TEMPLATE" "false" "false")
  DELEG_CID=$(echo "$DELEG_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$DELEG_CID" ] || [ "$DELEG_CID" = "null" ]; then
    log_error "No MergeDelegation found for $WALLET_HINT"
    exit 1
  fi
  log "    MergeDelegation verified: ${DELEG_CID:0:30}..."

  # 1b. Read holdings from JSON file
  HOLDINGS_DATA=$(jq -c --arg hint "$WALLET_HINT" '
    .wallets[] | select(.partyHint == $hint) | .holdings
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

  # 1c. Exercise TransferFactory_Transfer (self-transfer) on AllocationFactory (via interface)
  # NOTE: For interface choices, put the interface ID in templateId (Canton JSON API v2 requirement)
  TRANSFER_CMD=$(jq -n \
    --arg templateId "$TRANSFER_FACTORY_INTERFACE" \
    --arg factoryCid "$FACTORY_CID" \
    --arg admin "$CBTC_NETWORK_PARTY" \
    --arg tokenId "$CBTC_TOKEN_ID" \
    --arg party "$WALLET_PARTY" \
    --arg amount "$TOTAL_AMOUNT" \
    --arg requestedAt "$REQUEST_TIME" \
    --arg executeBefore "$EXPIRE_TIME" \
    --argjson holdingCids "$HOLDING_CIDS" \
    --arg icCid "$INSTRUMENT_CONFIG_CID" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
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
      }
    }]')

  TRANSFER_TX=$(interactive_submit "$TRANSFER_CMD" "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" \
    "merge-transfer-$WALLET_HINT" "$DISCLOSED_CONTRACTS") || {
    log_error "TransferFactory_Transfer failed for $WALLET_HINT"
    exit 1
  }

  # For self-transfers (sender==receiver), the utility code may directly produce a merged Holding
  # without creating a TransferOffer. Check for both cases.
  INSTRUCTION_CID=$(echo "$TRANSFER_TX" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | (contains("TransferOffer") or contains("TransferInstruction")))
     | select(.templateId | tostring | contains("TransferFactory") | not)
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -n "$INSTRUCTION_CID" ] && [ "$INSTRUCTION_CID" != "null" ]; then
    # Two-step: TransferOffer was created → need to accept it
    log "    Transfer instruction created: ${INSTRUCTION_CID:0:30}..."

    # 1d. Exercise TransferInstruction_Accept (completes merge)
    # NOTE: For interface choices, put the interface ID in templateId (Canton JSON API v2 requirement)
    ACCEPT_CMD=$(jq -n \
      --arg templateId "$TRANSFER_INSTRUCTION_INTERFACE" \
      --arg contractId "$INSTRUCTION_CID" \
      --arg icCid "$INSTRUMENT_CONFIG_CID" \
      '[{
        ExerciseCommand: {
          templateId: $templateId,
          contractId: $contractId,
          choice: "TransferInstruction_Accept",
          choiceArgument: {
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
        }
      }]')

    ACCEPT_TX=$(interactive_submit "$ACCEPT_CMD" "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" \
      "merge-accept-$WALLET_HINT" "$DISCLOSED_CONTRACTS") || {
      log_error "TransferInstruction_Accept failed for $WALLET_HINT"
      exit 1
    }

    # Extract the merged Holding CID from accept response
    MERGED_CID=$(echo "$ACCEPT_TX" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | contains("Holding:Holding") or contains("Holding.V0.Holding:Holding"))
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")
  else
    # Self-transfer optimization: Holding was directly created (no TransferOffer step)
    log "    Self-transfer: merged directly (no TransferOffer step)"
    MERGED_CID=$(echo "$TRANSFER_TX" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | contains("Holding:Holding") or contains("Holding.V0.Holding:Holding"))
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")
  fi

  if [ -z "$MERGED_CID" ]; then
    log_error "Could not extract merged Holding CID for $WALLET_HINT"
    log_error "Events: $(echo "${ACCEPT_TX:-$TRANSFER_TX}" | jq -c '[.transaction.events[] | (.CreatedEvent // .created // empty) | {templateId, contractId}]' 2>/dev/null | head -c 500)"
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
# Step 3: Verify balances match input holdings
##############################################################################

log ""
log "Step 3: Verifying balances..."

VERIFICATION_PASSED=true
MISMATCHES=0

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".wallets[$i].partyHint" "$HOLDINGS_INPUT_FILE")

  ORIGINAL_TOTAL=$(jq -r ".wallets[$i].totalAmount" "$HOLDINGS_INPUT_FILE")

  MERGED_TOTAL=$(jq -r --arg hint "$WALLET_HINT" '
    .wallets[] | select(.partyHint == $hint) | .totalAmount
  ' "$MERGED_HOLDINGS_FILE" 2>/dev/null || echo "0")

  # Compare as integers (truncate decimals) to avoid formatting differences like 1151 vs 1151.0000000000
  ORIG_NORMALIZED=$(echo "$ORIGINAL_TOTAL" | jq 'tonumber | floor')
  MERGED_NORMALIZED=$(echo "$MERGED_TOTAL" | jq 'tonumber | floor')

  if [ "$ORIG_NORMALIZED" != "$MERGED_NORMALIZED" ]; then
    log_error "MISMATCH: $WALLET_HINT — original: $ORIGINAL_TOTAL, merged: $MERGED_TOTAL"
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
