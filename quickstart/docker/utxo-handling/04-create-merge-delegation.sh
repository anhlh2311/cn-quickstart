#!/bin/bash
# Creates MergeDelegation contracts for each user wallet party.
#
# Two-step process per wallet:
#   1. Owner (user wallet, external party) creates MergeDelegationProposal
#      via interactive submission (signed by wallet's private key)
#   2. Operator (executor party) accepts the proposal via regular submission
#      which creates the MergeDelegation contract
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - 01-generate-user-wallet.sh must have been run successfully
#   - canton-exchange-backend .env must exist (for EXECUTOR_PARTY_ID)
#
# Usage: ./04-create-merge-delegation.sh

set -eo pipefail

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-exchange" && pwd)"

# Load shared configuration from setup-exchange .env
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[merge-delegation] ERROR: $SETUP_DIR/.env not found. Run setup-exchange first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

# Alias for shared-secret user (uses the app-user participant)
SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# Load user wallet keypairs
KEYPAIRS_FILE="$SCRIPT_DIR/user-wallet-keypairs.json"
if [ ! -f "$KEYPAIRS_FILE" ]; then
  echo "[merge-delegation] ERROR: User wallet keypairs not found: $KEYPAIRS_FILE" >&2
  echo "[merge-delegation] Run 01-generate-user-wallet.sh first." >&2
  exit 1
fi

# Get EXECUTOR_PARTY_ID from backend .env (the operator)
BACKEND_ENV="$EXCHANGE_BACKEND_DIR/.env"
if [ ! -f "$BACKEND_ENV" ]; then
  echo "[merge-delegation] ERROR: Backend .env not found: $BACKEND_ENV" >&2
  echo "[merge-delegation] Run 01-setup-exchange.sh first." >&2
  exit 1
fi
OPERATOR_PARTY=$(grep -E '^EXECUTOR_PARTY_ID=' "$BACKEND_ENV" | cut -d= -f2-)

if [ -z "$OPERATOR_PARTY" ]; then
  echo "[merge-delegation] ERROR: EXECUTOR_PARTY_ID not found in $BACKEND_ENV" >&2
  exit 1
fi

NUM_WALLETS=$(jq '.wallets | length' "$KEYPAIRS_FILE")

# Template IDs
PROPOSAL_TEMPLATE_ID="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegationProposal"
DELEGATION_TEMPLATE_ID="#splice-util-token-standard-wallet:Splice.Util.Token.Wallet.MergeDelegation:MergeDelegation"

# Output file
OUTPUT_FILE="$SCRIPT_DIR/user-wallet-merge-delegation.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[merge-delegation] $*"
}

log_error() {
  echo "[merge-delegation] ERROR: $*" >&2
}

# Make an HTTP request with error handling
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

# Generate Canton shared-secret JWT
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

# Interactive submission: prepare -> sign -> execute (for external parties)
# Uses temp files to avoid shell variable corruption with large base64 payloads.
interactive_submit() {
  local party="$1"
  local priv_key="$2"
  local fp="$3"
  local command_json="$4"
  local cmd_id_prefix="$5"

  local cmd_id="${cmd_id_prefix}-$(date +%s)-$RANDOM"
  local tmp_prepare="/tmp/canton-is-prepare-$$-${RANDOM}.json"
  local tmp_execute_body="/tmp/canton-is-exec-body-$$-${RANDOM}.json"
  local tmp_execute_resp="/tmp/canton-is-exec-resp-$$-${RANDOM}.json"

  local prepare_body
  prepare_body=$(jq -n \
    --arg party "$party" \
    --arg cmdId "$cmd_id" \
    --arg userId "$SHARED_SECRET_USER" \
    --arg syncId "$SYNCHRONIZER_ID" \
    --argjson commands "$command_json" \
    '{
      commands: $commands,
      commandId: $cmdId,
      userId: $userId,
      actAs: [$party],
      readAs: [],
      disclosedContracts: [],
      synchronizerId: $syncId,
      verboseHashing: true,
      packageIdSelectionPreference: []
    }')

  local prepare_http
  prepare_http=$(curl -s -S -w "%{http_code}" -o "$tmp_prepare" \
    "$APP_USER_JSON_API/v2/interactive-submission/prepare" \
    -H "Authorization: Bearer $CANTON_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$prepare_body")

  if [ "$prepare_http" != "200" ] && [ "$prepare_http" != "201" ]; then
    log_error "Prepare failed with HTTP $prepare_http"
    log_error "Response: $(head -c 500 "$tmp_prepare" 2>/dev/null)"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi

  local prepared_hash
  prepared_hash=$(jq -r '.preparedTransactionHash // empty' "$tmp_prepare")
  local hashing_version
  hashing_version=$(jq -r '.hashingSchemeVersion // empty' "$tmp_prepare")

  if [ -z "$prepared_hash" ]; then
    log_error "Prepare response missing preparedTransactionHash"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi

  local sig
  sig=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { signTransactionHash } = require('@canton-network/core-signing-lib');
    const signature = signTransactionHash('$prepared_hash', '$priv_key');
    process.stdout.write(signature);
  " 2>/dev/null) || sig=""

  if [ -z "$sig" ]; then
    log_error "Failed to sign prepared transaction"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi

  jq -n \
    --arg userId "$SHARED_SECRET_USER" \
    --arg submissionId "merge-deleg-${cmd_id}" \
    --arg preparedTx "$(jq -r '.preparedTransaction' "$tmp_prepare")" \
    --arg hashVersion "$hashing_version" \
    --arg party "$party" \
    --arg sig "$sig" \
    --arg signedBy "$fp" \
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
    "$APP_USER_JSON_API/v2/interactive-submission/executeAndWaitForTransaction" \
    -H "Authorization: Bearer $CANTON_TOKEN" \
    -H "Content-Type: application/json" \
    -d @"$tmp_execute_body")

  if [ "$execute_http" != "200" ] && [ "$execute_http" != "201" ]; then
    log_error "Execute failed with HTTP $execute_http"
    log_error "Response: $(head -c 500 "$tmp_execute_resp" 2>/dev/null)"
    rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
    return 1
  fi

  cat "$tmp_execute_resp"
  rm -f "$tmp_prepare" "$tmp_execute_body" "$tmp_execute_resp"
}

# Regular submission for non-external parties
# Usage: regular_submit <actAs_party> <command_json> <command_id_prefix>
# Returns: the transaction result JSON
regular_submit() {
  local party="$1"
  local command_json="$2"
  local cmd_id_prefix="$3"

  local cmd_id="${cmd_id_prefix}-$(date +%s%N)"

  local submit_body
  submit_body=$(jq -n \
    --arg party "$party" \
    --arg cmdId "$cmd_id" \
    --arg userId "$SHARED_SECRET_USER" \
    --argjson commands "$command_json" \
    '{
      commands: {
        commands: $commands,
        commandId: $cmdId,
        userId: $userId,
        actAs: [$party],
        readAs: [],
        disclosedContracts: [],
        deduplicationPeriod: {Empty: {}},
        packageIdSelectionPreference: []
      }
    }')

  curl_check "$APP_USER_JSON_API/v2/commands/submit-and-wait-for-transaction" "$CANTON_TOKEN" "application/json" \
    --data-raw "$submit_body" || return 1
}

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Create MergeDelegation Contracts"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Operator (executor): ${OPERATOR_PARTY:0:50}..."
log "  Proposal template: $PROPOSAL_TEMPLATE_ID"
log "  Delegation template: $DELEGATION_TEMPLATE_ID"
log ""

# Generate Canton token for app-user participant
CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

# Get connected synchronizer (needed for interactive submission)
SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

##############################################################################
# Step 1: Create MergeDelegationProposal + Accept for each wallet
##############################################################################

log ""
log "Step 1: Creating MergeDelegation contracts..."

# Array to collect results
DELEGATIONS=()

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r '.partyHint' "$KEYPAIRS_FILE")
  WALLET_NAME=$(jq -r ".wallets[$i].userId" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".wallets[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".wallets[$i].userId" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".wallets[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".wallets[$i].fingerprint" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_NAME..."

  # Step 1a: Owner creates MergeDelegationProposal via interactive submission
  PROPOSAL_CMD=$(jq -n \
    --arg templateId "$PROPOSAL_TEMPLATE_ID" \
    --arg operator "$OPERATOR_PARTY" \
    --arg owner "$WALLET_PARTY" \
    '[{
      CreateCommand: {
        templateId: $templateId,
        createArguments: {
          delegation: {
            operator: $operator,
            owner: $owner,
            meta: { values: {} }
          }
        }
      }
    }]')

  PROPOSAL_RESULT=$(interactive_submit "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" "$PROPOSAL_CMD" "proposal-$WALLET_NAME") || {
    log_error "Failed to create MergeDelegationProposal for $WALLET_NAME"
    exit 1
  }

  # Extract MergeDelegationProposal contract ID from created events
  PROPOSAL_CID=$(echo "$PROPOSAL_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("MergeDelegationProposal")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$PROPOSAL_CID" ]; then
    log_error "Could not extract MergeDelegationProposal contract ID for $WALLET_NAME"
    log_error "Response: $(echo "$PROPOSAL_RESULT" | head -c 500)"
    exit 1
  fi
  log "    Proposal created: ${PROPOSAL_CID:0:40}..."

  # Step 1b: Operator accepts the proposal via regular submission
  ACCEPT_CMD=$(jq -n \
    --arg templateId "$PROPOSAL_TEMPLATE_ID" \
    --arg contractId "$PROPOSAL_CID" \
    '[{
      ExerciseCommand: {
        templateId: $templateId,
        contractId: $contractId,
        choice: "MergeDelegationProposal_Accept",
        choiceArgument: {}
      }
    }]')

  ACCEPT_RESULT=$(regular_submit "$OPERATOR_PARTY" "$ACCEPT_CMD" "accept-$WALLET_NAME") || {
    log_error "Failed to accept MergeDelegationProposal for $WALLET_NAME"
    exit 1
  }

  # Extract MergeDelegation contract ID from created events
  DELEGATION_CID=$(echo "$ACCEPT_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("MergeDelegation") and (contains("Proposal") | not)) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$DELEGATION_CID" ]; then
    log_error "Could not extract MergeDelegation contract ID for $WALLET_NAME"
    log_error "Response: $(echo "$ACCEPT_RESULT" | head -c 500)"
    exit 1
  fi
  log "    MergeDelegation created: ${DELEGATION_CID:0:40}..."

  DELEGATIONS+=("${i}|${DELEGATION_CID}")
done

log ""
log "  All $NUM_WALLETS MergeDelegation contracts created."

##############################################################################
# Step 2: Write output JSON
##############################################################################

log ""
log "Step 2: Writing merge delegation report..."

PARTY_HINT_VALUE=$(jq -r '.partyHint' "$KEYPAIRS_FILE")

REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg partyHint "$PARTY_HINT_VALUE" \
  --arg operatorParty "$OPERATOR_PARTY" \
  --arg templateId "$DELEGATION_TEMPLATE_ID" \
  --argjson totalDelegations "${#DELEGATIONS[@]}" \
  '{
    generatedAt: $generatedAt,
    partyHint: $partyHint,
    operatorParty: $operatorParty,
    mergeDelegationTemplateId: $templateId,
    totalDelegations: $totalDelegations,
    wallets: []
  }')

for entry in "${DELEGATIONS[@]}"; do
  IFS='|' read -r WALLET_IDX DELEGATION_CID <<< "$entry"

  WALLET_PARTY=$(jq -r ".wallets[$WALLET_IDX].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".wallets[$WALLET_IDX].userId" "$KEYPAIRS_FILE")

  REPORT_JSON=$(echo "$REPORT_JSON" | jq \
    --arg partyId "$WALLET_PARTY" \
    --arg userId "$WALLET_USER" \
    --arg delegationCid "$DELEGATION_CID" \
    '.wallets += [{
      partyId: $partyId,
      userId: $userId,
      mergeDelegationContractId: $delegationCid
    }]')
done

echo "$REPORT_JSON" | jq '.' > "$OUTPUT_FILE"

log "  Report written to: $OUTPUT_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "MergeDelegation Creation Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Operator: $OPERATOR_PARTY"
log "  Delegations created: ${#DELEGATIONS[@]}"
log "  Template: $DELEGATION_TEMPLATE_ID"
log "  Output file: $OUTPUT_FILE"
log ""
