#!/bin/bash
# Registers the CBTC token in the canton-exchange-backend.
# This script:
#   1. Generates an Ed25519 keypair (NaCl format) and stores it in cbtc-network-keypair.json
#   2. Onboards "CBTC-NETWORK" as an external party via generate-topology + sign + allocate
#   3. Creates a Canton user for the external party with ActAs/ReadAs rights
#   4. Creates a TokenAllocationFactory contract on the ledger
#   5. Acquires the AllocationFactory disclosure (createdEventBlob)
#   6. Registers the AllocationFactory in the backend (POST /allocation-factory)
#   7. Registers the token issuer in the backend (POST /token-issuer)
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - setup-exchange.sh must have been run (DARs uploaded, contracts created)
#   - canton-exchange-backend must be running (yarn start:dev)
#
# Usage: ./register-cbtc-token.sh

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

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Register CBTC Token"
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
# Step 4: Create AllocationFactory contract via interactive submission
#         (external party requires prepare → sign → execute flow)
##############################################################################

log ""
log "Step 4: Creating TokenAllocationFactory contract..."

# Query for existing AllocationFactory (use admin token since external party
# rights were granted to admin user in Step 3)
LEDGER_END=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

FACTORY_QUERY=$(cat <<FQEOF
{
  "filter":{
    "filtersByParty":{
      "$CBTC_NETWORK_PARTY":{
        "cumulative":[{
          "identifierFilter":{
            "TemplateFilter":{
              "value":{
                "templateId":"#fungible-token:Fungible.TokenAllocationFactory:TokenAllocationFactory",
                "includeCreatedEventBlob":false
              }
            }
          }
        }]
      }
    }
  },
  "verbose":false,
  "activeAtOffset":"$LEDGER_END"
}
FQEOF
)

ALLOCATION_FACTORY_CID=""
FACTORY_RESPONSE=$(curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
  --data-raw "$FACTORY_QUERY" 2>/dev/null) || FACTORY_RESPONSE=""

if [ -n "$FACTORY_RESPONSE" ]; then
  ALLOCATION_FACTORY_CID=$(echo "$FACTORY_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -n "$ALLOCATION_FACTORY_CID" ]; then
  log "  AllocationFactory already exists: ${ALLOCATION_FACTORY_CID:0:40}..."
else
  log "  No existing AllocationFactory found, creating via interactive submission..."

  # Get connected synchronizer for interactive submission
  SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
    | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

  # 4a. Prepare the CreateCommand for interactive submission
  FACTORY_CMD_ID="create-allocation-factory-$(date +%s)"
  PREPARE_BODY=$(jq -n \
    --arg party "$CBTC_NETWORK_PARTY" \
    --arg cmdId "$FACTORY_CMD_ID" \
    --arg userId "$SHARED_SECRET_USER" \
    --arg syncId "$SYNCHRONIZER_ID" \
    '{
      commands: [{
        CreateCommand: {
          templateId: "#fungible-token:Fungible.TokenAllocationFactory:TokenAllocationFactory",
          createArguments: {
            admin: $party,
            meta: {values: {}}
          }
        }
      }],
      commandId: $cmdId,
      userId: $userId,
      actAs: [$party],
      readAs: [],
      disclosedContracts: [],
      synchronizerId: $syncId,
      verboseHashing: true,
      packageIdSelectionPreference: []
    }')

  log "  Preparing interactive submission..."
  PREPARE_RESULT=$(curl_check "$APP_USER_JSON_API/v2/interactive-submission/prepare" "$CANTON_TOKEN" "application/json" \
    --data-raw "$PREPARE_BODY") || {
    log_error "Failed to prepare AllocationFactory command"
    exit 1
  }

  PREPARED_TX=$(echo "$PREPARE_RESULT" | jq -r '.preparedTransaction // empty')
  PREPARED_HASH=$(echo "$PREPARE_RESULT" | jq -r '.preparedTransactionHash // empty')
  HASHING_VERSION=$(echo "$PREPARE_RESULT" | jq -r '.hashingSchemeVersion // empty')

  if [ -z "$PREPARED_TX" ] || [ -z "$PREPARED_HASH" ]; then
    log_error "Prepare response missing required fields"
    log_error "Response: $(echo "$PREPARE_RESULT" | head -c 500)"
    exit 1
  fi
  log "  Prepared transaction hash: ${PREPARED_HASH:0:30}..."

  # 4b. Sign the prepared transaction hash with the external party's private key
  log "  Signing with external party key..."
  FACTORY_SIGNATURE=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { signTransactionHash } = require('@canton-network/core-signing-lib');
    const signature = signTransactionHash('$PREPARED_HASH', '$KEYPAIR_PRIV');
    process.stdout.write(signature);
  " 2>/dev/null) || FACTORY_SIGNATURE=""

  if [ -z "$FACTORY_SIGNATURE" ]; then
    log_error "Failed to sign prepared transaction"
    exit 1
  fi

  # 4c. Execute the signed transaction
  log "  Executing signed transaction..."
  EXECUTE_BODY=$(jq -n \
    --arg userId "$SHARED_SECRET_USER" \
    --arg submissionId "register-cbtc-factory-$FACTORY_CMD_ID" \
    --arg preparedTx "$PREPARED_TX" \
    --arg hashVersion "$HASHING_VERSION" \
    --arg party "$CBTC_NETWORK_PARTY" \
    --arg sig "$FACTORY_SIGNATURE" \
    --arg signedBy "$KEYPAIR_FP" \
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

  FACTORY_RESULT=$(curl_check "$APP_USER_JSON_API/v2/interactive-submission/executeAndWaitForTransaction" "$CANTON_TOKEN" "application/json" \
    --data-raw "$EXECUTE_BODY") || {
    log_error "Failed to execute AllocationFactory transaction"
    exit 1
  }

  ALLOCATION_FACTORY_CID=$(echo "$FACTORY_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("TokenAllocationFactory")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -n "$ALLOCATION_FACTORY_CID" ]; then
    log "  AllocationFactory created: ${ALLOCATION_FACTORY_CID:0:40}..."
  else
    log_error "AllocationFactory command succeeded but could not extract contract ID"
    log "  Response: $(echo "$FACTORY_RESULT" | head -c 500)"
    exit 1
  fi
fi

##############################################################################
# Step 5: Acquire AllocationFactory disclosure (with createdEventBlob)
##############################################################################

log ""
log "Step 5: Acquiring AllocationFactory disclosure..."

# Re-fetch ledger end and query with includeCreatedEventBlob=true
LEDGER_END=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

DISCLOSURE_QUERY=$(cat <<DQEOF
{
  "filter":{
    "filtersByParty":{
      "$CBTC_NETWORK_PARTY":{
        "cumulative":[{
          "identifierFilter":{
            "TemplateFilter":{
              "value":{
                "templateId":"#fungible-token:Fungible.TokenAllocationFactory:TokenAllocationFactory",
                "includeCreatedEventBlob":true
              }
            }
          }
        }]
      }
    }
  },
  "verbose":false,
  "activeAtOffset":"$LEDGER_END"
}
DQEOF
)

DISCLOSURE_RESPONSE=$(curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
  --data-raw "$DISCLOSURE_QUERY") || {
  log_error "Failed to query AllocationFactory with disclosure"
  exit 1
}

# Extract the full disclosure object
DISCLOSED_CONTRACT=$(echo "$DISCLOSURE_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract][0]
  | {
      contractId: .createdEvent.contractId,
      templateId: .createdEvent.templateId,
      createdEventBlob: .createdEvent.createdEventBlob,
      synchronizerId: .synchronizerId
    }
' 2>/dev/null || echo "")

if [ -z "$DISCLOSED_CONTRACT" ] || [ "$DISCLOSED_CONTRACT" = "null" ]; then
  log_error "Failed to extract AllocationFactory disclosure"
  exit 1
fi

DISCLOSURE_CID=$(echo "$DISCLOSED_CONTRACT" | jq -r '.contractId // empty')
DISCLOSURE_BLOB=$(echo "$DISCLOSED_CONTRACT" | jq -r '.createdEventBlob // empty')

if [ -z "$DISCLOSURE_CID" ] || [ -z "$DISCLOSURE_BLOB" ]; then
  log_error "Disclosure missing contractId or createdEventBlob"
  exit 1
fi

log "  Disclosure acquired for: ${DISCLOSURE_CID:0:40}..."
log "  createdEventBlob length: ${#DISCLOSURE_BLOB}"

##############################################################################
# Step 6: Register AllocationFactory in backend (POST /allocation-factory)
##############################################################################

log ""
log "Step 6: Registering AllocationFactory in backend..."

# Check if already registered
EXISTING_FACTORY=$(curl -sf "$BACKEND_URL/allocation-factory/type/cbtc" \
  -H "Authorization: Bearer $BACKEND_TOKEN" 2>/dev/null || echo "")

if [ -n "$EXISTING_FACTORY" ] && echo "$EXISTING_FACTORY" | jq -e '.data.factoryId // .factoryId' > /dev/null 2>&1; then
  EXISTING_FACTORY_ID=$(echo "$EXISTING_FACTORY" | jq -r '.data.factoryId // .factoryId')
  log "  AllocationFactory already registered in backend: $EXISTING_FACTORY_ID"
else
  FACTORY_REG_BODY=$(jq -n \
    --arg factoryId "$ALLOCATION_FACTORY_CID" \
    --argjson discloseContracts "[$DISCLOSED_CONTRACT]" \
    '{
      type: "cbtc",
      factoryId: $factoryId,
      discloseContracts: $discloseContracts,
      choiceContextData: {"values": {"key": "value"}}
    }')

  FACTORY_REG_RESULT=$(curl -sf -w "\n%{http_code}" "$BACKEND_URL/allocation-factory" \
    -H "Authorization: Bearer $BACKEND_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$FACTORY_REG_BODY" 2>&1) || true

  FACTORY_HTTP_CODE=$(echo "$FACTORY_REG_RESULT" | tail -n1 | tr -d '\r')
  FACTORY_REG_BODY_RESP=$(echo "$FACTORY_REG_RESULT" | sed '$d')

  case "$FACTORY_HTTP_CODE" in
    200|201)
      log "  AllocationFactory registered successfully!"
      log "  Factory ID: $ALLOCATION_FACTORY_CID"
      ;;
    409)
      log "  AllocationFactory already registered (type 'cbtc' exists)."
      ;;
    *)
      log_error "AllocationFactory registration failed with HTTP $FACTORY_HTTP_CODE"
      log_error "Response: $FACTORY_REG_BODY_RESP"
      exit 1
      ;;
  esac
fi

##############################################################################
# Step 7: Register token issuer in backend (POST /token-issuer)
##############################################################################

log ""
log "Step 7: Registering CBTC token issuer in backend..."

# Check if already registered
EXISTING_ISSUER=$(curl -sf "$BACKEND_URL/token-issuer/token/$CBTC_TOKEN_ID" \
  -H "Authorization: Bearer $BACKEND_TOKEN" 2>/dev/null || echo "")

if [ -n "$EXISTING_ISSUER" ] && echo "$EXISTING_ISSUER" | jq -e '.data.tokenId // .tokenId' > /dev/null 2>&1; then
  EXISTING_TOKEN_ID=$(echo "$EXISTING_ISSUER" | jq -r '.data.tokenId // .tokenId')
  log "  Token issuer already registered: tokenId=$EXISTING_TOKEN_ID"
else
  TOKEN_ISSUER_BODY=$(jq -n \
    --arg admin "$CBTC_NETWORK_PARTY" \
    --arg tokenId "$CBTC_TOKEN_ID" \
    --arg registrar "$CBTC_NETWORK_PARTY" \
    --arg factoryContractId "$ALLOCATION_FACTORY_CID" \
    --arg symbol "$CBTC_SYMBOL" \
    --arg displayName "$CBTC_DISPLAY_NAME" \
    --arg priceSourceId "$CBTC_PRICE_SOURCE_ID" \
    --argjson discloseContracts "[$DISCLOSED_CONTRACT]" \
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
      choiceContextData: {"values": {"key": "value"}}
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
log "  AllocationFactory CID: $ALLOCATION_FACTORY_CID"
log "  Token issuer: $CBTC_TOKEN_ID ($CBTC_DISPLAY_NAME)"
log ""
log "Verify:"
log "  curl -s $BACKEND_URL/allocation-factory/type/cbtc -H 'Authorization: Bearer <token>' | jq"
log "  curl -s $BACKEND_URL/token-issuer/token/$CBTC_TOKEN_ID -H 'Authorization: Bearer <token>' | jq"
