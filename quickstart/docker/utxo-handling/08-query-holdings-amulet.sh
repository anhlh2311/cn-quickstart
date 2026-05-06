#!/bin/bash
# Queries all active Amulet (CC) contracts for each user wallet and writes
# the results to user-wallet-holdings-amulet.json.
#
# Template: #splice-amulet:Splice.Amulet:Amulet
#
# Note: Amulet amounts use ExpiringAmount, so the field is
# .createArgument.amount.initialAmount (not a flat .amount).
#
# Prerequisites:
#   - quickstart must be running (DevNet mode)
#   - 01-generate-user-wallet.sh must have been run
#   - 03-request-faucet-amulet.sh must have been run (holdings exist on ledger)
#
# Usage: ./08-query-holdings-amulet.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load configuration
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

PARTICIPANT_JSON_API="${PARTICIPANT_JSON_API:-http://localhost:2975}"

# Auth configuration
SHARED_SECRET="${SHARED_SECRET:-unsafe}"
SHARED_SECRET_AUDIENCE="${SHARED_SECRET_AUDIENCE:-https://canton.network.global}"
SHARED_SECRET_USER="${SHARED_SECRET_USER:-ledger-api-user}"

# SV participant (for fetching AmuletRules / OpenMiningRound)
SV_JSON_API="${SV_JSON_API:-http://localhost:4975}"
SHARED_SECRET_SV_USER="${SHARED_SECRET_SV_USER:-ledger-api-user}"
PARTICIPANT_VALIDATOR_API="${PARTICIPANT_VALIDATOR_API:-http://localhost:2903}"

# User wallet keypairs
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"
if [ ! -f "$KEYPAIRS_FILE" ]; then
  echo "[query-amulet] ERROR: User wallet keypairs not found: $KEYPAIRS_FILE" >&2
  exit 1
fi

NUM_WALLETS=$(jq '.wallets | length' "$KEYPAIRS_FILE")

# Template ID for Amulet
AMULET_TEMPLATE="#splice-amulet:Splice.Amulet:Amulet"

# Output file
OUTPUT_FILE="$SCRIPT_DIR/user-wallet-holdings-amulet.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[query-amulet] $*"
}

log_error() {
  echo "[query-amulet] ERROR: $*" >&2
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

# Query active contracts for a given party and template
query_active_contracts() {
  local party="$1"
  local template_id="$2"

  local ledger_end
  ledger_end=$(curl_check "$PARTICIPANT_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

  local query_body
  query_body=$(jq -n \
    --arg party "$party" \
    --arg templateId "$template_id" \
    --arg offset "$ledger_end" \
    '{
      filter: {
        filtersByParty: {
          ($party): {
            cumulative: [{
              identifierFilter: {
                TemplateFilter: {
                  value: {
                    templateId: $templateId,
                    includeCreatedEventBlob: false
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

  curl_check "$PARTICIPANT_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
}

##############################################################################
# Main
##############################################################################

log "=========================================="
log "Query Amulet (CC) Holdings for User Wallets"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Template: $AMULET_TEMPLATE"
log ""

CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

# Resolve DSO party ID
DSO_PARTY=$(curl_check "$PARTICIPANT_VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" "$CANTON_TOKEN" "application/json" \
  | jq -r '.dso_party_id // empty')

if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party ID"
  exit 1
fi
log "  DSO party: ${DSO_PARTY:0:50}..."

# Build the result JSON
PARTY_HINT_VALUE=$(jq -r '.partyHint' "$KEYPAIRS_FILE")
REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg partyHint "$PARTY_HINT_VALUE" \
  --arg dsoParty "$DSO_PARTY" \
  --arg tokenId "Amulet" \
  --arg templateId "$AMULET_TEMPLATE" \
  '{
    generatedAt: $generatedAt,
    partyHint: $partyHint,
    dsoParty: $dsoParty,
    tokenId: $tokenId,
    templateId: $templateId,
    totalHoldings: 0,
    wallets: []
  }')

TOTAL_HOLDINGS=0

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_NAME=$(jq -r ".wallets[$i].userId" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".wallets[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".wallets[$i].userId" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_NAME..."

  HOLDINGS_RESPONSE=$(query_active_contracts "$WALLET_PARTY" "$AMULET_TEMPLATE")

  # Extract holdings: contractId and amount
  # Note: field is "createArgument" (singular). Amulet uses ExpiringAmount: .createArgument.amount.initialAmount
  HOLDINGS_DATA=$(echo "$HOLDINGS_RESPONSE" | jq -c '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
     | { contractId: .contractId, amount: (.createArgument.amount.initialAmount // .createArgument.amount // "0" | tonumber) }]
  ' 2>/dev/null || echo "[]")

  HOLDING_COUNT=$(echo "$HOLDINGS_DATA" | jq 'length')
  WALLET_TOTAL=$(echo "$HOLDINGS_DATA" | jq '[.[].amount | tonumber] | add // 0')
  TOTAL_HOLDINGS=$((TOTAL_HOLDINGS + HOLDING_COUNT))

  log "    Holdings: $HOLDING_COUNT (total amount: $WALLET_TOTAL CC)"

  REPORT_JSON=$(echo "$REPORT_JSON" | jq \
    --arg partyId "$WALLET_PARTY" \
    --arg userId "$WALLET_USER" \
    --argjson holdings "$HOLDINGS_DATA" \
    --argjson totalAmount "$WALLET_TOTAL" \
    '.wallets += [{
      partyId: $partyId,
      userId: $userId,
      holdings: $holdings,
      totalAmount: $totalAmount
    }]')
done

# Update totalHoldings
REPORT_JSON=$(echo "$REPORT_JSON" | jq --argjson total "$TOTAL_HOLDINGS" '.totalHoldings = $total')

echo "$REPORT_JSON" | jq '.' > "$OUTPUT_FILE"

GRAND_TOTAL=$(echo "$REPORT_JSON" | jq '[.wallets[].totalAmount] | add // 0')

log ""
log "=========================================="
log "Amulet Holdings Query Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets queried: $NUM_WALLETS"
log "  Total holdings: $TOTAL_HOLDINGS"
log "  Total CC: $GRAND_TOTAL"
log "  Output file: $OUTPUT_FILE"
log ""
