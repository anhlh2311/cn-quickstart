#!/bin/bash
# Generates 25 "farming wallet" external parties, mints CBTC tokens for each,
# and writes a holdings report to JSON.
#
# This script:
#   1. Generates 25 Ed25519 keypairs (NaCl format)
#   2. Onboards 25 external parties via generate-topology + sign + allocate
#   3. Creates 25 Canton users with ActAs/ReadAs rights
#   4. Creates 20 TokenMintRequest contracts per wallet (500 total, 100-1000 CBTC each)
#   5. CBTC-NETWORK accepts all mint requests via AcceptMint
#   6. Writes farming-wallet-holdings.json with all holdings
#
# Prerequisites:
#   - quickstart must be running (cd quickstart && make start)
#   - 03-register-cbtc-token.sh must have been run successfully
#
# Usage: ./generate-farming-wallets.sh

set -eo pipefail

NUM_WALLETS=25
MINTS_PER_WALLET=20
MIN_AMOUNT=100
MAX_AMOUNT=1000

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-exchange" && pwd)"

# Load shared configuration from setup-exchange .env
if [ ! -f "$SETUP_DIR/.env" ]; then
  echo "[farming] ERROR: $SETUP_DIR/.env not found. Run setup-exchange first." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SETUP_DIR/.env"

# Load CBTC configuration
CBTC_CONFIG_FILE="$SETUP_DIR/cbtc-config.json"
if [ ! -f "$CBTC_CONFIG_FILE" ]; then
  echo "[farming] ERROR: CBTC config not found: $CBTC_CONFIG_FILE" >&2
  echo "[farming] Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
CBTC_TOKEN_ID=$(jq -r '.tokenId' "$CBTC_CONFIG_FILE")

# Load CBTC-NETWORK keypair
CBTC_KEYPAIR_FILE="$SETUP_DIR/cbtc-network-keypair.json"
if [ ! -f "$CBTC_KEYPAIR_FILE" ]; then
  echo "[farming] ERROR: CBTC-NETWORK keypair not found: $CBTC_KEYPAIR_FILE" >&2
  echo "[farming] Run 03-register-cbtc-token.sh first." >&2
  exit 1
fi
CBTC_NETWORK_PARTY=$(jq -r '.partyId' "$CBTC_KEYPAIR_FILE")
CBTC_PRIV_KEY=$(jq -r '.privateKey' "$CBTC_KEYPAIR_FILE")
CBTC_PUB_KEY=$(jq -r '.publicKey' "$CBTC_KEYPAIR_FILE")
CBTC_FP=$(jq -r '.fingerprint' "$CBTC_KEYPAIR_FILE")

if [ -z "$CBTC_NETWORK_PARTY" ] || [ "$CBTC_NETWORK_PARTY" = "null" ]; then
  echo "[farming] ERROR: CBTC-NETWORK partyId is empty in $CBTC_KEYPAIR_FILE" >&2
  exit 1
fi

# Alias for shared-secret user (uses the app-user participant)
SHARED_SECRET_USER="$SHARED_SECRET_APP_USER_USER"

# Output files
KEYPAIRS_FILE="$SCRIPT_DIR/farming-wallet-keypairs.json"
HOLDINGS_FILE="$SCRIPT_DIR/farming-wallet-holdings.json"

##############################################################################
# Helper Functions
##############################################################################

log() {
  echo "[farming] $*"
}

log_error() {
  echo "[farming] ERROR: $*" >&2
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

# Make an HTTP request returning status code (no error on non-2xx)
curl_status_code() {
  local url=$1
  local token=$2
  local content_type=${3:-application/json}

  curl -s -o /dev/null -w "%{http_code}" "$url" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: $content_type"
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

# Interactive submission: prepare → sign → execute
# Usage: interactive_submit <actAs_party> <private_key> <fingerprint> <command_json> <command_id_prefix>
# Returns: the transaction result JSON
interactive_submit() {
  local party="$1"
  local priv_key="$2"
  local fp="$3"
  local command_json="$4"
  local cmd_id_prefix="$5"

  local cmd_id="${cmd_id_prefix}-$(date +%s%N)"

  # Prepare
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

  local prepare_result
  prepare_result=$(curl_check "$APP_USER_JSON_API/v2/interactive-submission/prepare" "$CANTON_TOKEN" "application/json" \
    --data-raw "$prepare_body") || return 1

  local prepared_tx
  prepared_tx=$(echo "$prepare_result" | jq -r '.preparedTransaction // empty')
  local prepared_hash
  prepared_hash=$(echo "$prepare_result" | jq -r '.preparedTransactionHash // empty')
  local hashing_version
  hashing_version=$(echo "$prepare_result" | jq -r '.hashingSchemeVersion // empty')

  if [ -z "$prepared_tx" ] || [ -z "$prepared_hash" ]; then
    log_error "Prepare response missing required fields"
    return 1
  fi

  # Sign
  local signature
  signature=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { signTransactionHash } = require('@canton-network/core-signing-lib');
    const signature = signTransactionHash('$prepared_hash', '$priv_key');
    process.stdout.write(signature);
  " 2>/dev/null) || signature=""

  if [ -z "$signature" ]; then
    log_error "Failed to sign prepared transaction"
    return 1
  fi

  # Execute
  local execute_body
  execute_body=$(jq -n \
    --arg userId "$SHARED_SECRET_USER" \
    --arg submissionId "farming-$cmd_id" \
    --arg preparedTx "$prepared_tx" \
    --arg hashVersion "$hashing_version" \
    --arg party "$party" \
    --arg sig "$signature" \
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
    }')

  curl_check "$APP_USER_JSON_API/v2/interactive-submission/executeAndWaitForTransaction" "$CANTON_TOKEN" "application/json" \
    --data-raw "$execute_body" || return 1
}

##############################################################################
# Step 0: Pre-flight checks
##############################################################################

log "=========================================="
log "Generate Farming Wallets"
log "=========================================="
log "  Wallets: $NUM_WALLETS"
log "  Mints per wallet: $MINTS_PER_WALLET"
log "  Amount range: $MIN_AMOUNT - $MAX_AMOUNT CBTC"
log "  CBTC-NETWORK party: ${CBTC_NETWORK_PARTY:0:50}..."
log ""

# Generate Canton token for app-user participant
CANTON_TOKEN=$(generate_canton_jwt "$SHARED_SECRET_USER" "$SHARED_SECRET_AUDIENCE")

# Get connected synchronizer
SYNCHRONIZER_ID=$(curl_check "$APP_USER_JSON_API/v2/state/connected-synchronizers" "$CANTON_TOKEN" "application/json" \
  | jq -r '.connectedSynchronizers[0].synchronizerId // empty')

if [ -z "$SYNCHRONIZER_ID" ]; then
  log_error "Could not get connected synchronizer"
  exit 1
fi
log "  Synchronizer: ${SYNCHRONIZER_ID:0:40}..."

##############################################################################
# Step 1: Generate 25 Ed25519 keypairs (idempotent)
##############################################################################

log ""
log "Step 1: Generating $NUM_WALLETS keypairs..."

if [ -f "$KEYPAIRS_FILE" ]; then
  EXISTING_COUNT=$(jq 'length' "$KEYPAIRS_FILE")
  if [ "$EXISTING_COUNT" -ge "$NUM_WALLETS" ]; then
    log "  Keypairs file already exists with $EXISTING_COUNT entries: $KEYPAIRS_FILE"
  else
    log "  Keypairs file exists but only has $EXISTING_COUNT entries, regenerating..."
    rm -f "$KEYPAIRS_FILE"
  fi
fi

if [ ! -f "$KEYPAIRS_FILE" ]; then
  # Generate all keypairs in a single Node.js invocation for efficiency
  KEYPAIRS_RAW=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
    const { createKeyPair } = require('@canton-network/core-signing-lib');
    const crypto = require('crypto');
    const wallets = [];
    for (let i = 1; i <= $NUM_WALLETS; i++) {
      const kp = createKeyPair();
      const pubKeyBytes = Buffer.from(kp.publicKey, 'base64');
      const hashInput = Buffer.alloc(4 + pubKeyBytes.length);
      hashInput.writeUInt32BE(12, 0);
      pubKeyBytes.copy(hashInput, 4);
      const hash = crypto.createHash('sha256').update(hashInput).digest();
      const fingerprint = Buffer.concat([Buffer.from([0x12, 0x20]), hash]).toString('hex');
      const idx = String(i).padStart(2, '0');
      wallets.push({
        index: i - 1,
        partyHint: 'farming-wallet-' + idx,
        userId: 'farming-wallet-' + idx + '-user',
        partyId: '',
        publicKey: kp.publicKey,
        privateKey: kp.privateKey,
        fingerprint: fingerprint
      });
    }
    console.log(JSON.stringify(wallets));
  " 2>/dev/null) || KEYPAIRS_RAW=""

  if [ -z "$KEYPAIRS_RAW" ]; then
    log_error "Failed to generate keypairs. Ensure Node.js and @canton-network/core-signing-lib are available."
    exit 1
  fi

  echo "$KEYPAIRS_RAW" | jq '.' > "$KEYPAIRS_FILE"
  log "  Generated $NUM_WALLETS keypairs → $KEYPAIRS_FILE"
fi

##############################################################################
# Step 2: Onboard external parties via generate-topology + sign + allocate
##############################################################################

log ""
log "Step 2: Onboarding $NUM_WALLETS external parties..."

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PUB=$(jq -r ".[$i].publicKey" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".[$i].fingerprint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")

  # Skip if already onboarded
  if [ -n "$WALLET_PARTY" ] && [ "$WALLET_PARTY" != "" ] && [ "$WALLET_PARTY" != "null" ]; then
    log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT already onboarded: ${WALLET_PARTY:0:40}..."
    continue
  fi

  EXPECTED_PARTY="$WALLET_HINT::$WALLET_FP"

  # Check if party exists on participant
  PARTY_CHECK=$(curl_check "$APP_USER_JSON_API/v2/parties/party?parties=$EXPECTED_PARTY" "$CANTON_TOKEN" "application/json" \
    | jq -r '.partyDetails[0].party // empty' 2>/dev/null || echo "")

  if [ -n "$PARTY_CHECK" ] && [ "$PARTY_CHECK" != "null" ]; then
    WALLET_PARTY="$PARTY_CHECK"
    log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT already exists: ${WALLET_PARTY:0:40}..."
  else
    # 2a. Generate topology
    TOPO_BODY=$(jq -n \
      --arg sync "$SYNCHRONIZER_ID" \
      --arg keyData "$WALLET_PUB" \
      --arg hint "$WALLET_HINT" \
      '{
        synchronizer: $sync,
        publicKey: {
          format: "CRYPTO_KEY_FORMAT_RAW",
          keyData: $keyData,
          keySpec: "SIGNING_KEY_SPEC_EC_CURVE25519"
        },
        partyHint: $hint,
        confirmationThreshold: 1,
        otherConfirmingParticipantUids: [],
        observingParticipantUids: [],
        localParticipantObservationOnly: false
      }')

    TOPO_RESULT=$(curl_check "$APP_USER_JSON_API/v2/parties/external/generate-topology" "$CANTON_TOKEN" "application/json" \
      --data-raw "$TOPO_BODY") || {
      log_error "Failed to generate topology for $WALLET_HINT"
      exit 1
    }

    MULTI_HASH=$(echo "$TOPO_RESULT" | jq -r '.multiHash // empty')
    TOPO_PARTY_ID=$(echo "$TOPO_RESULT" | jq -r '.partyId // empty')
    PUB_KEY_FP=$(echo "$TOPO_RESULT" | jq -r '.publicKeyFingerprint // empty')
    TOPO_TRANSACTIONS=$(echo "$TOPO_RESULT" | jq -c '.topologyTransactions // []')

    if [ -z "$MULTI_HASH" ] || [ -z "$TOPO_PARTY_ID" ] || [ -z "$PUB_KEY_FP" ]; then
      log_error "generate-topology response missing required fields for $WALLET_HINT"
      exit 1
    fi

    # 2b. Sign the multiHash
    SIGNED_HASH=$(cd "$EXCHANGE_BACKEND_DIR" && node -e "
      const { signTransactionHash } = require('@canton-network/core-signing-lib');
      const signature = signTransactionHash('$MULTI_HASH', '$WALLET_PRIV');
      process.stdout.write(signature);
    " 2>/dev/null) || SIGNED_HASH=""

    if [ -z "$SIGNED_HASH" ]; then
      log_error "Failed to sign topology hash for $WALLET_HINT"
      exit 1
    fi

    # 2c. Build onboarding transactions
    ONBOARDING_TXS=$(echo "$TOPO_TRANSACTIONS" | jq -c '[.[] | {transaction: ., signatures: []}]')

    # 2d. Allocate external party
    ALLOCATE_BODY=$(jq -n \
      --arg sync "$SYNCHRONIZER_ID" \
      --argjson txs "$ONBOARDING_TXS" \
      --arg sig "$SIGNED_HASH" \
      --arg signedBy "$PUB_KEY_FP" \
      '{
        synchronizer: $sync,
        onboardingTransactions: $txs,
        multiHashSignatures: [{
          format: "SIGNATURE_FORMAT_RAW",
          signature: $sig,
          signedBy: $signedBy,
          signingAlgorithmSpec: "SIGNING_ALGORITHM_SPEC_ED25519"
        }],
        identityProviderId: ""
      }')

    ALLOCATE_RESULT=$(curl_check "$APP_USER_JSON_API/v2/parties/external/allocate" "$CANTON_TOKEN" "application/json" \
      --data-raw "$ALLOCATE_BODY") || {
      log_error "Failed to allocate external party $WALLET_HINT"
      exit 1
    }

    WALLET_PARTY=$(echo "$ALLOCATE_RESULT" | jq -r '.partyId // empty')
    if [ -z "$WALLET_PARTY" ]; then
      log_error "Allocate succeeded but no partyId in response for $WALLET_HINT"
      exit 1
    fi

    log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT allocated: ${WALLET_PARTY:0:40}..."
  fi

  # Update keypairs file with resolved partyId
  jq --arg idx "$i" --arg partyId "$WALLET_PARTY" \
    '.[($idx | tonumber)].partyId = $partyId' "$KEYPAIRS_FILE" > "$KEYPAIRS_FILE.tmp" \
    && mv "$KEYPAIRS_FILE.tmp" "$KEYPAIRS_FILE"
done

log "  All $NUM_WALLETS external parties onboarded."

##############################################################################
# Step 3: Create Canton users + grant rights
##############################################################################

log ""
log "Step 3: Creating Canton users and granting rights..."

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".[$i].userId" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")

  # 3a. Grant admin user rights over this wallet party
  curl_check "$APP_USER_JSON_API/v2/users/$SHARED_SECRET_USER/rights" "$CANTON_TOKEN" "application/json" \
    --data-raw '{
      "userId": "'"$SHARED_SECRET_USER"'",
      "identityProviderId": "",
      "rights": [
        {"kind": {"CanActAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}},
        {"kind": {"CanReadAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}}
      ]
    }' > /dev/null 2>&1 || true

  # 3b. Create dedicated Canton user (idempotent)
  USER_STATUS=$(curl_status_code "$APP_USER_JSON_API/v2/users/$WALLET_USER" "$CANTON_TOKEN")

  if [ "$USER_STATUS" != "200" ]; then
    curl_check "$APP_USER_JSON_API/v2/users" "$CANTON_TOKEN" "application/json" \
      --data-raw '{
        "user": {
          "id": "'"$WALLET_USER"'",
          "isDeactivated": false,
          "primaryParty": "'"$WALLET_PARTY"'",
          "identityProviderId": "",
          "metadata": {
            "resourceVersion": "",
            "annotations": {
              "username": "'"$WALLET_HINT"'"
            }
          }
        },
        "rights": []
      }' > /dev/null
  fi

  # 3c. Grant ActAs + ReadAs rights to dedicated user
  curl_check "$APP_USER_JSON_API/v2/users/$WALLET_USER/rights" "$CANTON_TOKEN" "application/json" \
    --data-raw '{
      "userId": "'"$WALLET_USER"'",
      "identityProviderId": "",
      "rights": [
        {"kind": {"CanActAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}},
        {"kind": {"CanReadAs": {"value": {"party": "'"$WALLET_PARTY"'"}}}}
      ]
    }' > /dev/null 2>&1 || true

  log "  [$((i+1))/$NUM_WALLETS] User $WALLET_USER created with rights"
done

log "  All $NUM_WALLETS users created."

##############################################################################
# Step 4: Create TokenMintRequests (20 per wallet = 500 total)
#         Each wallet (external party) creates a mint request via interactive submission
##############################################################################

log ""
log "Step 4: Creating TokenMintRequests ($MINTS_PER_WALLET per wallet, $((NUM_WALLETS * MINTS_PER_WALLET)) total)..."

# Array to store mint request CIDs: "walletIndex|contractId|amount"
MINT_REQUESTS=()

for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_PRIV=$(jq -r ".[$i].privateKey" "$KEYPAIRS_FILE")
  WALLET_FP=$(jq -r ".[$i].fingerprint" "$KEYPAIRS_FILE")

  log "  [$((i+1))/$NUM_WALLETS] $WALLET_HINT: creating $MINTS_PER_WALLET mint requests..."

  for j in $(seq 1 "$MINTS_PER_WALLET"); do
    # Random amount between MIN_AMOUNT and MAX_AMOUNT
    AMOUNT=$(( (RANDOM % (MAX_AMOUNT - MIN_AMOUNT + 1)) + MIN_AMOUNT ))

    # Build CreateCommand for TokenMintRequest
    CMD_JSON=$(jq -n \
      --arg admin "$CBTC_NETWORK_PARTY" \
      --arg tokenId "$CBTC_TOKEN_ID" \
      --arg recipient "$WALLET_PARTY" \
      --arg amount "${AMOUNT}.0" \
      '[{
        CreateCommand: {
          templateId: "#fungible-token:Fungible.TokenMint:TokenMintRequest",
          createArguments: {
            instrumentId: { admin: $admin, id: $tokenId },
            recipient: $recipient,
            amount: $amount
          }
        }
      }]')

    TX_RESULT=$(interactive_submit "$WALLET_PARTY" "$WALLET_PRIV" "$WALLET_FP" "$CMD_JSON" "mint-req-${WALLET_HINT}-${j}") || {
      log_error "Failed to create mint request #$j for $WALLET_HINT"
      exit 1
    }

    # Extract TokenMintRequest contract ID from created events
    MINT_CID=$(echo "$TX_RESULT" | jq -r '
      [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("TokenMintRequest")) | .contractId][0] // empty
    ' 2>/dev/null || echo "")

    if [ -z "$MINT_CID" ]; then
      log_error "Could not extract TokenMintRequest contract ID for $WALLET_HINT mint #$j"
      log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
      exit 1
    fi

    MINT_REQUESTS+=("${i}|${MINT_CID}|${AMOUNT}")
  done

  log "    Created $MINTS_PER_WALLET mint requests for $WALLET_HINT"
done

log "  Total mint requests created: ${#MINT_REQUESTS[@]}"

##############################################################################
# Step 5: CBTC-NETWORK accepts all mint requests via AcceptMint
##############################################################################

log ""
log "Step 5: CBTC-NETWORK accepting ${#MINT_REQUESTS[@]} mint requests..."

# Array to store holdings: "walletIndex|contractId|amount"
HOLDINGS=()
ACCEPT_COUNT=0

for entry in "${MINT_REQUESTS[@]}"; do
  IFS='|' read -r WALLET_IDX MINT_CID AMOUNT <<< "$entry"
  ACCEPT_COUNT=$((ACCEPT_COUNT + 1))

  if [ $((ACCEPT_COUNT % 50)) -eq 0 ] || [ "$ACCEPT_COUNT" -eq 1 ]; then
    log "  Accepting mint request $ACCEPT_COUNT/${#MINT_REQUESTS[@]}..."
  fi

  # Build ExerciseCommand for AcceptMint
  CMD_JSON=$(jq -n \
    --arg contractId "$MINT_CID" \
    '[{
      ExerciseCommand: {
        templateId: "#fungible-token:Fungible.TokenMint:TokenMintRequest",
        contractId: $contractId,
        choice: "AcceptMint",
        choiceArgument: {}
      }
    }]')

  TX_RESULT=$(interactive_submit "$CBTC_NETWORK_PARTY" "$CBTC_PRIV_KEY" "$CBTC_FP" "$CMD_JSON" "accept-mint-$ACCEPT_COUNT") || {
    log_error "Failed to accept mint request $MINT_CID"
    exit 1
  }

  # Extract TokenHolding contract ID from created events
  HOLDING_CID=$(echo "$TX_RESULT" | jq -r '
    [.transaction.events[] | (.CreatedEvent // .created // empty) | select(.templateId | tostring | contains("TokenHolding")) | .contractId][0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$HOLDING_CID" ]; then
    log_error "Could not extract TokenHolding contract ID for mint $MINT_CID"
    log_error "Response: $(echo "$TX_RESULT" | head -c 500)"
    exit 1
  fi

  HOLDINGS+=("${WALLET_IDX}|${HOLDING_CID}|${AMOUNT}")
done

log "  All ${#HOLDINGS[@]} mint requests accepted."

##############################################################################
# Step 6: Write holdings report
##############################################################################

log ""
log "Step 6: Writing holdings report..."

# Build the JSON report
REPORT_JSON=$(jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cbtcNetworkParty "$CBTC_NETWORK_PARTY" \
  --arg tokenId "$CBTC_TOKEN_ID" \
  --argjson totalHoldings "${#HOLDINGS[@]}" \
  '{
    generatedAt: $generatedAt,
    cbtcNetworkParty: $cbtcNetworkParty,
    tokenId: $tokenId,
    totalHoldings: $totalHoldings,
    wallets: []
  }')

# Group holdings by wallet and build wallet entries
for i in $(seq 0 $((NUM_WALLETS - 1))); do
  WALLET_HINT=$(jq -r ".[$i].partyHint" "$KEYPAIRS_FILE")
  WALLET_PARTY=$(jq -r ".[$i].partyId" "$KEYPAIRS_FILE")
  WALLET_USER=$(jq -r ".[$i].userId" "$KEYPAIRS_FILE")

  # Collect holdings for this wallet
  WALLET_HOLDINGS="[]"
  WALLET_TOTAL=0

  for entry in "${HOLDINGS[@]}"; do
    IFS='|' read -r WALLET_IDX HOLDING_CID AMOUNT <<< "$entry"
    if [ "$WALLET_IDX" = "$i" ]; then
      WALLET_HOLDINGS=$(echo "$WALLET_HOLDINGS" | jq \
        --arg cid "$HOLDING_CID" \
        --argjson amount "$AMOUNT" \
        '. + [{ contractId: $cid, amount: $amount }]')
      WALLET_TOTAL=$((WALLET_TOTAL + AMOUNT))
    fi
  done

  REPORT_JSON=$(echo "$REPORT_JSON" | jq \
    --arg hint "$WALLET_HINT" \
    --arg partyId "$WALLET_PARTY" \
    --arg userId "$WALLET_USER" \
    --argjson holdings "$WALLET_HOLDINGS" \
    --argjson totalAmount "$WALLET_TOTAL" \
    '.wallets += [{ partyHint: $hint, partyId: $partyId, userId: $userId, holdings: $holdings, totalAmount: $totalAmount }]')
done

echo "$REPORT_JSON" | jq '.' > "$HOLDINGS_FILE"

# Calculate grand total
GRAND_TOTAL=$(jq '[.wallets[].totalAmount] | add' "$HOLDINGS_FILE")

log "  Holdings report written to: $HOLDINGS_FILE"

##############################################################################
# Done
##############################################################################

log ""
log "=========================================="
log "Farming Wallet Generation Complete!"
log "=========================================="
log ""
log "Summary:"
log "  Wallets created: $NUM_WALLETS"
log "  Holdings per wallet: $MINTS_PER_WALLET"
log "  Total holdings: ${#HOLDINGS[@]}"
log "  Total CBTC minted: $GRAND_TOTAL"
log "  Keypairs file: $KEYPAIRS_FILE"
log "  Holdings file: $HOLDINGS_FILE"
log ""
