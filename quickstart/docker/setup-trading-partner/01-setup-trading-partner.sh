#!/bin/bash
# Setup script for trading-partner validator node on local quickstart network.
# Uploads kairo-dex-simple-escrow-v5 and utility-related DAR files, resolves party IDs,
# and outputs configuration needed for the trading-js-sdk.
#
# Prerequisites: quickstart must be running with trading-partner profile enabled
#
# Usage: ./01-setup-trading-partner.sh

set -eo pipefail

##############################################################################
# Dependency checks
##############################################################################

for cmd in curl jq openssl; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "[setup-trading-partner] ERROR: Required tool '$cmd' not found. Please install it." >&2
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
  echo "[setup-trading-partner] ERROR: $SCRIPT_DIR/.env not found. Copy .env.example to .env first." >&2
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
  echo "[setup-trading-partner] $*"
}

log_error() {
  echo "[setup-trading-partner] ERROR: $*" >&2
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

# Source shared auth helpers (shared-secret + OAuth2)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/auth.sh"

# Detect auth mode:
#   1. Use AUTH_MODE from .env if explicitly set to "oauth2"
#   2. Fall back to quickstart/.env.local (localnet convenience)
#   3. Default to "shared-secret"
detect_auth_mode() {
  if [ "${AUTH_MODE:-}" = "oauth2" ]; then
    log "AUTH_MODE=oauth2 (from .env)"
    return
  fi
  local env_local="$QUICKSTART_DIR/.env.local"
  if [ -f "$env_local" ]; then
    local detected
    detected=$(grep -E '^AUTH_MODE=' "$env_local" | cut -d= -f2 | tr -d '"' | tr -d "'" | head -1)
    if [ -n "$detected" ]; then
      AUTH_MODE="$detected"
      log "Detected AUTH_MODE=$AUTH_MODE (from quickstart/.env.local)"
      return
    fi
  fi
  AUTH_MODE="${AUTH_MODE:-shared-secret}"
  log "AUTH_MODE=$AUTH_MODE (default)"
}

# Obtain tokens for trading-partner and SV nodes.
# The SV node is always accessed via shared-secret regardless of AUTH_MODE.
get_tokens() {
  log "Obtaining auth tokens (AUTH_MODE=$AUTH_MODE)..."
  TRADING_PARTNER_TOKEN=$(get_participant_token)
  # SV is always shared-secret
  SV_TOKEN=$(_generate_jwt "${SHARED_SECRET_SV_USER:-ledger-api-user}" \
    "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" \
    "${SHARED_SECRET:-unsafe}")

  if [ -z "$TRADING_PARTNER_TOKEN" ] || [ -z "$SV_TOKEN" ]; then
    log_error "Failed to obtain auth tokens"
    exit 1
  fi
  log "Auth tokens obtained"
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

# Get connected synchronizer ID
get_synchronizer_id() {
  local token=$1
  local participant=$2
  curl_check "$participant/v2/state/connected-synchronizers" "$token" "application/json" \
    | jq -r '.connectedSynchronizers[0].synchronizerId'
}

# Extract main package ID from DAR manifest
get_dar_package_id() {
  local dar_path=$1
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
log "Trading Partner Validator Setup"
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
# Step 3: Upload DARs to trading-partner participant node
##############################################################################

log ""
log "Step 2: Uploading DAR files to trading-partner participant node..."

if check_all_dars_uploaded "$TRADING_PARTNER_TOKEN" "$TRADING_PARTNER_JSON_API" "${DAR_FILES[@]}"; then
  log "All DAR packages already present on trading-partner participant, skipping upload."
else
  log "Uploading to trading-partner participant ($TRADING_PARTNER_JSON_API)..."
  for dar in "${DAR_FILES[@]}"; do
    upload_dar "$DARS_DIR/$dar" "$TRADING_PARTNER_TOKEN" "$TRADING_PARTNER_JSON_API"
  done
  log "All DAR files uploaded successfully"
fi

##############################################################################
# Step 4: Resolve party IDs and network info
##############################################################################

log ""
log "Step 3: Resolving party IDs and network info..."

TRADING_PARTNER_PARTY=$(get_party_id "$TRADING_PARTNER_TOKEN" "$ADMIN_USER" "$TRADING_PARTNER_JSON_API")
log "  TRADING_PARTNER_PARTY=$TRADING_PARTNER_PARTY"

DSO_PARTY=$(get_dso_party_id "$TRADING_PARTNER_TOKEN" "$TRADING_PARTNER_VALIDATOR_API")
log "  DSO_PARTY=$DSO_PARTY"

SYNCHRONIZER_ID=$(get_synchronizer_id "$TRADING_PARTNER_TOKEN" "$TRADING_PARTNER_JSON_API")
log "  SYNCHRONIZER_ID=$SYNCHRONIZER_ID"

##############################################################################
# Step 5: Write output config
##############################################################################

log ""
log "Step 4: Writing trading-partner configuration..."

if [ "${AUTH_MODE:-shared-secret}" = "oauth2" ]; then
  AUTH_CONFIG=$(jq -n \
    --arg tokenUrl "${OAUTH2_TOKEN_URL:-}" \
    --arg clientId "${OAUTH2_CLIENT_ID:-}" \
    --arg audience "${OAUTH2_AUDIENCE:-}" \
    '{tokenUrl: $tokenUrl, clientId: $clientId, audience: $audience}')
else
  AUTH_CONFIG=$(jq -n \
    --arg secret "${SHARED_SECRET:-unsafe}" \
    --arg audience "${SHARED_SECRET_AUDIENCE:-https://canton.network.global}" \
    --arg userId "${SHARED_SECRET_TRADING_PARTNER_USER:-ledger-api-user}" \
    '{secret: $secret, audience: $audience, userId: $userId}')
fi

jq -n \
  --arg party "$TRADING_PARTNER_PARTY" \
  --arg dso "$DSO_PARTY" \
  --arg sync "$SYNCHRONIZER_ID" \
  --arg ledgerApi "$TRADING_PARTNER_JSON_API" \
  --arg validatorApi "$TRADING_PARTNER_VALIDATOR_API" \
  --arg authMode "${AUTH_MODE:-shared-secret}" \
  --argjson authConfig "$AUTH_CONFIG" \
  '{
    tradingPartnerParty: $party,
    dsoParty: $dso,
    synchronizerId: $sync,
    ledgerApiUrl: $ledgerApi,
    validatorApiUrl: $validatorApi,
    authMode: $authMode,
    authConfig: $authConfig,
    ports: { ledgerApi: 1901, adminApi: 1902, jsonApi: 1975, validatorApi: 1903 }
  }' > "$SCRIPT_DIR/trading-partner-config.json"
log "  Written: $SCRIPT_DIR/trading-partner-config.json"

log ""
log "=========================================="
log "Trading Partner Setup Complete"
log "=========================================="
log ""
log "Trading Partner Party: $TRADING_PARTNER_PARTY"
log "DSO Party:             $DSO_PARTY"
log "Synchronizer ID:       $SYNCHRONIZER_ID"
log "JSON API:              $TRADING_PARTNER_JSON_API"
log "Validator API:         $TRADING_PARTNER_VALIDATOR_API"
log ""
log "Config written to: $SCRIPT_DIR/trading-partner-config.json"
log ""
log "To use with trading-js-sdk:"
log "  const client = new KairoExchangeClient({"
log "    kairoApiUrl: 'http://localhost:3003',"
log "    apiKey: '<partner-api-key>',"
log "    ledgerApiUrl: '$TRADING_PARTNER_JSON_API',"
log "    validatorApiUrl: '$TRADING_PARTNER_VALIDATOR_API',"
log "    // authMode and authConfig — see trading-partner-config.json"
log "    executorPartyId: '$TRADING_PARTNER_PARTY',"
log "    synchronizerId: '$SYNCHRONIZER_ID',"
log "  });"
