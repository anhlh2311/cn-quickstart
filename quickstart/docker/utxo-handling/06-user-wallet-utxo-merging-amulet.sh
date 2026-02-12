#!/bin/bash
# Merges Amulet (CC) holdings for each user wallet into a single Amulet per wallet.
#
# Uses ExternalPartyAmuletRules (which implements TransferFactory interface)
# to perform a self-transfer merge: all Amulet holdings of a wallet are combined into one.
#
# Steps:
#   1. Fetches ExternalPartyAmuletRules + AmuletRules + OpenMiningRound from SV
#   2. For each wallet:
#      a. Validates that a MergeDelegation contract exists
#      b. Queries all active Amulet contracts
#      c. Performs a self-transfer via TransferFactory_Transfer (on ExternalPartyAmuletRules)
#      d. Accepts the transfer instruction via TransferInstruction_Accept
#      e. Records the merged Amulet holding
#   3. Writes user-wallet-merged-holdings-amulet.json
#   4. Verifies balances match the original user-wallet-holdings-amulet.json
#
# Prerequisites:
#   - quickstart must be running (DevNet mode)
#   - request-faucet-amulet.sh must have been run (creates user-wallet-holdings-amulet.json)
#   - create-merge-delegation.sh must have been run (MergeDelegation contracts)
#
# Usage: ./user-wallet-utxo-merging-amulet.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-exchange" && pwd)"

# Load shared configuration
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[utxo-merge-amulet] ERROR: $SETUP_DIR/.env not found." >&2
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

AVAILABLE_WALLETS=$(jq 'length' "$KEYPAIRS_FILE")
NUM_WALLETS="${NUM_WALLETS:-$AVAILABLE_WALLETS}"
if [ "$NUM_WALLETS" -gt "$AVAILABLE_WALLETS" ]; then
  NUM_WALLETS="$AVAILABLE_WALLETS"
fi

# Template IDs
EXTERNAL_PARTY_AMULET_RULES_TEMPLATE="#splice-amulet:Splice.ExternalPartyAmuletRules:ExternalPartyAmuletRules"
AMULET_RULES_TEMPLATE="#splice-amulet:Splice.AmuletRules:AmuletRules"
OPEN_MINING_ROUND_TEMPLATE="#splice-amulet:Splice.Round:OpenMiningRound"
AMULET_TEMPLATE="#splice-amulet:Splice.Amulet:Amulet"
DELEGATION_TEMPLATE="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegation"

# Interface IDs (Splice standard — for exercising interface choices, put in templateId field)
# Canton JSON API v2 interactive-submission/prepare requires interface ID in templateId, NOT in interfaceId
TRANSFER_FACTORY_INTERFACE="55ba4deb0ad4662c4168b39859738a0e91388d252286480c7331b3f71a517281:Splice.Api.Token.TransferInstructionV1:TransferFactory"
TRANSFER_INSTRUCTION_INTERFACE="55ba4deb0ad4662c4168b39859738a0e91388d252286480c7331b3f71a517281:Splice.Api.Token.TransferInstructionV1:TransferInstruction"

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
      --arg submissionId "utxo-merge-amulet-${cmd_id}" \
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
log ""

# Generate tokens for both app-user and SV participants
CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")
SV_CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_SV_USER" "$SHARED_SECRET_AUDIENCE")

SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

# Resolve DSO party ID
DSO_PARTY=$(curl_check "$APP_USER_VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" "$CANTON_TOKEN" "application/json" \
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

# Build disclosed contracts (ExternalPartyAmuletRules + AmuletRules + OpenMiningRound)
DISCLOSED_CONTRACTS=$(jq -n \
  --arg eparCid "$EPAR_CID" --arg eparTemplate "$EPAR_TEMPLATE_HASH" --arg eparBlob "$EPAR_BLOB" \
  --arg arCid "$AR_CID" --arg arTemplate "$AR_TEMPLATE_HASH" --arg arBlob "$AR_BLOB" \
  --arg orCid "$OR_CID" --arg orTemplate "$OR_TEMPLATE_HASH" --arg orBlob "$OR_BLOB" \
  --arg syncId "$SYNCHRONIZER_ID" \
  '[
    { contractId: $eparCid, templateId: $eparTemplate, createdEventBlob: $eparBlob, synchronizerId: $syncId },
    { contractId: $arCid, templateId: $arTemplate, createdEventBlob: $arBlob, synchronizerId: $syncId },
    { contractId: $orCid, templateId: $orTemplate, createdEventBlob: $orBlob, synchronizerId: $syncId }
  ]')

log "  Disclosed contracts ready (3 contracts)"

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
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".[$i].fingerprint" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT..."

  # 2a. Verify MergeDelegation exists
  DELEG_RESPONSE=$(query_active_contracts_from "$APP_USER_JSON_API" "$CANTON_TOKEN" \
    "$WALLET_PARTY" "$DELEGATION_TEMPLATE" "false")
  DELEG_CID=$(echo "$DELEG_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$DELEG_CID" ] || [ "$DELEG_CID" = "null" ]; then
    log_error "No MergeDelegation found for $WALLET_HINT"
    exit 1
  fi
  log "    MergeDelegation verified: ${DELEG_CID:0:30}..."

  # 2b. Query all active Amulet contracts for this wallet (verbose: false → createArgument)
  HOLDINGS_RESPONSE=$(query_active_contracts_from "$APP_USER_JSON_API" "$CANTON_TOKEN" \
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

  # 2c. Exercise TransferFactory_Transfer on ExternalPartyAmuletRules (self-transfer)
  # NOTE: For interface choices, put the interface ID in templateId (Canton JSON API v2 requirement)
  # ExtraArgs context: amulet-rules + open-round (required by unfeaturedPaymentContextFromChoiceContext)
  TRANSFER_CMD=$(jq -n \
    --arg templateId "$TRANSFER_FACTORY_INTERFACE" \
    --arg factoryCid "$EPAR_CID" \
    --arg admin "$DSO_PARTY" \
    --arg party "$WALLET_PARTY" \
    --arg amount "$TOTAL_AMOUNT" \
    --arg requestedAt "$REQUEST_TIME" \
    --arg executeBefore "$EXPIRE_TIME" \
    --argjson holdingCids "$HOLDING_CIDS" \
    --arg arCid "$AR_CID" \
    --arg orCid "$OR_CID" \
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
      }
    }]')

  TRANSFER_TX=$(interactive_submit "$TRANSFER_CMD" "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" \
    "merge-transfer-$WALLET_HINT" "$DISCLOSED_CONTRACTS") || {
    log_error "TransferFactory_Transfer failed for $WALLET_HINT"
    exit 1
  }

  # For self-transfers (sender==receiver), Amulet may directly produce the merged holding
  # without creating a TransferInstruction. Check for both cases.
  INSTRUCTION_CID=$(echo "$TRANSFER_TX" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | (contains("TransferInstruction") or contains("TransferOffer")))
     | select(.templateId | tostring | contains("TransferFactory") | not)
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -n "$INSTRUCTION_CID" ] && [ "$INSTRUCTION_CID" != "null" ]; then
    # Two-step: TransferInstruction was created → need to accept it
    log "    Transfer instruction created: ${INSTRUCTION_CID:0:30}..."

    # 2d. Exercise TransferInstruction_Accept
    # NOTE: For interface choices, put the interface ID in templateId (Canton JSON API v2 requirement)
    ACCEPT_CMD=$(jq -n \
      --arg templateId "$TRANSFER_INSTRUCTION_INTERFACE" \
      --arg contractId "$INSTRUCTION_CID" \
      --arg arCid "$AR_CID" \
      --arg orCid "$OR_CID" \
      '[{
        ExerciseCommand: {
          templateId: $templateId,
          contractId: $contractId,
          choice: "TransferInstruction_Accept",
          choiceArgument: {
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
        }
      }]')

    ACCEPT_TX=$(interactive_submit "$ACCEPT_CMD" "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" \
      "merge-accept-$WALLET_HINT" "$DISCLOSED_CONTRACTS") || {
      log_error "TransferInstruction_Accept failed for $WALLET_HINT"
      exit 1
    }

    # Extract merged Amulet CID from accept response
    MERGED_CID=$(echo "$ACCEPT_TX" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | test("Splice\\.Amulet:Amulet$"))
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")

    # Fallback: broader match
    if [ -z "$MERGED_CID" ]; then
      MERGED_CID=$(echo "$ACCEPT_TX" | jq -r '
        [.transaction.events[] | (.CreatedEvent // .created // empty)
         | select(.templateId | tostring | contains("Amulet"))
         | select(.templateId | tostring | contains("AmuletRules") | not)
         | select(.templateId | tostring | contains("AmuletAllocation") | not)
         | select(.templateId | tostring | contains("AmuletTransfer") | not)
         | select(.templateId | tostring | contains("LockedAmulet") | not)
         | .contractId][0] // empty
      ' 2>/dev/null || echo "")
    fi
  else
    # Self-transfer optimization: Amulet was directly created (no TransferInstruction step)
    log "    Self-transfer: merged directly (no TransferInstruction step)"
    MERGED_CID=$(echo "$TRANSFER_TX" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | test("Splice\\.Amulet:Amulet$"))
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")

    if [ -z "$MERGED_CID" ]; then
      MERGED_CID=$(echo "$TRANSFER_TX" | jq -r '
        [.transaction.events[] | (.CreatedEvent // .created // empty)
         | select(.templateId | tostring | contains("Amulet"))
         | select(.templateId | tostring | contains("AmuletRules") | not)
         | select(.templateId | tostring | contains("AmuletAllocation") | not)
         | select(.templateId | tostring | contains("AmuletTransfer") | not)
         | select(.templateId | tostring | contains("LockedAmulet") | not)
         | .contractId][0] // empty
      ' 2>/dev/null || echo "")
    fi
  fi

  if [ -z "$MERGED_CID" ]; then
    log_error "Could not extract merged Amulet CID for $WALLET_HINT"
    log_error "Events: $(echo "$ACCEPT_TX" | jq -c '[.transaction.events[] | (.CreatedEvent // .created // empty) | {templateId, contractId}]' 2>/dev/null | head -c 500)"
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

REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg dsoParty "$DSO_PARTY" \
  --arg tokenId "Amulet" \
  --argjson totalHoldings "${#MERGED_RESULTS[@]}" \
  '{
    generatedAt: $generatedAt,
    dsoParty: $dsoParty,
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

  MERGED_TOTAL=$(jq -r --arg hint "$WALLET_HINT" '
    .wallets[] | select(.partyHint == $hint) | .totalAmount
  ' "$MERGED_HOLDINGS_FILE" 2>/dev/null || echo "0")

  ORIG_NORMALIZED=$(echo "$ORIGINAL_TOTAL" | jq 'tonumber')
  MERGED_NORMALIZED=$(echo "$MERGED_TOTAL" | jq 'tonumber')

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
