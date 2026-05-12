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
#   PARTIES_FILE=./internal-parties.mainnet.json ./02-create-transfer-preapprovals.sh
#   OUTPUT_FILE=./transfer-preapprovals.mainnet.json ./02-create-transfer-preapprovals.sh
#   POLL_TIMEOUT=120 ./02-create-transfer-preapprovals.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Save caller-provided env vars before sourcing .env (CLI overrides take precedence)
_cli_PARTICIPANT_JSON_API="${PARTICIPANT_JSON_API:-}"
_cli_VALIDATOR_API="${VALIDATOR_API:-}"
_cli_AUTH_MODE="${AUTH_MODE:-}"
_cli_POLL_TIMEOUT="${POLL_TIMEOUT:-}"
_cli_PARTIES_FILE="${PARTIES_FILE:-}"
_cli_OUTPUT_FILE="${OUTPUT_FILE:-}"

# Load configuration from .env
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

# CLI overrides > .env > defaults
PARTICIPANT_JSON_API="${_cli_PARTICIPANT_JSON_API:-${PARTICIPANT_JSON_API:-http://localhost:2975}}"
VALIDATOR_API="${_cli_VALIDATOR_API:-${VALIDATOR_API:-http://localhost:2903}}"
AUTH_MODE="${_cli_AUTH_MODE:-${AUTH_MODE:-shared-secret}}"
# Max seconds to wait for validator to accept each proposal
POLL_TIMEOUT="${_cli_POLL_TIMEOUT:-${POLL_TIMEOUT:-300}}"

# Source shared auth helpers
source "$SCRIPT_DIR/auth.sh"

PARTIES_FILE="${_cli_PARTIES_FILE:-${PARTIES_FILE:-$SCRIPT_DIR/internal-parties.json}}"
OUTPUT_FILE="${_cli_OUTPUT_FILE:-${OUTPUT_FILE:-$SCRIPT_DIR/transfer-preapprovals.json}}"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[transfer-preapproval] $*"
}

log_error() {
  echo "[transfer-preapproval] ERROR: $*" >&2
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
PROVIDER_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$PARTICIPANT_JSON_API/v2/users/$ADMIN_USER" 2>/dev/null || echo "")
PROVIDER_HTTP=$(echo "$PROVIDER_RESP" | tail -n1 | tr -d '\r')
PROVIDER_BODY=$(echo "$PROVIDER_RESP" | sed '$d')

if [ "$PROVIDER_HTTP" != "200" ]; then
  log_error "Could not resolve provider party from user $ADMIN_USER (HTTP $PROVIDER_HTTP)"
  log_error "Response: $(echo "$PROVIDER_BODY" | head -c 300)"
  exit 1
fi
PROVIDER_PARTY=$(echo "$PROVIDER_BODY" | jq -r '.user.primaryParty // empty')
if [ -z "$PROVIDER_PARTY" ]; then
  log_error "User $ADMIN_USER has no primaryParty set"
  exit 1
fi
log "  Provider (validator) party: ${PROVIDER_PARTY:0:50}..."

# Resolve DSO party from validator API
DSO_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $VALIDATOR_TOKEN" \
  -H "Content-Type: application/json" \
  "$VALIDATOR_API/api/validator/v0/scan-proxy/dso-party-id" 2>/dev/null || echo "")
DSO_HTTP=$(echo "$DSO_RESP" | tail -n1 | tr -d '\r')
DSO_BODY=$(echo "$DSO_RESP" | sed '$d')

if [ "$DSO_HTTP" != "200" ]; then
  log_error "Could not resolve DSO party from validator API (HTTP $DSO_HTTP)"
  log_error "Response: $(echo "$DSO_BODY" | head -c 300)"
  exit 1
fi
DSO_PARTY=$(echo "$DSO_BODY" | jq -r '.dso_party_id // empty')
if [ -z "$DSO_PARTY" ]; then
  log_error "DSO party ID not found in validator response"
  exit 1
fi
log "  DSO party: ${DSO_PARTY:0:50}..."

# Get synchronizer ID
SYNC_RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$PARTICIPANT_JSON_API/v2/state/connected-synchronizers" 2>/dev/null || echo "")
SYNC_HTTP=$(echo "$SYNC_RESP" | tail -n1 | tr -d '\r')
SYNC_BODY=$(echo "$SYNC_RESP" | sed '$d')

if [ "$SYNC_HTTP" != "200" ]; then
  log_error "Could not get connected synchronizers (HTTP $SYNC_HTTP)"
  log_error "Response: $(echo "$SYNC_BODY" | head -c 300)"
  exit 1
fi
SYNCHRONIZER_ID=$(echo "$SYNC_BODY" | jq -r '.connectedSynchronizers[0].synchronizerId // empty')
if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "No connected synchronizers found"
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
    # Ensure admin user has ActAs/ReadAs rights for this party (idempotent).
    # In OAuth2 mode, get_user_token returns the admin token, so the admin user
    # needs CanActAs to submit commands with actAs: [party].
    RIGHTS_RESP=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      "$PARTICIPANT_JSON_API/v2/users/$ADMIN_USER/rights" \
      --data-raw "$(jq -n \
        --arg userId "$ADMIN_USER" \
        --arg party "$PARTY_ID" \
        '{
          userId: $userId,
          identityProviderId: "",
          rights: [
            {kind: {CanActAs: {value: {party: $party}}}},
            {kind: {CanReadAs: {value: {party: $party}}}}
          ]
        }')" 2>/dev/null || echo "")
    RIGHTS_HTTP=$(echo "$RIGHTS_RESP" | tail -n1 | tr -d '\r')
    if [ "$RIGHTS_HTTP" != "200" ] && [ "$RIGHTS_HTTP" != "201" ] && [ "$RIGHTS_HTTP" != "204" ]; then
      RIGHTS_BODY=$(echo "$RIGHTS_RESP" | sed '$d')
      log "  WARNING: Failed to grant admin ($ADMIN_USER) rights for $PARTY_HINT (HTTP $RIGHTS_HTTP)"
      log "    Response: $(echo "$RIGHTS_BODY" | head -c 200)"
      log "    Proposal submission may fail with 403. Continuing anyway..."
    fi

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

    SUBMIT_RESP=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $USER_TOKEN" \
      -H "Content-Type: application/json" \
      "$PARTICIPANT_JSON_API/v2/commands/submit-and-wait-for-transaction" \
      --data-raw "$PROPOSAL_BODY" 2>/dev/null || echo "")
    SUBMIT_HTTP=$(echo "$SUBMIT_RESP" | tail -n1 | tr -d '\r')
    SUBMIT_BODY=$(echo "$SUBMIT_RESP" | sed '$d')

    if [ "$SUBMIT_HTTP" != "200" ] && [ "$SUBMIT_HTTP" != "201" ]; then
      log_error "Failed to create TransferPreapprovalProposal for $PARTY_HINT (HTTP $SUBMIT_HTTP)"
      log_error "Response: $(echo "$SUBMIT_BODY" | head -c 500)"
      SKIPPED=$((${SKIPPED:-0} + 1))
      continue
    fi

    PROPOSAL_CID=$(echo "$SUBMIT_BODY" | jq -r '
      [.transaction.events[] | select(.CreatedEvent) | .CreatedEvent.contractId][0] // empty
    ')

    if [ -z "$PROPOSAL_CID" ]; then
      log_error "No contract ID in proposal creation response for $PARTY_HINT"
      log_error "Response: $(echo "$SUBMIT_BODY" | head -c 300)"
      SKIPPED=$((${SKIPPED:-0} + 1))
      continue
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
