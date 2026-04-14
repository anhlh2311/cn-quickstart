#!/bin/bash
# Setup script for Canton Exchange Backend on local quickstart network.
# Prerequisites: quickstart must be running (cd quickstart && make start)
#
# Usage: ./setup-exchange.sh
#
# This script:
#   1. Detects auth mode (oauth2 or shared-secret) from quickstart/.env.local
#   2. Uploads DAR files to App Provider & App User participant nodes
#   3. Creates a FeaturedAppRight contract for the app-user party
#   4. Generates .env.local for canton-exchange-backend
#   5. Starts the exchange backend database and runs migrations

set -eo pipefail

##############################################################################
# Dependency checks
##############################################################################

for cmd in curl jq openssl docker; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "[setup-exchange] ERROR: Required tool '$cmd' not found. Please install it." >&2
    exit 1
  fi
done

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUICKSTART_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DARS_DIR="$QUICKSTART_DIR/daml/dars"

# Load shared configuration from .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[setup-exchange] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

# Convert comma-separated DAR_FILES to bash array
IFS=',' read -ra DAR_FILES <<< "$DAR_FILES"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[setup-exchange] $*"
}

log_error() {
  echo "[setup-exchange] ERROR: $*" >&2
}

# Make an HTTP request with error handling (reuses pattern from splice-onboarding utils.sh)
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

# Generate a shared-secret JWT (HS256, secret="unsafe")
generate_shared_secret_jwt() {
  local sub="$1"
  local aud="$2"
  local now
  now=$(date +%s)
  local exp=$((now + 86400))

  # Base64url encode helper
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

# Get Keycloak client_credentials token
get_keycloak_token() {
  local client_id=$1
  local client_secret=$2
  local token_url=$3

  curl -f -s -S "$token_url" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "client_id=${client_id}" \
    -d "client_secret=${client_secret}" \
    -d 'grant_type=client_credentials' \
    -d 'scope=openid' | jq -r .access_token
}

# Detect auth mode from quickstart .env.local
detect_auth_mode() {
  local env_local="$QUICKSTART_DIR/.env.local"
  if [ ! -f "$env_local" ]; then
    log_error "quickstart/.env.local not found. Run 'make setup' in quickstart/ first."
    exit 1
  fi
  AUTH_MODE=$(grep -E '^AUTH_MODE=' "$env_local" | cut -d= -f2 | tr -d '"' | tr -d "'")
  if [ -z "$AUTH_MODE" ]; then
    AUTH_MODE="shared-secret"
  fi
  log "Detected AUTH_MODE=$AUTH_MODE"
}

# Get auth tokens based on detected mode
get_tokens() {
  if [ "$AUTH_MODE" = "oauth2" ]; then
    log "Obtaining OAuth2 tokens from Keycloak..."
    APP_PROVIDER_TOKEN=$(get_keycloak_token "$KEYCLOAK_APP_PROVIDER_CLIENT_ID" "$KEYCLOAK_APP_PROVIDER_CLIENT_SECRET" "$KEYCLOAK_APP_PROVIDER_TOKEN_URL")
    APP_USER_TOKEN=$(get_keycloak_token "$KEYCLOAK_APP_USER_CLIENT_ID" "$KEYCLOAK_APP_USER_CLIENT_SECRET" "$KEYCLOAK_APP_USER_TOKEN_URL")
    # SV uses shared-secret even in oauth2 mode (no keycloak realm for SV in quickstart)
    SV_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_SV_USER" "$SHARED_SECRET_AUDIENCE")
  else
    log "Generating shared-secret JWT tokens..."
    APP_PROVIDER_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_APP_PROVIDER_USER" "$SHARED_SECRET_AUDIENCE")
    APP_USER_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_APP_USER_USER" "$SHARED_SECRET_AUDIENCE")
    SV_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_SV_USER" "$SHARED_SECRET_AUDIENCE")
  fi

  if [ -z "$APP_PROVIDER_TOKEN" ] || [ -z "$APP_USER_TOKEN" ] || [ -z "$SV_TOKEN" ]; then
    log_error "Failed to obtain auth tokens"
    exit 1
  fi
  log "Auth tokens obtained successfully"
}

# Resolve party ID from user
get_party_id() {
  local token=$1
  local user_id=$2
  local participant=$3
  curl_check "$participant/v2/users/$user_id" "$token" "application/json" | jq -r .user.primaryParty
}

# Get DSO party ID from validator
get_dso_party_id() {
  local token=$1
  local validator=$2
  curl_check "$validator/api/validator/v0/scan-proxy/dso-party-id" "$token" "application/json" | jq -r .dso_party_id
}

# Extract main package ID (SHA-256 hash) from a DAR file's manifest
get_dar_package_id() {
  local dar_path=$1
  # Read manifest, unwrap RFC 822 continuation lines, extract 64-char hex hash
  unzip -p "$dar_path" META-INF/MANIFEST.MF 2>/dev/null \
    | tr -d '\r' \
    | awk '/^ /{printf "%s", substr($0,2); next}{if(NR>1)print ""; printf "%s", $0}END{print ""}' \
    | grep "^Main-Dalf:" \
    | grep -oE '[a-f0-9]{64}' \
    | head -1
}

# Check if all DAR packages are already uploaded to a participant
check_all_dars_uploaded() {
  local token=$1
  local participant=$2
  shift 2
  local dar_files=("$@")

  # Get list of packages from participant
  local pkg_response
  pkg_response=$(curl_check "$participant/v2/packages" "$token" "application/json" 2>/dev/null) || return 1

  for dar in "${dar_files[@]}"; do
    local pkg_id
    pkg_id=$(get_dar_package_id "$DARS_DIR/$dar")
    if [ -z "$pkg_id" ]; then
      return 1
    fi
    if ! echo "$pkg_response" | grep -q "$pkg_id"; then
      log "  Package $dar not yet uploaded to $participant"
      return 1
    fi
  done
  return 0
}

# Upload a single DAR file to a participant node (with retries)
upload_dar() {
  local dar_path=$1
  local token=$2
  local participant=$3
  local dar_name
  dar_name=$(basename "$dar_path")

  log "  Uploading $dar_name to $participant ..."
  local max_retries=3
  local retry=0
  while [ $retry -lt $max_retries ]; do
    if curl_check "$participant/v2/packages" "$token" "application/octet-stream" \
      --data-binary @"$dar_path" > /dev/null 2>&1; then
      log "  Uploaded $dar_name"
      return 0
    fi
    retry=$((retry + 1))
    if [ $retry -lt $max_retries ]; then
      log "  Retry $retry/$max_retries for $dar_name (waiting 10s)..."
      sleep 10
    fi
  done
  log_error "Failed to upload $dar_name after $max_retries attempts"
  return 1
}

##############################################################################
# Step 1: Detect auth mode and obtain tokens
##############################################################################

log "=========================================="
log "Canton Exchange Backend Setup"
log "=========================================="

detect_auth_mode
get_tokens

##############################################################################
# Step 2: Verify DAR files exist
##############################################################################

log ""
log "Step 1: Verifying DAR files..."
for dar in "${DAR_FILES[@]}"; do
  if [ ! -f "$DARS_DIR/$dar" ]; then
    log_error "DAR file not found: $DARS_DIR/$dar"
    log_error "Please place the DAR file in $DARS_DIR/ before running this script."
    exit 1
  fi
  log "  Found: $dar"
done

##############################################################################
# Step 3: Upload DARs to both participant nodes
##############################################################################

log ""
log "Step 2: Uploading DAR files to participant nodes..."

# Check if all packages are already uploaded to both participants
if check_all_dars_uploaded "$APP_PROVIDER_TOKEN" "$APP_PROVIDER_JSON_API" "${DAR_FILES[@]}" && \
   check_all_dars_uploaded "$APP_USER_TOKEN" "$APP_USER_JSON_API" "${DAR_FILES[@]}"; then
  log "All DAR packages already present on both participants, skipping upload."
else
  log "Uploading to App Provider participant ($APP_PROVIDER_JSON_API)..."
  for dar in "${DAR_FILES[@]}"; do
    upload_dar "$DARS_DIR/$dar" "$APP_PROVIDER_TOKEN" "$APP_PROVIDER_JSON_API"
  done

  log "Uploading to App User participant ($APP_USER_JSON_API)..."
  for dar in "${DAR_FILES[@]}"; do
    upload_dar "$DARS_DIR/$dar" "$APP_USER_TOKEN" "$APP_USER_JSON_API"
  done

  log "All DAR files uploaded successfully"
fi

##############################################################################
# Step 4: Resolve party IDs and network info
##############################################################################

log ""
log "Step 3: Resolving party IDs and network info..."

if [ "$AUTH_MODE" = "oauth2" ]; then
  APP_PROVIDER_PARTY=$(get_party_id "$APP_PROVIDER_TOKEN" "$KEYCLOAK_APP_PROVIDER_VALIDATOR_USER_ID" "$APP_PROVIDER_JSON_API")
  APP_USER_PARTY=$(get_party_id "$APP_USER_TOKEN" "$KEYCLOAK_APP_USER_VALIDATOR_USER_ID" "$APP_USER_JSON_API")
  ADMIN_USER_ID="$KEYCLOAK_APP_PROVIDER_VALIDATOR_USER_ID"
  APP_USER_ADMIN_NAME="$KEYCLOAK_APP_USER_VALIDATOR_USER_ID"
else
  APP_PROVIDER_PARTY=$(get_party_id "$APP_PROVIDER_TOKEN" "$SHARED_SECRET_APP_PROVIDER_USER" "$APP_PROVIDER_JSON_API")
  APP_USER_PARTY=$(get_party_id "$APP_USER_TOKEN" "$SHARED_SECRET_APP_USER_USER" "$APP_USER_JSON_API")
  ADMIN_USER_ID="$SHARED_SECRET_APP_PROVIDER_USER"
  APP_USER_ADMIN_NAME="$SHARED_SECRET_APP_USER_USER"
fi

DSO_PARTY=$(get_dso_party_id "$APP_USER_TOKEN" "$APP_USER_VALIDATOR_API")

# Resolve the global synchronizer ID from the participant
GLOBAL_SYNCHRONIZER_ID=$(curl_check "$APP_PROVIDER_JSON_API/v2/state/connected-synchronizers" "$APP_PROVIDER_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$GLOBAL_SYNCHRONIZER_ID" ]; then
  log_error "Could not resolve synchronizer ID from participant"
  exit 1
fi

log "  APP_PROVIDER_PARTY=$APP_PROVIDER_PARTY"
log "  APP_USER_PARTY=$APP_USER_PARTY"
log "  DSO_PARTY=$DSO_PARTY"
log "  GLOBAL_SYNCHRONIZER_ID=$GLOBAL_SYNCHRONIZER_ID"

# Grant CanReadAsAnyParty to ADMIN_USER on App Provider participant
# This allows active contract queries to return contract IDs for any party
log "  Granting CanReadAsAnyParty to $ADMIN_USER_ID on App Provider..."
curl_check "$APP_PROVIDER_JSON_API/v2/users/$ADMIN_USER_ID/rights" "$APP_PROVIDER_TOKEN" "application/json" \
  --data-raw '{
    "userId": "'"$ADMIN_USER_ID"'",
    "identityProviderId": "",
    "rights": [{"kind":{"CanReadAsAnyParty":{"value":{}}}}]
  }' > /dev/null 2>&1 || log "  (CanReadAsAnyParty may already be granted)"

##############################################################################
# Step 5: Create FeaturedAppRight for app-user (idempotent)
##############################################################################

log ""
log "Step 4: FeaturedAppRight for app-user..."

# Query for existing FeaturedAppRight on app-user participant
APP_USER_LEDGER_END=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$APP_USER_TOKEN" "application/json" | jq -r '.offset')

FEATURED_APP_RIGHT_QUERY=$(cat <<FARQEOF
{
  "filter":{
    "filtersByParty":{
      "$APP_USER_PARTY":{
        "cumulative":[{
          "identifierFilter":{
            "TemplateFilter":{
              "value":{
                "templateId":"#splice-amulet:Splice.Amulet:FeaturedAppRight",
                "includeCreatedEventBlob":false
              }
            }
          }
        }]
      }
    }
  },
  "verbose":false,
  "activeAtOffset":"$APP_USER_LEDGER_END"
}
FARQEOF
)

FEATURED_APP_RIGHT_CID=""
FAR_RESPONSE=$(curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$APP_USER_TOKEN" "application/json" \
  --data-raw "$FEATURED_APP_RIGHT_QUERY" 2>/dev/null) || FAR_RESPONSE=""

if [ -n "$FAR_RESPONSE" ]; then
  FEATURED_APP_RIGHT_CID=$(echo "$FAR_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -n "$FEATURED_APP_RIGHT_CID" ]; then
  log "  FeaturedAppRight already exists: $FEATURED_APP_RIGHT_CID"
else
  log "  No existing FeaturedAppRight found, creating..."

  # Fetch AmuletRules contract from SV participant (which has DSO visibility)
  log "  Fetching AmuletRules contract from SV participant..."
  SV_LEDGER_END=$(curl_check "$SV_JSON_API/v2/state/ledger-end" "$SV_TOKEN" "application/json" | jq -r '.offset')

  AMULET_RULES_QUERY=$(cat <<QUERYEOF
{
  "filter":{
    "filtersByParty":{
      "$DSO_PARTY":{
        "cumulative":[{
          "identifierFilter":{
            "TemplateFilter":{
              "value":{
                "templateId":"#splice-amulet:Splice.AmuletRules:AmuletRules",
                "includeCreatedEventBlob":true
              }
            }
          }
        }]
      }
    }
  },
  "verbose":false,
  "activeAtOffset":"$SV_LEDGER_END"
}
QUERYEOF
)

  AMULET_RULES_RESPONSE=$(curl_check "$SV_JSON_API/v2/state/active-contracts" "$SV_TOKEN" "application/json" \
    --data-raw "$AMULET_RULES_QUERY") || {
    log_error "Failed to query AmuletRules contract from SV participant"
    log_error "Continuing with setup..."
    AMULET_RULES_RESPONSE=""
  }

  AMULET_RULES_CID=""
  DISCLOSED_CONTRACT=""
  if [ -n "$AMULET_RULES_RESPONSE" ]; then
    DISCLOSED_CONTRACT=$(echo "$AMULET_RULES_RESPONSE" | jq -c '
      [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract][0]
      | {
          contractId: .createdEvent.contractId,
          templateId: .createdEvent.templateId,
          createdEventBlob: .createdEvent.createdEventBlob,
          synchronizerId: .synchronizerId
        }
    ' 2>/dev/null || echo "")
    AMULET_RULES_CID=$(echo "$DISCLOSED_CONTRACT" | jq -r '.contractId // empty' 2>/dev/null || echo "")
  fi

  if [ -z "$AMULET_RULES_CID" ]; then
    log_error "Could not find AmuletRules contract. FeaturedAppRight creation skipped."
  else
    log "  Found AmuletRules contract: ${AMULET_RULES_CID:0:40}..."

    FEATURE_CMD_ID="create-featured-app-right-$(date +%s)"
    FEATURE_APP_BODY=$(cat <<CMDEOF
{
  "commands": [{
    "ExerciseCommand": {
      "templateId": "#splice-amulet:Splice.AmuletRules:AmuletRules",
      "contractId": "$AMULET_RULES_CID",
      "choice": "AmuletRules_DevNet_FeatureApp",
      "choiceArgument": {
        "provider": "$APP_USER_PARTY"
      }
    }
  }],
  "workflowId": "setup-exchange-feature-app",
  "applicationId": "$APP_USER_ADMIN_NAME",
  "commandId": "$FEATURE_CMD_ID",
  "deduplicationPeriod": {"Empty": {}},
  "actAs": ["$APP_USER_PARTY"],
  "readAs": [],
  "submissionId": "setup-exchange-feature-app-$FEATURE_CMD_ID",
  "disclosedContracts": [$DISCLOSED_CONTRACT],
  "domainId": "",
  "packageIdSelectionPreference": []
}
CMDEOF
)

    FEATURE_APP_WRAPPED=$(jq -n --argjson body "$FEATURE_APP_BODY" '{"commands": $body}')
    FEATURE_APP_RESULT=$(curl_check "$APP_USER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$APP_USER_TOKEN" "application/json" \
      --data-raw "$FEATURE_APP_WRAPPED") || {
      log_error "Failed to create FeaturedAppRight. This may happen if:"
      log_error "  - The quickstart is not running in DevNet mode"
      log_error "  - AmuletRules contract has changed since we queried it"
      log_error "Continuing with setup..."
      FEATURE_APP_RESULT=""
    }

    if [ -n "$FEATURE_APP_RESULT" ]; then
      FEATURED_APP_RIGHT_CID=$(echo "$FEATURE_APP_RESULT" | jq -r '
        [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("FeaturedAppRight")) | .contractId][0] // empty
      ' 2>/dev/null || echo "")
      if [ -n "$FEATURED_APP_RIGHT_CID" ]; then
        log "  FeaturedAppRight created: $FEATURED_APP_RIGHT_CID"
      else
        log_error "  FeaturedAppRight command succeeded but could not extract contract ID"
        log "  Response: $(echo "$FEATURE_APP_RESULT" | head -c 500)"
      fi
    fi
  fi
fi

##############################################################################
# Step 6: Create BatchedMarkersProxy for app-user (idempotent)
##############################################################################

log ""
log "Step 5: BatchedMarkersProxy for app-user..."

# Query for existing BatchedMarkersProxy on app-user participant
# Re-fetch ledger end in case it changed after step 4
APP_USER_LEDGER_END=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$APP_USER_TOKEN" "application/json" | jq -r '.offset')

BATCHED_PROXY_QUERY=$(cat <<BPQEOF
{
  "filter":{
    "filtersByParty":{
      "$APP_USER_PARTY":{
        "cumulative":[{
          "identifierFilter":{
            "TemplateFilter":{
              "value":{
                "templateId":"#splice-util-batched-markers:Splice.Util.FeaturedApp.BatchedMarkersProxy:BatchedMarkersProxy",
                "includeCreatedEventBlob":false
              }
            }
          }
        }]
      }
    }
  },
  "verbose":false,
  "activeAtOffset":"$APP_USER_LEDGER_END"
}
BPQEOF
)

BATCHED_MARKERS_PROXY_CID=""
BMP_RESPONSE=$(curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$APP_USER_TOKEN" "application/json" \
  --data-raw "$BATCHED_PROXY_QUERY" 2>/dev/null) || BMP_RESPONSE=""

if [ -n "$BMP_RESPONSE" ]; then
  BATCHED_MARKERS_PROXY_CID=$(echo "$BMP_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -n "$BATCHED_MARKERS_PROXY_CID" ]; then
  log "  BatchedMarkersProxy already exists: $BATCHED_MARKERS_PROXY_CID"
else
  log "  No existing BatchedMarkersProxy found, creating..."

  BATCHED_PROXY_CMD_ID="create-batched-markers-proxy-$(date +%s)"
  BATCHED_PROXY_BODY=$(cat <<BPEOF
{
  "commands": [{
    "CreateCommand": {
      "templateId": "#splice-util-batched-markers:Splice.Util.FeaturedApp.BatchedMarkersProxy:BatchedMarkersProxy",
      "createArguments": {
        "provider": "$APP_USER_PARTY",
        "dso": "$DSO_PARTY"
      }
    }
  }],
  "workflowId": "setup-exchange-batched-markers-proxy",
  "applicationId": "$APP_USER_ADMIN_NAME",
  "commandId": "$BATCHED_PROXY_CMD_ID",
  "deduplicationPeriod": {"Empty": {}},
  "actAs": ["$APP_USER_PARTY"],
  "readAs": [],
  "submissionId": "setup-exchange-batched-markers-proxy-$BATCHED_PROXY_CMD_ID",
  "disclosedContracts": [],
  "domainId": "",
  "packageIdSelectionPreference": []
}
BPEOF
)

  BATCHED_PROXY_WRAPPED=$(jq -n --argjson body "$BATCHED_PROXY_BODY" '{"commands": $body}')
  BATCHED_PROXY_RESULT=$(curl_check "$APP_USER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$APP_USER_TOKEN" "application/json" \
    --data-raw "$BATCHED_PROXY_WRAPPED") || {
    log_error "Failed to create BatchedMarkersProxy."
    log_error "Continuing with setup..."
    BATCHED_PROXY_RESULT=""
  }

  if [ -n "$BATCHED_PROXY_RESULT" ]; then
    BATCHED_MARKERS_PROXY_CID=$(echo "$BATCHED_PROXY_RESULT" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("BatchedMarkersProxy")) | .contractId][0] // empty
    ' 2>/dev/null || echo "")
    if [ -n "$BATCHED_MARKERS_PROXY_CID" ]; then
      log "  BatchedMarkersProxy created: $BATCHED_MARKERS_PROXY_CID"
    else
      log_error "  BatchedMarkersProxy command succeeded but could not extract contract ID"
      log "  Response: $(echo "$BATCHED_PROXY_RESULT" | head -c 500)"
    fi
  fi
fi

##############################################################################
# Step 7: Generate .env.local for canton-exchange-backend
##############################################################################

log ""
log "Step 6: Generating .env.local for canton-exchange-backend..."

if [ "$AUTH_MODE" = "oauth2" ]; then
  BACKEND_AUTH_MODE="keycloak"
  BACKEND_AUTH_SECRET=""
  BACKEND_AUTH0_TOKEN_URL="$KEYCLOAK_APP_PROVIDER_TOKEN_URL"
  BACKEND_AUTH0_CLIENT_ID="$KEYCLOAK_APP_PROVIDER_CLIENT_ID"
  BACKEND_AUTH0_CLIENT_SECRET="$KEYCLOAK_APP_PROVIDER_CLIENT_SECRET"
  BACKEND_AUTH0_AUDIENCE="https://canton.network.global"
  BACKEND_VALIDATOR_AUDIENCE="https://canton.network.global"
else
  BACKEND_AUTH_MODE="share-secret"
  BACKEND_AUTH_SECRET="$SHARED_SECRET"
  BACKEND_AUTH0_TOKEN_URL=""
  BACKEND_AUTH0_CLIENT_ID=""
  BACKEND_AUTH0_CLIENT_SECRET=""
  BACKEND_AUTH0_AUDIENCE="$SHARED_SECRET_AUDIENCE"
  BACKEND_VALIDATOR_AUDIENCE="$SHARED_SECRET_AUDIENCE"
fi

cat > "$EXCHANGE_BACKEND_DIR/.env.local" <<ENVEOF
# Generated by setup-exchange.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Local quickstart network configuration

PORT=$BACKEND_PORT
NODE_ENV=development
BACKEND_APP_NAME=canton-exchange-backend

# Database (exchange backend's own PostgreSQL via docker-compose)
DB_HOST=$EXCHANGE_DB_HOST
DB_PORT=$EXCHANGE_DB_PORT
DB_USERNAME=$EXCHANGE_DB_USERNAME
DB_PASSWORD=$EXCHANGE_DB_PASSWORD
DB_NAME=$EXCHANGE_DB_NAME

# Canton participant (App User) - local quickstart
PARTICIPANT_LEDGER_API=$APP_USER_JSON_API
VALIDATOR_API=$APP_USER_VALIDATOR_API
ADMIN_USER=$ADMIN_USER_ID
GLOBAL_SYNCHRONIZER_ID=$GLOBAL_SYNCHRONIZER_ID
PARTY_ID_PREFIX=$PARTY_ID_PREFIX

# Auth
AUTH_MODE="$BACKEND_AUTH_MODE"
AUTH_SECRET="$BACKEND_AUTH_SECRET"
AUTH0_TOKEN_URL=$BACKEND_AUTH0_TOKEN_URL
AUTH0_CLIENT_ID=$BACKEND_AUTH0_CLIENT_ID
AUTH0_CLIENT_SECRET=$BACKEND_AUTH0_CLIENT_SECRET
AUTH0_AUDIENCE=$BACKEND_AUTH0_AUDIENCE
VALIDATOR_AUDIENCE=$BACKEND_VALIDATOR_AUDIENCE

# JWT
JWT_ACCESS_TOKEN_EXPIRES_IN=1d
JWT_REFRESH_TOKEN_EXPIRES_IN=7d

# Google Auth (disabled for local)
GOOGLE_OAUTH_CLIENT_ID=
GOOGLE_OAUTH_CLIENT_SECRET=

# Party IDs (resolved from local network)
EXECUTOR_PARTY_ID=$APP_USER_PARTY
LIQUIDITY_PROVIDER_PARTY_ID=$APP_PROVIDER_PARTY
ADMIN_WALLET_PARTY_ID=
HOST_VALIDATOR_PARTY_ID=
ADMIN_WALLET_FINGER_PRINT=
ADMIN_WALLET_PRIVATE_KEY=
ADMIN_WALLET_PUBLIC_KEY=
LIQUIDITY_PROVIDER_FINGER_PRINT=
LIQUIDITY_PROVIDER_PRIVATE_KEY=

# Template IDs (matching uploaded DARs)
MARKET_QUOTE_TEMPLATE_ID="#kairo-dex:Exchange.MarketQuote:MarketQuote"
SETTLEMENT_ESCROW_TEMPLATE_ID="#kairo-dex:Exchange.SettlementEscrow:SettlementEscrow"
MARKET_QUOTE_PROPOSAL_TEMPLATE_ID="#kairo-dex:Exchange.MarketQuoteProposal:MarketQuoteProposal"
FUNGIBLE_ALLOCATION_TEMPLATE_ID="#fungible-token:Fungible.TokenAllocation:TokenAllocation"
AMULET_ALLOCATION_TEMPLATE_ID="#splice-amulet:Splice.AmuletAllocation:AmuletAllocation"
MERGE_DELEGATION_TEMPLATE_ID="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegation"
MERGE_DELEGATION_PROPOSAL_TEMPLATE_ID="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegationProposal"
BATCH_MERGE_UTILITY_TEMPLATE_ID="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:BatchMergeUtility"
TRADE_PROPOSAL_FACTORY_TEMPLATE_ID="#kairo-dex-simple-escrow-v4:Kairo.Escrow.TradeProposalFactory:TradeProposalFactory"
TRADE_PROPOSAL_TEMPLATE_ID="#kairo-dex-simple-escrow-v4:Kairo.Escrow.TradeProposal:TradeProposal"
TRADE_ESCROW_TEMPLATE_ID="#kairo-dex-simple-escrow-v4:Kairo.Escrow.TradeEscrow:TradeEscrow"

# Swagger
SWAGGER_USERNAME=$SWAGGER_USERNAME
SWAGGER_PASSWORD=$SWAGGER_PASSWORD

# Admin
ADMIN_API_KEY=$ADMIN_API_KEY
WHITELIST_VERIFICATION_CODE=$WHITELIST_VERIFICATION_CODE

# Chainlink Data Streams (placeholder - not available locally)
CHAINLINK_API_URL=$CHAINLINK_API_URL
CHAINLINK_API_KEY=$CHAINLINK_API_KEY
CHAINLINK_API_SECRET=$CHAINLINK_API_SECRET

# Transfer token interfaces
UTILITIES_API_URL=$UTILITIES_API_URL
TRANSFERFACTORY_INTERFACE=#splice-api-token-transfer-instruction-v1:Splice.Api.Token.TransferInstructionV1:TransferFactory
HOLDING_INTERFACE=#splice-api-token-holding-v1:Splice.Api.Token.HoldingV1:Holding
TRANSFER_INSTRUCTION_INTERFACE=#splice-api-token-transfer-instruction-v1:Splice.Api.Token.TransferInstructionV1:TransferInstruction
CBTC_TRANSFER_OFFER_TEMPLATE_ID=#utility-registry-app-v0:Utility.Registry.App.V0.Model.Transfer:TransferOffer

# DSO (resolved from local network)
DSO=$DSO_PARTY

# CBTC (placeholder - not available locally)
CBTC_API=$CBTC_API
CBTC_CHAIN=$CBTC_CHAIN
REGISTRAR_PARTY_ID=
CBTC_NETWORK_PARTY_ID=

# Prometheus (local quickstart observability stack)
PROMETHEUS_NODE_API_URL=$PROMETHEUS_NODE_API_URL
PROMETHEUS_NODE_NAME=$PROMETHEUS_NODE_NAME
PROMETHEUS_NODE_JOB=$PROMETHEUS_NODE_JOB
ENVEOF

log "  Generated: $EXCHANGE_BACKEND_DIR/.env.local"

##############################################################################
# Step 8: Start exchange backend database and run migrations
##############################################################################

log ""
log "Step 7: Starting exchange backend..."

if [ ! -d "$EXCHANGE_BACKEND_DIR" ]; then
  log_error "Exchange backend directory not found: $EXCHANGE_BACKEND_DIR"
  exit 1
fi

cd "$EXCHANGE_BACKEND_DIR"

# Copy .env.local as the active .env (the backend reads .env)
if [ -f ".env" ]; then
  cp ".env" ".env.backup.$(date +%s)"
  log "  Backed up existing .env"
fi
cp ".env.local" ".env"
log "  Activated .env.local as .env"

# Ensure the external Docker network exists (exchange backend expects splice-validator_splice_validator)
if ! docker network inspect splice-validator_splice_validator > /dev/null 2>&1; then
  log "  Creating Docker network splice-validator_splice_validator..."
  docker network create splice-validator_splice_validator 2>/dev/null || true
fi

# Start PostgreSQL via docker-compose
log "  Starting PostgreSQL..."
docker compose up -d postgres 2>&1 || {
  log_error "Failed to start PostgreSQL. Make sure Docker is running."
  exit 1
}

# Wait for PostgreSQL to be ready
log "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U "$EXCHANGE_DB_USERNAME" > /dev/null 2>&1; then
    log "  PostgreSQL is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    log_error "PostgreSQL did not become ready in time"
    exit 1
  fi
  sleep 2
done

# Run database migrations
log "  Running database migrations..."
if [ -f "yarn.lock" ]; then
  yarn install --frozen-lockfile 2>/dev/null || yarn install
  yarn migration:run 2>&1 || {
    log_error "Migration failed. Check database configuration."
    exit 1
  }
elif [ -f "package-lock.json" ]; then
  npm ci 2>/dev/null || npm install
  npm run migration:run 2>&1 || {
    log_error "Migration failed. Check database configuration."
    exit 1
  }
fi
log "  Migrations completed"

##############################################################################
# Step 9: Register FeaturedAppRight in backend DB (optional)
##############################################################################

if [ -n "$FEATURED_APP_RIGHT_CID" ]; then
  log ""
  log "Step 8: FeaturedAppRight registration..."
  log "  CID: $FEATURED_APP_RIGHT_CID"
  log "  After starting the backend, run:"
  log "  $SCRIPT_DIR/register-featured-app-right.sh"
fi

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Setup complete!"
log "=========================================="
log ""
log "Summary:"
log "  DAR files uploaded to App Provider ($APP_PROVIDER_JSON_API) and App User ($APP_USER_JSON_API)"
if [ -n "$FEATURED_APP_RIGHT_CID" ]; then
  log "  FeaturedAppRight created for app-user: $FEATURED_APP_RIGHT_CID"
else
  log "  FeaturedAppRight: check ledger for contract status"
fi
if [ -n "$BATCHED_MARKERS_PROXY_CID" ]; then
  log "  BatchedMarkersProxy created for app-user: $BATCHED_MARKERS_PROXY_CID"
else
  log "  BatchedMarkersProxy: check ledger for contract status"
fi
log "  Backend .env configured at: $EXCHANGE_BACKEND_DIR/.env"
log "  PostgreSQL running on port $EXCHANGE_DB_PORT"
log "  Migrations applied"
log ""
log "To start the backend:"
log "  cd $EXCHANGE_BACKEND_DIR"
log "  yarn start:dev"
log ""
log "Backend will be available at: $BACKEND_URL"
