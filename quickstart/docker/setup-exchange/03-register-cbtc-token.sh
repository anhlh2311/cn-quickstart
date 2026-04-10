#!/bin/bash
# Registers the CBTC token in the canton-exchange-backend using the Utility package.
# This script:
#   1. Generates an Ed25519 keypair (NaCl format) and stores it in cbtc-network-keypair.json
#   2. Onboards "CBTC-NETWORK" as an external party via generate-topology + sign + allocate
#   3. Creates a Canton user for the external party with ActAs/ReadAs rights
#   4. Creates an InstrumentConfiguration contract on the ledger (utility-registry-v0)
#   5. Creates an AllocationFactory contract on the ledger (utility-registry-app-v0)
#      — this single contract implements AllocationFactory, TransferFactory, AND BurnMintFactory interfaces
#   5b. Creates a TransferRule contract on the ledger (utility-registry-v0)
#       — must be disclosed during transfers; signatory: provider+registrar=CBTC-NETWORK
#   5c. Creates an AppRewardConfiguration contract on the ledger (utility-registry-v0)
#       — defines operator/provider app reward split; signatory: operator=APP_USER_PARTY
#   6. Acquires disclosures (createdEventBlob) for all four contracts
#   7. Writes cbtc-factories.json with all contract IDs and disclosures
#   8. Registers the token issuer in the backend (POST /token-issuer) with factory + disclosed contracts
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - 01-setup-exchange.sh must have been run (DARs uploaded, contracts created)
#   - canton-exchange-backend must be running (yarn start:dev)
#   - Utility DARs must be uploaded (included in DAR_FILES in .env)
#
# Usage: ./03-register-cbtc-token.sh
#
# Note: The previous fungible-token version is preserved as 03-register-cbtc-token-using-fungible-token.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUICKSTART_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load shared configuration from .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[register-cbtc] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

# Load CBTC configuration from JSON
CBTC_CONFIG_FILE="$SCRIPT_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[register-cbtc] ERROR: CBTC config not found: $CBTC_CONFIG_FILE" >&2
  exit 1
fi
CBTC_NETWORK_USER_ID=$(jq -r '.networkUserId' "$CBTC_CONFIG_FILE")
CBTC_NETWORK_PARTY_HINT=$(jq -r '.partyHint' "$CBTC_CONFIG_FILE")
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")
CBTC_DISPLAY_NAME=$(jq -r '.displayName' "$CBTC_CONFIG_FILE")
CBTC_SYMBOL=$(jq -r '.symbol' "$CBTC_CONFIG_FILE")
CBTC_PRICE_SOURCE_ID=$(jq -r '.priceSourceId' "$CBTC_CONFIG_FILE")

# Alias for shared-secret user (uses the app-user participant)
SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# DB credentials from shared .env
DB_HOST="$EXCHANGE_DB_HOST"
DB_PORT="$EXCHANGE_DB_PORT"
DB_USERNAME="$EXCHANGE_DB_USERNAME"
DB_PASSWORD="$EXCHANGE_DB_PASSWORD"
DB_NAME="$EXCHANGE_DB_NAME"

# Template IDs for utility packages
INSTRUMENT_CONFIG_TEMPLATE="#utility-registry-v0:Utility.Registry.V0.Configuration.Instrument:InstrumentConfiguration"
ALLOCATION_FACTORY_TEMPLATE="#utility-registry-app-v0:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory"
TRANSFER_RULE_TEMPLATE="#utility-registry-v0:Utility.Registry.V0.Rule.Transfer:TransferRule"
APP_REWARD_CONFIG_TEMPLATE="#utility-registry-v0:Utility.Registry.V0.Configuration.AppReward:AppRewardConfiguration"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[register-cbtc] $*"
}

log_error() {
  echo "[register-cbtc] ERROR: $*" >&2
}

# Make an HTTP request with error handling
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

# Get DSO party from scan-proxy
get_dso_party() {
  local token="$1"
  local validator_api="$2"
  curl_check "$validator_api/api/validator/v0/scan-proxy/dso-party-id" "$token" "application/json" | jq -r '.dso_party_id // empty'
}

# Make an HTTP request returning status code (no error on non-2xx)
curl_status_code() {
  local url=$1
  local token=$2
  local content_type=${3:-application/json}

  curl -s -o /dev/null -w "%{http_code}" "$url" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: $content_type"
}

# Generate Canton shared-secret JWT
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

# Generate a backend JWT for the setup user
generate_backend_jwt() {
  local user_id="$1"
  local email="$2"
  local now
  now=$(date +%s)
  local exp=$((now + 86400))

  b64url() {
    openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
  }

  local header
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  local payload
  payload=$(printf '{"sub":"%s","email":"%s","iat":%d,"exp":%d}' "$user_id" "$email" "$now" "$exp" | b64url)
  local signature
  signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$BACKEND_JWT_SECRET" -binary | b64url)

  echo "${header}.${payload}.${signature}"
}

# Query active contracts by party and template
query_active_contracts() {
  local party="$1"
  local template_id="$2"
  local include_blob="${3:-false}"

  local ledger_end
  ledger_end=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

  local query_body
  query_body=$(cat <<AQEOF
{
  "filter":{
    "filtersByParty":{
      "$party":{
        "cumulative":[{
          "identifierFilter":{
            "TemplateFilter":{
              "value":{
                "templateId":"$template_id",
                "includeCreatedEventBlob":$include_blob
              }
            }
          }
        }]
      }
    }
  },
  "verbose":false,
  "activeAtOffset":"$ledger_end"
}
AQEOF
)

  curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
    --data-raw "$query_body"
}

# Interactive submission: prepare → sign → execute
# Uses temp files to avoid shell variable corruption with large base64 payloads.
# Args: $1=commands_json, $2=act_as_party, $3=private_key, $4=fingerprint, $5=command_id_prefix, $6=submission_id_prefix
interactive_submit() {
  local commands_json="$1"
  local act_as_party="$2"
  local private_key="$3"
  local fingerprint="$4"
  local cmd_id_prefix="$5"
  local submission_id_prefix="$6"

  local cmd_id="${cmd_id_prefix}-$(date +%s)-$RANDOM"
  local tmp_prepare="/tmp/canton-is-prepare-$$-${RANDOM}.json"
  local tmp_execute_body="/tmp/canton-is-exec-body-$$-${RANDOM}.json"
  local tmp_execute_resp="/tmp/canton-is-exec-resp-$$-${RANDOM}.json"

  # Ensure synchronizer ID is available
  if [ -z "$SYNCHRONIZER_ID" ]; then
    SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
      | jq -r '.connectedSynchronizers[0].synchronizerId // empty')
  fi

  # Prepare — save response to file to handle large base64 preparedTransaction
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
    log_error "Response: $(head -c 500 "$tmp_prepare")"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi

  local prepared_hash
  prepared_hash=$(jq -r '.preparedTransactionHash // empty' "$tmp_prepare")
  local hashing_version
  hashing_version=$(jq -r '.hashingSchemeVersion // empty' "$tmp_prepare")

  if [ -z "$prepared_hash" ]; then
    log_error "Prepare response missing preparedTransactionHash"
    log_error "Response: $(head -c 500 "$tmp_prepare")"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi
  log "    Prepared hash: ${prepared_hash:0:30}..."

  # Sign
  log "    Signing..."
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

  # Build execute body from prepare file (avoids passing large base64 through shell vars)
  jq -n \
    --arg userId "$SHARED_SECRET_USER" \
    --arg submissionId "${submission_id_prefix}-${cmd_id}" \
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

  # Execute — save response to file to preserve large JSON with event blobs
  log "    Executing..."
  local execute_http
  execute_http=$(curl -s -S -w "%{http_code}" -o "$tmp_execute_resp" \
    "$APP_USER_JSON_API/v2/interactive-submission/executeAndWaitForTransaction" \
    -H "Authorization: Bearer $CANTON_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$tmp_execute_body")

  if [ "$execute_http" != "200" ] && [ "$execute_http" != "201" ]; then
    log_error "Execute failed with HTTP $execute_http"
    log_error "Response: $(head -c 500 "$tmp_execute_resp")"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi

  # Output the response (from file, not shell variable) and clean up
  cat "$tmp_execute_resp"
  rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
}

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Register CBTC Token (Utility Package)"
log "=========================================="

BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
if [ ! -f "$BACKEND_ENV" ]; then
  log_error "Backend .env not found: $BACKEND_ENV"
  log_error "Run setup-exchange.sh first."
  exit 1
fi

# Check backend is running
if ! curl -sf "$BACKEND_URL" > /dev/null 2>&1; then
  log_error "Backend not reachable at $BACKEND_URL"
  log_error "Start the backend first: cd $EXCHANGE_BACKEND_DIR && yarn start:dev"
  exit 1
fi
log "  Backend is running at $BACKEND_URL"

# Generate Canton token for app-user participant (admin operations)
CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

# Ensure setup user exists in backend DB and generate backend JWT
log "  Ensuring setup user exists in database..."
UPSERT_SQL="INSERT INTO users (id, email, username, password, first_name, last_name, is_active) VALUES ('$SETUP_USER_ID', '$SETUP_USER_EMAIL', '$SETUP_USER_NAME', 'setup-no-login', 'Setup', 'Script', true) ON CONFLICT (id) DO NOTHING;"

if command -v psql > /dev/null 2>&1; then
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_NAME" -q -c "$UPSERT_SQL" 2>/dev/null || \
    docker exec -e PGPASSWORD="$DB_PASSWORD" canton-exchange-postgres \
      psql -h localhost -U "$DB_USERNAME" -d "$DB_NAME" -q -c "$UPSERT_SQL"
else
  docker exec -e PGPASSWORD="$DB_PASSWORD" canton-exchange-postgres \
    psql -h localhost -U "$DB_USERNAME" -d "$DB_NAME" -q -c "$UPSERT_SQL"
fi

BACKEND_TOKEN=$(generate_backend_jwt "$SETUP_USER_ID" "$SETUP_USER_EMAIL")

##############################################################################
# Step 1: Generate / load Ed25519 keypair (idempotent)
##############################################################################

log ""
log "Step 1: Generating keypair for $CBTC_NETWORK_PARTY_HINT..."

KEYPAIR_FILE="$SCRIPT_DIR/cbtc-network-keypair.json"

if [ -f "$KEYPAIR_FILE" ]; then
  log "  Keypair file already exists: $KEYPAIR_FILE"
  KEYPAIR_PUB=$(jq -r '.publicKey' "$KEYPAIR_FILE")
  KEYPAIR_PRIV=$(jq -r '.privateKey' "$KEYPAIR_FILE")
  KEYPAIR_FP=$(jq -r '.fingerprint' "$KEYPAIR_FILE")
else
  # Generate Ed25519 keypair using the backend's core-signing-lib (NaCl/TweetNaCl format)
  KEYPAIR_RAW=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { createKeyPair } = require('@canton-network/core-signing-lib');
    const crypto = require('crypto');
    const kp = createKeyPair();
    // Compute Canton fingerprint: 1220 + SHA256(uint32BE(12) + publicKeyBytes)
    const pubKeyBytes = Buffer.from(kp.publicKey, 'base64');
    const hashInput = Buffer.alloc(4 + pubKeyBytes.length);
    hashInput.writeUInt32BE(12, 0);
    pubKeyBytes.copy(hashInput, 4);
    const hash = crypto.createHash('sha256').update(hashInput).digest();
    const fingerprint = Buffer.concat([Buffer.from([0x12, 0x20]), hash]).toString('hex');
    console.log(JSON.stringify({ publicKey: kp.publicKey, privateKey: kp.privateKey, fingerprint }));
  " 2>/dev/null) || KEYPAIR_RAW=""

  if [ -z "$KEYPAIR_RAW" ]; then
    log_error "Failed to generate keypair. Ensure Node.js and @canton-network/core-signing-lib are available in $EXCHANGE_BACKEND_DIR"
    exit 1
  fi

  KEYPAIR_PUB=$(echo "$KEYPAIR_RAW" | jq -r '.publicKey')
  KEYPAIR_PRIV=$(echo "$KEYPAIR_RAW" | jq -r '.privateKey')
  KEYPAIR_FP=$(echo "$KEYPAIR_RAW" | jq -r '.fingerprint')

  # Save keypair to file (partyId will be populated after allocation in Step 2)
  jq -n \
    --arg partyId "" \
    --arg userId "$CBTC_NETWORK_USER_ID" \
    --arg partyHint "$CBTC_NETWORK_PARTY_HINT" \
    --arg publicKey "$KEYPAIR_PUB" \
    --arg privateKey "$KEYPAIR_PRIV" \
    --arg fingerprint "$KEYPAIR_FP" \
    '{
      partyId: $partyId,
      userId: $userId,
      partyHint: $partyHint,
      publicKey: $publicKey,
      privateKey: $privateKey,
      fingerprint: $fingerprint
    }' > "$KEYPAIR_FILE"

  log "  Keypair generated and stored: $KEYPAIR_FILE"
fi

log "  Public key: ${KEYPAIR_PUB:0:20}..."
log "  Fingerprint: ${KEYPAIR_FP:0:30}..."

# The expected external party ID is hint::fingerprint
EXPECTED_PARTY_ID="$CBTC_NETWORK_PARTY_HINT::$KEYPAIR_FP"
log "  Expected party ID: ${EXPECTED_PARTY_ID:0:50}..."

##############################################################################
# Step 2: Onboard external party via generate-topology + sign + allocate
##############################################################################

log ""
log "Step 2: Onboarding $CBTC_NETWORK_PARTY_HINT as external party..."

# Check if the external party already exists on the participant
PARTY_CHECK=$(curl_check "$APP_USER_JSON_API/v2/parties/party?parties=$EXPECTED_PARTY_ID" "$CANTON_TOKEN" "application/json" \
  | jq -r '.partyDetails[0].party // empty' 2>/dev/null || echo "")

if [ -n "$PARTY_CHECK" ] && [ "$PARTY_CHECK" != "null" ]; then
  CBTC_NETWORK_PARTY="$PARTY_CHECK"
  log "  External party already exists: $CBTC_NETWORK_PARTY"
else
  log "  External party not found, allocating..."

  # 2a. Get connected synchronizer
  SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
    | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

  if [ -z "$SYNCHRONIZER_ID" ]; then
    log_error "Could not get connected synchronizer"
    exit 1
  fi
  log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

  # 2b. Generate topology transactions
  log "  Generating external party topology..."
  TOPO_BODY=$(jq -n \
    --arg sync "$SYNCHRONIZER_ID" \
    --arg keyData "$KEYPAIR_PUB" \
    --arg hint "$CBTC_NETWORK_PARTY_HINT" \
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
    log_error "Failed to generate external party topology"
    exit 1
  }

  MULTI_HASH=$(echo "$TOPO_RESULT" | jq -r '.multiHash // empty')
  TOPO_PARTY_ID=$(echo "$TOPO_RESULT" | jq -r '.partyId // empty')
  PUB_KEY_FP=$(echo "$TOPO_RESULT" | jq -r '.publicKeyFingerprint // empty')
  TOPO_TRANSACTIONS=$(echo "$TOPO_RESULT" | jq -c '.topologyTransactions // []')

  if [ -z "$MULTI_HASH" ] || [ -z "$TOPO_PARTY_ID" ] || [ -z "$PUB_KEY_FP" ]; then
    log_error "generate-topology response missing required fields"
    log_error "Response: $(echo "$TOPO_RESULT" | head -c 500)"
    exit 1
  fi
  log "  Topology generated for party: $TOPO_PARTY_ID"
  log "  MultiHash: ${MULTI_HASH:0:30}..."

  # 2c. Sign the multiHash with the private key (NaCl Ed25519 detached signature)
  log "  Signing topology hash..."
  SIGNED_HASH=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { signTransactionHash } = require('@canton-network/core-signing-lib');
    const signature = signTransactionHash('$MULTI_HASH', '$KEYPAIR_PRIV');
    process.stdout.write(signature);
  " 2>/dev/null) || SIGNED_HASH=""

  if [ -z "$SIGNED_HASH" ]; then
    log_error "Failed to sign topology hash"
    exit 1
  fi
  log "  Signature: ${SIGNED_HASH:0:30}..."

  # 2d. Build onboardingTransactions array from topology transactions
  ONBOARDING_TXS=$(echo "$TOPO_TRANSACTIONS" | jq -c '[.[] | {transaction: ., signatures: []}]')

  # 2e. Allocate the external party
  log "  Submitting external party allocation..."
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
    log_error "Failed to allocate external party"
    exit 1
  }

  CBTC_NETWORK_PARTY=$(echo "$ALLOCATE_RESULT" | jq -r '.partyId // empty')
  if [ -z "$CBTC_NETWORK_PARTY" ]; then
    log_error "Allocate succeeded but no partyId in response"
    log_error "Response: $(echo "$ALLOCATE_RESULT" | head -c 500)"
    exit 1
  fi
  log "  External party allocated: $CBTC_NETWORK_PARTY"
fi

# Update keypair file with resolved partyId
STORED_PARTY=$(jq -r '.partyId // empty' "$KEYPAIR_FILE")
if [ "$STORED_PARTY" != "$CBTC_NETWORK_PARTY" ]; then
  jq --arg partyId "$CBTC_NETWORK_PARTY" '.partyId = $partyId' "$KEYPAIR_FILE" > "$KEYPAIR_FILE.tmp" \
    && mv "$KEYPAIR_FILE.tmp" "$KEYPAIR_FILE"
  log "  Updated keypair file with partyId"
fi

##############################################################################
# Step 3: Create Canton user + grant rights for external party (idempotent)
##############################################################################

log ""
log "Step 3: Creating Canton user and granting rights for $CBTC_NETWORK_PARTY_HINT..."

# Read executor party ID from backend .env (needed for ReadAs grant)
APP_USER_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)

# 3a. Grant the admin user (ledger-api-user) rights to act as the external party
log "  Granting admin user rights over external party..."
ADMIN_RIGHTS='[
  {"kind": {"CanActAs": {"value": {"party": "'"$CBTC_NETWORK_PARTY"'"}}}},
  {"kind": {"CanReadAs": {"value": {"party": "'"$CBTC_NETWORK_PARTY"'"}}}}
]'
if [ -n "$APP_USER_PARTY" ]; then
  ADMIN_RIGHTS=$(echo "$ADMIN_RIGHTS" | jq --arg ep "$APP_USER_PARTY" \
    '. + [{"kind": {"CanReadAs": {"value": {"party": $ep}}}}]')
fi
curl_check "$APP_USER_JSON_API/v2/users/$SHARED_SECRET_USER/rights" "$CANTON_TOKEN" "application/json" \
  --data-raw '{
    "userId": "'"$SHARED_SECRET_USER"'",
    "identityProviderId": "",
    "rights": '"$ADMIN_RIGHTS"'
  }' > /dev/null 2>&1 || log "  (Admin rights may already be granted)"

# 3b. Create dedicated Canton user for the external party
USER_STATUS=$(curl_status_code "$APP_USER_JSON_API/v2/users/$CBTC_NETWORK_USER_ID" "$CANTON_TOKEN")

if [ "$USER_STATUS" = "200" ]; then
  log "  User '$CBTC_NETWORK_USER_ID' already exists"
else
  log "  Creating user '$CBTC_NETWORK_USER_ID'..."
  curl_check "$APP_USER_JSON_API/v2/users" "$CANTON_TOKEN" "application/json" \
    --data-raw '{
      "user": {
        "id": "'"$CBTC_NETWORK_USER_ID"'",
        "isDeactivated": false,
        "primaryParty": "'"$CBTC_NETWORK_PARTY"'",
        "identityProviderId": "",
        "metadata": {
          "resourceVersion": "",
          "annotations": {
            "username": "'"$CBTC_NETWORK_PARTY_HINT"'"
          }
        }
      },
      "rights": []
    }' > /dev/null
  log "  User created"
fi

# 3c. Grant ActAs + ReadAs rights to the dedicated user
log "  Granting ActAs + ReadAs rights to $CBTC_NETWORK_USER_ID..."
curl_check "$APP_USER_JSON_API/v2/users/$CBTC_NETWORK_USER_ID/rights" "$CANTON_TOKEN" "application/json" \
  --data-raw '{
    "userId": "'"$CBTC_NETWORK_USER_ID"'",
    "identityProviderId": "",
    "rights": [
      {"kind": {"CanActAs": {"value": {"party": "'"$CBTC_NETWORK_PARTY"'"}}}},
      {"kind": {"CanReadAs": {"value": {"party": "'"$CBTC_NETWORK_PARTY"'"}}}}
    ]
  }' > /dev/null 2>&1 || log "  (Rights may already be granted)"
log "  Rights granted"

##############################################################################
# Step 4: Create InstrumentConfiguration contract via interactive submission
##############################################################################

log ""
log "Step 4: Creating InstrumentConfiguration contract..."

# Query for existing InstrumentConfiguration
INSTRUMENT_CONFIG_CID=""
IC_RESPONSE=$(query_active_contracts "$CBTC_NETWORK_PARTY" "$INSTRUMENT_CONFIG_TEMPLATE" "false" 2>/dev/null) || IC_RESPONSE=""

if [ -n "$IC_RESPONSE" ]; then
  INSTRUMENT_CONFIG_CID=$(echo "$IC_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -n "$INSTRUMENT_CONFIG_CID" ]; then
  log "  InstrumentConfiguration already exists: ${INSTRUMENT_CONFIG_CID:0:40}..."
else
  log "  No existing InstrumentConfiguration found, creating via interactive submission..."

  # Build CreateCommand for InstrumentConfiguration
  IC_COMMANDS=$(jq -n \
    --arg party "$CBTC_NETWORK_PARTY" \
    --arg tokenId "$CBTC_TOKEN_ID" \
    --arg templateId "$INSTRUMENT_CONFIG_TEMPLATE" \
    '[{
      CreateCommand: {
        templateId: $templateId,
        createArguments: {
          operator: $party,
          provider: $party,
          registrar: $party,
          defaultIdentifier: {
            source: $party,
            id: $tokenId,
            scheme: "RegistrarInternalScheme"
          },
          additionalIdentifiers: [],
          issuerRequirements: [],
          holderRequirements: [],
          providerAppRewardBeneficiaries: null
        }
      }
    }]')

  log "  Submitting interactive submission..."
  IC_RESULT=$(interactive_submit "$IC_COMMANDS" "$CBTC_NETWORK_PARTY" "$KEYPAIR_PRIV" "$KEYPAIR_FP" \
    "create-instrument-config" "register-cbtc-ic") || {
    log_error "Failed to create InstrumentConfiguration"
    exit 1
  }

  INSTRUMENT_CONFIG_CID=$(echo "$IC_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("InstrumentConfiguration")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -n "$INSTRUMENT_CONFIG_CID" ]; then
    log "  InstrumentConfiguration created: ${INSTRUMENT_CONFIG_CID:0:40}..."
  else
    log_error "InstrumentConfiguration command succeeded but could not extract contract ID"
    log "  Response: $(echo "$IC_RESULT" | jq -c '.transaction.events[:3]' 2>/dev/null | head -c 500)"
    exit 1
  fi
fi

##############################################################################
# Step 5: Create AllocationFactory contract via interactive submission
#         (implements AllocationFactory, TransferFactory, and BurnMintFactory)
##############################################################################

log ""
log "Step 5: Creating AllocationFactory contract (utility)..."

# Query for existing AllocationFactory
ALLOCATION_FACTORY_CID=""
AF_RESPONSE=$(query_active_contracts "$CBTC_NETWORK_PARTY" "$ALLOCATION_FACTORY_TEMPLATE" "false" 2>/dev/null) || AF_RESPONSE=""

if [ -n "$AF_RESPONSE" ]; then
  ALLOCATION_FACTORY_CID=$(echo "$AF_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -n "$ALLOCATION_FACTORY_CID" ]; then
  log "  AllocationFactory already exists: ${ALLOCATION_FACTORY_CID:0:40}..."
else
  log "  No existing AllocationFactory found, creating via interactive submission..."

  # Build CreateCommand for AllocationFactory
  AF_COMMANDS=$(jq -n \
    --arg party "$CBTC_NETWORK_PARTY" \
    --arg templateId "$ALLOCATION_FACTORY_TEMPLATE" \
    '[{
      CreateCommand: {
        templateId: $templateId,
        createArguments: {
          provider: $party,
          registrar: $party,
          operator: $party
        }
      }
    }]')

  log "  Submitting interactive submission..."
  AF_RESULT=$(interactive_submit "$AF_COMMANDS" "$CBTC_NETWORK_PARTY" "$KEYPAIR_PRIV" "$KEYPAIR_FP" \
    "create-alloc-factory" "register-cbtc-af") || {
    log_error "Failed to create AllocationFactory"
    exit 1
  }

  ALLOCATION_FACTORY_CID=$(echo "$AF_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("AllocationFactory")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -n "$ALLOCATION_FACTORY_CID" ]; then
    log "  AllocationFactory created: ${ALLOCATION_FACTORY_CID:0:40}..."
  else
    log_error "AllocationFactory command succeeded but could not extract contract ID"
    log "  Response: $(echo "$AF_RESULT" | jq -c '.transaction.events[:3]' 2>/dev/null | head -c 500)"
    exit 1
  fi
fi

##############################################################################
# Step 5b: Create TransferRule contract via interactive submission
#          (signatory: provider=CBTC_NETWORK_PARTY, registrar=CBTC_NETWORK_PARTY)
##############################################################################

log ""
log "Step 5b: Creating TransferRule contract..."

TRANSFER_RULE_CID=""
TR_RESPONSE=$(query_active_contracts "$CBTC_NETWORK_PARTY" "$TRANSFER_RULE_TEMPLATE" "false" 2>/dev/null) || TR_RESPONSE=""

if [ -n "$TR_RESPONSE" ]; then
  TRANSFER_RULE_CID=$(echo "$TR_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -n "$TRANSFER_RULE_CID" ]; then
  log "  TransferRule already exists: ${TRANSFER_RULE_CID:0:40}..."
else
  log "  No existing TransferRule found, creating via interactive submission..."

  TR_COMMANDS=$(jq -n \
    --arg templateId "$TRANSFER_RULE_TEMPLATE" \
    --arg operator "$APP_USER_PARTY" \
    --arg provider "$CBTC_NETWORK_PARTY" \
    --arg registrar "$CBTC_NETWORK_PARTY" \
    '[{
      CreateCommand: {
        templateId: $templateId,
        createArguments: {
          operator: $operator,
          provider: $provider,
          registrar: $registrar
        }
      }
    }]')

  TR_RESULT=$(interactive_submit "$TR_COMMANDS" "$CBTC_NETWORK_PARTY" "$KEYPAIR_PRIV" "$KEYPAIR_FP" \
    "create-transfer-rule" "register-cbtc-tr") || {
    log_error "Failed to create TransferRule"
    exit 1
  }

  TRANSFER_RULE_CID=$(echo "$TR_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("TransferRule")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -n "$TRANSFER_RULE_CID" ]; then
    log "  TransferRule created: ${TRANSFER_RULE_CID:0:40}..."
  else
    log_error "TransferRule command succeeded but could not extract contract ID"
    log "  Response: $(echo "$TR_RESULT" | jq -c '.transaction.events[:3]' 2>/dev/null | head -c 500)"
    exit 1
  fi
fi

##############################################################################
# Step 5c: Create AppRewardConfiguration contract via submit-and-wait
#          (signatory: operator=APP_USER_PARTY)
##############################################################################

log ""
log "Step 5c: Creating AppRewardConfiguration contract..."

# Resolve DSO party (try backend .env first, then scan-proxy)
DSO_PARTY=$(grep -E '^DSO=' "$BACKEND_ENV" | cut -d= -f2- | tr -d '"' 2>/dev/null || echo "")
if [ -z "$DSO_PARTY" ]; then
  DSO_PARTY=$(get_dso_party "$CANTON_TOKEN" "$APP_USER_VALIDATOR_API") || DSO_PARTY=""
fi
if [ -z "$DSO_PARTY" ]; then
  log_error "Could not determine DSO party. Ensure the validator scan-proxy is accessible at $APP_USER_VALIDATOR_API."
  exit 1
fi
log "  DSO party: ${DSO_PARTY:0:50}..."

APP_REWARD_CONFIG_CID=""
ARC_RESPONSE=$(query_active_contracts "$APP_USER_PARTY" "$APP_REWARD_CONFIG_TEMPLATE" "false" 2>/dev/null) || ARC_RESPONSE=""

if [ -n "$ARC_RESPONSE" ]; then
  APP_REWARD_CONFIG_CID=$(echo "$ARC_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -n "$APP_REWARD_CONFIG_CID" ]; then
  log "  AppRewardConfiguration already exists: ${APP_REWARD_CONFIG_CID:0:40}..."
else
  log "  No existing AppRewardConfiguration found, creating via submit-and-wait..."

  ARC_CMD_ID="create-app-reward-config-$(date +%s)-$RANDOM"
  ARC_CREATE_BODY=$(jq -n \
    --arg templateId "$APP_REWARD_CONFIG_TEMPLATE" \
    --arg operator "$APP_USER_PARTY" \
    --arg provider "$CBTC_NETWORK_PARTY" \
    --arg dso "$DSO_PARTY" \
    --arg userId "$SHARED_SECRET_USER" \
    --arg cmdId "$ARC_CMD_ID" \
    '{
      commands: {
        commands: [{
          CreateCommand: {
            templateId: $templateId,
            createArguments: {
              operator: $operator,
              provider: $provider,
              details: {
                dso: $dso,
                operatorAppRewardBeneficiary: {
                  beneficiary: $operator,
                  weight: "0.5"
                }
              }
            }
          }
        }],
        commandId: $cmdId,
        applicationId: $userId,
        actAs: [$operator],
        readAs: [$provider],
        deduplicationPeriod: { Empty: {} },
        submissionId: $cmdId,
        disclosedContracts: [],
        domainId: "",
        packageIdSelectionPreference: []
      }
    }')

  ARC_RESULT=$(curl_check "$APP_USER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$CANTON_TOKEN" "application/json" \
    --data-raw "$ARC_CREATE_BODY") || {
    log_error "Failed to create AppRewardConfiguration"
    exit 1
  }

  APP_REWARD_CONFIG_CID=$(echo "$ARC_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("AppRewardConfiguration")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -n "$APP_REWARD_CONFIG_CID" ]; then
    log "  AppRewardConfiguration created: ${APP_REWARD_CONFIG_CID:0:40}..."
  else
    log_error "AppRewardConfiguration command succeeded but could not extract contract ID"
    log "  Response: $(echo "$ARC_RESULT" | jq -c '.transaction.events[:3]' 2>/dev/null | head -c 500)"
    exit 1
  fi
fi

##############################################################################
# Step 6: Acquire disclosures (with createdEventBlob) for both contracts
##############################################################################

log ""
log "Step 6: Acquiring disclosures..."

# 6a. AllocationFactory disclosure
log "  6a. AllocationFactory disclosure..."

AF_DISCLOSURE_RESPONSE=$(query_active_contracts "$CBTC_NETWORK_PARTY" "$ALLOCATION_FACTORY_TEMPLATE" "true") || {
  log_error "Failed to query AllocationFactory with disclosure"
  exit 1
}

ALLOC_DISCLOSED_CONTRACT=$(echo "$AF_DISCLOSURE_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract][0]
  | {
      contractId: .createdEvent.contractId,
      templateId: .createdEvent.templateId,
      createdEventBlob: .createdEvent.createdEventBlob,
      synchronizerId: .synchronizerId
    }
' 2>/dev/null || echo "")

if [ -z "$ALLOC_DISCLOSED_CONTRACT" ] || [ "$ALLOC_DISCLOSED_CONTRACT" = "null" ]; then
  log_error "Failed to extract AllocationFactory disclosure"
  exit 1
fi

ALLOC_BLOB=$(echo "$ALLOC_DISCLOSED_CONTRACT" | jq -r '.createdEventBlob // empty')
if [ -z "$ALLOC_BLOB" ]; then
  log_error "AllocationFactory disclosure missing createdEventBlob"
  exit 1
fi
log "  AllocationFactory disclosure acquired: ${ALLOCATION_FACTORY_CID:0:40}..."
log "  createdEventBlob length: ${#ALLOC_BLOB}"

# 6b. InstrumentConfiguration disclosure
log "  6b. InstrumentConfiguration disclosure..."

IC_DISCLOSURE_RESPONSE=$(query_active_contracts "$CBTC_NETWORK_PARTY" "$INSTRUMENT_CONFIG_TEMPLATE" "true") || {
  log_error "Failed to query InstrumentConfiguration with disclosure"
  exit 1
}

INSTRUMENT_DISCLOSED_CONTRACT=$(echo "$IC_DISCLOSURE_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract][0]
  | {
      contractId: .createdEvent.contractId,
      templateId: .createdEvent.templateId,
      createdEventBlob: .createdEvent.createdEventBlob,
      synchronizerId: .synchronizerId
    }
' 2>/dev/null || echo "")

if [ -z "$INSTRUMENT_DISCLOSED_CONTRACT" ] || [ "$INSTRUMENT_DISCLOSED_CONTRACT" = "null" ]; then
  log_error "Failed to extract InstrumentConfiguration disclosure"
  exit 1
fi

IC_BLOB=$(echo "$INSTRUMENT_DISCLOSED_CONTRACT" | jq -r '.createdEventBlob // empty')
if [ -z "$IC_BLOB" ]; then
  log_error "InstrumentConfiguration disclosure missing createdEventBlob"
  exit 1
fi
log "  InstrumentConfiguration disclosure acquired: ${INSTRUMENT_CONFIG_CID:0:40}..."
log "  createdEventBlob length: ${#IC_BLOB}"

# 6c. TransferRule disclosure
log "  6c. TransferRule disclosure..."
sleep 10

TR_DISCLOSURE_RESPONSE=$(query_active_contracts "$CBTC_NETWORK_PARTY" "$TRANSFER_RULE_TEMPLATE" "true") || {
  log_error "Failed to query TransferRule with disclosure"
  exit 1
}

TRANSFER_RULE_DISCLOSED_CONTRACT=$(echo "$TR_DISCLOSURE_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract][0]
  | {
      contractId: .createdEvent.contractId,
      templateId: .createdEvent.templateId,
      createdEventBlob: .createdEvent.createdEventBlob,
      synchronizerId: .synchronizerId
    }
' 2>/dev/null || echo "")

if [ -z "$TRANSFER_RULE_DISCLOSED_CONTRACT" ] || [ "$TRANSFER_RULE_DISCLOSED_CONTRACT" = "null" ]; then
  log_error "Failed to extract TransferRule disclosure"
  exit 1
fi

TR_BLOB=$(echo "$TRANSFER_RULE_DISCLOSED_CONTRACT" | jq -r '.createdEventBlob // empty')
if [ -z "$TR_BLOB" ]; then
  log_error "TransferRule disclosure missing createdEventBlob"
  exit 1
fi
log "  TransferRule disclosure acquired: ${TRANSFER_RULE_CID:0:40}..."
log "  createdEventBlob length: ${#TR_BLOB}"

# 6d. AppRewardConfiguration disclosure
log "  6d. AppRewardConfiguration disclosure..."
sleep 10

ARC_DISCLOSURE_RESPONSE=$(query_active_contracts "$APP_USER_PARTY" "$APP_REWARD_CONFIG_TEMPLATE" "true") || {
  log_error "Failed to query AppRewardConfiguration with disclosure"
  exit 1
}

APP_REWARD_CONFIG_DISCLOSED_CONTRACT=$(echo "$ARC_DISCLOSURE_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract][0]
  | {
      contractId: .createdEvent.contractId,
      templateId: .createdEvent.templateId,
      createdEventBlob: .createdEvent.createdEventBlob,
      synchronizerId: .synchronizerId
    }
' 2>/dev/null || echo "")

if [ -z "$APP_REWARD_CONFIG_DISCLOSED_CONTRACT" ] || [ "$APP_REWARD_CONFIG_DISCLOSED_CONTRACT" = "null" ]; then
  log_error "Failed to extract AppRewardConfiguration disclosure"
  exit 1
fi

ARC_BLOB=$(echo "$APP_REWARD_CONFIG_DISCLOSED_CONTRACT" | jq -r '.createdEventBlob // empty')
if [ -z "$ARC_BLOB" ]; then
  log_error "AppRewardConfiguration disclosure missing createdEventBlob"
  exit 1
fi
log "  AppRewardConfiguration disclosure acquired: ${APP_REWARD_CONFIG_CID:0:40}..."
log "  createdEventBlob length: ${#ARC_BLOB}"

##############################################################################
# Step 7: Write cbtc-factories.json
##############################################################################

log ""
log "Step 7: Writing cbtc-factories.json..."

FACTORIES_FILE="$SCRIPT_DIR/cbtc-factories.json"

jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cbtcNetworkParty "$CBTC_NETWORK_PARTY" \
  --arg allocCid "$ALLOCATION_FACTORY_CID" \
  --arg allocTemplateName "AllocationFactory" \
  --arg allocTemplateId "$ALLOCATION_FACTORY_TEMPLATE" \
  --argjson allocDisclosure "$ALLOC_DISCLOSED_CONTRACT" \
  --arg icCid "$INSTRUMENT_CONFIG_CID" \
  --arg icTemplateName "InstrumentConfiguration" \
  --arg icTemplateId "$INSTRUMENT_CONFIG_TEMPLATE" \
  --argjson icDisclosure "$INSTRUMENT_DISCLOSED_CONTRACT" \
  --arg trCid "$TRANSFER_RULE_CID" \
  --arg trTemplateName "TransferRule" \
  --arg trTemplateId "$TRANSFER_RULE_TEMPLATE" \
  --argjson trDisclosure "$TRANSFER_RULE_DISCLOSED_CONTRACT" \
  --arg arcCid "$APP_REWARD_CONFIG_CID" \
  --arg arcTemplateName "AppRewardConfiguration" \
  --arg arcTemplateId "$APP_REWARD_CONFIG_TEMPLATE" \
  --argjson arcDisclosure "$APP_REWARD_CONFIG_DISCLOSED_CONTRACT" \
  '{
    generatedAt: $generatedAt,
    cbtcNetworkParty: $cbtcNetworkParty,
    factories: {
      allocationFactory: {
        contractId: $allocCid,
        templateName: $allocTemplateName,
        templateId: $allocTemplateId,
        disclosure: $allocDisclosure
      }
    },
    instrumentConfiguration: {
      contractId: $icCid,
      templateName: $icTemplateName,
      templateId: $icTemplateId,
      disclosure: $icDisclosure
    },
    transferRule: {
      contractId: $trCid,
      templateName: $trTemplateName,
      templateId: $trTemplateId,
      disclosure: $trDisclosure
    },
    appRewardConfiguration: {
      contractId: $arcCid,
      templateName: $arcTemplateName,
      templateId: $arcTemplateId,
      disclosure: $arcDisclosure
    }
  }' > "$FACTORIES_FILE"

log "  Written to: $FACTORIES_FILE"
log "  AllocationFactory CID: ${ALLOCATION_FACTORY_CID:0:40}..."
log "  InstrumentConfiguration CID: ${INSTRUMENT_CONFIG_CID:0:40}..."
log "  TransferRule CID: ${TRANSFER_RULE_CID:0:40}..."
log "  AppRewardConfiguration CID: ${APP_REWARD_CONFIG_CID:0:40}..."

##############################################################################
# Step 8: Register token issuer in backend (POST /token-issuer)
# Note: allocation_factories table was dropped — factory data (factoryContractId,
# discloseContracts, choiceContextData) is now stored directly in token_issuers.
##############################################################################

log ""
log "Step 8: Registering CBTC token issuer in backend..."

# Check if already registered
EXISTING_ISSUER=$(curl -sf "$BACKEND_URL/token-issuer/token/$CBTC_TOKEN_ID" \
  -H "Authorization: Bearer $BACKEND_TOKEN" 2>/dev/null || echo "")

if [ -n "$EXISTING_ISSUER" ] && echo "$EXISTING_ISSUER" | jq -e '.data.tokenId // .tokenId' > /dev/null 2>&1; then
  EXISTING_TOKEN_ID=$(echo "$EXISTING_ISSUER" | jq -r '.data.tokenId // .tokenId')
  log "  Token issuer already registered: tokenId=$EXISTING_TOKEN_ID"
else
  # Reuse the same disclose contracts and choice context data from Step 8
  if [ -z "$DISCLOSE_CONTRACTS" ]; then
    DISCLOSE_CONTRACTS=$(jq -n \
      --argjson alloc "$ALLOC_DISCLOSED_CONTRACT" \
      --argjson ic "$INSTRUMENT_DISCLOSED_CONTRACT" \
      '[$alloc, $ic]')
  fi
  if [ -z "$CHOICE_CONTEXT_DATA" ]; then
    CHOICE_CONTEXT_DATA=$(jq -n \
      --arg icCid "$INSTRUMENT_CONFIG_CID" \
      '{
        values: {
          "sender-credentials": { tag: "AV_List", value: [] },
          "instrument-configuration": { tag: "AV_ContractId", value: $icCid },
          "utility.digitalasset.com/sender-credentials": { tag: "AV_List", value: [] },
          "utility.digitalasset.com/receiver-credentials": { tag: "AV_List", value: [] },
          "utility.digitalasset.com/instrument-configuration": { tag: "AV_ContractId", value: $icCid }
        }
      }')
  fi

  TOKEN_ISSUER_BODY=$(jq -n \
    --arg admin "$CBTC_NETWORK_PARTY" \
    --arg tokenId "$CBTC_TOKEN_ID" \
    --arg registrar "$CBTC_NETWORK_PARTY" \
    --arg factoryContractId "$ALLOCATION_FACTORY_CID" \
    --arg symbol "$CBTC_SYMBOL" \
    --arg displayName "$CBTC_DISPLAY_NAME" \
    --arg priceSourceId "$CBTC_PRICE_SOURCE_ID" \
    --argjson discloseContracts "$DISCLOSE_CONTRACTS" \
    --argjson choiceContextData "$CHOICE_CONTEXT_DATA" \
    '{
      admin: $admin,
      tokenId: $tokenId,
      registrar: $registrar,
      factoryContractId: $factoryContractId,
      symbol: $symbol,
      displayName: $displayName,
      priceSourceId: $priceSourceId,
      metadata: null,
      discloseContracts: $discloseContracts,
      choiceContextData: $choiceContextData
    }')

  ISSUER_REG_RESULT=$(curl -sf -w "\n%{http_code}" "$BACKEND_URL/token-issuer" \
    -H "Authorization: Bearer $BACKEND_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$TOKEN_ISSUER_BODY" 2>&1) || true

  ISSUER_HTTP_CODE=$(echo "$ISSUER_REG_RESULT" | tail -n1 | tr -d '\r')
  ISSUER_REG_BODY=$(echo "$ISSUER_REG_RESULT" | sed '$d')

  case "$ISSUER_HTTP_CODE" in
    200|201)
      log "  Token issuer registered successfully!"
      log "  Token ID: $CBTC_TOKEN_ID"
      log "  Admin: $CBTC_NETWORK_PARTY"
      log "  Factory: $ALLOCATION_FACTORY_CID"
      ;;
    409)
      log "  Token issuer already registered (tokenId '$CBTC_TOKEN_ID' exists)."
      ;;
    *)
      log_error "Token issuer registration failed with HTTP $ISSUER_HTTP_CODE"
      log_error "Response: $ISSUER_REG_BODY"
      exit 1
      ;;
  esac
fi

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "CBTC Token Registration Complete!"
log "=========================================="
log ""
log "Summary:"
log "  CBTC-NETWORK party (external): $CBTC_NETWORK_PARTY"
log "  Keypair file: $KEYPAIR_FILE"
log "  Factories file: $FACTORIES_FILE"
log "  AllocationFactory CID: $ALLOCATION_FACTORY_CID"
log "  InstrumentConfiguration CID: $INSTRUMENT_CONFIG_CID"
log "  TransferRule CID: $TRANSFER_RULE_CID"
log "  AppRewardConfiguration CID: $APP_REWARD_CONFIG_CID"
log "  Token issuer: $CBTC_TOKEN_ID ($CBTC_DISPLAY_NAME)"
log ""
log "Verify:"
log "  curl -s $BACKEND_URL/token-issuer/token/$CBTC_TOKEN_ID -H 'Authorization: Bearer <token>' | jq"
log "  jq '.' $FACTORIES_FILE"
