#!/bin/bash
# Allocates and onboards internal parties on a Canton participant node.
#
# Internal parties are hosted directly on the participant (share the
# participant's namespace/fingerprint), unlike external parties which have
# their own keypairs. They use regular submission (no interactive submission).
#
# This script:
#   1. Resolves the participant's namespace (fingerprint)
#   2. Allocates N internal parties via POST /v2/parties
#   3. Creates Canton users with ActAs/ReadAs rights for each party
#
# Environment variables:
#   PARTICIPANT_JSON_API  — Canton JSON API URL (default: http://localhost:2975)
#   NUM_PARTIES           — Number of parties to allocate (default: 10)
#   PARTY_HINT_PREFIX     — Prefix for party hints; parties are named
#                           <PREFIX>-0, <PREFIX>-1, etc. (default: trader)
#   APPEND_PARTIES        — Set to "true" to append new parties to the existing
#                           output file instead of overwriting (default: false)
#   ONBOARD_ONLY          — Set to "true" to skip party allocation and only
#                           create Canton users from the existing output file.
#                           NUM_PARTIES and APPEND_PARTIES are ignored. (default: false)
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#
# Usage:
#   ./01-allocate-internal-parties.sh
#   NUM_PARTIES=5 PARTY_HINT_PREFIX=lp ./01-allocate-internal-parties.sh
#   APPEND_PARTIES=true NUM_PARTIES=5 ./01-allocate-internal-parties.sh
#   ONBOARD_ONLY=true ./01-allocate-internal-parties.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load configuration from .env
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

PARTICIPANT_JSON_API="${PARTICIPANT_JSON_API:-http://localhost:2975}"
NUM_PARTIES="${NUM_PARTIES:-10}"
PARTY_HINT_PREFIX="${PARTY_HINT_PREFIX:-trader}"
SHARED_SECRET="${SHARED_SECRET:-unsafe}"
SHARED_SECRET_AUDIENCE="${SHARED_SECRET_AUDIENCE:-https://canton.network.global}"
SHARED_SECRET_USER="${SHARED_SECRET_USER:-ledger-api-user}"
APPEND_PARTIES="${APPEND_PARTIES:-false}"
ONBOARD_ONLY="${ONBOARD_ONLY:-false}"

# Output file
PARTIES_FILE="$SCRIPT_DIR/internal-parties.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[internal-parties] $*"
}

log_error() {
  echo "[internal-parties] ERROR: $*" >&2
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

generate_jwt() {
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

##############################################################################
# Pre-flight checks
##############################################################################

log "=========================================="
log "Allocate Internal Parties"
log "=========================================="
if [ "$ONBOARD_ONLY" = "true" ]; then
  log "  Mode: onboard-only (skip party allocation)"
else
  log "  Parties: $NUM_PARTIES"
  log "  Prefix: $PARTY_HINT_PREFIX"
  log "  Append mode: $APPEND_PARTIES"
fi
log "  Participant: $PARTICIPANT_JSON_API"
log ""

TOKEN=$(generate_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

# Verify participant is reachable
VERSION=$(curl_check "$PARTICIPANT_JSON_API/v2/version" "" "application/json" 2>/dev/null | jq -r '.version // empty') || VERSION=""
if [ -z "$VERSION" ]; then
  log_error "Cannot reach participant at $PARTICIPANT_JSON_API"
  exit 1
fi
log "  Canton version: $VERSION"

# Get participant namespace (fingerprint)
PARTICIPANT_ID=$(curl_check "$PARTICIPANT_JSON_API/v2/parties/participant-id" "$TOKEN" "application/json" \
  | jq -r '.participantId // empty')

if [ -z "$PARTICIPANT_ID" ]; then
  log_error "Could not get participant ID"
  exit 1
fi

NAMESPACE="${PARTICIPANT_ID#participant::}"
log "  Participant ID: $PARTICIPANT_ID"
log "  Namespace: ${NAMESPACE:0:40}..."

##############################################################################
# ONBOARD_ONLY: validate and skip to user creation
##############################################################################

if [ "$ONBOARD_ONLY" = "true" ]; then
  if [ ! -f "$PARTIES_FILE" ]; then
    log_error "ONBOARD_ONLY=true but parties file not found: $PARTIES_FILE"
    exit 1
  fi

  if ! jq -e '[
    .participantId, .namespace,
    (.parties | type == "array"), (.parties | length > 0),
    (.parties[0] | has("partyId", "partyHint", "userId"))
  ] | all' "$PARTIES_FILE" > /dev/null 2>&1; then
    log_error "ONBOARD_ONLY=true but parties file is invalid or empty."
    log_error "Expected: { participantId, namespace, parties: [{ partyId, partyHint, userId, ... }] }"
    exit 1
  fi

  TOTAL_PARTIES=$(jq '.parties | length' "$PARTIES_FILE")
  log "Onboard-only mode: found $TOTAL_PARTIES parties in $PARTIES_FILE"
  log "Skipping party allocation (Step 1)."
else

##############################################################################
# Step 1: Allocate internal parties
##############################################################################

log ""

# Determine starting index for new parties
START_INDEX=0
if [ "$APPEND_PARTIES" = "true" ] && [ -f "$PARTIES_FILE" ]; then
  START_INDEX=$(jq '.parties | length' "$PARTIES_FILE")
  log "Step 1: Appending $NUM_PARTIES parties to existing $START_INDEX parties..."
elif [ -f "$PARTIES_FILE" ] && [ "$APPEND_PARTIES" != "true" ]; then
  log "Step 1: Overwriting existing parties file with $NUM_PARTIES new parties..."
  rm -f "$PARTIES_FILE"
else
  log "Step 1: Allocating $NUM_PARTIES internal parties..."
fi

# Initialize output file if needed
if [ ! -f "$PARTIES_FILE" ]; then
  jq -n \
    --arg pid "$PARTICIPANT_ID" \
    --arg ns "$NAMESPACE" \
    --arg prefix "$PARTY_HINT_PREFIX" \
    --arg participant "$PARTICIPANT_JSON_API" \
    '{
      participantId: $pid,
      namespace: $ns,
      partyHintPrefix: $prefix,
      participantJsonApi: $participant,
      parties: []
    }' > "$PARTIES_FILE"
fi

for i in $(seq 0 $((NUM_PARTIES - 1))); do
  IDX=$((START_INDEX + i))
  PARTY_HINT="${PARTY_HINT_PREFIX}-${IDX}"
  EXPECTED_PARTY="${PARTY_HINT}::${NAMESPACE}"
  USER_ID="${PARTY_HINT}"
  DISPLAY_NAME="${PARTY_HINT_PREFIX} ${IDX}"

  # Check if party already exists on the participant
  EXISTING_PARTY=$(curl_check "$PARTICIPANT_JSON_API/v2/parties/party?parties=$EXPECTED_PARTY" "$TOKEN" "application/json" \
    | jq -r '.partyDetails[0].party // empty' 2>/dev/null || echo "")

  if [ -n "$EXISTING_PARTY" ] && [ "$EXISTING_PARTY" != "null" ]; then
    PARTY_ID="$EXISTING_PARTY"
    log "  [$((i+1))/$NUM_PARTIES] $PARTY_HINT already exists: ${PARTY_ID:0:50}..."
  else
    # Allocate the party on the participant
    ALLOC_RESULT=$(curl_check "$PARTICIPANT_JSON_API/v2/parties" "$TOKEN" "application/json" \
      --data-raw "$(jq -n \
        --arg hint "$PARTY_HINT" \
        --arg name "$DISPLAY_NAME" \
        '{
          partyIdHint: $hint,
          displayName: $name,
          identityProviderId: ""
        }')" ) || {
      log_error "Failed to allocate party $PARTY_HINT"
      exit 1
    }

    PARTY_ID=$(echo "$ALLOC_RESULT" | jq -r '.partyDetails.party // empty')
    if [ -z "$PARTY_ID" ]; then
      log_error "Allocate succeeded but no partyId in response for $PARTY_HINT"
      log_error "Response: $(echo "$ALLOC_RESULT" | head -c 300)"
      exit 1
    fi

    log "  [$((i+1))/$NUM_PARTIES] $PARTY_HINT allocated: ${PARTY_ID:0:50}..."
  fi

  # Append to output file
  jq --arg partyId "$PARTY_ID" \
    --arg hint "$PARTY_HINT" \
    --arg userId "$USER_ID" \
    --arg displayName "$DISPLAY_NAME" \
    --argjson idx "$IDX" \
    '.parties += [{
      index: $idx,
      partyHint: $hint,
      partyId: $partyId,
      userId: $userId,
      displayName: $displayName
    }]' "$PARTIES_FILE" > "$PARTIES_FILE.tmp" \
    && mv "$PARTIES_FILE.tmp" "$PARTIES_FILE"
done

TOTAL_PARTIES=$(jq '.parties | length' "$PARTIES_FILE")
log "  All parties allocated. Total: $TOTAL_PARTIES"

fi  # end of ONBOARD_ONLY=false block

##############################################################################
# Step 2: Create Canton users + grant rights
##############################################################################

log ""
log "Step 2: Creating Canton users and granting rights..."

TOTAL_PARTIES=$(jq '.parties | length' "$PARTIES_FILE")

for i in $(seq 0 $((TOTAL_PARTIES - 1))); do
  PARTY_USER=$(jq -r ".parties[$i].userId" "$PARTIES_FILE")
  PARTY_ID=$(jq -r ".parties[$i].partyId" "$PARTIES_FILE")

  # Grant admin user ActAs/ReadAs over this party
  curl_check "$PARTICIPANT_JSON_API/v2/users/$SHARED_SECRET_USER/rights" "$TOKEN" "application/json" \
    --data-raw "$(jq -n \
      --arg userId "$SHARED_SECRET_USER" \
      --arg party "$PARTY_ID" \
      '{
        userId: $userId,
        identityProviderId: "",
        rights: [
          {kind: {CanActAs: {value: {party: $party}}}},
          {kind: {CanReadAs: {value: {party: $party}}}}
        ]
      }')" > /dev/null 2>&1 || true

  # Check if user already exists
  USER_STATUS=$(curl_status_code "$PARTICIPANT_JSON_API/v2/users/$PARTY_USER" "$TOKEN")

  if [ "$USER_STATUS" != "200" ]; then
    # Create the user
    curl_check "$PARTICIPANT_JSON_API/v2/users" "$TOKEN" "application/json" \
      --data-raw "$(jq -n \
        --arg userId "$PARTY_USER" \
        --arg party "$PARTY_ID" \
        '{
          user: {
            id: $userId,
            isDeactivated: false,
            primaryParty: $party,
            identityProviderId: "",
            metadata: {
              resourceVersion: "",
              annotations: { username: $userId }
            }
          },
          rights: []
        }')" > /dev/null
  fi

  # Grant user ActAs/ReadAs rights
  curl_check "$PARTICIPANT_JSON_API/v2/users/$PARTY_USER/rights" "$TOKEN" "application/json" \
    --data-raw "$(jq -n \
      --arg userId "$PARTY_USER" \
      --arg party "$PARTY_ID" \
      '{
        userId: $userId,
        identityProviderId: "",
        rights: [
          {kind: {CanActAs: {value: {party: $party}}}},
          {kind: {CanReadAs: {value: {party: $party}}}}
        ]
      }')" > /dev/null 2>&1 || true

  log "  [$((i+1))/$TOTAL_PARTIES] User $PARTY_USER created with rights"
done

log "  All $TOTAL_PARTIES users created."

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Internal Party Allocation Complete!"
log "=========================================="
log ""
if [ "$ONBOARD_ONLY" = "true" ]; then
  log "Summary:"
  log "  Mode: onboard-only (no parties allocated)"
else
  log "Summary:"
  log "  New parties allocated: $NUM_PARTIES"
fi
log "  Total parties in file: $TOTAL_PARTIES"
log "  Participant: $PARTICIPANT_JSON_API"
log "  Namespace: ${NAMESPACE:0:40}..."
log "  Output file: $PARTIES_FILE"
log ""
log "Party IDs:"
jq -r '.parties[] | "  \(.partyHint): \(.partyId)"' "$PARTIES_FILE"
log ""
