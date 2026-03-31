#!/bin/bash
# Creates TransferPreapproval contracts for internal parties.
#
# For each party in internal-parties.json:
#   1. Creates a TransferPreapprovalProposal (receiver=party, provider=validator party)
#   2. Waits for the validator automation to accept the proposal and create
#      the TransferPreapproval contract
#   3. Records the TransferPreapproval contract ID in the output file
#
# The validator's AcceptTransferPreapprovalProposalTrigger automatically accepts
# proposals by exercising AmuletRules_CreateTransferPreapproval and paying the
# preapproval fee from validator's treasury.
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - 01-allocate-internal-parties.sh must have been run
#
# Usage:
#   ./02-create-transfer-preapprovals.sh
#   POLL_TIMEOUT=120 ./02-create-transfer-preapprovals.sh

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
VALIDATOR_API="${VALIDATOR_API:-http://localhost:2903}"
AUTH_MODE="${AUTH_MODE:-shared-secret}"
# Max seconds to wait for validator to accept each proposal
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"

# Source shared auth helpers
source "$SCRIPT_DIR/auth.sh"

PARTIES_FILE="$SCRIPT_DIR/internal-parties.json"
OUTPUT_FILE="$SCRIPT_DIR/transfer-preapprovals.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[transfer-preapproval] $*"
}

log_error() {
  echo "[transfer-preapproval] ERROR: $*" >&2
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

##############################################################################
# Pre-flight checks
##############################################################################

log "=========================================="
log "Create Transfer Preapprovals"
log "=========================================="

if [ ! -f "$PARTIES_FILE" ]; then
  log_error "Parties file not found: $PARTIES_FILE"
  log_error "Run 01-allocate-internal-parties.sh first."
  exit 1
fi

TOTAL_PARTIES=$(jq '.parties | length' "$PARTIES_FILE")
log "  Parties: $TOTAL_PARTIES"
log "  Participant: $PARTICIPANT_JSON_API"
log "  Validator: $VALIDATOR_API"
log "  Auth mode: $AUTH_MODE"
log "  Poll timeout: ${POLL_TIMEOUT}s per party"
log ""

TOKEN=$(get_participant_token)
VALIDATOR_TOKEN=$(get_validator_token)

# Resolve the validator (provider) party — the primary party of the admin user
ADMIN_USER="${ADMIN_USER:-${SHARED_SECRET_USER:-ledger-api-user}}"
PROVIDER_PARTY=$(curl_check "$PARTICIPANT_JSON_API/v2/users/$ADMIN_USER" "$TOKEN" "application/json" \
  | jq -r '.user.primaryParty // empty')

if [ -z "$PROVIDER_PARTY" ]; then
  log_error "Could not resolve provider (validator) party from user $ADMIN_USER"
  exit 1
fi
log "  Provider (validator) party: ${PROVIDER_PARTY:0:50}..."

# Resolve DSO party from validator API
DSO_PARTY=$(curl_check "$VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" "$VALIDATOR_TOKEN" "application/json" \
  | jq -r '.dso_party_id // empty')

if [ -z "$DSO_PARTY" ]; then
  log_error "Could not resolve DSO party from validator API"
  exit 1
fi
log "  DSO party: ${DSO_PARTY:0:50}..."

# Get synchronizer ID
SYNCHRONIZER_ID=$(curl_check "$PARTICIPANT_JSON_API/v2/state/connected-synchronizers" "$TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

# Initialize output file
jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg participant "$PARTICIPANT_JSON_API" \
  --arg provider "$PROVIDER_PARTY" \
  --arg dso "$DSO_PARTY" \
  '{
    generatedAt: $generatedAt,
    participantJsonApi: $participant,
    providerParty: $provider,
    dsoParty: $dso,
    preapprovals: []
  }' > "$OUTPUT_FILE"

##############################################################################
# Step 1: Create TransferPreapprovalProposal for each party
##############################################################################

log ""
log "Step 1: Creating TransferPreapprovalProposals and waiting for acceptance..."

PROPOSAL_TEMPLATE="#splice-wallet:Splice.Wallet.TransferPreapproval:TransferPreapprovalProposal"

for i in $(seq 0 $((TOTAL_PARTIES - 1))); do
  PARTY_HINT=$(jq -r ".parties[$i].partyHint" "$PARTIES_FILE")
  PARTY_ID=$(jq -r ".parties[$i].partyId" "$PARTIES_FILE")
  USER_ID=$(jq -r ".parties[$i].userId" "$PARTIES_FILE")

  # Check if preapproval already exists via validator API
  EXISTING=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $VALIDATOR_TOKEN" \
    "$VALIDATOR_API/api/validator/v0/admin/transfer-preapprovals/by-party/$PARTY_ID" 2>/dev/null || echo "")
  EXISTING_HTTP=$(echo "$EXISTING" | tail -n1 | tr -d '\r')
  EXISTING_BODY=$(echo "$EXISTING" | sed '$d')

  if [ "$EXISTING_HTTP" = "200" ] && echo "$EXISTING_BODY" | jq -e '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id' > /dev/null 2>&1; then
    PREAPPROVAL_CID=$(echo "$EXISTING_BODY" | jq -r '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id')
    log "  [$((i+1))/$TOTAL_PARTIES] $PARTY_HINT: preapproval already exists: ${PREAPPROVAL_CID:0:40}..."
  else
    # Get a token to submit as the receiver party
    USER_TOKEN=$(get_user_token "$USER_ID")

    # Create TransferPreapprovalProposal
    CMD_ID="transfer-preapproval-proposal-${PARTY_HINT}-$(date +%s)-$RANDOM"

    PROPOSAL_BODY=$(jq -n \
      --arg cmdId "$CMD_ID" \
      --arg party "$PARTY_ID" \
      --arg provider "$PROVIDER_PARTY" \
      --arg dso "$DSO_PARTY" \
      --arg templateId "$PROPOSAL_TEMPLATE" \
      '{
        commands: {
          commands: [{
            CreateCommand: {
              templateId: $templateId,
              createArguments: {
                receiver: $party,
                provider: $provider,
                expectedDso: $dso
              }
            }
          }],
          workflowId: "setup-transfer-preapproval",
          applicationId: "setup-internal-parties",
          commandId: $cmdId,
          deduplicationPeriod: { Empty: {} },
          actAs: [$party],
          readAs: [],
          submissionId: $cmdId,
          disclosedContracts: [],
          domainId: "",
          packageIdSelectionPreference: []
        }
      }')

    SUBMIT_RESULT=$(curl_check "$PARTICIPANT_JSON_API/v2/commands/submit-and-wait-for-transaction" \
      "$USER_TOKEN" "application/json" --data-raw "$PROPOSAL_BODY") || {
      log_error "Failed to create TransferPreapprovalProposal for $PARTY_HINT"
      exit 1
    }

    PROPOSAL_CID=$(echo "$SUBMIT_RESULT" | jq -r '
      [.transaction.events[] | select(.CreatedEvent) | .CreatedEvent.contractId][0] // empty
    ')

    if [ -z "$PROPOSAL_CID" ]; then
      log_error "No contract ID in proposal creation response for $PARTY_HINT"
      exit 1
    fi

    log "  [$((i+1))/$TOTAL_PARTIES] $PARTY_HINT: proposal created: ${PROPOSAL_CID:0:40}..."

    # Poll for the accepted TransferPreapproval
    # Tries both: (1) validator admin API and (2) direct ledger query
    log "    Waiting for validator to accept proposal (timeout: ${POLL_TIMEOUT}s)..."
    PREAPPROVAL_CID=""
    ELAPSED=0
    POLL_INTERVAL=5

    while [ $ELAPSED -lt $POLL_TIMEOUT ]; do
      # Method 1: Try validator admin API
      POLL_RESP=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $VALIDATOR_TOKEN" \
        "$VALIDATOR_API/api/validator/v0/admin/transfer-preapprovals/by-party/$PARTY_ID" 2>/dev/null || echo "")
      POLL_HTTP=$(echo "$POLL_RESP" | tail -n1 | tr -d '\r')
      POLL_BODY=$(echo "$POLL_RESP" | sed '$d')

      if [ "$POLL_HTTP" = "200" ] && echo "$POLL_BODY" | jq -e '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id' > /dev/null 2>&1; then
        PREAPPROVAL_CID=$(echo "$POLL_BODY" | jq -r '.transfer_preapproval.contract_id // .transfer_preapproval.contract.contract_id')
        break
      fi

      # Method 2: Query ledger directly for TransferPreapproval contract
      LEDGER_OFFSET=$(curl -s "$PARTICIPANT_JSON_API/v2/state/ledger-end" \
        -H "Authorization: Bearer $TOKEN" | jq -r '.offset // empty' 2>/dev/null || echo "")
      if [ -n "$LEDGER_OFFSET" ]; then
        LEDGER_QUERY=$(jq -n --arg party "$PARTY_ID" --arg offset "$LEDGER_OFFSET" '{
          filter: { filtersByParty: { ($party): { cumulative: [{ identifierFilter: { TemplateFilter: { value: {
            templateId: "#splice-amulet:Splice.AmuletRules:TransferPreapproval",
            includeCreatedEventBlob: false }}}}]}}},
          verbose: false, activeAtOffset: $offset }')
        LEDGER_RESP=$(curl -s "$PARTICIPANT_JSON_API/v2/state/active-contracts" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d "$LEDGER_QUERY" 2>/dev/null || echo "")
        PREAPPROVAL_CID=$(echo "$LEDGER_RESP" | jq -r '
          [.[] | select(.contractEntry.JsActiveContract) | .contractEntry.JsActiveContract.createdEvent.contractId][0] // empty
        ' 2>/dev/null || echo "")
        if [ -n "$PREAPPROVAL_CID" ]; then
          break
        fi
      fi

      sleep $POLL_INTERVAL
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
      # Log progress every 30s
      if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        log "    Still waiting... (${ELAPSED}s / ${POLL_TIMEOUT}s)"
      fi
    done

    if [ -z "$PREAPPROVAL_CID" ]; then
      log "    WARNING: Timeout after ${POLL_TIMEOUT}s for $PARTY_HINT. Skipping — re-run to retry."
      SKIPPED=$((${SKIPPED:-0} + 1))
      continue
    fi

    log "    Accepted! TransferPreapproval: ${PREAPPROVAL_CID:0:40}..."
  fi

  # Record in output file
  jq --arg partyId "$PARTY_ID" \
    --arg hint "$PARTY_HINT" \
    --arg userId "$USER_ID" \
    --arg preapprovalCid "$PREAPPROVAL_CID" \
    '.preapprovals += [{
      partyHint: $hint,
      partyId: $partyId,
      userId: $userId,
      transferPreapprovalCid: $preapprovalCid
    }]' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp" \
    && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
done

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Transfer Preapprovals Complete!"
log "=========================================="
log ""
COMPLETED=$(jq '.preapprovals | length' "$OUTPUT_FILE")
log "Summary:"
log "  Completed: $COMPLETED / $TOTAL_PARTIES"
if [ "${SKIPPED:-0}" -gt 0 ]; then
  log "  Skipped (timeout): $SKIPPED — re-run the script to retry"
fi
log "  Provider: ${PROVIDER_PARTY:0:50}..."
log "  Output file: $OUTPUT_FILE"
log ""
log "Preapprovals:"
jq -r '.preapprovals[] | "  \(.partyHint): \(.transferPreapprovalCid)"' "$OUTPUT_FILE"
log ""
