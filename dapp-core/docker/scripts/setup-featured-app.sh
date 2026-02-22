#!/bin/bash
# Create FeaturedAppRight + BatchedMarkersProxy contracts for the app-provider party.
# Prerequisites: dapp-core localnet must be running (make start)
#
# Usage: ./setup-featured-app.sh
#        make setup-featured-app

set -eo pipefail

##############################################################################
# Dependency checks
##############################################################################

for cmd in curl jq openssl; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "[setup-featured-app] ERROR: Required tool '$cmd' not found." >&2
    exit 1
  fi
done

##############################################################################
# Configuration (override via environment variables)
##############################################################################

APP_PROVIDER_JSON_API="${APP_PROVIDER_JSON_API:-http://localhost:3975}"
SV_JSON_API="${SV_JSON_API:-http://localhost:4975}"
APP_PROVIDER_VALIDATOR_API="${APP_PROVIDER_VALIDATOR_API:-http://localhost:3903}"

SHARED_SECRET="${SHARED_SECRET:-unsafe}"
SHARED_SECRET_AUDIENCE="${SHARED_SECRET_AUDIENCE:-https://canton.network.global}"
APP_PROVIDER_USER="${APP_PROVIDER_USER:-ledger-api-user}"
SV_USER="${SV_USER:-ledger-api-user}"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[setup-featured-app] $*"
}

log_error() {
  echo "[setup-featured-app] ERROR: $*" >&2
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

get_party_id() {
  local token=$1
  local user_id=$2
  local participant=$3
  curl_check "$participant/v2/users/$user_id" "$token" "application/json" | jq -r .user.primaryParty
}

get_dso_party_id() {
  local token=$1
  local validator=$2
  curl_check "$validator/api/validator/v0/scan-proxy/dso-party-id" "$token" "application/json" | jq -r .dso_party_id
}

##############################################################################
# Step 1: Generate tokens & resolve party IDs
##############################################################################

log "=========================================="
log "Setup FeaturedAppRight + BatchedMarkersProxy"
log "for app-provider"
log "=========================================="

log ""
log "Step 1: Generating tokens and resolving party IDs..."

APP_PROVIDER_TOKEN=$(generate_shared_secret_jwt "$APP_PROVIDER_USER" "$SHARED_SECRET_AUDIENCE")
SV_TOKEN=$(generate_shared_secret_jwt "$SV_USER" "$SHARED_SECRET_AUDIENCE")

if [ -z "$APP_PROVIDER_TOKEN" ] || [ -z "$SV_TOKEN" ]; then
  log_error "Failed to generate auth tokens"
  exit 1
fi
log "  Auth tokens generated"

APP_PROVIDER_PARTY=$(get_party_id "$APP_PROVIDER_TOKEN" "$APP_PROVIDER_USER" "$APP_PROVIDER_JSON_API")
DSO_PARTY=$(get_dso_party_id "$APP_PROVIDER_TOKEN" "$APP_PROVIDER_VALIDATOR_API")

if [ -z "$APP_PROVIDER_PARTY" ] || [ "$APP_PROVIDER_PARTY" = "null" ]; then
  log_error "Could not resolve APP_PROVIDER_PARTY"
  exit 1
fi
if [ -z "$DSO_PARTY" ] || [ "$DSO_PARTY" = "null" ]; then
  log_error "Could not resolve DSO_PARTY"
  exit 1
fi

log "  APP_PROVIDER_PARTY=$APP_PROVIDER_PARTY"
log "  DSO_PARTY=$DSO_PARTY"

##############################################################################
# Step 2: Create FeaturedAppRight for app-provider (idempotent)
##############################################################################

log ""
log "Step 2: FeaturedAppRight for app-provider..."

APP_PROVIDER_LEDGER_END=$(curl_check "$APP_PROVIDER_JSON_API/v2/state/ledger-end" "$APP_PROVIDER_TOKEN" "application/json" | jq -r '.offset')

FEATURED_APP_RIGHT_QUERY=$(cat <<FARQEOF
{
  "filter":{
    "filtersByParty":{
      "$APP_PROVIDER_PARTY":{
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
  "activeAtOffset":"$APP_PROVIDER_LEDGER_END"
}
FARQEOF
)

FEATURED_APP_RIGHT_CID=""
FAR_RESPONSE=$(curl_check "$APP_PROVIDER_JSON_API/v2/state/active-contracts" "$APP_PROVIDER_TOKEN" "application/json" \
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
        "provider": "$APP_PROVIDER_PARTY"
      }
    }
  }],
  "workflowId": "setup-featured-app-provider",
  "applicationId": "$APP_PROVIDER_USER",
  "commandId": "$FEATURE_CMD_ID",
  "deduplicationPeriod": {"Empty": {}},
  "actAs": ["$APP_PROVIDER_PARTY"],
  "readAs": [],
  "submissionId": "setup-featured-app-provider-$FEATURE_CMD_ID",
  "disclosedContracts": [$DISCLOSED_CONTRACT],
  "domainId": "",
  "packageIdSelectionPreference": []
}
CMDEOF
)

    FEATURE_APP_WRAPPED=$(jq -n --argjson body "$FEATURE_APP_BODY" '{"commands": $body}')
    FEATURE_APP_RESULT=$(curl_check "$APP_PROVIDER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$APP_PROVIDER_TOKEN" "application/json" \
      --data-raw "$FEATURE_APP_WRAPPED") || {
      log_error "Failed to create FeaturedAppRight. This may happen if:"
      log_error "  - The localnet is not running in DevNet mode"
      log_error "  - AmuletRules contract has changed since we queried it"
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
# Step 3: Create BatchedMarkersProxy for app-provider (idempotent)
##############################################################################

log ""
log "Step 3: BatchedMarkersProxy for app-provider..."

# Re-fetch ledger end in case it changed after step 2
APP_PROVIDER_LEDGER_END=$(curl_check "$APP_PROVIDER_JSON_API/v2/state/ledger-end" "$APP_PROVIDER_TOKEN" "application/json" | jq -r '.offset')

BATCHED_PROXY_QUERY=$(cat <<BPQEOF
{
  "filter":{
    "filtersByParty":{
      "$APP_PROVIDER_PARTY":{
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
  "activeAtOffset":"$APP_PROVIDER_LEDGER_END"
}
BPQEOF
)

BATCHED_MARKERS_PROXY_CID=""
BMP_RESPONSE=$(curl_check "$APP_PROVIDER_JSON_API/v2/state/active-contracts" "$APP_PROVIDER_TOKEN" "application/json" \
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
        "provider": "$APP_PROVIDER_PARTY",
        "dso": "$DSO_PARTY"
      }
    }
  }],
  "workflowId": "setup-batched-markers-proxy-provider",
  "applicationId": "$APP_PROVIDER_USER",
  "commandId": "$BATCHED_PROXY_CMD_ID",
  "deduplicationPeriod": {"Empty": {}},
  "actAs": ["$APP_PROVIDER_PARTY"],
  "readAs": [],
  "submissionId": "setup-batched-markers-proxy-provider-$BATCHED_PROXY_CMD_ID",
  "disclosedContracts": [],
  "domainId": "",
  "packageIdSelectionPreference": []
}
BPEOF
)

  BATCHED_PROXY_WRAPPED=$(jq -n --argjson body "$BATCHED_PROXY_BODY" '{"commands": $body}')
  BATCHED_PROXY_RESULT=$(curl_check "$APP_PROVIDER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$APP_PROVIDER_TOKEN" "application/json" \
    --data-raw "$BATCHED_PROXY_WRAPPED") || {
    log_error "Failed to create BatchedMarkersProxy."
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
# Done
##############################################################################

log ""
log "=========================================="
log "Setup complete!"
log "=========================================="
log ""
log "Summary:"
if [ -n "$FEATURED_APP_RIGHT_CID" ]; then
  log "  FeaturedAppRight for app-provider: $FEATURED_APP_RIGHT_CID"
else
  log "  FeaturedAppRight: check ledger for contract status"
fi
if [ -n "$BATCHED_MARKERS_PROXY_CID" ]; then
  log "  BatchedMarkersProxy for app-provider: $BATCHED_MARKERS_PROXY_CID"
else
  log "  BatchedMarkersProxy: check ledger for contract status"
fi
