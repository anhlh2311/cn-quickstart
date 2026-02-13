#!/bin/bash
# Mints CBTC tokens for user wallets using the Utility package's AllocationFactory.
#
# This script:
#   1. Creates mint requests via AllocationFactory_RequestMint (user wallet signs)
#   2. CBTC-NETWORK accepts all mint requests via MintRequest_Accept → creates Holdings
#   3. Writes user-wallet-holdings-cbtc.json with all holdings
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - 03-register-cbtc-token.sh must have been run (creates cbtc-factories.json)
#   - 01-generate-user-wallet.sh must have been run (wallets onboarded)
#
# Usage: ./02-request-minting-cbtc.sh

set -eo pipefail

# Unique run ID to prevent command ID collisions across runs
RUN_ID=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-exchange" && pwd)"

# Load utxo-handling configuration
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi
MINTS_PER_WALLET="${MINTS_PER_WALLET:-20}"
MIN_AMOUNT="${MIN_AMOUNT:-100}"
MAX_AMOUNT="${MAX_AMOUNT:-1000}"

# Load shared configuration from setup-exchange .env
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[mint-cbtc] ERROR: $SETUP_DIR/.env not found. Run setup-exchange first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

# Load CBTC configuration
CBTC_CONFIG_FILE="$SETUP_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[mint-cbtc] ERROR: CBTC config not found: $CBTC_CONFIG_FILE" >&2
  echo "[mint-cbtc] Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")

# Load CBTC-NETWORK keypair
CBTC_KEYPAIR_FILE="$SETUP_DIR/cbtc-network-keypair.json"
if [ ! -f "$CBTC_KEYPAIR_FILE" ]; then
  echo "[mint-cbtc] ERROR: CBTC-NETWORK keypair not found: $CBTC_KEYPAIR_FILE" >&2
  echo "[mint-cbtc] Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
CBTC_NETWORK_PARTY=$(jq -r '.partyId' "$CBTC_KEYPAIR_FILE")
CBTC_PRIV_KEY=$(jq -r '.privateKey' "$CBTC_KEYPAIR_FILE")
CBTC_FP=$(jq -r '.fingerprint' "$CBTC_KEYPAIR_FILE")

if [ -z "$CBTC_NETWORK_PARTY" ] || [ "$CBTC_NETWORK_PARTY" = "null" ]; then
  echo "[mint-cbtc] ERROR: CBTC-NETWORK partyId is empty in $CBTC_KEYPAIR_FILE" >&2
  exit 1
fi

# Load CBTC factories configuration (AllocationFactory + InstrumentConfiguration)
FACTORIES_FILE="$SETUP_DIR/cbtc-factories.json"
if [ ! -f "$FACTORIES_FILE" ]; then
  echo "[mint-cbtc] ERROR: CBTC factories not found: $FACTORIES_FILE" >&2
  echo "[mint-cbtc] Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
ALLOCATION_FACTORY_CID=$(jq -r '.factories.allocationFactory.contractId' "$FACTORIES_FILE")
INSTRUMENT_CONFIG_CID=$(jq -r '.instrumentConfiguration.contractId' "$FACTORIES_FILE")

if [ -z "$ALLOCATION_FACTORY_CID" ] || [ "$ALLOCATION_FACTORY_CID" = "null" ]; then
  echo "[mint-cbtc] ERROR: AllocationFactory CID not found in $FACTORIES_FILE" >&2
  exit 1
fi
if [ -z "$INSTRUMENT_CONFIG_CID" ] || [ "$INSTRUMENT_CONFIG_CID" = "null" ]; then
  echo "[mint-cbtc] ERROR: InstrumentConfiguration CID not found in $FACTORIES_FILE" >&2
  exit 1
fi

# Build disclosed contracts JSON for interactive submissions (user wallets need
# AllocationFactory + InstrumentConfiguration disclosed since they're not signatories)
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

# Template IDs for utility packages
ALLOCATION_FACTORY_TEMPLATE="#utility-registry-app-v0:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory"
MINT_REQUEST_TEMPLATE="#utility-registry-app-v0:Utility.Registry.App.V0.Model.Mint:MintRequest"

# Alias for shared-secret user (uses the app-user participant)
SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# Load user wallet keypairs
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"
if [ ! -f "$KEYPAIRS_FILE" ]; then
  echo "[mint-cbtc] ERROR: User wallet keypairs not found: $KEYPAIRS_FILE" >&2
  echo "[mint-cbtc] Run 01-generate-user-wallet.sh first." >&2
  exit 1
fi
TOTAL_KEYPAIRS=$(jq '.wallets | length' "$KEYPAIRS_FILE")
# Use configured NUM_WALLETS but cap at available keypairs
if [ -z "$NUM_WALLETS" ] || [ "$NUM_WALLETS" -gt "$TOTAL_KEYPAIRS" ]; then
  NUM_WALLETS="$TOTAL_KEYPAIRS"
fi

# Output file
HOLDINGS_FILE="$SCRIPT_DIR/user-wallet-holdings-cbtc.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[mint-cbtc] $*"
}

log_error() {
  echo "[mint-cbtc] ERROR: $*" >&2
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

# Interactive submission: prepare → sign → execute
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
    # Generate fresh command ID for each attempt to avoid SUBMISSION_ALREADY_IN_FLIGHT
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

    if [ "$prepare_http" != "200" ] && [ "$prepare_http" != "201" ]; then
      if { [ "$prepare_http" = "503" ] || [ "$prepare_http" = "429" ] || [ "$prepare_http" = "409" ]; } && [ "$attempt" -lt 3 ]; then
        log "  (prepare returned $prepare_http, attempt $attempt/3, retrying in 3s...)" >&2
        sleep 3
        continue
      fi
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
      --arg submissionId "mint-cbtc-${cmd_id}" \
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

    if [ "$execute_http" = "200" ] || [ "$execute_http" = "201" ]; then
      cat "$tmp_execute_resp"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 0
    fi
    if { [ "$execute_http" = "503" ] || [ "$execute_http" = "429" ] || [ "$execute_http" = "409" ]; } && [ "$attempt" -lt 3 ]; then
      log "  (execute returned $execute_http, attempt $attempt/3, retrying in 3s...)" >&2
      sleep 3
      continue
    fi
    log_error "Execute failed with HTTP $execute_http"
    log_error "Response: $(head -c 500 "$tmp_execute_resp" 2>/dev/null)"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  done

  log_error "interactive_submit failed after 3 attempts"
  rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
  return 1
}

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Mint CBTC for User Wallets"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Mints per wallet: $MINTS_PER_WALLET"
log "  Amount range: $MIN_AMOUNT - $MAX_AMOUNT CBTC"
log "  CBTC-NETWORK party: ${CBTC_NETWORK_PARTY:0:50}..."
log "  AllocationFactory: ${ALLOCATION_FACTORY_CID:0:40}..."
log "  InstrumentConfiguration: ${INSTRUMENT_CONFIG_CID:0:40}..."
log ""

CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")
# Token for CBTC-NETWORK user on the app-user participant (for MintRequest_Accept)
CBTC_NETWORK_USER="cbtc-network-user"
CANTON_CBTC_TOKEN=$(generate_canton_jwt "$CBTC_NETWORK_USER" "$SHARED_SECRET_AUDIENCE")

SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

##############################################################################
# Step 1: Request mints via AllocationFactory_RequestMint
##############################################################################

log ""
log "Step 1: Creating mint requests ($MINTS_PER_WALLET per wallet, $((NUM_WALLETS * MINTS_PER_WALLET)) total)..."

MINT_REQUESTS=()

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r '.partyHint' "$KEYPAIRS_FILE")
  WALLET_NAME=$(jq -r ".wallets[$i].userId" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".wallets[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".wallets[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".wallets[$i].fingerprint" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_NAME: creating $MINTS_PER_WALLET mint requests..."

  for j in $(seq 1 "$MINTS_PER_WALLET"); do
    AMOUNT=$(( (RANDOM % (MAX_AMOUNT - MIN_AMOUNT + 1)) + MIN_AMOUNT ))

    REQUESTED_AT=$(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ")
    EXECUTE_BEFORE=$(date -u -v+1d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+1 day" +"%Y-%m-%dT%H:%M:%SZ")

    CMD_JSON=$(jq -n \
      --arg contractId "$ALLOCATION_FACTORY_CID" \
      --arg templateId "$ALLOCATION_FACTORY_TEMPLATE" \
      --arg admin "$CBTC_NETWORK_PARTY" \
      --arg tokenId "$CBTC_TOKEN_ID" \
      --arg holder "$WALLET_PARTY" \
      --arg amount "${AMOUNT}.0" \
      --arg reference "user-mint-${WALLET_NAME}-${j}" \
      --arg requestedAt "$REQUESTED_AT" \
      --arg executeBefore "$EXECUTE_BEFORE" \
      --arg icCid "$INSTRUMENT_CONFIG_CID" \
      '[{
        ExerciseCommand: {
          templateId: $templateId,
          contractId: $contractId,
          choice: "AllocationFactory_RequestMint",
          choiceArgument: {
            expectedAdmin: $admin,
            mint: {
              instrumentId: { admin: $admin, id: $tokenId },
              amount: $amount,
              holder: $holder,
              reference: $reference,
              requestedAt: $requestedAt,
              executeBefore: $executeBefore,
              meta: { values: {} }
            },
            extraArgs: {
              context: {
                values: {
                  "utility.digitalasset.com/instrument-configuration": { tag: "AV_ContractId", value: $icCid },
                  "utility.digitalasset.com/issuer-credentials": { tag: "AV_List", value: [] }
                }
              },
              meta: { values: {} }
            }
          }
        }
      }]')

    TX_RESULT=$(interactive_submit "$CMD_JSON" "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" \
      "mint-req-${WALLET_NAME}-${j}" "$DISCLOSED_CONTRACTS") || {
      log_error "Failed to create mint request #$j for $WALLET_NAME"
      exit 1
    }

    MINT_CID=$(echo "$TX_RESULT" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("MintRequest")) | .contractId][0] // empty
    ' 2>/dev/null || echo "")

    if [ -z "$MINT_CID" ]; then
      log_error "Could not extract MintRequest contract ID for $WALLET_NAME mint #$j"
      log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
      exit 1
    fi

    MINT_REQUESTS+=("${i}|${MINT_CID}|${AMOUNT}")
  done

  log "    Created $MINTS_PER_WALLET mint requests for $WALLET_NAME"
done

log "  Total mint requests created: ${#MINT_REQUESTS[@]}"

##############################################################################
# Step 2: CBTC-NETWORK accepts all mint requests via MintRequest_Accept
##############################################################################

log ""
log "Step 2: CBTC-NETWORK accepting ${#MINT_REQUESTS[@]} mint requests..."

HOLDINGS=()
ACCEPT_COUNT=0

for entry in "${MINT_REQUESTS[@]}"; do
  IFS='|' read -r WALLET_IDX MINT_CID AMOUNT <<< "$entry"
  ACCEPT_COUNT=$((ACCEPT_COUNT + 1))

  if [ $((ACCEPT_COUNT % 50)) -eq 0 ] || [ "$ACCEPT_COUNT" -eq 1 ]; then
    log "  Accepting mint request $ACCEPT_COUNT/${#MINT_REQUESTS[@]}..."
  fi

  CMD_JSON=$(jq -n \
    --arg contractId "$MINT_CID" \
    --arg templateId "$MINT_REQUEST_TEMPLATE" \
    --arg icCid "$INSTRUMENT_CONFIG_CID" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
        contractId: $contractId,
        choice: "MintRequest_Accept",
        choiceArgument: {
          extraArgs: {
            context: {
              values: {
                "utility.digitalasset.com/instrument-configuration": { tag: "AV_ContractId", value: $icCid },
                "utility.digitalasset.com/issuer-credentials": { tag: "AV_List", value: [] }
              }
            },
            meta: { values: {} }
          }
        }
      }
    }]')

  TX_RESULT=$(interactive_submit "$CMD_JSON" "$CBTC_NETWORK_PARTY" "$CBTC_PRIV_KEY" "$CBTC_FP" \
    "accept-mint-$ACCEPT_COUNT" "[]" "$APP_USER_JSON_API" "$CANTON_CBTC_TOKEN" "$CBTC_NETWORK_USER") || {
    log_error "Failed to accept mint request $MINT_CID"
    exit 1
  }

  HOLDING_CID=$(echo "$TX_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("Holding:Holding")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$HOLDING_CID" ]; then
    log_error "Could not extract Holding contract ID for mint $MINT_CID"
    log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
    exit 1
  fi

  HOLDINGS+=("${WALLET_IDX}|${HOLDING_CID}|${AMOUNT}")
done

log "  All ${#HOLDINGS[@]} mint requests accepted."

##############################################################################
# Step 3: Write holdings report
##############################################################################

log ""
log "Step 3: Writing holdings report..."

PARTY_HINT_VALUE=$(jq -r '.partyHint' "$KEYPAIRS_FILE")

REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg partyHint "$PARTY_HINT_VALUE" \
  --arg cbtcNetworkParty "$CBTC_NETWORK_PARTY" \
  --arg tokenId "$CBTC_TOKEN_ID" \
  --argjson totalHoldings "${#HOLDINGS[@]}" \
  '{
    generatedAt: $generatedAt,
    partyHint: $partyHint,
    cbtcNetworkParty: $cbtcNetworkParty,
    tokenId: $tokenId,
    totalHoldings: $totalHoldings,
    wallets: []
  }')

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_PARTY=$(jq -r ".wallets[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".wallets[$i].userId" "$KEYPAIRS_FILE")

  WALLET_HOLDINGS="[]"
  WALLET_TOTAL=0

  for entry in "${HOLDINGS[@]}"; do
    IFS='|' read -r WALLET_IDX HOLDING_CID AMOUNT <<< "$entry"
    if [ "$WALLET_IDX" = "$i" ]; then
      WALLET_HOLDINGS=$(echo "$WALLET_HOLDINGS" | jq \
        --arg cid "$HOLDING_CID" \
        --argjson amount "$AMOUNT" \
        '. + [{ contractId: $cid, amount: $amount }]')
      WALLET_TOTAL=$((WALLET_TOTAL + AMOUNT))
    fi
  done

  REPORT_JSON=$(echo "$REPORT_JSON" | jq \
    --arg partyId "$WALLET_PARTY" \
    --arg userId "$WALLET_USER" \
    --argjson holdings "$WALLET_HOLDINGS" \
    --argjson totalAmount "$WALLET_TOTAL" \
    '.wallets += [{ partyId: $partyId, userId: $userId, holdings: $holdings, totalAmount: $totalAmount }]')
done

echo "$REPORT_JSON" | jq '.' > "$HOLDINGS_FILE"

GRAND_TOTAL=$(jq '[.wallets[].totalAmount] | add' "$HOLDINGS_FILE")

log "  Holdings report written to: $HOLDINGS_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "CBTC Minting Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets: $NUM_WALLETS"
log "  Holdings per wallet: $MINTS_PER_WALLET"
log "  Total holdings: ${#HOLDINGS[@]}"
log "  Total CBTC minted: $GRAND_TOTAL"
log "  Holdings file: $HOLDINGS_FILE"
log ""
