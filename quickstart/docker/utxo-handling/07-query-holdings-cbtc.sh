#!/bin/bash
# Queries all active CBTC Holding contracts for each user wallet and writes
# the results to user-wallet-holdings-cbtc.json.
#
# Template: #utility-registry-holding-v0:Utility.Registry.Holding.V0.Holding:Holding
#
# Prerequisites:
#   - quickstart must be running
#   - 01-generate-user-wallet.sh must have been run
#   - 02-request-minting-cbtc.sh must have been run (holdings exist on ledger)
#
# Usage: ./07-query-holdings-cbtc.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-exchange" && pwd)"

# Load shared configuration
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[query-cbtc] ERROR: $SETUP_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# Load CBTC config
CBTC_CONFIG_FILE="$SETUP_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[query-cbtc] ERROR: CBTC config not found: $CBTC_CONFIG_FILE" >&2
  exit 1
fi
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")

# Load CBTC-NETWORK keypair (for the network party ID)
CBTC_KEYPAIR_FILE="$SETUP_DIR/cbtc-network-keypair.json"
if [ ! -f "$CBTC_KEYPAIR_FILE" ]; then
  echo "[query-cbtc] ERROR: CBTC-NETWORK keypair not found: $CBTC_KEYPAIR_FILE" >&2
  exit 1
fi
CBTC_NETWORK_PARTY=$(jq -r '.partyId' "$CBTC_KEYPAIR_FILE")

# User wallet keypairs
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"
if [ ! -f "$KEYPAIRS_FILE" ]; then
  echo "[query-cbtc] ERROR: User wallet keypairs not found: $KEYPAIRS_FILE" >&2
  exit 1
fi

NUM_WALLETS=$(jq '.wallets | length' "$KEYPAIRS_FILE")

# Template ID for utility Holding
HOLDING_TEMPLATE="#utility-registry-holding-v0:Utility.Registry.Holding.V0.Holding:Holding"

# Output file
OUTPUT_FILE="$SCRIPT_DIR/user-wallet-holdings-cbtc.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[query-cbtc] $*"
}

log_error() {
  echo "[query-cbtc] ERROR: $*" >&2
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
  ledger_end=$(curl_check "$APP_USER_JSON_API/v2/state/ledger-end" "$CANTON_TOKEN" "application/json" | jq -r '.offset')

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

  curl_check "$APP_USER_JSON_API/v2/state/active-contracts" "$CANTON_TOKEN" "application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
}

##############################################################################
# Main
##############################################################################

log "=========================================="
log "Query CBTC Holdings for User Wallets"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Template: $HOLDING_TEMPLATE"
log "  CBTC-NETWORK: ${CBTC_NETWORK_PARTY:0:50}..."
log ""

CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

# Build the result JSON
PARTY_HINT_VALUE=$(jq -r '.partyHint' "$KEYPAIRS_FILE")
REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg partyHint "$PARTY_HINT_VALUE" \
  --arg cbtcNetworkParty "$CBTC_NETWORK_PARTY" \
  --arg tokenId "$CBTC_TOKEN_ID" \
  --arg templateId "$HOLDING_TEMPLATE" \
  '{
    generatedAt: $generatedAt,
    partyHint: $partyHint,
    cbtcNetworkParty: $cbtcNetworkParty,
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

  HOLDINGS_RESPONSE=$(query_active_contracts "$WALLET_PARTY" "$HOLDING_TEMPLATE")

  # Extract holdings: contractId and amount
  # Note: field is "createArgument" (singular), amount is a string like "267.0000000000"
  HOLDINGS_DATA=$(echo "$HOLDINGS_RESPONSE" | jq -c '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
     | { contractId: .contractId, amount: (.createArgument.amount // "0" | tonumber) }]
  ' 2>/dev/null || echo "[]")

  HOLDING_COUNT=$(echo "$HOLDINGS_DATA" | jq 'length')
  WALLET_TOTAL=$(echo "$HOLDINGS_DATA" | jq '[.[].amount | tonumber] | add // 0')
  TOTAL_HOLDINGS=$((TOTAL_HOLDINGS + HOLDING_COUNT))

  log "    Holdings: $HOLDING_COUNT (total amount: $WALLET_TOTAL)"

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
log "CBTC Holdings Query Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets queried: $NUM_WALLETS"
log "  Total holdings: $TOTAL_HOLDINGS"
log "  Total CBTC: $GRAND_TOTAL"
log "  Output file: $OUTPUT_FILE"
log ""
