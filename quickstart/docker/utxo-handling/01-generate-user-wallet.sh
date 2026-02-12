#!/bin/bash
# Generates 25 "user wallet" external parties on the Canton Network.
#
# This script:
#   1. Generates 25 Ed25519 keypairs (NaCl format)
#   2. Onboards 25 external parties via generate-topology + sign + allocate
#   3. Creates 25 Canton users with ActAs/ReadAs rights
#
# After running this script, use 02-request-minting-cbtc.sh or 03-request-faucet-amulet.sh
# to mint tokens for the user wallets.
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - 01-setup-exchange.sh must have been run (DARs uploaded)
#
# Usage: ./01-generate-user-wallet.sh

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
NUM_WALLETS="${NUM_WALLETS:-25}"

# Load shared configuration from setup-exchange .env
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[user-wallet] ERROR: $SETUP_DIR/.env not found. Run setup-exchange first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

# Alias for shared-secret user (uses the app-user participant)
SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# Output files
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[user-wallet] $*"
}

log_error() {
  echo "[user-wallet] ERROR: $*" >&2
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

curl_status_code() {
  local url=$1
  local token=$2
  local content_type=${3:-application/json}

  curl -s -o /dev/null -w "%{http_code}" "$url" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: $content_type"
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

  local cmd_id="${cmd_id_prefix}-$(date +%s)-$RANDOM"
  local tmp_prepare="/tmp/canton-is-prepare-$$-${RANDOM}.json"
  local tmp_execute_body="/tmp/canton-is-exec-body-$$-${RANDOM}.json"
  local tmp_execute_resp="/tmp/canton-is-exec-resp-$$-${RANDOM}.json"

  local prepare_body
  prepare_body=$(jq -n \
    --argjson commands "$commands_json" \
    --arg cmdId "$cmd_id" \
    --arg userId "$SHARED_SECRET_USER" \
    --arg syncId "$SYNCHRONIZER_ID" \
    --arg party "$act_as_party" \
    '{
      commands: $commands,
      commandId: $cmdId,
      userId: $userId,
      actAs: [$party],
      readAs: [],
      disclosedContracts: [],
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
    --arg submissionId "user-wallet-${cmd_id}" \
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

  if [ "$execute_http" != "200" ] && [ "$execute_http" != "201" ]; then
    log_error "Execute failed with HTTP $execute_http"
    log_error "Response: $(head -c 500 "$tmp_execute_resp" 2>/dev/null)"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi

  cat "$tmp_execute_resp"
  rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
}

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Generate User Wallets"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
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
# Clean up downstream JSON files from previous runs
##############################################################################

log "Cleaning up downstream JSON files from previous runs..."
CLEANUP_FILES=(
  "$SCRIPT_DIR/user-wallet-holdings-cbtc.json"
  "$SCRIPT_DIR/user-wallet-holdings-amulet.json"
  "$SCRIPT_DIR/user-wallet-merge-delegation.json"
  "$SCRIPT_DIR/user-wallet-merged-holdings-cbtc.json"
  "$SCRIPT_DIR/user-wallet-merged-holdings-amulet.json"
)
for f in "${CLEANUP_FILES[@]}"; do
  if [ -f "$f" ]; then
    rm -f "$f"
    log "  Removed $(basename "$f")"
  fi
done
log "  Cleanup done."

##############################################################################
# Step 1: Generate 25 Ed25519 keypairs (idempotent)
##############################################################################

log ""
log "Step 1: Generating $NUM_WALLETS keypairs..."

if [ -f "$KEYPAIRS_FILE" ]; then
  EXISTING_COUNT=$(jq 'length' "$KEYPAIRS_FILE")
  if [ "$EXISTING_COUNT" -ge "$NUM_WALLETS" ]; then
    log "  Keypairs file already exists with $EXISTING_COUNT entries: $KEYPAIRS_FILE"
  else
    log "  Keypairs file exists but only has $EXISTING_COUNT entries, regenerating..."
    rm -f "$KEYPAIRS_FILE"
  fi
fi

if [ ! -f "$KEYPAIRS_FILE" ]; then
  KEYPAIRS_RAW=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { createKeyPair } = require('@canton-network/core-signing-lib');
    const crypto = require('crypto');
    const wallets = [];
    for (let i = 1; i <= $NUM_WALLETS; i++) {
      const kp = createKeyPair();
      const pubKeyBytes = Buffer.from(kp.publicKey, 'base64');
      const hashInput = Buffer.alloc(4 + pubKeyBytes.length);
      hashInput.writeUInt32BE(12, 0);
      pubKeyBytes.copy(hashInput, 4);
      const hash = crypto.createHash('sha256').update(hashInput).digest();
      const fingerprint = Buffer.concat([Buffer.from([0x12, 0x20]), hash]).toString('hex');
      const idx = String(i).padStart(2, '0');
      wallets.push({
        index: i - 1,
        partyHint: 'user-wallet-' + idx,
        userId: 'user-wallet-' + idx + '-user',
        partyId: '',
        publicKey: kp.publicKey,
        privateKey: kp.privateKey,
        fingerprint: fingerprint
      });
    }
    console.log(JSON.stringify(wallets));
  " 2>/dev/null) || KEYPAIRS_RAW=""

  if [ -z "$KEYPAIRS_RAW" ]; then
    log_error "Failed to generate keypairs. Ensure Node.js and @canton-network/core-signing-lib are available."
    exit 1
  fi

  echo "$KEYPAIRS_RAW" | jq '.' > "$KEYPAIRS_FILE"
  log "  Generated $NUM_WALLETS keypairs -> $KEYPAIRS_FILE"
fi

##############################################################################
# Step 2: Onboard external parties via generate-topology + sign + allocate
##############################################################################

log ""
log "Step 2: Onboarding $NUM_WALLETS external parties..."

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PUB=$(jq -r ".[$i].publicKey" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".[$i].fingerprint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")

  EXPECTED_PARTY="$WALLET_HINT::$WALLET_FP"

  # Always verify the party exists on the participant (topology may be lost after restart)
  PARTY_CHECK=$(curl_check "$APP_USER_JSON_API/v2/parties/party?parties=$EXPECTED_PARTY" "$CANTON_TOKEN" "application/json" \
    | jq -r '.partyDetails[0].party // empty' 2>/dev/null || echo "")

  if [ -n "$PARTY_CHECK" ] && [ "$PARTY_CHECK" != "null" ]; then
    WALLET_PARTY="$PARTY_CHECK"
    log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT already onboarded: ${WALLET_PARTY:0:40}..."
  else
    TOPO_BODY=$(jq -n \
      --arg sync "$SYNCHRONIZER_ID" \
      --arg keyData "$WALLET_PUB" \
      --arg hint "$WALLET_HINT" \
      '{
        synchronizer: $sync,
        publicKey: {
          format: "CRYPTO_KEY_FORMAT_RAW",
          keyData: $keyData,
          keySpec: "SIGNING_KEY_SPEC_EC_CURVE25519"
        },
        partyHint: $hint,
        confirmationThreshold: 1,
        otherConfirmingParticipantUids: [],
        observingParticipantUids: [],
        localParticipantObservationOnly: false
      }')

    TOPO_RESULT=$(curl_check "$APP_USER_JSON_API/v2/parties/external/generate-topology" "$CANTON_TOKEN" "application/json" \
      --data-raw "$TOPO_BODY") || {
      log_error "Failed to generate topology for $WALLET_HINT"
      exit 1
    }

    MULTI_HASH=$(echo "$TOPO_RESULT" | jq -r '.multiHash // empty')
    TOPO_PARTY_ID=$(echo "$TOPO_RESULT" | jq -r '.partyId // empty')
    PUB_KEY_FP=$(echo "$TOPO_RESULT" | jq -r '.publicKeyFingerprint // empty')
    TOPO_TRANSACTIONS=$(echo "$TOPO_RESULT" | jq -c '.topologyTransactions // []')

    if [ -z "$MULTI_HASH" ] || [ -z "$TOPO_PARTY_ID" ] || [ -z "$PUB_KEY_FP" ]; then
      log_error "generate-topology response missing required fields for $WALLET_HINT"
      exit 1
    fi

    SIGNED_HASH=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
      const { signTransactionHash } = require('@canton-network/core-signing-lib');
      const signature = signTransactionHash('$MULTI_HASH', '$WALLET_PRIV');
      process.stdout.write(signature);
    " 2>/dev/null) || SIGNED_HASH=""

    if [ -z "$SIGNED_HASH" ]; then
      log_error "Failed to sign topology hash for $WALLET_HINT"
      exit 1
    fi

    ONBOARDING_TXS=$(echo "$TOPO_TRANSACTIONS" | jq -c '[.[] | {transaction: ., signatures: []}]')

    ALLOCATE_BODY=$(jq -n \
      --arg sync "$SYNCHRONIZER_ID" \
      --argjson txs "$ONBOARDING_TXS" \
      --arg sig "$SIGNED_HASH" \
      --arg signedBy "$PUB_KEY_FP" \
      '{
        synchronizer: $sync,
        onboardingTransactions: $txs,
        multiHashSignatures: [{
          format: "SIGNATURE_FORMAT_RAW",
          signature: $sig,
          signedBy: $signedBy,
          signingAlgorithmSpec: "SIGNING_ALGORITHM_SPEC_ED25519"
        }],
        identityProviderId: ""
      }')

    ALLOCATE_RESULT=$(curl_check "$APP_USER_JSON_API/v2/parties/external/allocate" "$CANTON_TOKEN" "application/json" \
      --data-raw "$ALLOCATE_BODY") || {
      log_error "Failed to allocate external party $WALLET_HINT"
      exit 1
    }

    WALLET_PARTY=$(echo "$ALLOCATE_RESULT" | jq -r '.partyId // empty')
    if [ -z "$WALLET_PARTY" ]; then
      log_error "Allocate succeeded but no partyId in response for $WALLET_HINT"
      exit 1
    fi

    log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT allocated: ${WALLET_PARTY:0:40}..."
  fi

  jq --arg idx "$i" --arg partyId "$WALLET_PARTY" \
    '.[($idx | tonumber)].partyId = $partyId' "$KEYPAIRS_FILE" > "$KEYPAIRS_FILE.tmp" \
    && mv "$KEYPAIRS_FILE.tmp" "$KEYPAIRS_FILE"
done

log "  All $NUM_WALLETS external parties onboarded."

##############################################################################
# Step 3: Create Canton users + grant rights
##############################################################################

log ""
log "Step 3: Creating Canton users and granting rights..."

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".[$i].userId" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")

  curl_check "$APP_USER_JSON_API/v2/users/$SHARED_SECRET_USER/rights" "$CANTON_TOKEN" "application/json" \
    --data-raw '{
      "userId": "'"$SHARED_SECRET_USER"'",
      "identityProviderId": "",
      "rights": [
        {"kind": {"CanActAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}},
        {"kind": {"CanReadAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}}
      ]
    }' > /dev/null 2>&1 || true

  USER_STATUS=$(curl_status_code "$APP_USER_JSON_API/v2/users/$WALLET_USER" "$CANTON_TOKEN")

  if [ "$USER_STATUS" != "200" ]; then
    curl_check "$APP_USER_JSON_API/v2/users" "$CANTON_TOKEN" "application/json" \
      --data-raw '{
        "user": {
          "id": "'"$WALLET_USER"'",
          "isDeactivated": false,
          "primaryParty": "'"$WALLET_PARTY"'",
          "identityProviderId": "",
          "metadata": {
            "resourceVersion": "",
            "annotations": {
              "username": "'"$WALLET_HINT"'"
            }
          }
        },
        "rights": []
      }' > /dev/null
  fi

  curl_check "$APP_USER_JSON_API/v2/users/$WALLET_USER/rights" "$CANTON_TOKEN" "application/json" \
    --data-raw '{
      "userId": "'"$WALLET_USER"'",
      "identityProviderId": "",
      "rights": [
        {"kind": {"CanActAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}},
        {"kind": {"CanReadAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}}
      ]
    }' > /dev/null 2>&1 || true

  log "  [$((i+1))/$NUM_WALLETS] User $WALLET_USER created with rights"
done

log "  All $NUM_WALLETS users created."

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "User Wallet Generation Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets created: $NUM_WALLETS"
log "  Keypairs file: $KEYPAIRS_FILE"
log ""
log "Next steps:"
log "  ./02-request-minting-cbtc.sh    — Mint CBTC tokens for wallets"
log "  ./03-request-faucet-amulet.sh   — Faucet Amulet tokens for wallets"
log ""
