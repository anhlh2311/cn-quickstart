#!/bin/bash
# Registers the FeaturedAppRight contract in the canton-exchange-backend database
# and exports contract data to featured-app-right.json for use by MergeDelegation scripts.
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - setup-exchange.sh must have been run (DARs uploaded, contracts created)
#   - canton-exchange-backend must be running (yarn start:dev)
#
# Outputs:
#   - featured-app-right.json — contract ID, disclosure data (blob, templateId, synchronizerId)
#
# Usage: ./02-register-featured-app-right.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUICKSTART_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load shared configuration from .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[register-far] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

# Alias for shared-secret user (register script uses the app-user participant)
SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[register-far] $*"
}

log_error() {
  echo "[register-far] ERROR: $*" >&2
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

# Output file for FeaturedAppRight contract data
FAR_OUTPUT_FILE="$SCRIPT_DIR/featured-app-right.json"

# Query FeaturedAppRight from Canton ledger (with createdEventBlob for disclosed contracts)
query_far_from_ledger() {
  local canton_token="$1"
  local party="$2"

  local offset
  offset=$(curl -sf "$APP_USER_JSON_API/v2/state/ledger-end" \
    -H "Authorization: Bearer $canton_token" \
    -H "Content-Type: application/json" | jq -r '.offset')

  local query_body
  query_body=$(jq -n \
    --arg party "$party" \
    --arg offset "$offset" \
    '{
      filter: {
        filtersByParty: {
          ($party): {
            cumulative: [{
              identifierFilter: {
                TemplateFilter: {
                  value: {
                    templateId: "#splice-amulet:Splice.Amulet:FeaturedAppRight",
                    includeCreatedEventBlob: true
                  }
                }
              }
            }]
          }
        }
      },
      verbose: false,
      activeAtOffset: $offset
    }')

  curl -sf "$APP_USER_JSON_API/v2/state/active-contracts" \
    -H "Authorization: Bearer $canton_token" \
    -H "Content-Type: application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
}

# Write featured-app-right.json with contract ID and disclosure data
write_far_json() {
  local contract_id="$1"
  local template_id_hash="$2"
  local blob="$3"
  local sync_id="$4"
  local party="$5"

  jq -n \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg contractId "$contract_id" \
    --arg templateId "#splice-amulet:Splice.Amulet:FeaturedAppRight" \
    --arg type "$FEATURE_APP_RIGHT_TYPE" \
    --arg beneficiary "$party" \
    --arg disclosureCid "$contract_id" \
    --arg disclosureTemplate "$template_id_hash" \
    --arg disclosureBlob "$blob" \
    --arg disclosureSyncId "$sync_id" \
    '{
      generatedAt: $generatedAt,
      featuredAppRight: {
        contractId: $contractId,
        templateId: $templateId,
        type: $type,
        beneficiaries: [
          { beneficiary: $beneficiary, weight: "1.0" }
        ],
        disclosure: {
          contractId: $disclosureCid,
          templateId: $disclosureTemplate,
          createdEventBlob: $disclosureBlob,
          synchronizerId: $disclosureSyncId
        }
      }
    }' > "$FAR_OUTPUT_FILE"

  log "  Exported to: $FAR_OUTPUT_FILE"
}

##############################################################################
# Step 1: Read backend .env for party IDs and DB config
##############################################################################

log "=========================================="
log "Register FeaturedAppRight in Backend"
log "=========================================="

BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
if [ ! -f "$BACKEND_ENV" ]; then
  log_error "Backend .env not found: $BACKEND_ENV"
  log_error "Run setup-exchange.sh first."
  exit 1
fi

# Read party ID from backend .env (dynamically resolved by setup-exchange.sh)
APP_USER_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)

# DB credentials from shared .env
DB_HOST="$EXCHANGE_DB_HOST"
DB_PORT="$EXCHANGE_DB_PORT"
DB_USERNAME="$EXCHANGE_DB_USERNAME"
DB_PASSWORD="$EXCHANGE_DB_PASSWORD"
DB_NAME="$EXCHANGE_DB_NAME"

if [ -z "$APP_USER_PARTY" ]; then
  log_error "EXECUTOR_PARTY_ID not found in .env"
  exit 1
fi

log "  APP_USER_PARTY=$APP_USER_PARTY"

##############################################################################
# Step 2: Check backend is running
##############################################################################

log ""
log "Step 1: Checking backend is running..."

if ! curl -sf "$BACKEND_URL" > /dev/null 2>&1; then
  log_error "Backend not reachable at $BACKEND_URL"
  log_error "Start the backend first: cd $EXCHANGE_BACKEND_DIR && yarn start:dev"
  exit 1
fi
log "  Backend is running at $BACKEND_URL"

##############################################################################
# Step 3: Check if FeaturedAppRight is already registered
##############################################################################

log ""
log "Step 2: Checking existing registration..."

# Generate a backend JWT to check the API
# First, ensure the setup user exists in the database
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

# Check if already registered
EXISTING=$(curl -sf "$BACKEND_URL/feature-app-right/type/$FEATURE_APP_RIGHT_TYPE" \
  -H "Authorization: Bearer $BACKEND_TOKEN" 2>/dev/null || echo "")

if [ -n "$EXISTING" ] && echo "$EXISTING" | jq -e '.data.featuredAppRightCid // .featuredAppRightCid' > /dev/null 2>&1; then
  EXISTING_CID=$(echo "$EXISTING" | jq -r '.data.featuredAppRightCid // .featuredAppRightCid')
  log "  FeaturedAppRight already registered in backend: type=$FEATURE_APP_RIGHT_TYPE"
  log "  CID: $EXISTING_CID"

  # Still export the JSON file (needed by MergeDelegation scripts)
  if [ ! -f "$FAR_OUTPUT_FILE" ]; then
    log "  Exporting FeaturedAppRight to JSON..."
    CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

    SYNCHRONIZER_ID=$(curl -sf "$APP_USER_JSON_API/v2/state/connected-synchronizers" \
      -H "Authorization: Bearer $CANTON_TOKEN" \
      -H "Content-Type: application/json" | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

    FAR_RESPONSE=$(query_far_from_ledger "$CANTON_TOKEN" "$APP_USER_PARTY")
    if [ -n "$FAR_RESPONSE" ]; then
      FAR_TEMPLATE_HASH=$(echo "$FAR_RESPONSE" | jq -r '
        [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
      ' 2>/dev/null || echo "")
      FAR_BLOB=$(echo "$FAR_RESPONSE" | jq -r '
        [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
      ' 2>/dev/null || echo "")

      if [ -n "$FAR_BLOB" ] && [ -n "$SYNCHRONIZER_ID" ]; then
        write_far_json "$EXISTING_CID" "$FAR_TEMPLATE_HASH" "$FAR_BLOB" "$SYNCHRONIZER_ID" "$APP_USER_PARTY"
      else
        log "  WARNING: Could not export JSON (missing blob or synchronizerId)"
      fi
    fi
  else
    log "  JSON already exported: $FAR_OUTPUT_FILE"
  fi

  log ""
  log "Done. No action needed."
  exit 0
fi

log "  Not yet registered, proceeding..."

##############################################################################
# Step 4: Query FeaturedAppRight contract ID from Canton ledger
##############################################################################

log ""
log "Step 3: Querying FeaturedAppRight from Canton ledger..."

CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

# Get synchronizer ID for disclosed contract metadata
SYNCHRONIZER_ID=$(curl -sf "$APP_USER_JSON_API/v2/state/connected-synchronizers" \
  -H "Authorization: Bearer $CANTON_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

# Query with includeCreatedEventBlob: true (needed for disclosure data)
FAR_RESPONSE=$(query_far_from_ledger "$CANTON_TOKEN" "$APP_USER_PARTY")

FEATURED_APP_RIGHT_CID=""
FAR_TEMPLATE_HASH=""
FAR_BLOB=""
if [ -n "$FAR_RESPONSE" ]; then
  FEATURED_APP_RIGHT_CID=$(echo "$FAR_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
  FAR_TEMPLATE_HASH=$(echo "$FAR_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
  ' 2>/dev/null || echo "")
  FAR_BLOB=$(echo "$FAR_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
  ' 2>/dev/null || echo "")
fi

if [ -z "$FEATURED_APP_RIGHT_CID" ]; then
  log_error "No FeaturedAppRight contract found on the ledger."
  log_error "Run setup-exchange.sh first to create the contract."
  exit 1
fi

log "  Found FeaturedAppRight: $FEATURED_APP_RIGHT_CID"

##############################################################################
# Step 5: Register in backend via API
##############################################################################

log ""
log "Step 4: Registering FeaturedAppRight in backend..."

REGISTER_BODY=$(jq -n \
  --arg cid "$FEATURED_APP_RIGHT_CID" \
  --arg validator "$APP_USER_PARTY" \
  --arg type "$FEATURE_APP_RIGHT_TYPE" \
  --arg beneficiary "$APP_USER_PARTY" \
  '{
    featuredAppRightCid: $cid,
    validator: $validator,
    type: $type,
    beneficiaries: [{
      beneficiary: $beneficiary,
      weight: "1.0"
    }]
  }')

REGISTER_RESULT=$(curl -sf -w "\n%{http_code}" "$BACKEND_URL/feature-app-right" \
  -H "Authorization: Bearer $BACKEND_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$REGISTER_BODY" 2>&1) || true

HTTP_CODE=$(echo "$REGISTER_RESULT" | tail -n1 | tr -d '\r')
RESPONSE_BODY=$(echo "$REGISTER_RESULT" | sed '$d')

case "$HTTP_CODE" in
  200|201)
    log "  Registered successfully!"
    REGISTERED_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null || echo "")
    log "  DB ID: $REGISTERED_ID"
    log "  Type: $FEATURE_APP_RIGHT_TYPE"
    log "  CID: $FEATURED_APP_RIGHT_CID"
    ;;
  409)
    log "  Already registered (type '$FEATURE_APP_RIGHT_TYPE' exists)."
    ;;
  *)
    log_error "Registration failed with HTTP $HTTP_CODE"
    log_error "Response: $RESPONSE_BODY"
    exit 1
    ;;
esac

##############################################################################
# Step 6: Export FeaturedAppRight to JSON file
##############################################################################

log ""
log "Step 5: Exporting FeaturedAppRight to JSON..."

if [ -n "$FAR_BLOB" ] && [ -n "$SYNCHRONIZER_ID" ]; then
  write_far_json "$FEATURED_APP_RIGHT_CID" "$FAR_TEMPLATE_HASH" "$FAR_BLOB" "$SYNCHRONIZER_ID" "$APP_USER_PARTY"
else
  log "  WARNING: Could not export JSON (missing blob or synchronizerId)"
  log "  Re-run this script to generate the JSON file."
fi

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Registration complete!"
log "=========================================="
log ""
log "Verify: curl -s $BACKEND_URL/feature-app-right | jq"
log "JSON export: cat $FAR_OUTPUT_FILE | jq"
