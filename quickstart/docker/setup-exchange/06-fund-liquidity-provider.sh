#!/bin/bash
# Funds the Liquidity Provider party with CBTC and Amulet tokens.
#
# This script:
#   1. Mints CBTC tokens via AllocationFactory_RequestMint + MintRequest_Accept
#   2. Faucets Amulet tokens via AmuletRules_DevNet_Tap
#   3. Writes lp-holdings.json with all created holdings
#
# Prerequisites:
#   - Quickstart localnet is running (DevNet mode)
#   - 01-setup-exchange.sh has been run (DARs uploaded, contracts created)
#   - 03-register-cbtc-token.sh has been run (CBTC factories created)
#   - 05-setup-liquidity-provider.sh has been run (LP party created)
#
# Environment variables (optional overrides):
#   CBTC_TOTAL_AMOUNT   — Total CBTC to mint (default: 10000)
#   CBTC_NUM_HOLDINGS   — Number of CBTC holdings to create (default: 10)
#   AMULET_TOTAL_AMOUNT — Total Amulet to tap (default: 100000000)
#   AMULET_NUM_HOLDINGS — Number of Amulet holdings to create (default: 100)
#
# Usage:
#   ./06-fund-liquidity-provider.sh
#   CBTC_TOTAL_AMOUNT=50000 AMULET_TOTAL_AMOUNT=500000000 ./06-fund-liquidity-provider.sh

set -eo pipefail

# Unique run ID to prevent command ID collisions across runs
RUN_ID=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUICKSTART_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load shared configuration from .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[fund-lp] ERROR: $SCRIPT_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"

# Funding amounts
CBTC_TOTAL_AMOUNT="${CBTC_TOTAL_AMOUNT:-10000}"
CBTC_NUM_HOLDINGS="${CBTC_NUM_HOLDINGS:-10}"
AMULET_TOTAL_AMOUNT="${AMULET_TOTAL_AMOUNT:-100000000}"
AMULET_NUM_HOLDINGS="${AMULET_NUM_HOLDINGS:-100}"

# Load LP configuration from liquidity-provider.json
LP_CONFIG_FILE="$SCRIPT_DIR/liquidity-provider.json"
if [ ! -f "$LP_CONFIG_FILE" ]; then
  echo "[fund-lp] ERROR: $LP_CONFIG_FILE not found. Run 05-setup-liquidity-provider.sh first." >&2
  exit 1
fi
LP_PARTY_ID=$(jq -r '.liquidityProvider.lpPartyId' "$LP_CONFIG_FILE")
LP_NAME=$(jq -r '.liquidityProvider.lpName' "$LP_CONFIG_FILE")
LP_PARTY_HINT=$(jq -r '.liquidityProvider.partyHint' "$LP_CONFIG_FILE")

if [ -z "$LP_PARTY_ID" ] || [ "$LP_PARTY_ID" = "null" ]; then
  echo "[fund-lp] ERROR: LP party ID not found in $LP_CONFIG_FILE" >&2
  exit 1
fi

# Load CBTC configuration
CBTC_CONFIG_FILE="$SCRIPT_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[fund-lp] ERROR: CBTC config not found: $CBTC_CONFIG_FILE. Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")

# Load CBTC-NETWORK keypair (needed for MintRequest_Accept)
CBTC_KEYPAIR_FILE="$SCRIPT_DIR/cbtc-network-keypair.json"
if [ ! -f "$CBTC_KEYPAIR_FILE" ]; then
  echo "[fund-lp] ERROR: CBTC-NETWORK keypair not found. Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
CBTC_NETWORK_PARTY=$(jq -r '.partyId' "$CBTC_KEYPAIR_FILE")
CBTC_PRIV_KEY=$(jq -r '.privateKey' "$CBTC_KEYPAIR_FILE")
CBTC_FP=$(jq -r '.fingerprint' "$CBTC_KEYPAIR_FILE")

# Load CBTC factories (AllocationFactory + InstrumentConfiguration)
FACTORIES_FILE="$SCRIPT_DIR/cbtc-factories.json"
if [ ! -f "$FACTORIES_FILE" ]; then
  echo "[fund-lp] ERROR: CBTC factories not found. Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
ALLOCATION_FACTORY_CID=$(jq -r '.factories.allocationFactory.contractId' "$FACTORIES_FILE")
INSTRUMENT_CONFIG_CID=$(jq -r '.instrumentConfiguration.contractId' "$FACTORIES_FILE")

# Build CBTC disclosed contracts from factories file
CBTC_DISCLOSED_CONTRACTS=$(jq -c '[
  {
    contractId: .factories.allocationFactory.disclosure.contractId,
    templateId: .factories.allocationFactory.disclosure.templateId,
    createdEventBlob: .factories.allocationFactory.disclosure.createdEventBlob,
    synchronizerId: .factories.allocationFactory.disclosure.synchronizerId
  },
  {
    contractId: .instrumentConfiguration.disclosure.contractId,
    templateId: .instrumentConfiguration.disclosure.templateId,
    createdEventBlob: .instrumentConfiguration.disclosure.createdEventBlob,
    synchronizerId: .instrumentConfiguration.disclosure.synchronizerId
  }
]' "$FACTORIES_FILE")

# Template IDs
ALLOCATION_FACTORY_TEMPLATE="#utility-registry-app-v0:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory"
MINT_REQUEST_TEMPLATE="#utility-registry-app-v0:Utility.Registry.App.V0.Model.Mint:MintRequest"
AMULET_RULES_TEMPLATE="#splice-amulet:Splice.AmuletRules:AmuletRules"
OPEN_MINING_ROUND_TEMPLATE="#splice-amulet:Splice.Round:OpenMiningRound"

# Auth users
SHARED_SECRET_USER_APP_PROVIDER="$SHARED_SECRET_APP_PROVIDER_USER"
SHARED_SECRET_USER_APP_USER="$SHARED_SECRET_APP_USER_USER"
CBTC_NETWORK_USER="cbtc-network-user"

# Output file
HOLDINGS_FILE="$SCRIPT_DIR/lp-holdings.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[fund-lp] $*"
}

log_error() {
  echo "[fund-lp] ERROR: $*" >&2
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

# Submit-and-wait for internal parties (no interactive submission needed)
submit_and_wait() {
  local commands_json="$1"
  local act_as_party="$2"
  local cmd_id_prefix="$3"
  local disclosed_json="${4:-[]}"
  local json_api="$5"
  local auth_token="$6"
  local user_id="$7"

  local cmd_id="${cmd_id_prefix}-${RUN_ID}-${RANDOM}${RANDOM}"

  local body
  body=$(jq -n \
    --argjson commands "$commands_json" \
    --arg cmdId "$cmd_id" \
    --arg userId "$user_id" \
    --arg syncId "$SYNCHRONIZER_ID" \
    --arg party "$act_as_party" \
    --argjson disclosed "$disclosed_json" \
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

  local max_retries=3
  local retry=0
  while [ $retry -lt $max_retries ]; do
    local result
    result=$(curl_check "$json_api/v2/commands/submit-and-wait-for-transaction" "$auth_token" "application/json" \
      --data-raw "$body" 2>&1) && {
      echo "$result"
      return 0
    }

    retry=$((retry + 1))
    if [ $retry -lt $max_retries ]; then
      log "  (submit-and-wait failed, attempt $retry/$max_retries, retrying in 3s...)"
      sleep 3
      # Regenerate command ID for retry
      cmd_id="${cmd_id_prefix}-${RUN_ID}-${RANDOM}${RANDOM}"
      body=$(echo "$body" | jq --arg cmdId "$cmd_id" '.commands.commandId = $cmdId | .commands.submissionId = $cmdId')
    fi
  done

  log_error "submit_and_wait failed after $max_retries attempts"
  return 1
}

# Interactive submission for external parties (CBTC-NETWORK)
interactive_submit() {
  local commands_json="$1"
  local act_as_party="$2"
  local private_key="$3"
  local fingerprint="$4"
  local cmd_id_prefix="$5"
  local disclosed_json="${6:-[]}"
  local json_api="$7"
  local auth_token="$8"
  local user_id="$9"

  local tmp_prepare="/tmp/canton-is-prepare-$$-${RANDOM}.json"
  local tmp_execute_body="/tmp/canton-is-exec-body-$$-${RANDOM}.json"
  local tmp_execute_resp="/tmp/canton-is-exec-resp-$$-${RANDOM}.json"

  local attempt
  for attempt in 1 2 3; do
    local cmd_id="${cmd_id_prefix}-${RUN_ID}-${RANDOM}${RANDOM}"

    local prepare_body
    prepare_body=$(jq -n \
      --argjson commands "$commands_json" \
      --arg cmdId "$cmd_id" \
      --arg userId "$user_id" \
      --arg syncId "$SYNCHRONIZER_ID" \
      --arg party "$act_as_party" \
      --argjson disclosed "$disclosed_json" \
      '{
        commands: $commands,
        commandId: $cmdId,
        userId: $userId,
        actAs: [$party],
        readAs: [],
        disclosedContracts: $disclosed,
        synchronizerId: $syncId,
        verboseHashing: true,
        packageIdSelectionPreference: []
      }')

    local prepare_http
    prepare_http=$(curl -s -S -w "%{http_code}" -o "$tmp_prepare" \
      "$json_api/v2/interactive-submission/prepare" \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      --data-raw "$prepare_body")

    if [ "$prepare_http" != "200" ] && [ "$prepare_http" != "201" ]; then
      if { [ "$prepare_http" = "503" ] || [ "$prepare_http" = "429" ] || [ "$prepare_http" = "409" ]; } && [ "$attempt" -lt 3 ]; then
        log "  (prepare returned $prepare_http, attempt $attempt/3, retrying in 3s...)" >&2
        sleep 3
        continue
      fi
      log_error "Prepare failed with HTTP $prepare_http"
      log_error "Response: $(head -c 500 "$tmp_prepare" 2>/dev/null)"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 1
    fi

    local prepared_hash
    prepared_hash=$(jq -r '.preparedTransactionHash // empty' "$tmp_prepare")

    if [ -z "$prepared_hash" ]; then
      log_error "Prepare response missing preparedTransactionHash"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 1
    fi

    local sig
    sig=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
      const { signTransactionHash } = require('@canton-network/core-signing-lib');
      const signature = signTransactionHash('$prepared_hash', '$private_key');
      process.stdout.write(signature);
    " 2>/dev/null) || sig=""

    if [ -z "$sig" ]; then
      log_error "Failed to sign prepared transaction"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 1
    fi

    local hashing_version
    hashing_version=$(jq -r '.hashingSchemeVersion // empty' "$tmp_prepare")

    jq -n \
      --arg userId "$user_id" \
      --arg submissionId "fund-lp-${cmd_id}" \
      --arg preparedTx "$(jq -r '.preparedTransaction' "$tmp_prepare")" \
      --arg hashVersion "$hashing_version" \
      --arg party "$act_as_party" \
      --arg sig "$sig" \
      --arg signedBy "$fingerprint" \
      '{
        userId: $userId,
        submissionId: $submissionId,
        preparedTransaction: $preparedTx,
        hashingSchemeVersion: $hashVersion,
        partySignatures: {
          signatures: [{
            party: $party,
            signatures: [{
              signature: $sig,
              signedBy: $signedBy,
              format: "SIGNATURE_FORMAT_RAW",
              signingAlgorithmSpec: "SIGNING_ALGORITHM_SPEC_ED25519"
            }]
          }]
        },
        deduplicationPeriod: {Empty: {}}
      }' > "$tmp_execute_body"

    local execute_http
    execute_http=$(curl -s -S -w "%{http_code}" -o "$tmp_execute_resp" \
      "$json_api/v2/interactive-submission/executeAndWaitForTransaction" \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      -d @"$tmp_execute_body")

    if [ "$execute_http" = "200" ] || [ "$execute_http" = "201" ]; then
      cat "$tmp_execute_resp"
      rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
      return 0
    fi
    if { [ "$execute_http" = "503" ] || [ "$execute_http" = "429" ] || [ "$execute_http" = "409" ]; } && [ "$attempt" -lt 3 ]; then
      log "  (execute returned $execute_http, attempt $attempt/3, retrying in 3s...)" >&2
      sleep 3
      continue
    fi
    log_error "Execute failed with HTTP $execute_http"
    log_error "Response: $(head -c 500 "$tmp_execute_resp" 2>/dev/null)"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  done

  log_error "interactive_submit failed after 3 attempts"
  rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
  return 1
}

query_active_contracts_from() {
  local json_api="$1"
  local token="$2"
  local party="$3"
  local template_id="$4"
  local include_blob="${5:-false}"

  local ledger_end
  ledger_end=$(curl_check "$json_api/v2/state/ledger-end" "$token" "application/json" | jq -r '.offset')

  local query_body
  query_body=$(jq -n \
    --arg party "$party" \
    --arg templateId "$template_id" \
    --argjson includeBlob "$include_blob" \
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
                    includeCreatedEventBlob: $includeBlob
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

  curl_check "$json_api/v2/state/active-contracts" "$token" "application/json" \
    --data-raw "$query_body" 2>/dev/null || echo ""
}

##############################################################################
# Pre-flight checks
##############################################################################

log "=========================================="
log "Fund Liquidity Provider"
log "=========================================="
log "  LP: $LP_NAME ($LP_PARTY_HINT)"
log "  LP Party: ${LP_PARTY_ID:0:60}..."
log "  CBTC: $CBTC_TOTAL_AMOUNT ($CBTC_NUM_HOLDINGS holdings)"
log "  Amulet: $AMULET_TOTAL_AMOUNT ($AMULET_NUM_HOLDINGS holdings)"
log ""

# Generate auth tokens
APP_PROVIDER_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER_APP_PROVIDER" "$SHARED_SECRET_AUDIENCE")
APP_USER_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER_APP_USER" "$SHARED_SECRET_AUDIENCE")
SV_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_SV_USER" "$SHARED_SECRET_AUDIENCE")
CBTC_NETWORK_TOKEN=$(generate_canton_jwt "$CBTC_NETWORK_USER" "$SHARED_SECRET_AUDIENCE")

# Get synchronizer ID
SYNCHRONIZER_ID=$(curl_check "$APP_PROVIDER_JSON_API/v2/state/connected-synchronizers" "$APP_PROVIDER_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

# Get DSO party
DSO_PARTY=$(curl_check "$APP_USER_VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" "$APP_USER_TOKEN" "application/json" \
  | jq -r '.dso_party_id // empty')

if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party"
  exit 1
fi
log "  DSO: ${DSO_PARTY:0:50}..."

CBTC_HOLDINGS=()
AMULET_HOLDINGS=()

##############################################################################
# Step 1: Mint CBTC tokens
##############################################################################

log ""
log "Step 1: Minting $CBTC_TOTAL_AMOUNT CBTC ($CBTC_NUM_HOLDINGS holdings)..."

CBTC_PER_HOLDING=$((CBTC_TOTAL_AMOUNT / CBTC_NUM_HOLDINGS))
MINT_REQUESTS=()

# Step 1a: Create mint requests (LP party signs via submit-and-wait on app-provider)
log "  Creating $CBTC_NUM_HOLDINGS mint requests..."
for i in $(seq 1 "$CBTC_NUM_HOLDINGS"); do
  REQUESTED_AT=$(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ")
  EXECUTE_BEFORE=$(date -u -v+1d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+1 day" +"%Y-%m-%dT%H:%M:%SZ")

  CMD_JSON=$(jq -n \
    --arg contractId "$ALLOCATION_FACTORY_CID" \
    --arg templateId "$ALLOCATION_FACTORY_TEMPLATE" \
    --arg admin "$CBTC_NETWORK_PARTY" \
    --arg tokenId "$CBTC_TOKEN_ID" \
    --arg holder "$LP_PARTY_ID" \
    --arg amount "${CBTC_PER_HOLDING}.0" \
    --arg reference "lp-mint-${LP_PARTY_HINT}-${i}" \
    --arg requestedAt "$REQUESTED_AT" \
    --arg executeBefore "$EXECUTE_BEFORE" \
    --arg icCid "$INSTRUMENT_CONFIG_CID" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
        contractId: $contractId,
        choice: "AllocationFactory_RequestMint",
        choiceArgument: {
          expectedAdmin: $admin,
          mint: {
            instrumentId: { admin: $admin, id: $tokenId },
            amount: $amount,
            holder: $holder,
            reference: $reference,
            requestedAt: $requestedAt,
            executeBefore: $executeBefore,
            meta: { values: {} }
          },
          extraArgs: {
            context: {
              values: {
                "utility.digitalasset.com/instrument-configuration": { tag: "AV_ContractId", value: $icCid },
                "utility.digitalasset.com/issuer-credentials": { tag: "AV_List", value: [] }
              }
            },
            meta: { values: {} }
          }
        }
      }
    }]')

  TX_RESULT=$(submit_and_wait "$CMD_JSON" "$LP_PARTY_ID" "lp-mint-req-$i" \
    "$CBTC_DISCLOSED_CONTRACTS" "$APP_PROVIDER_JSON_API" "$APP_PROVIDER_TOKEN" "$SHARED_SECRET_USER_APP_PROVIDER") || {
    log_error "Failed to create mint request #$i"
    exit 1
  }

  MINT_CID=$(echo "$TX_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("MintRequest")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$MINT_CID" ]; then
    log_error "Could not extract MintRequest CID for mint #$i"
    log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
    exit 1
  fi

  MINT_REQUESTS+=("$MINT_CID")
  if [ $((i % 5)) -eq 0 ] || [ "$i" -eq "$CBTC_NUM_HOLDINGS" ]; then
    log "    Created $i/$CBTC_NUM_HOLDINGS mint requests"
  fi
done

# Step 1b: CBTC-NETWORK accepts all mint requests (interactive submission on app-user)
log "  CBTC-NETWORK accepting ${#MINT_REQUESTS[@]} mint requests..."
ACCEPT_COUNT=0

for MINT_CID in "${MINT_REQUESTS[@]}"; do
  ACCEPT_COUNT=$((ACCEPT_COUNT + 1))

  CMD_JSON=$(jq -n \
    --arg contractId "$MINT_CID" \
    --arg templateId "$MINT_REQUEST_TEMPLATE" \
    --arg icCid "$INSTRUMENT_CONFIG_CID" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
        contractId: $contractId,
        choice: "MintRequest_Accept",
        choiceArgument: {
          extraArgs: {
            context: {
              values: {
                "utility.digitalasset.com/instrument-configuration": { tag: "AV_ContractId", value: $icCid },
                "utility.digitalasset.com/issuer-credentials": { tag: "AV_List", value: [] }
              }
            },
            meta: { values: {} }
          }
        }
      }
    }]')

  TX_RESULT=$(interactive_submit "$CMD_JSON" "$CBTC_NETWORK_PARTY" "$CBTC_PRIV_KEY" "$CBTC_FP" \
    "lp-accept-mint-$ACCEPT_COUNT" "[]" "$APP_USER_JSON_API" "$CBTC_NETWORK_TOKEN" "$CBTC_NETWORK_USER") || {
    log_error "Failed to accept mint request $MINT_CID"
    exit 1
  }

  HOLDING_CID=$(echo "$TX_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("Holding:Holding")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$HOLDING_CID" ]; then
    log_error "Could not extract Holding CID for mint $MINT_CID"
    exit 1
  fi

  CBTC_HOLDINGS+=("$HOLDING_CID|$CBTC_PER_HOLDING")
  if [ $((ACCEPT_COUNT % 5)) -eq 0 ] || [ "$ACCEPT_COUNT" -eq "${#MINT_REQUESTS[@]}" ]; then
    log "    Accepted $ACCEPT_COUNT/${#MINT_REQUESTS[@]}"
  fi
done

log "  CBTC minting complete: ${#CBTC_HOLDINGS[@]} holdings, total ${CBTC_TOTAL_AMOUNT} CBTC"

##############################################################################
# Step 2: Faucet Amulet tokens
##############################################################################

log ""
log "Step 2: Tapping $AMULET_TOTAL_AMOUNT Amulet ($AMULET_NUM_HOLDINGS holdings)..."

# Fetch AmuletRules + OpenMiningRound from SV participant (for disclosed contracts)
log "  Fetching AmuletRules + OpenMiningRound from SV..."

AMULET_RULES_RESPONSE=$(query_active_contracts_from "$SV_JSON_API" "$SV_TOKEN" \
  "$DSO_PARTY" "$AMULET_RULES_TEMPLATE" "true")

AMULET_RULES_CID=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
' 2>/dev/null || echo "")
AMULET_RULES_TEMPLATE_HASH=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
' 2>/dev/null || echo "")
AMULET_RULES_BLOB=$(echo "$AMULET_RULES_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.createdEventBlob][0] // empty
' 2>/dev/null || echo "")

if [ -z "$AMULET_RULES_CID" ] || [ -z "$AMULET_RULES_BLOB" ]; then
  log_error "Could not fetch AmuletRules from SV"
  exit 1
fi
log "  AmuletRules: ${AMULET_RULES_CID:0:40}..."

OPEN_ROUND_RESPONSE=$(query_active_contracts_from "$SV_JSON_API" "$SV_TOKEN" \
  "$DSO_PARTY" "$OPEN_MINING_ROUND_TEMPLATE" "true")

OPEN_ROUND_CID=$(echo "$OPEN_ROUND_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
   | {contractId, round: (.createArguments.round // .createArguments.round.number // 0)}]
  | sort_by(.round) | last | .contractId // empty
' 2>/dev/null || echo "")
OPEN_ROUND_TEMPLATE_HASH=$(echo "$OPEN_ROUND_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.templateId][0] // empty
' 2>/dev/null || echo "")
OPEN_ROUND_BLOB=$(echo "$OPEN_ROUND_RESPONSE" | jq -r '
  [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent
   | {createdEventBlob, round: (.createArguments.round // .createArguments.round.number // 0)}]
  | sort_by(.round) | last | .createdEventBlob // empty
' 2>/dev/null || echo "")

if [ -z "$OPEN_ROUND_CID" ] || [ -z "$OPEN_ROUND_BLOB" ]; then
  log_error "Could not fetch OpenMiningRound from SV"
  exit 1
fi
log "  OpenMiningRound: ${OPEN_ROUND_CID:0:40}..."

AMULET_DISCLOSED_CONTRACTS=$(jq -n \
  --arg arCid "$AMULET_RULES_CID" \
  --arg arTemplate "$AMULET_RULES_TEMPLATE_HASH" \
  --arg arBlob "$AMULET_RULES_BLOB" \
  --arg orCid "$OPEN_ROUND_CID" \
  --arg orTemplate "$OPEN_ROUND_TEMPLATE_HASH" \
  --arg orBlob "$OPEN_ROUND_BLOB" \
  --arg syncId "$SYNCHRONIZER_ID" \
  '[
    { contractId: $arCid, templateId: $arTemplate, createdEventBlob: $arBlob, synchronizerId: $syncId },
    { contractId: $orCid, templateId: $orTemplate, createdEventBlob: $orBlob, synchronizerId: $syncId }
  ]')

AMULET_PER_HOLDING=$((AMULET_TOTAL_AMOUNT / AMULET_NUM_HOLDINGS))

log "  Tapping $AMULET_NUM_HOLDINGS times (${AMULET_PER_HOLDING} CC each)..."
for i in $(seq 1 "$AMULET_NUM_HOLDINGS"); do
  CMD_JSON=$(jq -n \
    --arg contractId "$AMULET_RULES_CID" \
    --arg templateId "$AMULET_RULES_TEMPLATE" \
    --arg receiver "$LP_PARTY_ID" \
    --arg amount "${AMULET_PER_HOLDING}.0" \
    --arg openRound "$OPEN_ROUND_CID" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
        contractId: $contractId,
        choice: "AmuletRules_DevNet_Tap",
        choiceArgument: {
          receiver: $receiver,
          amount: $amount,
          openRound: $openRound
        }
      }
    }]')

  TX_RESULT=$(submit_and_wait "$CMD_JSON" "$LP_PARTY_ID" "lp-tap-$i" \
    "$AMULET_DISCLOSED_CONTRACTS" "$APP_PROVIDER_JSON_API" "$APP_PROVIDER_TOKEN" "$SHARED_SECRET_USER_APP_PROVIDER") || {
    log_error "Failed to tap Amulet #$i"
    exit 1
  }

  AMULET_CID=$(echo "$TX_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty)
     | select(.templateId | tostring | test("Splice\\.Amulet:Amulet$"))
     | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  # Fallback: match any Amulet that is NOT AmuletRules/AmuletAllocation
  if [ -z "$AMULET_CID" ]; then
    AMULET_CID=$(echo "$TX_RESULT" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty)
       | select(.templateId | tostring | contains("Amulet"))
       | select(.templateId | tostring | contains("AmuletRules") | not)
       | select(.templateId | tostring | contains("AmuletAllocation") | not)
       | select(.templateId | tostring | contains("AmuletTransfer") | not)
       | .contractId][0] // empty
    ' 2>/dev/null || echo "")
  fi

  if [ -z "$AMULET_CID" ]; then
    log_error "Could not extract Amulet CID for tap #$i"
    log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
    exit 1
  fi

  AMULET_HOLDINGS+=("$AMULET_CID|$AMULET_PER_HOLDING")
  if [ $((i % 10)) -eq 0 ] || [ "$i" -eq "$AMULET_NUM_HOLDINGS" ]; then
    log "    Tapped $i/$AMULET_NUM_HOLDINGS"
  fi
done

log "  Amulet faucet complete: ${#AMULET_HOLDINGS[@]} holdings, total ${AMULET_TOTAL_AMOUNT} CC"

##############################################################################
# Step 3: Write holdings report
##############################################################################

log ""
log "Step 3: Writing holdings report..."

CBTC_HOLDINGS_JSON="[]"
for entry in "${CBTC_HOLDINGS[@]}"; do
  IFS='|' read -r CID AMOUNT <<< "$entry"
  CBTC_HOLDINGS_JSON=$(echo "$CBTC_HOLDINGS_JSON" | jq \
    --arg cid "$CID" \
    --argjson amount "$AMOUNT" \
    '. + [{ contractId: $cid, amount: $amount }]')
done

AMULET_HOLDINGS_JSON="[]"
for entry in "${AMULET_HOLDINGS[@]}"; do
  IFS='|' read -r CID AMOUNT <<< "$entry"
  AMULET_HOLDINGS_JSON=$(echo "$AMULET_HOLDINGS_JSON" | jq \
    --arg cid "$CID" \
    --argjson amount "$AMOUNT" \
    '. + [{ contractId: $cid, amount: $amount }]')
done

jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg lpPartyId "$LP_PARTY_ID" \
  --arg lpName "$LP_NAME" \
  --argjson cbtcHoldings "$CBTC_HOLDINGS_JSON" \
  --argjson cbtcTotal "$CBTC_TOTAL_AMOUNT" \
  --argjson amuletHoldings "$AMULET_HOLDINGS_JSON" \
  --argjson amuletTotal "$AMULET_TOTAL_AMOUNT" \
  '{
    generatedAt: $generatedAt,
    lpPartyId: $lpPartyId,
    lpName: $lpName,
    cbtc: {
      totalAmount: $cbtcTotal,
      holdings: $cbtcHoldings
    },
    amulet: {
      totalAmount: $amuletTotal,
      holdings: $amuletHoldings
    }
  }' > "$HOLDINGS_FILE"

log "  Written to: $HOLDINGS_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "LP Funding Complete!"
log "=========================================="
log ""
log "Summary:"
log "  LP Party: $LP_NAME (${LP_PARTY_ID:0:50}...)"
log "  CBTC: $CBTC_TOTAL_AMOUNT ($CBTC_NUM_HOLDINGS holdings of $CBTC_PER_HOLDING each)"
log "  Amulet: $AMULET_TOTAL_AMOUNT ($AMULET_NUM_HOLDINGS holdings of $AMULET_PER_HOLDING each)"
log "  Holdings: $HOLDINGS_FILE"
log ""
