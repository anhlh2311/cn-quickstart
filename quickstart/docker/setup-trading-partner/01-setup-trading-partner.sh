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

# Generate a shared-secret JWT (HS256, secret="unsafe")
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

# Get auth token for trading-partner (always uses shared-secret — no keycloak realm)
get_tokens() {
  log "Generating shared-secret JWT tokens..."
  TRADING_PARTNER_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_TRADING_PARTNER_USER" "$SHARED_SECRET_AUDIENCE")
  SV_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_SV_USER" "$SHARED_SECRET_AUDIENCE")

  if [ -z "$TRADING_PARTNER_TOKEN" ] || [ -z "$SV_TOKEN" ]; then
    log_error "Failed to generate auth tokens"
    exit 1
  fi
  log "Auth tokens generated successfully"
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

TRADING_PARTNER_PARTY=$(get_party_id "$TRADING_PARTNER_TOKEN" "$SHARED_SECRET_TRADING_PARTNER_USER" "$TRADING_PARTNER_JSON_API")
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

cat > "$SCRIPT_DIR/trading-partner-config.json" <<EOF
{
  "tradingPartnerParty": "$TRADING_PARTNER_PARTY",
  "dsoParty": "$DSO_PARTY",
  "synchronizerId": "$SYNCHRONIZER_ID",
  "ledgerApiUrl": "$TRADING_PARTNER_JSON_API",
  "validatorApiUrl": "$TRADING_PARTNER_VALIDATOR_API",
  "authMode": "share-secret",
  "authConfig": {
    "secret": "$SHARED_SECRET",
    "audience": "$SHARED_SECRET_AUDIENCE",
    "userId": "$SHARED_SECRET_TRADING_PARTNER_USER"
  },
  "ports": {
    "ledgerApi": 1901,
    "adminApi": 1902,
    "jsonApi": 1975,
    "validatorApi": 1903
  }
}
EOF
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
log "    authMode: 'share-secret',"
log "    authConfig: { secret: '$SHARED_SECRET', audience: '$SHARED_SECRET_AUDIENCE' },"
log "    executorPartyId: '$TRADING_PARTNER_PARTY',"
log "    synchronizerId: '$SYNCHRONIZER_ID',"
log "    adminUser: '$SHARED_SECRET_TRADING_PARTNER_USER'"
log "  });"
