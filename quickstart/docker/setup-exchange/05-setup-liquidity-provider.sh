#!/bin/bash
# Setup a Liquidity Provider on the app-provider node.
#
# This script:
#   1. Uploads DAR files to the app-provider participant node
#   2. Creates an internal party on the app-provider node (with configurable PartyHint)
#   3. Registers the party as a Liquidity Provider via the backend API
#   4. Writes the result to liquidity-provider.json
#
# Prerequisites:
#   - Quickstart localnet is running
#   - setup-exchange.sh (01) has been run
#   - canton-exchange-backend is running
#
# Environment variables (optional overrides):
#   LP_PARTY_HINT     — PartyHint prefix for the new LP party (default: "lp-provider")
#   LP_NAME           — Human-readable name for the LP (default: "Local LP")
#   LP_SELF           — Set to "true" for self-LP mode (default: "true")
#   LP_SUPPORT_TOKENS — Comma-separated token list (default: "Amulet,CBTC")
#
# Usage:
#   ./05-setup-liquidity-provider.sh
#   LP_PARTY_HINT=my-lp LP_NAME="My LP" ./05-setup-liquidity-provider.sh

set -eo pipefail

##############################################################################
# Dependency checks
##############################################################################

for cmd in curl jq openssl; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "[setup-lp] ERROR: Required tool '$cmd' not found." >&2
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
  echo "[setup-lp] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

# Convert comma-separated DAR_FILES to bash array
IFS=',' read -ra DAR_FILES <<< "$DAR_FILES"

# LP configuration (can be overridden via env vars)
LP_PARTY_HINT="${LP_PARTY_HINT:-lp-provider}"
LP_NAME="${LP_NAME:-Local LP}"
LP_SELF="${LP_SELF:-true}"
LP_TYPE="${LP_TYPE:-public}"
IFS=',' read -ra LP_SUPPORT_TOKENS <<< "${LP_SUPPORT_TOKENS:-Amulet,CBTC}"

# Output file
LP_OUTPUT_FILE="$SCRIPT_DIR/liquidity-provider.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[setup-lp] $*"
}

log_error() {
  echo "[setup-lp] ERROR: $*" >&2
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

generate_shared_secret_jwt() {
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

get_app_provider_token() {
  if [ "$AUTH_MODE" = "oauth2" ]; then
    APP_PROVIDER_TOKEN=$(get_keycloak_token "$KEYCLOAK_APP_PROVIDER_CLIENT_ID" "$KEYCLOAK_APP_PROVIDER_CLIENT_SECRET" "$KEYCLOAK_APP_PROVIDER_TOKEN_URL")
  else
    APP_PROVIDER_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_APP_PROVIDER_USER" "$SHARED_SECRET_AUDIENCE")
  fi

  if [ -z "$APP_PROVIDER_TOKEN" ]; then
    log_error "Failed to obtain app-provider auth token"
    exit 1
  fi
}

get_dar_package_id() {
  local dar_path=$1
  unzip -p "$dar_path" META-INF/MANIFEST.MF 2>/dev/null \
    | tr -d '\r' \
    | awk '/^ /{printf "%s", substr($0,2); next}{if(NR>1)print ""; printf "%s", $0}END{print ""}' \
    | grep "^Main-Dalf:" \
    | grep -oE '[a-f0-9]{64}' \
    | head -1
}

check_all_dars_uploaded() {
  local token=$1
  local participant=$2
  shift 2
  local dar_files=("$@")

  local pkg_response
  pkg_response=$(curl_check "$participant/v2/packages" "$token" "application/json" 2>/dev/null) || return 1

  for dar in "${dar_files[@]}"; do
    local pkg_id
    pkg_id=$(get_dar_package_id "$DARS_DIR/$dar")
    if [ -z "$pkg_id" ]; then
      return 1
    fi
    if ! echo "$pkg_response" | grep -q "$pkg_id"; then
      log "  Package $dar not yet uploaded"
      return 1
    fi
  done
  return 0
}

upload_dar() {
  local dar_path=$1
  local token=$2
  local participant=$3
  local dar_name
  dar_name=$(basename "$dar_path")

  log "  Uploading $dar_name ..."
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
log "Liquidity Provider Setup"
log "=========================================="
log "  LP_PARTY_HINT=$LP_PARTY_HINT"
log "  LP_NAME=$LP_NAME"
log "  LP_SELF=$LP_SELF"
log "  LP_SUPPORT_TOKENS=${LP_SUPPORT_TOKENS[*]}"
log ""

detect_auth_mode
get_app_provider_token

##############################################################################
# Step 2: Upload DARs to app-provider node
##############################################################################

log ""
log "Step 1: Uploading DARs to app-provider ($APP_PROVIDER_JSON_API)..."

if check_all_dars_uploaded "$APP_PROVIDER_TOKEN" "$APP_PROVIDER_JSON_API" "${DAR_FILES[@]}"; then
  log "  All DAR packages already present, skipping upload."
else
  for dar in "${DAR_FILES[@]}"; do
    if [ ! -f "$DARS_DIR/$dar" ]; then
      log_error "DAR file not found: $DARS_DIR/$dar"
      exit 1
    fi
    upload_dar "$DARS_DIR/$dar" "$APP_PROVIDER_TOKEN" "$APP_PROVIDER_JSON_API"
  done
  log "  All DARs uploaded."
fi

##############################################################################
# Step 3: Create internal party on app-provider node
##############################################################################

log ""
log "Step 2: Creating internal party on app-provider..."

if [ "$AUTH_MODE" = "oauth2" ]; then
  ADMIN_USER_ID="$KEYCLOAK_APP_PROVIDER_VALIDATOR_USER_ID"
else
  ADMIN_USER_ID="$SHARED_SECRET_APP_PROVIDER_USER"
fi

# Get participant namespace (fingerprint) to construct expected party ID
PARTICIPANT_ID=$(curl_check "$APP_PROVIDER_JSON_API/v2/parties/participant-id" "$APP_PROVIDER_TOKEN" "application/json" \
  | jq -r '.participantId // empty')

if [ -z "$PARTICIPANT_ID" ]; then
  log_error "Could not get participant ID from app-provider"
  exit 1
fi

NAMESPACE="${PARTICIPANT_ID#participant::}"
log "  Participant namespace: ${NAMESPACE:0:40}..."

# Check if party already exists
EXPECTED_PARTY="${LP_PARTY_HINT}::${NAMESPACE}"
EXISTING_PARTY=$(curl_check "$APP_PROVIDER_JSON_API/v2/parties/party?parties=$EXPECTED_PARTY" "$APP_PROVIDER_TOKEN" "application/json" \
  | jq -r '.partyDetails[0].party // empty' 2>/dev/null || echo "")

LP_PARTY_ID=""
if [ -n "$EXISTING_PARTY" ] && [ "$EXISTING_PARTY" != "null" ]; then
  LP_PARTY_ID="$EXISTING_PARTY"
  log "  Party already exists: ${LP_PARTY_ID:0:60}..."
else
  # Allocate a new internal party
  log "  Allocating party with hint '$LP_PARTY_HINT'..."
  ALLOCATE_RESULT=$(curl_check "$APP_PROVIDER_JSON_API/v2/parties" "$APP_PROVIDER_TOKEN" "application/json" \
    --data-raw "$(jq -n \
      --arg hint "$LP_PARTY_HINT" \
      --arg name "$LP_NAME" \
      '{
        partyIdHint: $hint,
        displayName: $name,
        identityProviderId: ""
      }')") || {
    log_error "Failed to allocate party '$LP_PARTY_HINT'"
    exit 1
  }

  LP_PARTY_ID=$(echo "$ALLOCATE_RESULT" | jq -r '.partyDetails.party // empty')
  if [ -z "$LP_PARTY_ID" ]; then
    log_error "Allocate succeeded but no partyId in response"
    log_error "Response: $(echo "$ALLOCATE_RESULT" | head -c 300)"
    exit 1
  fi

  log "  Party allocated: ${LP_PARTY_ID:0:60}..."
fi

log "  LP_PARTY_ID=$LP_PARTY_ID"

# Grant actAs and readAs rights to the admin user for the new party
log "  Granting rights to $ADMIN_USER_ID for $LP_PARTY_ID..."
curl_check "$APP_PROVIDER_JSON_API/v2/users/$ADMIN_USER_ID/rights" "$APP_PROVIDER_TOKEN" "application/json" \
  --data-raw "$(jq -n \
    --arg userId "$ADMIN_USER_ID" \
    --arg party "$LP_PARTY_ID" \
    '{
      userId: $userId,
      identityProviderId: "",
      rights: [
        { kind: { CanActAs: { value: { party: $party } } } },
        { kind: { CanReadAs: { value: { party: $party } } } }
      ]
    }')" > /dev/null 2>&1 || log "  (Rights may already be granted)"

# Create a Canton user for the LP party (with primaryParty set)
LP_USER_ID="$LP_PARTY_HINT"
log "  Creating Canton user '$LP_USER_ID' for $LP_PARTY_ID..."

USER_STATUS=$(curl_status_code "$APP_PROVIDER_JSON_API/v2/users/$LP_USER_ID" "$APP_PROVIDER_TOKEN")

if [ "$USER_STATUS" != "200" ]; then
  curl_check "$APP_PROVIDER_JSON_API/v2/users" "$APP_PROVIDER_TOKEN" "application/json" \
    --data-raw "$(jq -n \
      --arg userId "$LP_USER_ID" \
      --arg party "$LP_PARTY_ID" \
      --arg displayName "$LP_NAME" \
      '{
        user: {
          id: $userId,
          isDeactivated: false,
          primaryParty: $party,
          identityProviderId: "",
          metadata: {
            resourceVersion: "",
            annotations: { username: $userId, displayName: $displayName }
          }
        },
        rights: []
      }')" > /dev/null
  log "  User '$LP_USER_ID' created."
else
  log "  User '$LP_USER_ID' already exists."
fi

# Grant LP user ActAs/ReadAs rights over its party
curl_check "$APP_PROVIDER_JSON_API/v2/users/$LP_USER_ID/rights" "$APP_PROVIDER_TOKEN" "application/json" \
  --data-raw "$(jq -n \
    --arg userId "$LP_USER_ID" \
    --arg party "$LP_PARTY_ID" \
    '{
      userId: $userId,
      identityProviderId: "",
      rights: [
        { kind: { CanActAs: { value: { party: $party } } } },
        { kind: { CanReadAs: { value: { party: $party } } } }
      ]
    }')" > /dev/null 2>&1 || log "  (User rights may already be granted)"

##############################################################################
# Step 4: Register LP in the backend
##############################################################################

log ""
log "Step 3: Registering LP in backend ($BACKEND_URL)..."

# Check backend is running
if ! curl -sf "$BACKEND_URL" > /dev/null 2>&1; then
  log_error "Backend not reachable at $BACKEND_URL"
  log_error "Start the backend first: cd $EXCHANGE_BACKEND_DIR && yarn start:dev"
  exit 1
fi

# Login as admin to get a token
BACKEND_ADMIN_USERNAME="${BACKEND_ADMIN_USERNAME:-superadmin}"
BACKEND_ADMIN_PASSWORD="${BACKEND_ADMIN_PASSWORD:?BACKEND_ADMIN_PASSWORD env var is required}"

log "  Logging in as $BACKEND_ADMIN_USERNAME..."
ADMIN_LOGIN_RESULT=$(curl -s -w "\n%{http_code}" "$BACKEND_URL/admin/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"$BACKEND_ADMIN_USERNAME\", \"password\": \"$BACKEND_ADMIN_PASSWORD\"}")

ADMIN_HTTP_CODE=$(echo "$ADMIN_LOGIN_RESULT" | tail -n1 | tr -d '\r')
ADMIN_LOGIN_BODY=$(echo "$ADMIN_LOGIN_RESULT" | sed '$d')

if [ "$ADMIN_HTTP_CODE" -ne "200" ] && [ "$ADMIN_HTTP_CODE" -ne "201" ]; then
  log_error "Admin login failed with HTTP $ADMIN_HTTP_CODE"
  log_error "Response: $ADMIN_LOGIN_BODY"
  exit 1
fi

ADMIN_TOKEN=$(echo "$ADMIN_LOGIN_BODY" | jq -r '.data.accessToken // .accessToken // empty')
if [ -z "$ADMIN_TOKEN" ]; then
  log_error "Failed to extract admin access token"
  exit 1
fi
log "  Admin login successful."

# Get admin ID from login response
BACKEND_ADMIN_ID=$(echo "$ADMIN_LOGIN_BODY" | jq -r '.data.admin.id // empty')

# Issue a partner API key for the LP backend to call exchange backend's partner API
log "  Issuing partner API key for LP backend..."
PARTNER_KEY_RESULT=$(curl -s -w "\n%{http_code}" "$BACKEND_URL/admin/partner-api-keys" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d "{\"adminId\": \"$BACKEND_ADMIN_ID\", \"name\": \"LP Backend - $LP_NAME\"}")

PARTNER_KEY_HTTP=$(echo "$PARTNER_KEY_RESULT" | tail -n1 | tr -d '\r')
PARTNER_KEY_BODY=$(echo "$PARTNER_KEY_RESULT" | sed '$d')

KAIRO_PARTNER_API_KEY=""
if [ "$PARTNER_KEY_HTTP" = "200" ] || [ "$PARTNER_KEY_HTTP" = "201" ]; then
  KAIRO_PARTNER_API_KEY=$(echo "$PARTNER_KEY_BODY" | jq -r '.data.rawKey // .rawKey // empty')
  log "  Partner API key created: ${KAIRO_PARTNER_API_KEY:0:12}..."
else
  log "  Could not create partner API key (HTTP $PARTNER_KEY_HTTP), falling back to LP_BACKEND_API_KEY"
  KAIRO_PARTNER_API_KEY="${LP_BACKEND_API_KEY:-local-lp-api-key}"
fi

# Build supportTokens JSON array
SUPPORT_TOKENS_JSON=$(printf '%s\n' "${LP_SUPPORT_TOKENS[@]}" | jq -R . | jq -s .)

# Build the LP registration body
if [ "$LP_SELF" = "true" ]; then
  LP_BODY=$(jq -n \
    --arg lpPartyId "$LP_PARTY_ID" \
    --arg lpName "$LP_NAME" \
    --arg type "$LP_TYPE" \
    --argjson supportTokens "$SUPPORT_TOKENS_JSON" \
    '{
      lpPartyId: $lpPartyId,
      lpName: $lpName,
      type: $type,
      supportTokens: $supportTokens,
      isSelfLp: true
    }')
else
  LP_API="${LP_API:-http://localhost:3001}"
  LP_TOKEN="${LP_TOKEN:-local-lp-token}"
  LP_BODY=$(jq -n \
    --arg lpPartyId "$LP_PARTY_ID" \
    --arg lpName "$LP_NAME" \
    --arg lpApi "$LP_API" \
    --arg lpToken "$LP_TOKEN" \
    --arg burnPartyId "$LP_PARTY_ID" \
    --arg type "$LP_TYPE" \
    --argjson supportTokens "$SUPPORT_TOKENS_JSON" \
    '{
      lpPartyId: $lpPartyId,
      lpName: $lpName,
      lpApi: $lpApi,
      lpToken: $lpToken,
      burnPartyId: $burnPartyId,
      type: $type,
      supportTokens: $supportTokens,
      isSelfLp: false
    }')
fi

log "  Registering LP..."
LP_RESULT=$(curl -s -w "\n%{http_code}" "$BACKEND_URL/liquidity-provider" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d "$LP_BODY")

LP_HTTP_CODE=$(echo "$LP_RESULT" | tail -n1 | tr -d '\r')
LP_RESPONSE_BODY=$(echo "$LP_RESULT" | sed '$d')

case "$LP_HTTP_CODE" in
  200|201)
    log "  LP registered successfully!"
    ;;
  409)
    log "  LP already registered (conflict). Using existing."
    ;;
  *)
    log_error "LP registration failed with HTTP $LP_HTTP_CODE"
    log_error "Response: $LP_RESPONSE_BODY"
    exit 1
    ;;
esac

# Extract LP ID from response
LP_ID=$(echo "$LP_RESPONSE_BODY" | jq -r '.data.id // .id // empty' 2>/dev/null || echo "")

##############################################################################
# Step 5: Generate .env.local for kairo-dex-lp-backend
##############################################################################

log ""
log "Step 4: Generating .env.local for kairo-dex-lp-backend..."

if [ -z "$LP_BACKEND_DIR" ]; then
  log "  LP_BACKEND_DIR not set in .env, skipping LP backend .env generation."
else
  if [ ! -d "$LP_BACKEND_DIR" ]; then
    log_error "LP backend directory not found: $LP_BACKEND_DIR"
    log "  Skipping LP backend .env generation."
  else
    # Resolve the global synchronizer ID (reuse from app-provider participant)
    LP_GLOBAL_SYNCHRONIZER_ID=$(curl_check "$APP_PROVIDER_JSON_API/v2/state/connected-synchronizers" "$APP_PROVIDER_TOKEN" "application/json" \
      | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

    # Resolve executor party from the exchange backend .env
    BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
    LP_EXECUTOR_PARTY=""
    if [ -f "$BACKEND_ENV" ]; then
      LP_EXECUTOR_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)
    fi

    # Resolve DSO party
    LP_DSO_PARTY=""
    if [ -f "$BACKEND_ENV" ]; then
      LP_DSO_PARTY=$(grep -E '^DSO=' "$BACKEND_ENV" | cut -d= -f2-)
    fi

    # Resolve validator party ID (app-provider's primary party from the participant node)
    LP_VALIDATOR_PARTY=$(curl_check "$APP_PROVIDER_JSON_API/v2/users/$ADMIN_USER_ID" "$APP_PROVIDER_TOKEN" "application/json" \
      | jq -r '.user.primaryParty // empty')
    log "  VALIDATOR_PARTY_ID=$LP_VALIDATOR_PARTY"

    # Auth config for LP backend
    if [ "$AUTH_MODE" = "oauth2" ]; then
      LP_AUTH_MODE="oauth"
      LP_AUTH_SECRET=""
      LP_AUTH0_TOKEN_URL="$KEYCLOAK_APP_PROVIDER_TOKEN_URL"
      LP_AUTH0_CLIENT_ID="$KEYCLOAK_APP_PROVIDER_CLIENT_ID"
      LP_AUTH0_CLIENT_SECRET="$KEYCLOAK_APP_PROVIDER_CLIENT_SECRET"
      LP_AUTH0_AUDIENCE="https://canton.network.global"
      LP_VALIDATOR_AUDIENCE="https://canton.network.global"
    else
      LP_AUTH_MODE="share-secret"
      LP_AUTH_SECRET="$SHARED_SECRET"
      LP_AUTH0_TOKEN_URL=""
      LP_AUTH0_CLIENT_ID=""
      LP_AUTH0_CLIENT_SECRET=""
      LP_AUTH0_AUDIENCE="$SHARED_SECRET_AUDIENCE"
      LP_VALIDATOR_AUDIENCE="$SHARED_SECRET_AUDIENCE"
    fi

    LP_BACKEND_API_KEY="${LP_BACKEND_API_KEY:-local-lp-api-key}"

    cat > "$LP_BACKEND_DIR/.env.local" <<LPENVEOF
# Generated by 05-setup-liquidity-provider.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Local quickstart network configuration for kairo-dex-lp-backend

PORT=${LP_BACKEND_PORT:-3002}

# Canton participant (App Provider node — LP's validator)
PARTICIPANT_LEDGER_API=$APP_PROVIDER_JSON_API
VALIDATOR_API=$APP_PROVIDER_VALIDATOR_API
ADMIN_USER=$ADMIN_USER_ID
GLOBAL_SYNCHRONIZER_ID=$LP_GLOBAL_SYNCHRONIZER_ID

# DSO
DSO=$LP_DSO_PARTY

# API key protecting this LP backend's REST API
API_KEYS=$LP_BACKEND_API_KEY

# Auth (Canton Ledger Participant Auth)
AUTH_MODE=$LP_AUTH_MODE
AUTH_SECRET=$LP_AUTH_SECRET
AUTH0_TOKEN_URL=$LP_AUTH0_TOKEN_URL
AUTH0_CLIENT_ID=$LP_AUTH0_CLIENT_ID
AUTH0_CLIENT_SECRET=$LP_AUTH0_CLIENT_SECRET
AUTH0_AUDIENCE=$LP_AUTH0_AUDIENCE
VALIDATOR_AUDIENCE=$LP_VALIDATOR_AUDIENCE

# Party IDs
EXECUTOR_PARTY_ID=$LP_EXECUTOR_PARTY
VALIDATOR_PARTY_ID=$LP_VALIDATOR_PARTY

# Kairo Backend API (for token issuer, price feeds, feature app rights)
KAIRO_CLIENT_API_URL=$BACKEND_URL
KAIRO_CLIENT_API_KEY=$KAIRO_PARTNER_API_KEY

# Utilities API
UTILITIES_API_URL=$BACKEND_URL

# Template IDs (matching uploaded DARs)
MARKET_QUOTE_TEMPLATE_ID="#kairo-dex-simple-marketquote-v2:Kairo.Exchange.MarketQuote:MarketQuote"
MARKET_QUOTE_PROPOSAL_TEMPLATE_ID="#kairo-dex-simple-marketquote-v2:Kairo.Exchange.MarketQuoteProposal:MarketQuoteProposal"
FUNGIBLE_ALLOCATION_TEMPLATE_ID="#utility-registry-v0:Utility.Registry.V0.Holding.Allocation:DvpLegAllocation"
FUNGIBLE_TOKEN_HOLDING_TEMPLATE_ID="#utility-registry-holding-v0:Utility.Registry.Holding.V0.Holding:Holding"
AMULET_ALLOCATION_TEMPLATE_ID="#splice-amulet:Splice.AmuletAllocation:AmuletAllocation"
LOCKED_AMULET_TEMPLATE_ID="#splice-amulet:Splice.Amulet:LockedAmulet"
TRANSFER_FACTORY_TEMPLATE_ID="#utility-registry-app-v0:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory"
TRADE_PROPOSAL_TEMPLATE_ID="#kairo-dex-simple-escrow-v4:Kairo.Escrow.TradeProposal:TradeProposal"
LPENVEOF

    log "  Generated: $LP_BACKEND_DIR/.env.local"

    # Activate as .env (backup existing)
    if [ -f "$LP_BACKEND_DIR/.env" ]; then
      cp "$LP_BACKEND_DIR/.env" "$LP_BACKEND_DIR/.env.backup.$(date +%s)"
      log "  Backed up existing .env"
    fi
    cp "$LP_BACKEND_DIR/.env.local" "$LP_BACKEND_DIR/.env"
    log "  Activated .env.local as .env"
  fi
fi

##############################################################################
# Step 6: Write result to JSON
##############################################################################

log ""
log "Step 5: Writing result to $LP_OUTPUT_FILE..."

jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg lpId "$LP_ID" \
  --arg lpPartyId "$LP_PARTY_ID" \
  --arg lpName "$LP_NAME" \
  --arg lpSelf "$LP_SELF" \
  --arg lpType "$LP_TYPE" \
  --arg partyHint "$LP_PARTY_HINT" \
  --arg kairoPartnerApiKeyPrefix "${KAIRO_PARTNER_API_KEY:0:12}" \
  --argjson supportTokens "$SUPPORT_TOKENS_JSON" \
  --argjson registrationResponse "$(echo "$LP_RESPONSE_BODY" | jq '.' 2>/dev/null || echo '{}')" \
  '{
    generatedAt: $generatedAt,
    liquidityProvider: {
      id: $lpId,
      lpPartyId: $lpPartyId,
      lpName: $lpName,
      isSelfLp: ($lpSelf == "true"),
      type: $lpType,
      partyHint: $partyHint,
      supportTokens: $supportTokens,
      kairoPartnerApiKeyPrefix: $kairoPartnerApiKeyPrefix
    },
    registrationResponse: $registrationResponse
  }' > "$LP_OUTPUT_FILE"

log "  Written to: $LP_OUTPUT_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Liquidity Provider Setup Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Party ID:  $LP_PARTY_ID"
log "  LP Name:   $LP_NAME"
log "  Self-LP:   $LP_SELF"
log "  Type:      $LP_TYPE"
log "  Tokens:    ${LP_SUPPORT_TOKENS[*]}"
if [ -n "$LP_ID" ]; then
  log "  Backend ID: $LP_ID"
fi
log ""
log "Result: cat $LP_OUTPUT_FILE | jq"
