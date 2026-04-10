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
#   TRADER_PARTY_ID    — Trader's party ID (default: from internal-parties.json)
#   TRADER_USER_ID     — Trader's Canton user ID (default: from internal-parties.json)
#   INPUT_AMOUNT       — Amount of Amulet to swap (default: 10)
#   PARTNER_API_KEY    — Partner API key for exchange backend (default: from liquidity-provider.json)
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

# Load trader party from internal-parties.json
INTERNAL_PARTIES_FILE="$INTERNAL_PARTIES_DIR/internal-parties.json"
if [ -z "$TRADER_PARTY_ID" ]; then
  if [ -f "$INTERNAL_PARTIES_FILE" ]; then
    TRADER_PARTY_ID=$(jq -r '.parties[0].partyId' "$INTERNAL_PARTIES_FILE")
    TRADER_USER_ID=$(jq -r '.parties[0].userId' "$INTERNAL_PARTIES_FILE")
  fi
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

# Load executor party from backend .env (EXCHANGE_BACKEND_DIR comes from setup-exchange/.env)
BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
EXECUTOR_PARTY=""
if [ -f "$BACKEND_ENV" ]; then
  EXECUTOR_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)
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
TRADE_PROPOSAL_FACTORY_TEMPLATE="#kairo-dex-simple-escrow-v4:Kairo.Escrow.TradeProposalFactory:TradeProposalFactory"

##############################################################################
# Helper Functions
##############################################################################

log() { echo "[test] $*"; }
log_error() { echo "[test] ERROR: $*" >&2; }

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

generate_canton_jwt() {
  local sub="$1" aud="$2"
  local now; now=$(date +%s)
  local exp=$((now + 86400))
  b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
  local header; header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  local payload; payload=$(printf '{"sub":"%s","aud":"%s","iat":%d,"exp":%d,"iss":"unsafe-auth"}' "$sub" "$aud" "$now" "$exp" | b64url)
  local signature; signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$SHARED_SECRET" -binary | b64url)
  echo "${header}.${payload}.${signature}"
}

query_active_contracts() {
  local json_api="$1" token="$2" party="$3" template_id="$4" include_blob="${5:-false}"
  local offset; offset=$(curl_check "$json_api/v2/state/ledger-end" "$token" | jq -r '.offset')
  local body; body=$(jq -n \
    --arg party "$party" --arg templateId "$template_id" \
    --argjson includeBlob "$include_blob" --argjson offset "$offset" \
    '{
      filter: { filtersByParty: { ($party): { cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId: $templateId, includeCreatedEventBlob: $includeBlob } } } }] } } },
      verbose: true, activeAtOffset: $offset
    }')
  curl_check "$json_api/v2/state/active-contracts" "$token" "application/json" --data-raw "$body" 2>/dev/null || echo ""
}

##############################################################################
# Pre-flight
##############################################################################

log "=========================================="
log "Test: POST /trading-partner/trade-request"
log "=========================================="
log "  Trader: $TRADER_PARTY_ID"
log "  Executor: ${EXECUTOR_PARTY:0:50}..."
log "  Input: $INPUT_AMOUNT $INPUT_TOKEN_TYPE → $OUTPUT_TOKEN_TYPE"
log "  Backend: $BACKEND_URL"
log ""

[ -n "$TRADER_PARTY_ID" ] || { log_error "TRADER_PARTY_ID not set"; exit 1; }
[ -n "$EXECUTOR_PARTY" ] || { log_error "EXECUTOR_PARTY not set"; exit 1; }
[ -n "$PARTNER_API_KEY" ] || { log_error "PARTNER_API_KEY not set"; exit 1; }

# Tokens for trading-partner node
TP_TOKEN=$(generate_canton_jwt "${SHARED_SECRET_TRADING_PARTNER_USER:-ledger-api-user}" "$SHARED_SECRET_AUDIENCE")
# Token for the trader user specifically
TRADER_TOKEN=$(generate_canton_jwt "$TRADER_USER_ID" "$SHARED_SECRET_AUDIENCE")

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

log "  Factory CID: ${FACTORY_CID:0:40}..."

##############################################################################
# Step 2: Fetch Amulet allocation factory from scan-proxy
##############################################################################

log ""
log "Step 2: Fetching Amulet allocation factory..."

AMULET_FACTORY_RESPONSE=$(curl_check "$TRADING_PARTNER_VALIDATOR_API/api/validator/v0/scan-proxy/registry/allocation-instruction/v1/allocation-factory" \
  "$TP_TOKEN" "application/json" \
  --data-raw '{"choiceArguments":{},"excludeDebugFields":true}') || {
  log_error "Failed to fetch Amulet allocation factory from scan-proxy"
  exit 1
}

AMULET_FACTORY_CID=$(echo "$AMULET_FACTORY_RESPONSE" | jq -r '.factoryId // empty')
AMULET_CONTEXT_DATA=$(echo "$AMULET_FACTORY_RESPONSE" | jq -c '.choiceContextData // {values:{}}')
AMULET_FACTORY_DISCLOSED=$(echo "$AMULET_FACTORY_RESPONSE" | jq -c '[.disclosedContracts[]? | {contractId, templateId, createdEventBlob, synchronizerId}]')

log "  Amulet factory CID: ${AMULET_FACTORY_CID:0:40}..."

##############################################################################
# Step 3: Get trader's Amulet holdings
##############################################################################

log ""
log "Step 3: Querying trader's Amulet holdings..."

HOLDING_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
  "$TRADER_PARTY_ID" "$AMULET_HOLDING_TEMPLATE" "true")

HOLDING_CID=$(echo "$HOLDING_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
' 2>/dev/null || echo "")

if [ -z "$HOLDING_CID" ]; then
  log_error "No Amulet holdings found for trader. Faucet some Amulet first."
  exit 1
fi
log "  Holding CID: ${HOLDING_CID:0:40}..."

##############################################################################
# Step 4: Create TradeProposal on trading-partner node
##############################################################################

log ""
log "Step 4: Creating TradeProposal on trading-partner node..."

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
  --arg receiver "$EXECUTOR_PARTY" \
  --arg executor "$EXECUTOR_PARTY" \
  --arg amount "$INPUT_AMOUNT" \
  --arg holdingCid "$HOLDING_CID" \
  --arg amuletFactoryCid "$AMULET_FACTORY_CID" \
  --argjson allocateBefore "{\"microseconds\": $ALLOCATE_BEFORE_MICROS}" \
  --argjson settleBefore "{\"microseconds\": $SETTLE_BEFORE_MICROS}" \
  --argjson contextData "$AMULET_CONTEXT_DATA" \
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
          instrumentId: {
            id: "Amulet",
            admin: "DSO"
          },
          allocationFactoryCid: $amuletFactoryCid,
          inputHoldingCids: [$holdingCid],
          allocateBefore: $allocateBefore,
          settleBefore: $settleBefore,
          extraArgs: {
            context: $contextData,
            meta: { values: {} }
          }
        },
        expectedReceiverAmount: "0",
        expectedReceiverInstrumentId: {
          id: "CBTC",
          admin: "CBTC-NETWORK"
        }
      }
    }
  }]')

# Combine disclosed contracts: factory + amulet factory disclosures
ALL_DISCLOSED=$(jq -n \
  --argjson factory "[$FACTORY_DISCLOSED]" \
  --argjson amulet "$AMULET_FACTORY_DISCLOSED" \
  '$factory + $amulet')

# Submit via submit-and-wait (trader is internal party on trading-partner node)
# actAs: trader (choice controller = sender)
# readAs: empty — all contracts are provided via disclosedContracts
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
    }
  }')

log "  Submitting TradeProposalFactory_CreateTradeProposalAndAllocate..."
CREATE_RESULT=$(curl_check "$TRADING_PARTNER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$TRADER_TOKEN" "application/json" \
  --data-raw "$SUBMIT_BODY") || {
  log_error "Failed to create TradeProposal"
  exit 1
}

# Extract created contract CIDs
TRADE_PROPOSAL_CID=$(echo "$CREATE_RESULT" | jq -r '
  [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("TradeProposal:TradeProposal")) | .contractId][0] // empty
' 2>/dev/null || echo "")

TRADER_ALLOCATION_CID=$(echo "$CREATE_RESULT" | jq -r '
  [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("Allocation")) | .contractId][0] // empty
' 2>/dev/null || echo "")

if [ -z "$TRADE_PROPOSAL_CID" ]; then
  log_error "Could not extract TradeProposal CID"
  log_error "Events: $(echo "$CREATE_RESULT" | jq -c '[.transaction.events[] | (.CreatedEvent // .created // empty) | .templateId]' 2>/dev/null)"
  exit 1
fi

log "  TradeProposal CID: ${TRADE_PROPOSAL_CID:0:40}..."
log "  TraderAllocation CID: ${TRADER_ALLOCATION_CID:0:40}..."

##############################################################################
# Step 5: Query disclosures for created contracts
##############################################################################

log ""
log "Step 5: Querying disclosures for created contracts..."

# Query TradeProposal with blob
TP_DISCLOSED_RESPONSE=$(query_active_contracts "$TRADING_PARTNER_JSON_API" "$TP_TOKEN" \
  "$TRADER_PARTY_ID" "#kairo-dex-simple-escrow-v4:Kairo.Escrow.TradeProposal:TradeProposal" "true")

TP_DISCLOSED=$(echo "$TP_DISCLOSED_RESPONSE" | jq -c '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract | {
    contractId: .createdEvent.contractId,
    templateId: .createdEvent.templateId,
    createdEventBlob: .createdEvent.createdEventBlob,
    synchronizerId: .synchronizerId
  }] | [.[] | select(.contractId == "'"$TRADE_PROPOSAL_CID"'")][0] // empty
' 2>/dev/null || echo "")

if [ -z "$TP_DISCLOSED" ] || [ "$TP_DISCLOSED" = "null" ]; then
  log_error "Could not get disclosure for TradeProposal"
  exit 1
fi
log "  TradeProposal disclosure OK"

# Build disclosed contracts array for trade request
TRADE_REQUEST_DISCLOSED=$(jq -n \
  --argjson tp "$TP_DISCLOSED" \
  '[$tp]')

log "  Disclosures ready: $(echo "$TRADE_REQUEST_DISCLOSED" | jq length) contracts"

##############################################################################
# Step 6: Call POST /trading-partner/trade-request
##############################################################################

log ""
log "Step 6: Calling POST /trading-partner/trade-request..."

TRADE_REQUEST_BODY=$(jq -n \
  --arg tradeProposalCid "$TRADE_PROPOSAL_CID" \
  --arg trader "$TRADER_PARTY_ID" \
  --arg inputAmount "$INPUT_AMOUNT" \
  --arg inputTokenType "$INPUT_TOKEN_TYPE" \
  --arg outputTokenType "$OUTPUT_TOKEN_TYPE" \
  --argjson disclosedContracts "$TRADE_REQUEST_DISCLOSED" \
  '{
    tradeProposalCid: $tradeProposalCid,
    trader: $trader,
    inputAmount: $inputAmount,
    inputTokenType: $inputTokenType,
    outputTokenType: $outputTokenType,
    disclosedContracts: $disclosedContracts
  }')

TRADE_RESULT=$(curl -s -w "\n%{http_code}" "$BACKEND_URL/trading-partner/trade-request" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $PARTNER_API_KEY" \
  --data-raw "$TRADE_REQUEST_BODY")

TRADE_HTTP_CODE=$(echo "$TRADE_RESULT" | tail -n1 | tr -d '\r')
TRADE_RESPONSE=$(echo "$TRADE_RESULT" | sed '$d')

log "  HTTP: $TRADE_HTTP_CODE"
log "  Response:"
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
  exit 1
fi
