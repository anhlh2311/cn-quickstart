#!/bin/bash
# End-to-end test for POST /trading-partner/trade-request
#
# This script simulates what a trading partner would do:
#   1. Fetch TradeProposalFactory disclosure from Kairo's partner API
#   2. Fetch Amulet allocation factory from validator scan-proxy
#   3. Get trader's Amulet holding from the trading-partner node
#   4. Create TradeProposal on the trading-partner node (submit-and-wait)
#   5. Query disclosures for created contracts
#   6. Call POST /trading-partner/trade-request on the exchange backend
#   7. Verify result
#
# Prerequisites:
#   - Quickstart localnet running (DevNet)
#   - 01-setup-exchange.sh, 03-register-cbtc-token.sh, 04-register-amulet-token.sh run
#   - 05-setup-liquidity-provider.sh run (LP with CBTC holdings)
#   - 06-fund-liquidity-provider.sh run (LP funded)
#   - 07-create-trade-proposal-factory.sh run (factory exists)
#   - Exchange backend running on port 3003
#   - Trading partner node running (port 1975)
#   - A trader party onboarded on trading-partner with Amulet holdings
#
# Environment variables:
#   TRADER_PARTY_ID           — Trader's party ID (default: from internal-trader.json)
#   TRADER_USER_ID            — Trader's Canton user ID (default: from internal-trader.json)
#   INPUT_AMOUNT              — Amount of Amulet to swap (default: 10)
#   PARTNER_API_KEY           — Partner API key for exchange backend (default: from partner-api-key.json)
#   EXPECTED_RECEIVER_AMOUNT  — Expected output amount (default: calculated from GET /partner-api/token-prices)
#
# Usage:
#   ./test-trade-request.sh
#   INPUT_AMOUNT=50 ./test-trade-request.sh

set -eo pipefail

RUN_ID=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUICKSTART_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INTERNAL_PARTIES_DIR="$SCRIPT_DIR/../setup-internal-parties"
SETUP_EXCHANGE_DIR="$SCRIPT_DIR/../setup-exchange"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[test] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
if [ ! -f "$SETUP_EXCHANGE_DIR/.env" ]; then
  echo "[test] ERROR: $SETUP_EXCHANGE_DIR/.env not found. Run setup-exchange scripts first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
# shellcheck disable=SC1091
source "$SETUP_EXCHANGE_DIR/.env"

# Trading partner node (may be overridden by .env)
TRADING_PARTNER_JSON_API="${TRADING_PARTNER_JSON_API:-http://localhost:1975}"
TRADING_PARTNER_VALIDATOR_API="${TRADING_PARTNER_VALIDATOR_API:-http://localhost:1903}"
# App provider (exchange) node
APP_PROVIDER_JSON_API="${APP_PROVIDER_JSON_API:-http://localhost:3975}"

# Load trader party — prefer internal-trader.json (local), fall back to setup-internal-parties
if [ -z "$TRADER_PARTY_ID" ]; then
  for _parties_file in \
      "$SCRIPT_DIR/internal-trader.json" \
      "$INTERNAL_PARTIES_DIR/internal-parties.json"; do
    if [ -f "$_parties_file" ]; then
      TRADER_PARTY_ID=$(jq -r '.parties[0].partyId // empty' "$_parties_file" 2>/dev/null || echo "")
      TRADER_USER_ID=$(jq -r '.parties[0].userId // empty' "$_parties_file" 2>/dev/null || echo "")
      [ -n "$TRADER_PARTY_ID" ] && break
    fi
  done
fi
TRADER_USER_ID="${TRADER_USER_ID:-trading-partner-0}"

# Load partner API key — check partner-api-key.json first, then liquidity-provider.json
if [ -z "$PARTNER_API_KEY" ]; then
  PARTNER_KEY_FILE="$SCRIPT_DIR/partner-api-key.json"
  if [ -f "$PARTNER_KEY_FILE" ]; then
    PARTNER_API_KEY=$(jq -r '.partnerApiKey.rawKey // empty' "$PARTNER_KEY_FILE" 2>/dev/null || echo "")
  fi
fi
if [ -z "$PARTNER_API_KEY" ]; then
  LP_CONFIG="$SETUP_EXCHANGE_DIR/liquidity-provider.json"
  if [ -f "$LP_CONFIG" ]; then
    PARTNER_API_KEY=$(jq -r '.apiKey // empty' "$LP_CONFIG" 2>/dev/null || echo "")
  fi
fi

# Load executor and LP parties from backend .env (EXCHANGE_BACKEND_DIR comes from setup-exchange/.env)
BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
EXECUTOR_PARTY=""
LP_PARTY=""
if [ -f "$BACKEND_ENV" ]; then
  EXECUTOR_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)
  LP_PARTY=$(grep -E '^LIQUIDITY_PROVIDER_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)
fi

# Fall back to liquidity-provider.json
if [ -z "$LP_PARTY" ]; then
  LP_JSON="$SETUP_EXCHANGE_DIR/liquidity-provider.json"
  if [ -f "$LP_JSON" ]; then
    LP_PARTY=$(jq -r '.liquidityProvider.lpPartyId // empty' "$LP_JSON" 2>/dev/null || echo "")
  fi
fi

# Load DSO party from trading-partner-config.json (fully qualified ID needed for instrumentId.admin)
TP_CONFIG="$SCRIPT_DIR/trading-partner-config.json"
DSO_PARTY=""
if [ -f "$TP_CONFIG" ]; then
  DSO_PARTY=$(jq -r '.dsoParty // empty' "$TP_CONFIG" 2>/dev/null || echo "")
fi

# Load CBTC-NETWORK party from cbtc-factories.json if available.
# If missing, it will be fetched from the exchange backend in Step 2.
CBTC_FACTORIES_JSON="$SETUP_EXCHANGE_DIR/cbtc-factories.json"
CBTC_NETWORK_PARTY=""
if [ -f "$CBTC_FACTORIES_JSON" ]; then
  CBTC_NETWORK_PARTY=$(jq -r '.cbtcNetworkParty // empty' "$CBTC_FACTORIES_JSON" 2>/dev/null || echo "")
fi

# Load trade config from trade-request-config.json if available
TRADE_CONFIG_FILE="$SCRIPT_DIR/trade-request-config.json"
if [ -f "$TRADE_CONFIG_FILE" ]; then
  [ -z "$PARTNER_API_KEY" ] && PARTNER_API_KEY=$(jq -r '.partnerApiKey // empty' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "")
  [ -z "$TRADER_PARTY_ID" ] && TRADER_PARTY_ID=$(jq -r '.traderPartyId // empty' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "")
  [ -z "$TRADER_USER_ID" ] && TRADER_USER_ID=$(jq -r '.traderUserId // empty' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "")
fi

INPUT_AMOUNT="${INPUT_AMOUNT:-$([ -f "$TRADE_CONFIG_FILE" ] && jq -r '.tradeRequest.inputAmount // "10"' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "10")}"
INPUT_TOKEN_TYPE="${INPUT_TOKEN_TYPE:-$([ -f "$TRADE_CONFIG_FILE" ] && jq -r '.tradeRequest.inputTokenType // "Amulet"' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "Amulet")}"
OUTPUT_TOKEN_TYPE="${OUTPUT_TOKEN_TYPE:-$([ -f "$TRADE_CONFIG_FILE" ] && jq -r '.tradeRequest.outputTokenType // "CBTC"' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "CBTC")}"

# Templates
AMULET_HOLDING_TEMPLATE="#splice-amulet:Splice.Amulet:Amulet"
CBTC_HOLDING_TEMPLATE="#utility-registry-holding-v0:Utility.Registry.Holding.V0.Holding:Holding"
TRADE_PROPOSAL_FACTORY_TEMPLATE="${TRADE_PROPOSAL_FACTORY_TEMPLATE_ID:-#kairo-dex-simple-escrow-v5:Kairo.Escrow.TradeProposalFactory:TradeProposalFactory}"
TRADE_PROPOSAL_TEMPLATE="${TRADE_PROPOSAL_TEMPLATE_ID:-#kairo-dex-simple-escrow-v5:Kairo.Escrow.TradeProposal:TradeProposal}"
TRADE_ESCROW_TEMPLATE="${TRADE_ESCROW_TEMPLATE_ID:-#kairo-dex-simple-escrow-v5:Kairo.Escrow.TradeEscrow:TradeEscrow}"

##############################################################################
# Helper Functions
##############################################################################

# Source shared auth helpers
# shellcheck disable=SC1091
source "$SCRIPT_DIR/auth.sh"

log() { echo "[test] $*"; }
log_error() { echo "[test] ERROR: $*" >&2; }

confirm_step() {
  local step_name="$1"
  echo ""
  echo "[test] ------------------------------------------"
  echo "[test] Step complete: $step_name"
  echo "[test] ------------------------------------------"
  if [ -t 0 ]; then
    printf "[test] Press ENTER to continue, or Ctrl+C to abort: "
    read -r _
  fi
}

curl_check() {
  local url=$1 token=$2 content_type=${3:-application/json}
  local curl_args=(-s -S -w "\n%{http_code}" "$url")
  if [ -n "$token" ]; then
    curl_args+=(-H "Authorization: Bearer $token")
  fi
  curl_args+=(-H "Content-Type: $content_type")
  # Extra curl args (e.g. --data-raw) start at position 4, after url/token/content_type
  curl_args+=("${@:4}")
  local response
  response=$(curl "${curl_args[@]}")
  local http_code; http_code=$(echo "$response" | tail -n1 | tr -d '\r')
  local body; body=$(echo "$response" | sed '$d')
  if [ "$http_code" -ne "200" ] && [ "$http_code" -ne "201" ] && [ "$http_code" -ne "204" ]; then
    log_error "Request to $url failed with HTTP $http_code"
    log_error "Response: $body"
    return 1
  fi
  echo "$body"
}

query_active_contracts() {
  local json_api="$1" token="$2" party="$3" template_id="$4" include_blob="${5:-false}"
  local offset; offset=$(curl_check "$json_api/v2/state/ledger-end" "$token" | jq -r '.offset')
  local body; body=$(jq -n \
    --arg party "$party" --arg templateId "$template_id" \
    --argjson includeBlob "$include_blob" --argjson offset "$offset" \
    '{
      filter: { filtersByParty: { ($party): { cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId: $templateId, includeCreatedEventBlob: $includeBlob } } } }] } } },
      verbose: false, activeAtOffset: $offset
    }')
  curl_check "$json_api/v2/state/active-contracts" "$token" "application/json" --data-raw "$body" 2>/dev/null || echo ""
}

# Fetch a contract's blob via /v2/events/events-by-contract-id.
# This endpoint (unlike /v2/state/active-contracts) actually returns createdEventBlob.
# Returns a JSON object {contractId, templateId, createdEventBlob, synchronizerId}
# or empty string if not found / no blob.
get_blob_by_contract_id() {
  local json_api="$1" token="$2" contract_id="$3"
  local body; body=$(printf \
    '{"contractId":"%s","eventFormat":{"filtersForAnyParty":{"cumulative":[{"identifierFilter":{"WildcardFilter":{"value":{"includeCreatedEventBlob":true}}}}]},"verbose":false}}' \
    "$contract_id")
  local result; result=$(curl -s "$json_api/v2/events/events-by-contract-id" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    --data-raw "$body" 2>/dev/null || echo "{}")
  local blob; blob=$(echo "$result" | jq -r '.created.createdEvent.createdEventBlob // ""' 2>/dev/null)
  if [ -n "$blob" ] && [ "$blob" != "null" ] && [ "$blob" != "" ]; then
    echo "$result" | jq -c '{
      contractId: .created.createdEvent.contractId,
      templateId: .created.createdEvent.templateId,
      createdEventBlob: .created.createdEvent.createdEventBlob,
      synchronizerId: (.created.synchronizerId // null)
    }' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

##############################################################################
# Pre-flight
##############################################################################

log "=========================================="
log "Test: POST /trading-partner/trade-request"
log "=========================================="
log "  Trader:    $TRADER_PARTY_ID"
log "  Executor:  ${EXECUTOR_PARTY:0:50}..."
log "  LP:        ${LP_PARTY:0:50}..."
log "  DSO:       ${DSO_PARTY:0:50}..."
log "  Input:     $INPUT_AMOUNT $INPUT_TOKEN_TYPE → $OUTPUT_TOKEN_TYPE"
log "  Backend:   $BACKEND_URL"
log "  Auth mode: ${AUTH_MODE:-shared-secret} (AP: ${AP_AUTH_MODE:-shared-secret})"
log ""

[ -n "$TRADER_PARTY_ID" ] || { log_error "TRADER_PARTY_ID not set"; exit 1; }
[ -n "$EXECUTOR_PARTY" ] || { log_error "EXECUTOR_PARTY not set"; exit 1; }
[ -n "$LP_PARTY" ] || { log_error "LP_PARTY not set — run 05-setup-liquidity-provider.sh first"; exit 1; }
[ -n "$PARTNER_API_KEY" ] || { log_error "PARTNER_API_KEY not set"; exit 1; }
[ -n "$DSO_PARTY" ] || { log_error "DSO_PARTY not set — ensure trading-partner-config.json exists (run 01-setup-trading-partner.sh)"; exit 1; }

# Tokens for trading-partner node
TP_TOKEN=$(get_participant_token)
# Token for the trader user specifically
TRADER_TOKEN=$(get_user_token "$TRADER_USER_ID")

SYNCHRONIZER_ID=$(curl_check "$TRADING_PARTNER_JSON_API/v2/state/connected-synchronizers" "$TP_TOKEN" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

##############################################################################
# Step 1: Fetch TradeProposalFactory disclosure from partner API
##############################################################################

log ""
log "Step 1: Fetching TradeProposalFactory from partner API..."

FACTORY_RESPONSE=$(curl_check "$BACKEND_URL/partner-api/trade-proposal-factory" "" "application/json" \
  -H "x-api-key: $PARTNER_API_KEY") || {
  log_error "Failed to fetch TradeProposalFactory. Is the backend running? Is the factory created?"
  exit 1
}

FACTORY_CID=$(echo "$FACTORY_RESPONSE" | jq -r '.data.contractId // .contractId // empty')
FACTORY_DISCLOSED=$(echo "$FACTORY_RESPONSE" | jq -c '{
  contractId: (.data.contractId // .contractId),
  templateId: (.data.templateId // .templateId),
  createdEventBlob: (.data.createdEventBlob // .createdEventBlob),
  synchronizerId: (.data.synchronizerId // .synchronizerId)
}')

FACTORY_TEMPLATE=$(echo "$FACTORY_RESPONSE" | jq -r '.data.templateId // .templateId // "?"')
FACTORY_BLOB_LEN=$(echo "$FACTORY_RESPONSE" | jq -r '(.data.createdEventBlob // .createdEventBlob // "") | length')
FACTORY_SYNC_ID=$(echo "$FACTORY_RESPONSE" | jq -r '.data.synchronizerId // .synchronizerId // "?"')
log "  Factory CID:          ${FACTORY_CID:0:50}..."
log "  Template:             $FACTORY_TEMPLATE"
log "  createdEventBlob len: $FACTORY_BLOB_LEN chars"
log "  SynchronizerId:       ${FACTORY_SYNC_ID:0:50}..."
confirm_step "Step 1 — TradeProposalFactory fetched"

##############################################################################
# Step 2: Fetch input token allocation factory
##############################################################################

log ""
log "Step 2: Fetching $INPUT_TOKEN_TYPE allocation factory..."

if [ "$INPUT_TOKEN_TYPE" = "Amulet" ]; then
  AMULET_FACTORY_RESPONSE=$(curl_check "$TRADING_PARTNER_VALIDATOR_API/api/validator/v0/scan-proxy/registry/allocation-instruction/v1/allocation-factory" \
    "$TP_TOKEN" "application/json" \
    --data-raw '{"choiceArguments":{},"excludeDebugFields":true}') || {
    log_error "Failed to fetch Amulet allocation factory from scan-proxy"
    exit 1
  }
  INPUT_FACTORY_CID=$(echo "$AMULET_FACTORY_RESPONSE" | jq -r '.factoryId // empty')
  INPUT_CONTEXT_DATA=$(echo "$AMULET_FACTORY_RESPONSE" | jq -c \
    '(.choiceContext.choiceContextData // .choiceContextData // {values: {}})')
  INPUT_FACTORY_DISCLOSED=$(echo "$AMULET_FACTORY_RESPONSE" | jq -c \
    '(.choiceContext.disclosedContracts // .disclosedContracts // [])
     | [.[] | {contractId, templateId, createdEventBlob, synchronizerId}]')
  INPUT_INSTRUMENT_ID=$(jq -n --arg admin "$DSO_PARTY" '{"id":"Amulet","admin":$admin}')
else
  # CBTC — fetch factory, context, and disclosed contracts from exchange backend
  CBTC_TOKEN_RESPONSE=$(curl_check "$BACKEND_URL/token-issuer/token/CBTC" "" "application/json") || {
    log_error "Failed to fetch CBTC token info from $BACKEND_URL/token-issuer/token/CBTC"
    exit 1
  }
  INPUT_FACTORY_CID=$(echo "$CBTC_TOKEN_RESPONSE" | jq -r '.data.factoryContractId // empty')
  INPUT_CONTEXT_DATA=$(echo "$CBTC_TOKEN_RESPONSE" | jq -c '.data.choiceContextData // {values: {}}')
  INPUT_FACTORY_DISCLOSED=$(echo "$CBTC_TOKEN_RESPONSE" | jq -c \
    '.data.discloseContracts // [] | [.[] | {contractId, templateId, createdEventBlob, synchronizerId}]')
  # Override CBTC_NETWORK_PARTY from live API response in case cbtc-factories.json is stale
  CBTC_NETWORK_PARTY=$(echo "$CBTC_TOKEN_RESPONSE" | jq -r '.data.admin // empty')
  INPUT_INSTRUMENT_ID=$(jq -n --arg admin "$CBTC_NETWORK_PARTY" '{"id":"CBTC","admin":$admin}')
fi

if [ "$OUTPUT_TOKEN_TYPE" = "Amulet" ]; then
  OUTPUT_INSTRUMENT_ID=$(jq -n --arg admin "$DSO_PARTY" '{"id":"Amulet","admin":$admin}')
else
  # CBTC output — ensure CBTC_NETWORK_PARTY is set (may not have been loaded when input is Amulet)
  if [ -z "$CBTC_NETWORK_PARTY" ]; then
    CBTC_PARTY_RESP=$(curl_check "$BACKEND_URL/token-issuer/token/CBTC" "" "application/json") || {
      log_error "Failed to fetch CBTC admin party from $BACKEND_URL/token-issuer/token/CBTC"
      exit 1
    }
    CBTC_NETWORK_PARTY=$(echo "$CBTC_PARTY_RESP" | jq -r '.data.admin // empty')
  fi
  OUTPUT_INSTRUMENT_ID=$(jq -n --arg admin "$CBTC_NETWORK_PARTY" '{"id":"CBTC","admin":$admin}')
fi

log "  Input factory CID:         ${INPUT_FACTORY_CID}"
log "  Disclosed contracts:       $(echo "$INPUT_FACTORY_DISCLOSED" | jq 'length')"
log "  Context data keys:         $(echo "$INPUT_CONTEXT_DATA" | jq -r '[.values // {} | keys[]] | join(", ")')"
log "  Input instrument:          $(echo "$INPUT_INSTRUMENT_ID" | jq -r '.id')"
log "  Output instrument:         $(echo "$OUTPUT_INSTRUMENT_ID" | jq -r '.id')"
confirm_step "Step 2 — $INPUT_TOKEN_TYPE allocation factory fetched"

##############################################################################
# Step 2b: Fetch token prices and calculate expectedReceiverAmount
##############################################################################

log ""
log "Step 2b: Fetching token prices from partner API..."

# Priority: env var → trade-request-config.json → GET /partner-api/token-prices
if [ -z "$EXPECTED_RECEIVER_AMOUNT" ] && [ -f "$TRADE_CONFIG_FILE" ]; then
  EXPECTED_RECEIVER_AMOUNT=$(jq -r '.tradeRequest.expectedReceiverAmount // empty' "$TRADE_CONFIG_FILE" 2>/dev/null || echo "")
fi

if [ -z "$EXPECTED_RECEIVER_AMOUNT" ]; then
  PRICE_RESP=$(curl -s -w "\n%{http_code}" "$BACKEND_URL/partner-api/token-prices" \
    -H "x-api-key: $PARTNER_API_KEY")
  PRICE_HTTP=$(echo "$PRICE_RESP" | tail -n1 | tr -d '\r')
  PRICE_BODY=$(echo "$PRICE_RESP" | sed '$d')

  if [ "$PRICE_HTTP" = "200" ] || [ "$PRICE_HTTP" = "201" ]; then
    # Response: { prices: [{tokenId, price, ...}], updatedAt } (possibly wrapped in {data: ...})
    INPUT_PRICE=$(echo "$PRICE_BODY" | jq -r --arg tok "$INPUT_TOKEN_TYPE" \
      '(.data.prices // .prices // []) | .[] | select(.tokenId == $tok) | .price | tostring' \
      2>/dev/null | head -1)
    OUTPUT_PRICE=$(echo "$PRICE_BODY" | jq -r --arg tok "$OUTPUT_TOKEN_TYPE" \
      '(.data.prices // .prices // []) | .[] | select(.tokenId == $tok) | .price | tostring' \
      2>/dev/null | head -1)

    if [ -n "$INPUT_PRICE" ] && [ -n "$OUTPUT_PRICE" ] && \
       [ "$INPUT_PRICE" != "null" ] && [ "$OUTPUT_PRICE" != "null" ]; then
      EXPECTED_RECEIVER_AMOUNT=$(awk -v a="$INPUT_AMOUNT" -v ip="$INPUT_PRICE" -v op="$OUTPUT_PRICE" \
        'BEGIN { printf "%.10f", a * ip / op }')
      log "  $INPUT_TOKEN_TYPE price (USD): $INPUT_PRICE"
      log "  $OUTPUT_TOKEN_TYPE price (USD): $OUTPUT_PRICE"
      log "  Calculated expectedReceiverAmount: $EXPECTED_RECEIVER_AMOUNT"
    else
      log "  Could not extract prices for $INPUT_TOKEN_TYPE / $OUTPUT_TOKEN_TYPE from response"
      log "  Response: $(echo "$PRICE_BODY" | head -c 300)"
    fi
  else
    log "  Token prices endpoint returned HTTP $PRICE_HTTP (Chainlink may not be configured on localnet)"
  fi
fi

if [ -z "$EXPECTED_RECEIVER_AMOUNT" ]; then
  log_error "Cannot determine expectedReceiverAmount. Options:"
  log_error "  1. Set EXPECTED_RECEIVER_AMOUNT=<amount> env var"
  log_error "  2. Add tradeRequest.expectedReceiverAmount to $TRADE_CONFIG_FILE"
  log_error "  3. Ensure GET /partner-api/token-prices returns prices for $INPUT_TOKEN_TYPE and $OUTPUT_TOKEN_TYPE"
  exit 1
fi
log "  expectedReceiverAmount:    $EXPECTED_RECEIVER_AMOUNT $OUTPUT_TOKEN_TYPE"
confirm_step "Step 2b — Token prices fetched"

##############################################################################
# Step 3: Get trader's input token holdings
# Sort by amount ascending (smallest first) and accumulate until total >= INPUT_AMOUNT.
# This consolidates small UTXOs first, reducing active contract count over time.
##############################################################################

log ""
log "Step 3: Querying trader's $INPUT_TOKEN_TYPE holdings (need >= $INPUT_AMOUNT)..."

if [ "$INPUT_TOKEN_TYPE" = "Amulet" ]; then
  HOLDING_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
    "$TRADER_PARTY_ID" "$AMULET_HOLDING_TEMPLATE" "true")
  SORTED_HOLDINGS=$(echo "$HOLDING_RESPONSE" | jq -c '
    [.[] | select(.contractEntry.JsActiveContract)
         | .contractEntry.JsActiveContract.createdEvent
         | {contractId, amount: (.createArgument.amount.initialAmount | tonumber)}]
    | sort_by(.amount) | .[]
  ' 2>/dev/null || echo "")
else
  HOLDING_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
    "$TRADER_PARTY_ID" "$CBTC_HOLDING_TEMPLATE" "true")
  SORTED_HOLDINGS=$(echo "$HOLDING_RESPONSE" | jq -c '
    [.[] | select(.contractEntry.JsActiveContract)
         | .contractEntry.JsActiveContract.createdEvent
         | {contractId, amount: (.createArgument.amount | tonumber)}]
    | sort_by(.amount) | .[]
  ' 2>/dev/null || echo "")
fi

if [ -z "$SORTED_HOLDINGS" ]; then
  log_error "No $INPUT_TOKEN_TYPE holdings found for trader."
  exit 1
fi

# Accumulate holdings smallest-first until total >= INPUT_AMOUNT
HOLDING_CIDS="[]"
HOLDING_TOTAL=0
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  cid=$(echo "$entry" | jq -r '.contractId')
  amt=$(echo "$entry" | jq -r '.amount')
  HOLDING_CIDS=$(echo "$HOLDING_CIDS" | jq --arg cid "$cid" '. + [$cid]')
  HOLDING_TOTAL=$(awk -v a="$HOLDING_TOTAL" -v b="$amt" 'BEGIN { printf "%.10f", a + b }')
  awk -v total="$HOLDING_TOTAL" -v req="$INPUT_AMOUNT" 'BEGIN { exit (total + 0 >= req + 0) ? 0 : 1 }' && break
done <<< "$SORTED_HOLDINGS"

if ! awk -v total="$HOLDING_TOTAL" -v req="$INPUT_AMOUNT" 'BEGIN { exit (total + 0 >= req + 0) ? 0 : 1 }'; then
  log_error "Insufficient $INPUT_TOKEN_TYPE holdings. Required: $INPUT_AMOUNT, Available: $HOLDING_TOTAL"
  exit 1
fi

HOLDING_COUNT=$(echo "$HOLDING_CIDS" | jq 'length')
log "  Holdings selected: $HOLDING_COUNT contract(s), total: $HOLDING_TOTAL $INPUT_TOKEN_TYPE"
confirm_step "Step 3 — $INPUT_TOKEN_TYPE holdings collected"

##############################################################################
# Step 3b: Detect and optionally settle lingering TradeEscrow contracts
#
# A TradeEscrow is left on-chain when AcceptAndAllocate succeeded but
# settlement did not complete (e.g., backend timeout, crash, or network error).
# The LP's allocation is locked until the escrow is settled or expires.
# We query the app-provider node (LP's participant) for active TradeEscrows.
##############################################################################

log ""
log "Step 3b: Checking for lingering TradeEscrow on app-provider node..."

AP_TOKEN=$(get_ap_token)

ESCROW_RESPONSE=$(query_active_contracts "$APP_PROVIDER_JSON_API" "$AP_TOKEN" \
  "$LP_PARTY" "$TRADE_ESCROW_TEMPLATE" "false")
ESCROW_CIDS=$(echo "$ESCROW_RESPONSE" | jq -r \
  '[.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][]' \
  2>/dev/null || echo "")
ESCROW_COUNT=$(echo "$ESCROW_CIDS" | grep -c '[^[:space:]]' 2>/dev/null || echo "0")

if [ "$ESCROW_COUNT" -gt 0 ]; then
  log "  Found $ESCROW_COUNT active TradeEscrow(s) — settlement pending:"

  while IFS= read -r escrow_cid; do
    [ -z "$escrow_cid" ] && continue

    ESCROW_ARG=$(echo "$ESCROW_RESPONSE" | jq -r \
      --arg cid "$escrow_cid" '
        [.[] | select(.contractEntry.JsActiveContract)
             | .contractEntry.JsActiveContract.createdEvent
             | select(.contractId == $cid)
             | .createArgument][0]
      ' 2>/dev/null || echo "{}")

    ESCROW_SENDER=$(echo "$ESCROW_ARG"         | jq -r '.sender // "?"')
    ESCROW_RECEIVER=$(echo "$ESCROW_ARG"        | jq -r '.receiver // "?"')
    ESCROW_SENDER_ALLOC=$(echo "$ESCROW_ARG"    | jq -r '.senderAllocationCid // "?"')
    ESCROW_RECEIVER_ALLOC=$(echo "$ESCROW_ARG"  | jq -r '.receiverAllocationCid // "?"')
    ESCROW_REF_ID=$(echo "$ESCROW_ARG"          | jq -r '.tradeReferenceId // "?"')

    log ""
    log "    TradeEscrow:           ${escrow_cid:0:50}..."
    log "    sender (trader):       ${ESCROW_SENDER:0:60}..."
    log "    receiver (LP):         ${ESCROW_RECEIVER:0:60}..."
    log "    tradeReferenceId:      $ESCROW_REF_ID"
    log "    senderAllocationCid:   ${ESCROW_SENDER_ALLOC:0:50}..."
    log "    receiverAllocationCid: ${ESCROW_RECEIVER_ALLOC:0:50}..."

    SETTLE_CHOICE="y"
    if [ "${SKIP_ESCROW_SETTLE:-}" = "true" ]; then
      log "  SKIP_ESCROW_SETTLE=true — skipping settle of lingering TradeEscrow."
      SETTLE_CHOICE="n"
    elif [ -t 0 ]; then
      printf "[test] Settle this TradeEscrow? [y=settle / n=skip / Ctrl+C=abort]: "
      read -r SETTLE_CHOICE
    else
      log "  Non-interactive mode: auto-settling lingering TradeEscrow..."
    fi

    if [ "$SETTLE_CHOICE" = "y" ] || [ "$SETTLE_CHOICE" = "Y" ]; then
      log "  Fetching disclosed contracts for settle..."

      # Fetch senderAllocation blob — try trading-partner first, then app-provider
      SENDER_ALLOC_BLOB=""
      if [ "$ESCROW_SENDER_ALLOC" != "?" ]; then
        SENDER_ALLOC_BLOB=$(get_blob_by_contract_id \
          "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" "$ESCROW_SENDER_ALLOC" 2>/dev/null || echo "")
        if [ -z "$SENDER_ALLOC_BLOB" ]; then
          SENDER_ALLOC_BLOB=$(get_blob_by_contract_id \
            "$APP_PROVIDER_JSON_API" "$AP_TOKEN" "$ESCROW_SENDER_ALLOC" 2>/dev/null || echo "")
        fi
        [ -n "$SENDER_ALLOC_BLOB" ] && log "    senderAllocation blob: OK" || \
          log "    WARNING: senderAllocation blob not found"
      fi

      # Fetch receiverAllocation blob from app-provider
      RECEIVER_ALLOC_BLOB=""
      if [ "$ESCROW_RECEIVER_ALLOC" != "?" ]; then
        RECEIVER_ALLOC_BLOB=$(get_blob_by_contract_id \
          "$APP_PROVIDER_JSON_API" "$AP_TOKEN" "$ESCROW_RECEIVER_ALLOC" 2>/dev/null || echo "")
        [ -n "$RECEIVER_ALLOC_BLOB" ] && log "    receiverAllocation blob: OK" || \
          log "    WARNING: receiverAllocation blob not found"
      fi

      # Fetch LockedAmulet blobs for the trader from trading-partner node
      LA_SETTLE_BLOBS="[]"
      LA_ACS=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
        "$ESCROW_SENDER" "#splice-amulet:Splice.Amulet:LockedAmulet" "false")
      while IFS= read -r la_cid; do
        [ -z "$la_cid" ] && continue
        la_blob=$(get_blob_by_contract_id "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" "$la_cid")
        if [ -n "$la_blob" ]; then
          LA_SETTLE_BLOBS=$(jq -n --argjson a "$LA_SETTLE_BLOBS" --argjson b "$la_blob" '$a + [$b]')
        fi
      done <<< "$(echo "$LA_ACS" | jq -r \
        '[.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][]' \
        2>/dev/null || echo "")"
      LA_COUNT=$(echo "$LA_SETTLE_BLOBS" | jq 'length')
      log "    LockedAmulet blobs:   $LA_COUNT"

      # Combine all disclosed contracts
      SETTLE_DISCLOSED="[]"
      [ -n "$SENDER_ALLOC_BLOB" ] && \
        SETTLE_DISCLOSED=$(jq -n --argjson a "$SETTLE_DISCLOSED" --argjson b "$SENDER_ALLOC_BLOB" '$a + [$b]')
      [ -n "$RECEIVER_ALLOC_BLOB" ] && \
        SETTLE_DISCLOSED=$(jq -n --argjson a "$SETTLE_DISCLOSED" --argjson b "$RECEIVER_ALLOC_BLOB" '$a + [$b]')
      SETTLE_DISCLOSED=$(jq -n --argjson a "$SETTLE_DISCLOSED" --argjson b "$LA_SETTLE_BLOBS" '$a + $b')

      SETTLE_BODY=$(jq -n \
        --arg escrowCid "$escrow_cid" \
        --arg trader "$ESCROW_SENDER" \
        --arg lpPartyId "$ESCROW_RECEIVER" \
        --arg inputTokenType "$INPUT_TOKEN_TYPE" \
        --arg outputTokenType "$OUTPUT_TOKEN_TYPE" \
        --argjson disclosed "$SETTLE_DISCLOSED" \
        '{
          tradeEscrowCid: $escrowCid,
          trader: $trader,
          lpPartyId: $lpPartyId,
          inputTokenType: $inputTokenType,
          outputTokenType: $outputTokenType,
          disclosedContracts: $disclosed
        }')

      log "  Calling POST /trading-partner/settle-trade-escrow..."
      log "    Disclosed contracts: $(echo "$SETTLE_DISCLOSED" | jq 'length')"

      SETTLE_RESULT=$(curl -s -w "\n%{http_code}" \
        "$BACKEND_URL/trading-partner/settle-trade-escrow" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $PARTNER_API_KEY" \
        --data-raw "$SETTLE_BODY")
      SETTLE_HTTP=$(echo "$SETTLE_RESULT" | tail -n1 | tr -d '\r')
      SETTLE_RESP=$(echo "$SETTLE_RESULT" | sed '$d')

      log "  HTTP: $SETTLE_HTTP"
      if [ "$SETTLE_HTTP" = "200" ] || [ "$SETTLE_HTTP" = "201" ]; then
        SETTLE_STATUS=$(echo "$SETTLE_RESP" | jq -r '.status // "?"')
        SETTLE_UID=$(echo "$SETTLE_RESP"    | jq -r '.settleUpdateId // "?"')
        log "  Settled! status=$SETTLE_STATUS updateId=${SETTLE_UID:0:50}..."
      else
        log "  Settle failed: $(echo "$SETTLE_RESP" | jq -r '.errorMessage // .message // .' 2>/dev/null)"
        echo "$SETTLE_RESP" | jq '.' 2>/dev/null || echo "$SETTLE_RESP"
      fi
    else
      log "  Skipped. The lingering TradeEscrow will remain on-chain."
    fi
  done <<< "$ESCROW_CIDS"
else
  log "  No lingering TradeEscrow found."
fi

##############################################################################
# Step 4: Create or reuse TradeProposal on trading-partner node
##############################################################################

log ""
log "Step 4: Create or reuse TradeProposal on trading-partner node..."

# Check for a lingering TradeProposal from a previous failed run and reuse it
log "  Checking for existing TradeProposal..."
EXISTING_TP_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
  "$TRADER_PARTY_ID" "$TRADE_PROPOSAL_TEMPLATE" "true")
TRADE_PROPOSAL_CID=$(echo "$EXISTING_TP_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
' 2>/dev/null || echo "")
TRADER_ALLOCATION_CID=""
# The LockedAmulet CID — the underlying locked Amulet needed by TradeEscrow_Settle
LOCKED_AMULET_CID=""
# Raw create result (only set when creating a new TradeProposal, empty when reusing)
CREATE_RESULT=""

if [ -n "$TRADE_PROPOSAL_CID" ]; then
  # Parse and display lingering TradeProposal details
  TP_DATA=$(echo "$EXISTING_TP_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createArgument][0]
  ' 2>/dev/null || echo "{}")
  TP_SENDER=$(echo "$TP_DATA"        | jq -r '.sender // "?"')
  TP_RECEIVER=$(echo "$TP_DATA"      | jq -r '.receiver // "?"')
  TP_EXECUTOR=$(echo "$TP_DATA"      | jq -r '.executor // "?"')
  TP_ALLOC_CID=$(echo "$TP_DATA"     | jq -r '.senderAllocationCid // "?"')
  TP_REF_ID=$(echo "$TP_DATA"        | jq -r '.tradeReferenceId // "?"')
  TP_EXP_AMT=$(echo "$TP_DATA"       | jq -r '.expectedReceiverAmount // "?"')
  TP_EXP_OUT=$(echo "$TP_DATA"       | jq -r '.expectedReceiverInstrumentId.id // "?"')

  log "  Found lingering TradeProposal: ${TRADE_PROPOSAL_CID:0:50}..."
  log "    sender:                  ${TP_SENDER:0:60}..."
  log "    receiver (LP):           ${TP_RECEIVER:0:60}..."
  log "    executor:                ${TP_EXECUTOR:0:60}..."
  log "    senderAllocationCid:     ${TP_ALLOC_CID:0:50}..."
  log "    tradeReferenceId:        $TP_REF_ID"
  log "    expectedReceiverAmount:  $TP_EXP_AMT $TP_EXP_OUT"
  log ""

  # Check if the lingering TradeProposal targets the correct LP party.
  # If the receiver doesn't match LP_PARTY, always create a new one —
  # TradeProposal has no withdraw choice so the orphan stays on-chain.
  if [ "$TP_RECEIVER" != "$LP_PARTY" ]; then
    log "  Lingering TradeProposal receiver ($TP_RECEIVER) does not match LP ($LP_PARTY)."
    log "  Creating new TradeProposal (orphan will remain on-chain)."
    TRADE_PROPOSAL_CID=""
  elif [ -t 0 ]; then
    printf "[test] Use this TradeProposal? [y=reuse / n=create new / Ctrl+C=abort]: "
    read -r TP_CHOICE
    if [ "$TP_CHOICE" = "n" ] || [ "$TP_CHOICE" = "N" ]; then
      log "  Creating new TradeProposal (lingering one will remain on-chain)..."
      TRADE_PROPOSAL_CID=""
    else
      log "  Reusing lingering TradeProposal."
    fi
  else
    log "  Non-interactive mode: creating new TradeProposal."
    TRADE_PROPOSAL_CID=""
  fi
fi

if [ -z "$TRADE_PROPOSAL_CID" ]; then
  log "  No existing TradeProposal found, creating new one..."

  # allocateBefore/settleBefore are RelTime (relative duration, not absolute timestamp).
  # Daml RelTime JSON encoding: {"microseconds": N}
  # 10 min = 600 * 1_000_000, 15 min = 900 * 1_000_000
  ALLOCATE_BEFORE_MICROS=$(( 600 * 1000000 ))
  SETTLE_BEFORE_MICROS=$(( 900 * 1000000 ))
  CMD_ID="test-trade-req-${RUN_ID}-${RANDOM}"

  # Build the ExerciseCommand for TradeProposalFactory_CreateTradeProposalAndAllocate
  EXERCISE_CMD=$(jq -n \
    --arg factoryTemplateId "$TRADE_PROPOSAL_FACTORY_TEMPLATE" \
    --arg factoryCid "$FACTORY_CID" \
    --arg sender "$TRADER_PARTY_ID" \
    --arg receiver "$LP_PARTY" \
    --arg executor "$EXECUTOR_PARTY" \
    --arg amount "$INPUT_AMOUNT" \
    --argjson holdingCids "$HOLDING_CIDS" \
    --arg inputFactoryCid "$INPUT_FACTORY_CID" \
    --argjson inputInstrumentId "$INPUT_INSTRUMENT_ID" \
    --argjson outputInstrumentId "$OUTPUT_INSTRUMENT_ID" \
    --argjson allocateBefore "{\"microseconds\": $ALLOCATE_BEFORE_MICROS}" \
    --argjson settleBefore "{\"microseconds\": $SETTLE_BEFORE_MICROS}" \
    --argjson contextData "$INPUT_CONTEXT_DATA" \
    --arg expectedAmount "$EXPECTED_RECEIVER_AMOUNT" \
    '[{
      ExerciseCommand: {
        templateId: $factoryTemplateId,
        contractId: $factoryCid,
        choice: "TradeProposalFactory_CreateTradeProposalAndAllocate",
        choiceArgument: {
          sender: $sender,
          receiver: $receiver,
          executor: $executor,
          allocationArgs: {
            executor: $executor,
            amount: $amount,
            instrumentId: $inputInstrumentId,
            allocationFactoryCid: $inputFactoryCid,
            inputHoldingCids: $holdingCids,
            allocateBefore: $allocateBefore,
            settleBefore: $settleBefore,
            extraArgs: {
              context: $contextData,
              meta: { values: {} }
            }
          },
          expectedReceiverAmount: $expectedAmount,
          expectedReceiverInstrumentId: $outputInstrumentId
        }
      }
    }]')

  # Combine disclosed contracts: factory + input token factory disclosures
  ALL_DISCLOSED=$(jq -n \
    --argjson factory "[$FACTORY_DISCLOSED]" \
    --argjson inputFactory "$INPUT_FACTORY_DISCLOSED" \
    '$factory + $inputFactory')

  # Submit via submit-and-wait (trader is internal party on trading-partner node)
  # actAs: trader (choice controller = sender)
  # readAs: empty — all contracts are provided via disclosedContracts
  # eventFormat: request createdEventBlob for ALL contracts created in this transaction
  # (TradeProposal, AmuletAllocation, and LockedAmulet are all created here)
  SUBMIT_BODY=$(jq -n \
    --argjson commands "$EXERCISE_CMD" \
    --arg cmdId "$CMD_ID" \
    --arg userId "$TRADER_USER_ID" \
    --arg party "$TRADER_PARTY_ID" \
    --argjson disclosed "$ALL_DISCLOSED" \
    '{
      commands: {
        commands: $commands,
        commandId: $cmdId,
        applicationId: $userId,
        actAs: [$party],
        readAs: [],
        deduplicationPeriod: { Empty: {} },
        submissionId: $cmdId,
        disclosedContracts: $disclosed,
        domainId: "",
        packageIdSelectionPreference: []
      },
      eventFormat: {
        filtersForAnyParty: {
          cumulative: [{
            identifierFilter: {
              WildcardFilter: { value: { includeCreatedEventBlob: true } }
            }
          }]
        }
      }
    }')

  log "  Submitting TradeProposalFactory_CreateTradeProposalAndAllocate..."
  log "    sender:    $TRADER_PARTY_ID"
  log "    receiver:  $LP_PARTY"
  log "    executor:  $EXECUTOR_PARTY"
  log "    amount:    $INPUT_AMOUNT $INPUT_TOKEN_TYPE (from $HOLDING_COUNT holding(s), total $HOLDING_TOTAL)"
  log "    disclosed: $(echo "$ALL_DISCLOSED" | jq 'length') contracts"
  CREATE_RESULT=$(curl_check "$TRADING_PARTNER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$TRADER_TOKEN" "application/json" \
    --data-raw "$SUBMIT_BODY") || {
    log_error "Failed to create TradeProposal"
    exit 1
  }

  # Extract created contract CIDs from transaction events.
  # The creation creates 3 contracts: TradeProposal, AmuletAllocation, LockedAmulet.
  TRADE_PROPOSAL_CID=$(echo "$CREATE_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("TradeProposal:TradeProposal")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  TRADER_ALLOCATION_CID=$(echo "$CREATE_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("Allocation")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  # The LockedAmulet CID (underlying locked Amulet, needed by TradeEscrow_Settle as disclosedContract)
  LOCKED_AMULET_CID=$(echo "$CREATE_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("LockedAmulet")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$TRADE_PROPOSAL_CID" ]; then
    log_error "Could not extract TradeProposal CID"
    log_error "Events: $(echo "$CREATE_RESULT" | jq -c '[.transaction.events[] | (.CreatedEvent // .created // empty) | .templateId]' 2>/dev/null)"
    exit 1
  fi

  log "  TradeProposal CID:    ${TRADE_PROPOSAL_CID:0:50}..."
  log "  AmuletAllocation CID: ${TRADER_ALLOCATION_CID:0:50}..."
  log "  LockedAmulet CID:     ${LOCKED_AMULET_CID:0:50}..."
fi
confirm_step "Step 4 — TradeProposal created/reused"

##############################################################################
# Step 5: Fetch LockedAmulet blob via events-by-contract-id
#
# TradeEscrow_Settle requires the LockedAmulet (trader's locked Amulet) as a
# disclosed contract. This contract lives only on the trading-partner node.
#
# The /v2/events/events-by-contract-id endpoint correctly returns createdEventBlob,
# unlike /v2/state/active-contracts which always returns empty blobs for this node.
##############################################################################

log ""
log "Step 5: Fetching LockedAmulet blob from trading-partner node..."

TRADE_REQUEST_DISCLOSED="[]"
LOCKED_AMULET_BLOBS="[]"

if [ -n "$LOCKED_AMULET_CID" ]; then
  # New TradeProposal: we know the exact LockedAmulet CID from the creation events
  log "  Fetching blob for LockedAmulet: ${LOCKED_AMULET_CID:0:50}..."
  LOCKED_BLOB=$(get_blob_by_contract_id "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" "$LOCKED_AMULET_CID")
  if [ -n "$LOCKED_BLOB" ]; then
    LOCKED_BLOB_LEN=$(echo "$LOCKED_BLOB" | jq -r '.createdEventBlob | length')
    log "  LockedAmulet blob len: $LOCKED_BLOB_LEN chars"
    LOCKED_AMULET_BLOBS=$(jq -n --argjson b "$LOCKED_BLOB" '[$b]')
  else
    log "  WARNING: Could not fetch LockedAmulet blob for $LOCKED_AMULET_CID"
  fi
else
  # Reuse case: LockedAmulet CID unknown — query ACS for all active LockedAmulets and get all blobs.
  # The settle will use whichever one the TradeEscrow references; extras are safely ignored.
  log "  LOCKED_AMULET_CID not set (reuse case). Querying ACS for all active LockedAmulets..."
  LA_ACS_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
    "$TRADER_PARTY_ID" "#splice-amulet:Splice.Amulet:LockedAmulet" "false")
  LA_CIDS=$(echo "$LA_ACS_RESPONSE" | jq -r '
    [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][]
  ' 2>/dev/null || echo "")
  LA_COUNT=$(echo "$LA_CIDS" | grep -c . 2>/dev/null || echo "0")
  log "  Found $LA_COUNT LockedAmulet contract(s). Fetching blobs..."
  while IFS= read -r la_cid; do
    [ -z "$la_cid" ] && continue
    la_blob=$(get_blob_by_contract_id "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" "$la_cid")
    if [ -n "$la_blob" ]; then
      LOCKED_AMULET_BLOBS=$(jq -n --argjson a "$LOCKED_AMULET_BLOBS" --argjson b "$la_blob" '$a + [$b]')
      log "    Got blob for ${la_cid:0:50}..."
    fi
  done <<< "$LA_CIDS"
fi

LOCKED_BLOB_COUNT=$(echo "$LOCKED_AMULET_BLOBS" | jq 'length')
log "  LockedAmulet blobs obtained: $LOCKED_BLOB_COUNT"

# Build disclosed contracts for trade request
TRADE_REQUEST_DISCLOSED=$(echo "$LOCKED_AMULET_BLOBS" | jq -c '
  [.[] | select(.createdEventBlob != null and .createdEventBlob != "")]
')

BLOB_COUNT=$(echo "$TRADE_REQUEST_DISCLOSED" | jq 'length')
log "  Total disclosed for trade request: $BLOB_COUNT contract(s)"
if [ "$BLOB_COUNT" -eq "0" ]; then
  log "  WARNING: No LockedAmulet blobs obtained."
  log "           TradeEscrow_Settle will likely fail with CONTRACT_NOT_FOUND."
fi
confirm_step "Step 5 — Disclosures ready"

##############################################################################
# Step 6: Call POST /trading-partner/trade-request
##############################################################################

log ""
log "Waiting 10 seconds for TradeProposal to propagate to the exchange backend ledger..."
sleep 10

log ""
log "Step 6: Calling POST /trading-partner/trade-request..."
log "  lpPartyId: ${LP_PARTY:0:60}..."

TRADE_REQUEST_BODY=$(jq -n \
  --arg tradeProposalCid "$TRADE_PROPOSAL_CID" \
  --arg trader "$TRADER_PARTY_ID" \
  --arg inputAmount "$INPUT_AMOUNT" \
  --arg inputTokenType "$INPUT_TOKEN_TYPE" \
  --arg outputTokenType "$OUTPUT_TOKEN_TYPE" \
  --arg outputAmount "$EXPECTED_RECEIVER_AMOUNT" \
  --arg lpPartyId "$LP_PARTY" \
  --argjson disclosedContracts "$TRADE_REQUEST_DISCLOSED" \
  '{
    tradeProposalCid: $tradeProposalCid,
    trader: $trader,
    inputAmount: $inputAmount,
    inputTokenType: $inputTokenType,
    outputTokenType: $outputTokenType,
    outputAmount: $outputAmount,
    lpPartyId: $lpPartyId,
    disclosedContracts: $disclosedContracts
  }')

TRADE_RESULT=$(curl -s -w "\n%{http_code}" "$BACKEND_URL/trading-partner/trade-request" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $PARTNER_API_KEY" \
  --data-raw "$TRADE_REQUEST_BODY")

TRADE_HTTP_CODE=$(echo "$TRADE_RESULT" | tail -n1 | tr -d '\r')
TRADE_RESPONSE=$(echo "$TRADE_RESULT" | sed '$d')

log "  HTTP: $TRADE_HTTP_CODE"
log "  Status:        $(echo "$TRADE_RESPONSE" | jq -r '.data.status // .status // "?"')"
log "  TradeEscrow:   $(echo "$TRADE_RESPONSE" | jq -r '.data.tradeEscrowCid // .tradeEscrowCid // "?"' | cut -c1-50)..."
log "  SettleUpdateId: $(echo "$TRADE_RESPONSE" | jq -r '.data.settleUpdateId // .settleUpdateId // "?"' | cut -c1-50)..."
log "  ErrorMessage:  $(echo "$TRADE_RESPONSE" | jq -r '.data.errorMessage // .errorMessage // "none"')"
log "  Raw response:"
echo "$TRADE_RESPONSE" | jq '.' 2>/dev/null || echo "$TRADE_RESPONSE"

##############################################################################
# Step 7: Verify result
##############################################################################

log ""
log "Step 7: Verifying result..."

STATUS=$(echo "$TRADE_RESPONSE" | jq -r '.data.status // .status // "UNKNOWN"' 2>/dev/null)
TRADE_ESCROW_CID=$(echo "$TRADE_RESPONSE" | jq -r '.data.tradeEscrowCid // .tradeEscrowCid // "null"' 2>/dev/null)
SETTLE_UPDATE_ID=$(echo "$TRADE_RESPONSE" | jq -r '.data.settleUpdateId // .settleUpdateId // "null"' 2>/dev/null)

log ""
log "=========================================="
if [ "$STATUS" = "SUCCEEDED" ]; then
  log "TEST PASSED!"
else
  log "TEST FAILED — Status: $STATUS"
fi
log "=========================================="
log ""
log "Summary:"
log "  Status:         $STATUS"
log "  TradeProposal:  ${TRADE_PROPOSAL_CID:0:40}..."
log "  TradeEscrow:    ${TRADE_ESCROW_CID:0:40}..."
log "  SettleUpdateId: ${SETTLE_UPDATE_ID:0:40}..."
log ""

if [ "$STATUS" != "SUCCEEDED" ]; then
  ERROR_MSG=$(echo "$TRADE_RESPONSE" | jq -r '.data.errorMessage // .errorMessage // "none"' 2>/dev/null)
  log "  Error: $ERROR_MSG"
  log ""
  # Provide actionable guidance based on the error
  case "$ERROR_MSG" in
    *"No unlocked holdings"*|*"available balance"*)
      log "  Hint: The liquidity provider has no available $OUTPUT_TOKEN_TYPE holdings."
      log "        Fund the LP and retry:"
      log "          cd $SETUP_EXCHANGE_DIR && ./06-fund-liquidity-provider.sh"
      log "        Then run ./03-withdraw-allocation.sh to reclaim the locked Amulet"
      log "        before retrying this test."
      ;;
    *"Could not fetch TradeProposal"*)
      log "  Hint: The exchange backend could not read the TradeProposal yet."
      log "        Increase TRADE_PROPAGATION_DELAY or re-run — the TradeProposal"
      log "        is still active and will be reused on the next run."
      ;;
    *"TradeProposal"*"expired"*|*"allocateBefore"*)
      log "  Hint: The TradeProposal expired. Run ./03-withdraw-allocation.sh to"
      log "        reclaim locked Amulet, then retry."
      ;;
  esac
  exit 1
fi
