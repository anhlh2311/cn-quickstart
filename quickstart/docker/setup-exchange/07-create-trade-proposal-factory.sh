#!/bin/bash
# Creates (or finds) a TradeProposalFactory contract on the app-user (Kairo) node.
#
# This script:
#   1. Queries for an existing TradeProposalFactory on app-user
#   2. Creates one via submit-and-wait if not found
#   3. Writes the contract with disclosure data to trade-proposal-factory.json
#
# Prerequisites:
#   - Quickstart localnet is running
#   - 01-setup-exchange.sh has been run (DARs uploaded)
#
# Usage: ./07-create-trade-proposal-factory.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUICKSTART_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[factory] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

TRADE_PROPOSAL_FACTORY_TEMPLATE="${TRADE_PROPOSAL_FACTORY_TEMPLATE_ID:-#kairo-dex-simple-escrow-v5:Kairo.Escrow.TradeProposalFactory:TradeProposalFactory}"
OUTPUT_FILE="$SCRIPT_DIR/trade-proposal-factory.json"

##############################################################################
# Helper Functions
##############################################################################

log() { echo "[factory] $*"; }
log_error() { echo "[factory] ERROR: $*" >&2; }

curl_check() {
  local url=$1 token=$2 content_type=${3:-application/json}
  shift 3
  local response
  response=$(curl -s -S -w "\n%{http_code}" "$url" \
    ${token:+-H "Authorization: Bearer $token"} \
    -H "Content-Type: $content_type" "$@")
  local http_code
  http_code=$(echo "$response" | tail -n1 | tr -d '\r')
  local body
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" -ne "200" ] && [ "$http_code" -ne "201" ] && [ "$http_code" -ne "204" ]; then
    log_error "Request to $url failed with HTTP $http_code"
    log_error "Response: $body"
    return 1
  fi
  echo "$body"
}

generate_shared_secret_jwt() {
  local sub="$1" aud="$2"
  local now; now=$(date +%s)
  local exp=$((now + 86400))
  b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
  local header; header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  local payload; payload=$(printf '{"sub":"%s","aud":"%s","iat":%d,"exp":%d,"iss":"unsafe-auth"}' "$sub" "$aud" "$now" "$exp" | b64url)
  local signature; signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$SHARED_SECRET" -binary | b64url)
  echo "${header}.${payload}.${signature}"
}

get_keycloak_token() {
  curl -f -s -S "$3" -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "client_id=$1" -d "client_secret=$2" -d 'grant_type=client_credentials' -d 'scope=openid' | jq -r .access_token
}

detect_auth_mode() {
  local env_local="$QUICKSTART_DIR/.env.local"
  [ -f "$env_local" ] || { log_error "quickstart/.env.local not found."; exit 1; }
  AUTH_MODE=$(grep -E '^AUTH_MODE=' "$env_local" | cut -d= -f2 | tr -d '"' | tr -d "'")
  AUTH_MODE="${AUTH_MODE:-shared-secret}"
  log "AUTH_MODE=$AUTH_MODE"
}

get_app_user_token() {
  if [ "$AUTH_MODE" = "oauth2" ]; then
    APP_USER_TOKEN=$(get_keycloak_token "$KEYCLOAK_APP_USER_CLIENT_ID" "$KEYCLOAK_APP_USER_CLIENT_SECRET" "$KEYCLOAK_APP_USER_TOKEN_URL")
  else
    APP_USER_TOKEN=$(generate_shared_secret_jwt "$SHARED_SECRET_APP_USER_USER" "$SHARED_SECRET_AUDIENCE")
  fi
  [ -n "$APP_USER_TOKEN" ] || { log_error "Failed to get app-user token"; exit 1; }
}

get_party_id() {
  curl_check "$3/v2/users/$2" "$1" "application/json" | jq -r '.user.primaryParty // empty'
}

##############################################################################
# Main
##############################################################################

log "=========================================="
log "Create TradeProposalFactory"
log "=========================================="

detect_auth_mode
get_app_user_token

# Resolve executor party
if [ "$AUTH_MODE" = "oauth2" ]; then
  APP_USER_PARTY=$(get_party_id "$APP_USER_TOKEN" "$KEYCLOAK_APP_USER_VALIDATOR_USER_ID" "$APP_USER_JSON_API")
  ADMIN_USER_ID="$KEYCLOAK_APP_USER_VALIDATOR_USER_ID"
else
  APP_USER_PARTY=$(get_party_id "$APP_USER_TOKEN" "$SHARED_SECRET_APP_USER_USER" "$APP_USER_JSON_API")
  ADMIN_USER_ID="$SHARED_SECRET_APP_USER_USER"
fi

SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$APP_USER_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

log "  Executor: ${APP_USER_PARTY:0:60}..."
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

##############################################################################
# Step 1: Query existing factory (with blob)
##############################################################################

log ""
log "Step 1: Querying existing TradeProposalFactory..."

OFFSET=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$APP_USER_TOKEN" "application/json" | jq -r '.offset')

QUERY_BODY=$(jq -n \
  --arg party "$APP_USER_PARTY" \
  --arg templateId "$TRADE_PROPOSAL_FACTORY_TEMPLATE" \
  --argjson offset "$OFFSET" \
  '{
    filter: {
      filtersByParty: {
        ($party): {
          cumulative: [{
            identifierFilter: {
              TemplateFilter: {
                value: {
                  templateId: $templateId,
                  includeCreatedEventBlob: true
                }
              }
            }
          }]
        }
      }
    },
    verbose: true,
    activeAtOffset: $offset
  }')

QUERY_RESPONSE=$(curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$APP_USER_TOKEN" "application/json" \
  --data-raw "$QUERY_BODY" 2>/dev/null) || QUERY_RESPONSE=""

FACTORY_CID=""
FACTORY_TEMPLATE_HASH=""
FACTORY_BLOB=""
FACTORY_SYNC_ID=""

if [ -n "$QUERY_RESPONSE" ]; then
  FACTORY_CID=$(echo "$QUERY_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
  ' 2>/dev/null || echo "")
  FACTORY_TEMPLATE_HASH=$(echo "$QUERY_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
  ' 2>/dev/null || echo "")
  FACTORY_BLOB=$(echo "$QUERY_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
  ' 2>/dev/null || echo "")
  FACTORY_SYNC_ID=$(echo "$QUERY_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.synchronizerId][0] // empty
  ' 2>/dev/null || echo "")
fi

##############################################################################
# Step 2: Create if not found
##############################################################################

if [ -n "$FACTORY_CID" ] && [ -n "$FACTORY_BLOB" ]; then
  log "  Factory already exists: ${FACTORY_CID:0:40}..."
else
  log "  Not found. Creating TradeProposalFactory..."

  CMD_ID="create-trade-factory-$(date +%s)-${RANDOM}"
  CREATE_BODY=$(jq -n \
    --arg templateId "$TRADE_PROPOSAL_FACTORY_TEMPLATE" \
    --arg admin "$APP_USER_PARTY" \
    --arg cmdId "$CMD_ID" \
    --arg userId "$ADMIN_USER_ID" \
    '{
      commands: {
        commands: [{
          CreateCommand: {
            templateId: $templateId,
            createArguments: {
              admin: $admin
            }
          }
        }],
        commandId: $cmdId,
        applicationId: $userId,
        actAs: [$admin],
        readAs: [$admin],
        deduplicationPeriod: { Empty: {} },
        submissionId: $cmdId,
        disclosedContracts: [],
        domainId: "",
        packageIdSelectionPreference: []
      }
    }')

  CREATE_RESULT=$(curl_check "$APP_USER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$APP_USER_TOKEN" "application/json" \
    --data-raw "$CREATE_BODY") || {
    log_error "Failed to create TradeProposalFactory"
    exit 1
  }

  FACTORY_CID=$(echo "$CREATE_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("TradeProposalFactory")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$FACTORY_CID" ]; then
    log_error "Could not extract factory CID from creation result"
    log_error "Response: $(echo "$CREATE_RESULT" | head -c 500)"
    exit 1
  fi

  log "  Created: ${FACTORY_CID:0:40}..."

  # Re-query to get blob
  log "  Re-querying for disclosure blob..."
  sleep 2
  OFFSET=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$APP_USER_TOKEN" "application/json" | jq -r '.offset')

  QUERY_BODY2=$(jq -n \
    --arg party "$APP_USER_PARTY" \
    --arg templateId "$TRADE_PROPOSAL_FACTORY_TEMPLATE" \
    --argjson offset "$OFFSET" \
    '{
      filter: {
        filtersByParty: {
          ($party): {
            cumulative: [{
              identifierFilter: {
                TemplateFilter: {
                  value: {
                    templateId: $templateId,
                    includeCreatedEventBlob: true
                  }
                }
              }
            }]
          }
        }
      },
      verbose: true,
      activeAtOffset: $offset
    }')

  REQUERY_RESPONSE=$(curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$APP_USER_TOKEN" "application/json" \
    --data-raw "$QUERY_BODY2" 2>/dev/null) || REQUERY_RESPONSE=""

  if [ -n "$REQUERY_RESPONSE" ]; then
    FACTORY_TEMPLATE_HASH=$(echo "$REQUERY_RESPONSE" | jq -r '
      [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
    ' 2>/dev/null || echo "")
    FACTORY_BLOB=$(echo "$REQUERY_RESPONSE" | jq -r '
      [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
    ' 2>/dev/null || echo "")
    FACTORY_SYNC_ID=$(echo "$REQUERY_RESPONSE" | jq -r '
      [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.synchronizerId][0] // empty
    ' 2>/dev/null || echo "")
  fi
fi

if [ -z "$FACTORY_BLOB" ]; then
  log_error "Could not get disclosure blob for the factory"
  exit 1
fi

##############################################################################
# Step 3: Write output
##############################################################################

log ""
log "Step 2: Writing trade-proposal-factory.json..."

jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg contractId "$FACTORY_CID" \
  --arg templateId "$FACTORY_TEMPLATE_HASH" \
  --arg createdEventBlob "$FACTORY_BLOB" \
  --arg synchronizerId "$FACTORY_SYNC_ID" \
  --arg executorPartyId "$APP_USER_PARTY" \
  '{
    generatedAt: $generatedAt,
    tradeProposalFactory: {
      contractId: $contractId,
      templateId: $templateId,
      createdEventBlob: $createdEventBlob,
      synchronizerId: $synchronizerId
    },
    executorPartyId: $executorPartyId
  }' > "$OUTPUT_FILE"

log "  Written to: $OUTPUT_FILE"

log ""
log "=========================================="
log "TradeProposalFactory Ready!"
log "=========================================="
log ""
log "  Contract ID: ${FACTORY_CID:0:60}..."
log "  Executor: ${APP_USER_PARTY:0:60}..."
log "  Output: $OUTPUT_FILE"
log ""
