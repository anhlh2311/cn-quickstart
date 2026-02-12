#!/bin/bash
# Registers the Amulet (CC) token in the canton-exchange-backend.
# Unlike CBTC, Amulet is the native Canton Network cryptocurrency managed by the DSO.
# Its allocation factory is fetched **dynamically** from the validator's scan-proxy registry,
# so no external party onboarding, contract creation, or allocation-factory DB registration
# is needed. This script only registers the Amulet token issuer in the backend database.
#
# How Amulet differs from CBTC:
#   - No external party onboarding (DSO is already known to the network)
#   - No contract creation (AmuletRules, ExternalPartyAmuletRules, OpenMiningRound are DSO-managed)
#   - No allocation-factory DB entry (backend fetches it from scan-proxy on demand)
#   - Only a token-issuer DB entry is needed (admin = DSO party)
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - 01-setup-exchange.sh must have been run (DARs uploaded, contracts created)
#   - canton-exchange-backend must be running (yarn start:dev)
#
# Usage: ./04-register-amulet-token.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUICKSTART_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load shared configuration from .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[register-amulet] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

# Load Amulet configuration from JSON
AMULET_CONFIG_FILE="$SCRIPT_DIR/amulet-config.json"
if [ ! -f "$AMULET_CONFIG_FILE" ]; then
  echo "[register-amulet] ERROR: Amulet config not found: $AMULET_CONFIG_FILE" >&2
  exit 1
fi
AMULET_TOKEN_ID=$(jq -r '.tokenId' "$AMULET_CONFIG_FILE")
AMULET_DISPLAY_NAME=$(jq -r '.displayName' "$AMULET_CONFIG_FILE")
AMULET_SYMBOL=$(jq -r '.symbol' "$AMULET_CONFIG_FILE")
AMULET_PRICE_SOURCE_ID=$(jq -r '.priceSourceId' "$AMULET_CONFIG_FILE")

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
  echo "[register-amulet] $*"
}

log_error() {
  echo "[register-amulet] ERROR: $*" >&2
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

# Resolve the DSO party ID from the validator API
get_dso_party_id() {
  local token=$1
  local validator=$2
  curl_check "$validator/api/validator/v0/scan-proxy/dso-party-id" "$token" "application/json" | jq -r '.dso_party_id'
}

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Register Amulet Token (DSO-managed)"
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

# Generate Canton token for app-user participant
CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_APP_USER_USER" "$SHARED_SECRET_AUDIENCE")

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
# Step 1: Resolve DSO party ID
##############################################################################

log ""
log "Step 1: Resolving DSO party ID..."

# Try to get DSO from backend .env first
DSO_PARTY=$(grep -E '^DSO=' "$BACKEND_ENV" | cut -d= -f2- | tr -d '"' || echo "")

if [ -n "$DSO_PARTY" ] && [ "$DSO_PARTY" != "" ]; then
  log "  DSO party from backend .env: $DSO_PARTY"
else
  # Resolve from validator API
  log "  Resolving DSO party from validator API..."
  DSO_PARTY=$(get_dso_party_id "$CANTON_TOKEN" "$APP_USER_VALIDATOR_API") || {
    log_error "Failed to resolve DSO party ID"
    exit 1
  }
  log "  DSO party from validator: $DSO_PARTY"
fi

if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party ID"
  exit 1
fi

##############################################################################
# Step 2: Verify Amulet allocation factory is accessible (dynamic)
##############################################################################

log ""
log "Step 2: Verifying Amulet allocation factory is accessible..."

# The backend fetches Amulet factory contracts dynamically from the validator's
# scan-proxy registry endpoint. Verify it works by calling the backend API.
FACTORY_RESPONSE=$(curl -sf "$BACKEND_URL/allocation-factory/type/amulet" \
  -H "Authorization: Bearer $BACKEND_TOKEN" 2>/dev/null || echo "")

if [ -n "$FACTORY_RESPONSE" ]; then
  # Check if the response has the expected structure
  FACTORY_ID=$(echo "$FACTORY_RESPONSE" | jq -r '.data.factoryId // .factoryId // empty' 2>/dev/null || echo "")
  DISCLOSED_COUNT=$(echo "$FACTORY_RESPONSE" | jq -r '.data.choiceContext.disclosedContracts | length // 0' 2>/dev/null || echo "0")

  if [ -n "$FACTORY_ID" ]; then
    log "  Amulet allocation factory is accessible (dynamic from scan-proxy)"
    log "  Factory ID (ExternalPartyAmuletRules): ${FACTORY_ID:0:40}..."
    log "  Disclosed contracts: $DISCLOSED_COUNT"
  else
    log "  WARNING: Amulet allocation factory response missing factoryId"
    log "  Response: $(echo "$FACTORY_RESPONSE" | head -c 300)"
    log "  Continuing anyway — the factory may become available after network stabilizes"
  fi
else
  log "  WARNING: Could not reach Amulet allocation factory endpoint"
  log "  This is expected if the scan-proxy is not yet ready"
  log "  Continuing with token issuer registration..."
fi

##############################################################################
# Step 3: Register Amulet token issuer in backend (POST /token-issuer)
##############################################################################

log ""
log "Step 3: Registering Amulet token issuer in backend..."

# Check if already registered
EXISTING_ISSUER=$(curl -sf "$BACKEND_URL/token-issuer/token/$AMULET_TOKEN_ID" \
  -H "Authorization: Bearer $BACKEND_TOKEN" 2>/dev/null || echo "")

if [ -n "$EXISTING_ISSUER" ] && echo "$EXISTING_ISSUER" | jq -e '.data.tokenId // .tokenId' > /dev/null 2>&1; then
  EXISTING_TOKEN_ID=$(echo "$EXISTING_ISSUER" | jq -r '.data.tokenId // .tokenId')
  EXISTING_ADMIN=$(echo "$EXISTING_ISSUER" | jq -r '.data.admin // .admin // "unknown"')
  log "  Token issuer already registered: tokenId=$EXISTING_TOKEN_ID, admin=$EXISTING_ADMIN"
else
  # For Amulet, discloseContracts and choiceContextData are fetched dynamically
  # from the validator's scan-proxy registry at runtime. We store empty values
  # in the DB — the admin controller enriches the response with live data.
  TOKEN_ISSUER_BODY=$(jq -n \
    --arg admin "$DSO_PARTY" \
    --arg tokenId "$AMULET_TOKEN_ID" \
    --arg registrar "$DSO_PARTY" \
    --arg symbol "$AMULET_SYMBOL" \
    --arg displayName "$AMULET_DISPLAY_NAME" \
    --arg priceSourceId "$AMULET_PRICE_SOURCE_ID" \
    '{
      admin: $admin,
      tokenId: $tokenId,
      registrar: $registrar,
      factoryContractId: null,
      symbol: $symbol,
      displayName: $displayName,
      priceSourceId: (if $priceSourceId == "" then null else $priceSourceId end),
      metadata: null,
      discloseContracts: [],
      choiceContextData: { values: {} }
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
      log "  Token ID: $AMULET_TOKEN_ID"
      log "  Admin (DSO): $DSO_PARTY"
      ;;
    409)
      log "  Token issuer already registered (tokenId '$AMULET_TOKEN_ID' exists)."
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
log "Amulet Token Registration Complete!"
log "=========================================="
log ""
log "Summary:"
log "  DSO party (admin): $DSO_PARTY"
log "  Token ID: $AMULET_TOKEN_ID"
log "  Symbol: $AMULET_SYMBOL"
log "  Display name: $AMULET_DISPLAY_NAME"
log ""
log "Note: Amulet allocation factory is dynamic — fetched from the validator's"
log "scan-proxy registry at runtime. No allocation-factory DB entry is needed."
log ""
log "Verify:"
log "  curl -s $BACKEND_URL/token-issuer/token/$AMULET_TOKEN_ID -H 'Authorization: Bearer <token>' | jq"
log "  curl -s $BACKEND_URL/allocation-factory/type/amulet -H 'Authorization: Bearer <token>' | jq"
