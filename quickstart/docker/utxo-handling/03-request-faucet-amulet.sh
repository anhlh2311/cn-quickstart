#!/bin/bash
# Faucets Amulet (CC) tokens for user wallets using DevNet_Tap.
#
# This script:
#   1. Fetches AmuletRules + OpenMiningRound from SV participant (for disclosed contracts)
#   2. For each user wallet, taps Amulet N times via AmuletRules_DevNet_Tap
#   3. Writes user-wallet-holdings-amulet.json with all Amulet holdings
#
# Prerequisites:
#   - quickstart must be running (DevNet mode)
#   - 01-generate-user-wallet.sh must have been run (wallets onboarded)
#
# Usage: ./03-request-faucet-amulet.sh

set -eo pipefail

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
TAPS_PER_WALLET="${TAPS_PER_WALLET:-20}"
MIN_AMOUNT="${MIN_AMOUNT:-100}"
MAX_AMOUNT="${MAX_AMOUNT:-1000}"

# Load shared configuration from setup-exchange .env
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[faucet-amulet] ERROR: $SETUP_DIR/.env not found. Run setup-exchange first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

# Alias for shared-secret user (uses the app-user participant)
SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# Template IDs for Amulet/Splice contracts
AMULET_RULES_TEMPLATE="#splice-amulet:Splice.AmuletRules:AmuletRules"
OPEN_MINING_ROUND_TEMPLATE="#splice-amulet:Splice.Round:OpenMiningRound"

# Load user wallet keypairs
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"
if [ ! -f "$KEYPAIRS_FILE" ]; then
  echo "[faucet-amulet] ERROR: User wallet keypairs not found: $KEYPAIRS_FILE" >&2
  echo "[faucet-amulet] Run 01-generate-user-wallet.sh first." >&2
  exit 1
fi
TOTAL_KEYPAIRS=$(jq 'length' "$KEYPAIRS_FILE")
if [ -z "$NUM_WALLETS" ] || [ "$NUM_WALLETS" -gt "$TOTAL_KEYPAIRS" ]; then
  NUM_WALLETS="$TOTAL_KEYPAIRS"
fi

# Output file
HOLDINGS_FILE="$SCRIPT_DIR/user-wallet-holdings-amulet.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[faucet-amulet] $*"
}

log_error() {
  echo "[faucet-amulet] ERROR: $*" >&2
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

# Unique run ID to prevent command ID collisions across runs
RUN_ID=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")

# Interactive submission: prepare -> sign -> execute
# Uses temp files to avoid shell variable corruption with large base64 payloads.
# Retries on transient errors (503, 429, 409) with fresh command IDs.
interactive_submit() {
  local commands_json="$1"
  local act_as_party="$2"
  local private_key="$3"
  local fingerprint="$4"
  local cmd_id_prefix="$5"
  local disclosed_json="${6:-[]}"

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
      --arg userId "$SHARED_SECRET_USER" \
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
      "$APP_USER_JSON_API/v2/interactive-submission/prepare" \
      -H "Authorization: Bearer $CANTON_TOKEN" \
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
      --arg userId "$SHARED_SECRET_USER" \
      --arg submissionId "faucet-amulet-${cmd_id}" \
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
      "$APP_USER_JSON_API/v2/interactive-submission/executeAndWaitForTransaction" \
      -H "Authorization: Bearer $CANTON_TOKEN" \
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

# Query active contracts from a given JSON API endpoint
query_active_contracts_from() {
  local json_api="$1"
  local token="$2"
  local party="$3"
  local template_id="$4"
  local include_blob="${5:-false}"

  local ledger_end
  ledger_end=$(curl_check "$json_api/v2/state/ledger-end" "$token" "application/json" | jq -r '.offset')

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

  curl_check "$json_api/v2/state/active-contracts" "$token" "application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
}

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Faucet Amulet (CC) for User Wallets"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Taps per wallet: $TAPS_PER_WALLET"
log "  Amount range: $MIN_AMOUNT - $MAX_AMOUNT CC"
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

# Resolve DSO party ID from validator scan-proxy
DSO_PARTY=$(curl_check "$APP_USER_VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" "$CANTON_TOKEN" "application/json" \
  | jq -r '.dso_party_id // empty')

if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party ID"
  exit 1
fi
log "  DSO party: ${DSO_PARTY:0:50}..."

##############################################################################
# Step 1: Fetch AmuletRules + OpenMiningRound from SV participant
##############################################################################

log ""
log "Step 1: Fetching AmuletRules + OpenMiningRound from SV participant..."

# Query AmuletRules from SV (DSO is signatory, visible on SV)
AMULET_RULES_RESPONSE=$(query_active_contracts_from "$SV_JSON_API" "$SV_CANTON_TOKEN" \
  "$DSO_PARTY" "$AMULET_RULES_TEMPLATE" "true")

AMULET_RULES_CID=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
' 2>/dev/null || echo "")

AMULET_RULES_TEMPLATE_HASH=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
' 2>/dev/null || echo "")

AMULET_RULES_BLOB=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
' 2>/dev/null || echo "")

if [ -z "$AMULET_RULES_CID" ] || [ -z "$AMULET_RULES_BLOB" ]; then
  log_error "Could not fetch AmuletRules from SV participant"
  log_error "Response: $(echo "$AMULET_RULES_RESPONSE" | head -c 500)"
  exit 1
fi
log "  AmuletRules CID: ${AMULET_RULES_CID:0:40}..."

# Query OpenMiningRound from SV (pick the latest round)
OPEN_ROUND_RESPONSE=$(query_active_contracts_from "$SV_JSON_API" "$SV_CANTON_TOKEN" \
  "$DSO_PARTY" "$OPEN_MINING_ROUND_TEMPLATE" "true")

OPEN_ROUND_CID=$(echo "$OPEN_ROUND_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
   | {contractId, round: (.createArguments.round // .createArguments.round.number // 0)}]
  | sort_by(.round) | last | .contractId // empty
' 2>/dev/null || echo "")

OPEN_ROUND_TEMPLATE_HASH=$(echo "$OPEN_ROUND_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
' 2>/dev/null || echo "")

OPEN_ROUND_BLOB=$(echo "$OPEN_ROUND_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
   | {createdEventBlob, round: (.createArguments.round // .createArguments.round.number // 0)}]
  | sort_by(.round) | last | .createdEventBlob // empty
' 2>/dev/null || echo "")

if [ -z "$OPEN_ROUND_CID" ] || [ -z "$OPEN_ROUND_BLOB" ]; then
  log_error "Could not fetch OpenMiningRound from SV participant"
  log_error "Response: $(echo "$OPEN_ROUND_RESPONSE" | head -c 500)"
  exit 1
fi
log "  OpenMiningRound CID: ${OPEN_ROUND_CID:0:40}..."

# Build disclosed contracts array
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

log "  Disclosed contracts ready (AmuletRules + OpenMiningRound)"

##############################################################################
# Step 2: Tap Amulet for each user wallet
##############################################################################

log ""
log "Step 2: Tapping Amulet ($TAPS_PER_WALLET per wallet, $((NUM_WALLETS * TAPS_PER_WALLET)) total)..."

HOLDINGS=()

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".[$i].fingerprint" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT: tapping $TAPS_PER_WALLET times..."

  for j in $(seq 1 "$TAPS_PER_WALLET"); do
    AMOUNT=$(( (RANDOM % (MAX_AMOUNT - MIN_AMOUNT + 1)) + MIN_AMOUNT ))

    CMD_JSON=$(jq -n \
      --arg contractId "$AMULET_RULES_CID" \
      --arg templateId "$AMULET_RULES_TEMPLATE" \
      --arg receiver "$WALLET_PARTY" \
      --arg amount "${AMOUNT}.0" \
      --arg openRound "$OPEN_ROUND_CID" \
      '[{
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
      }]')

    TX_RESULT=$(interactive_submit "$CMD_JSON" "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" \
      "tap-${WALLET_HINT}-${j}" "$DISCLOSED_CONTRACTS") || {
      log_error "Failed to tap Amulet #$j for $WALLET_HINT"
      exit 1
    }

    # Extract created Amulet contract ID (template contains "Splice.Amulet:Amulet")
    AMULET_CID=$(echo "$TX_RESULT" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | test("Splice\\.Amulet:Amulet$"))
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")

    # Fallback: match any Amulet that is NOT AmuletRules/AmuletAllocation
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
      log_error "Could not extract Amulet contract ID for $WALLET_HINT tap #$j"
      log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
      exit 1
    fi

    HOLDINGS+=("${i}|${AMULET_CID}|${AMOUNT}")
  done

  log "    Tapped $TAPS_PER_WALLET Amulet holdings for $WALLET_HINT"
done

log "  Total Amulet holdings created: ${#HOLDINGS[@]}"

##############################################################################
# Step 3: Write holdings report
##############################################################################

log ""
log "Step 3: Writing holdings report..."

REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg dsoParty "$DSO_PARTY" \
  --arg tokenId "Amulet" \
  --argjson totalHoldings "${#HOLDINGS[@]}" \
  '{
    generatedAt: $generatedAt,
    dsoParty: $dsoParty,
    tokenId: $tokenId,
    totalHoldings: $totalHoldings,
    wallets: []
  }')

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".[$i].userId" "$KEYPAIRS_FILE")

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
    --arg hint "$WALLET_HINT" \
    --arg partyId "$WALLET_PARTY" \
    --arg userId "$WALLET_USER" \
    --argjson holdings "$WALLET_HOLDINGS" \
    --argjson totalAmount "$WALLET_TOTAL" \
    '.wallets += [{ partyHint: $hint, partyId: $partyId, userId: $userId, holdings: $holdings, totalAmount: $totalAmount }]')
done

echo "$REPORT_JSON" | jq '.' > "$HOLDINGS_FILE"

GRAND_TOTAL=$(jq '[.wallets[].totalAmount] | add' "$HOLDINGS_FILE")

log "  Holdings report written to: $HOLDINGS_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Amulet Faucet Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets: $NUM_WALLETS"
log "  Holdings per wallet: $TAPS_PER_WALLET"
log "  Total holdings: ${#HOLDINGS[@]}"
log "  Total CC tapped: $GRAND_TOTAL"
log "  Holdings file: $HOLDINGS_FILE"
log ""
