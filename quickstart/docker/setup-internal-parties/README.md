# Internal Party Setup

Scripts for allocating **internal parties** on a Canton participant node, setting up their Transfer Preapproval contracts, and funding them with Amulet (CC) tokens.

## Internal vs External Parties

| | Internal Parties | External Parties |
|---|---|---|
| **Hosted on** | Participant node directly | External to participant (own keypair) |
| **Namespace** | Shares participant's fingerprint | Has its own fingerprint from Ed25519 key |
| **Allocation** | Single `POST /v2/parties` call | 3-step: `generate-topology` → sign → `allocate` |
| **Submission** | Regular submission (`submit-and-wait`) | Interactive submission (prepare → sign → execute) |
| **Use case** | LP parties, executor parties, service accounts | End-user wallets, trader wallets |
| **Scripts** | This directory (`setup-internal-parties/`) | `utxo-handling/01-generate-user-wallet.sh` |

## Prerequisites

- Canton participant node running (quickstart localnet or devnet)

## Setup

```bash
cp .env.example .env
# Edit .env — set PARTICIPANT_JSON_API, VALIDATOR_API, AUTH_MODE, and auth credentials
./01-allocate-internal-parties.sh
./02-create-transfer-preapprovals.sh   # optional: enables TransferPreapproval-based transfers
./03-distribute-amulet.sh              # optional: distribute Amulet from sender to parties
./04-faucet-amulet.sh                  # optional: DevNet tap — direct faucet from AmuletRules
```

## Authentication

All scripts support both **shared-secret** and **OAuth2** authentication, configured via `AUTH_MODE` in `.env`. Auth logic is shared via `auth.sh`.

### Shared-secret (default, for localnet)

```bash
AUTH_MODE="shared-secret"
SHARED_SECRET="unsafe"
SHARED_SECRET_AUDIENCE="https://canton.network.global"
SHARED_SECRET_USER="ledger-api-user"
ADMIN_USER="ledger-api-user"
```

### OAuth2 (for devnet / production)

```bash
AUTH_MODE="oauth2"
OAUTH2_TOKEN_URL="<your-token-url>"
OAUTH2_CLIENT_ID="<your-client-id>"
OAUTH2_CLIENT_SECRET="<your-client-secret>"
OAUTH2_AUDIENCE=""                  # audience for the Canton JSON API
OAUTH2_VALIDATOR_AUDIENCE=""        # audience for the Validator Admin API (defaults to OAUTH2_AUDIENCE)
ADMIN_USER="<keycloak-user-uuid>"   # user ID for resolving participant's primary party
```

**`ADMIN_USER`**: Used to resolve the participant's primary party via `GET /v2/users/<ADMIN_USER>`. In shared-secret mode, this is `ledger-api-user`. In OAuth2 mode, this is the Keycloak/Auth0 user identifier (e.g., `client-id@clients`).

**Separate audiences**: On devnet, the JSON API and Validator Admin API may require different audiences. Set `OAUTH2_VALIDATOR_AUDIENCE` if your validator uses a different audience from the JSON API. If not set, it defaults to `OAUTH2_AUDIENCE`.

In OAuth2 mode, per-user tokens (used by script 02 for creating proposals) use the same participant token since OAuth2 client_credentials flow doesn't support per-user scoping.

**Security**: The `.env` file contains credentials and is gitignored. Only `.env.example` (with placeholder values) is committed. Output JSON files (`internal-parties.json`, `transfer-preapprovals.json`, `distributed-amulet.json`, `transfers.json`) are also gitignored as they contain environment-specific data.

## Usage

```bash
# Allocate 10 internal parties with default prefix "trader" (overwrites existing)
./01-allocate-internal-parties.sh

# Custom count and prefix
NUM_PARTIES=5 PARTY_HINT_PREFIX=lp ./01-allocate-internal-parties.sh

# Allocate on a different participant (e.g., trading-partner)
PARTICIPANT_JSON_API=http://localhost:1975 ./01-allocate-internal-parties.sh

# Append 5 more parties to the existing file
APPEND_PARTIES=true NUM_PARTIES=5 ./01-allocate-internal-parties.sh

# Re-onboard from existing file (skip allocation, just create Canton users)
ONBOARD_ONLY=true ./01-allocate-internal-parties.sh

# Use OAuth2 auth (override .env)
AUTH_MODE=oauth2 ./01-allocate-internal-parties.sh
```

## Script 1: `01-allocate-internal-parties.sh`

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PARTICIPANT_JSON_API` | `http://localhost:2975` | Canton JSON API URL of the target participant |
| `NUM_PARTIES` | `10` | Number of internal parties to allocate |
| `PARTY_HINT_PREFIX` | `trader` | Prefix for party hints (`<prefix>-0`, `<prefix>-1`, ...) |
| `ADMIN_USER` | `ledger-api-user` | Canton admin user ID for resolving primary party and granting rights |
| `AUTH_MODE` | `shared-secret` | Authentication mode: `shared-secret` or `oauth2` |
| `APPEND_PARTIES` | `false` | Append to existing output file instead of overwriting |
| `ONBOARD_ONLY` | `false` | Skip allocation, only create Canton users from existing file |

## What It Does

| Step | Action | Details |
|------|--------|---------|
| 0 | Pre-flight | Generates JWT, verifies participant is reachable, resolves participant namespace (fingerprint) |
| 1 | Allocate parties | For each party: checks if `<hint>::<namespace>` exists via `GET /v2/parties/party`, if not allocates via `POST /v2/parties`. Idempotent — existing parties are skipped |
| 2 | Create Canton users | Creates a Canton user per party with `CanActAs`/`CanReadAs` rights. Also grants admin user rights over each party. Existing users are skipped |

## Output

`internal-parties.json` — Contains all allocated party IDs and metadata:

```json
{
  "participantId": "participant::1220...",
  "namespace": "1220...",
  "partyHintPrefix": "trader",
  "participantJsonApi": "http://localhost:2975",
  "parties": [
    {
      "index": 0,
      "partyHint": "trader-0",
      "partyId": "trader-0::1220...",
      "userId": "trader-0",
      "displayName": "trader 0"
    }
  ]
}
```

## Party ID Format

Internal party IDs follow the format: `<partyHint>::<participantNamespace>`

Since all internal parties share the participant's namespace, they are distinguishable only by their hint prefix. For example, on the app-user participant:

```
trader-0::12200a1b2c...
trader-1::12200a1b2c...
trader-2::12200a1b2c...
```

This contrasts with external parties where each party has a unique namespace derived from its own Ed25519 public key.

---

## Script 2: `02-create-transfer-preapprovals.sh`

Creates a `TransferPreapproval` contract for each internal party. This enables other parties to send tokens to these parties without requiring per-transfer authorization.

### How It Works

1. For each party in `internal-parties.json`, creates a `TransferPreapprovalProposal` via regular submission (`POST /v2/commands/submit-and-wait-for-transaction`)
2. The validator's `AcceptTransferPreapprovalProposalTrigger` automation automatically detects the proposal, pays the preapproval fee from the validator's treasury, and creates the `TransferPreapproval` contract
3. The script polls the validator API (`GET /v0/admin/transfer-preapprovals/by-party/{party}`) until the preapproval is confirmed
4. Records all contract IDs to `transfer-preapprovals.json`

### Usage

```bash
# Requires: 01-allocate-internal-parties.sh completed, quickstart running
./02-create-transfer-preapprovals.sh

# With custom poll timeout (seconds per party, default: 60)
POLL_TIMEOUT=120 ./02-create-transfer-preapprovals.sh
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PARTICIPANT_JSON_API` | `http://localhost:2975` | Canton JSON API URL |
| `VALIDATOR_API` | `http://localhost:2903` | Validator Admin API URL (for DSO party + polling) |
| `ADMIN_USER` | `ledger-api-user` | Canton admin user ID for resolving provider party |
| `AUTH_MODE` | `shared-secret` | Authentication mode: `shared-secret` or `oauth2` |
| `POLL_TIMEOUT` | `60` | Max seconds to wait for validator to accept each proposal |

### Contract Details

**TransferPreapprovalProposal** (`#splice-wallet:Splice.Wallet.TransferPreapproval:TransferPreapprovalProposal`):
- `receiver` — The internal party (from `internal-parties.json`)
- `provider` — The validator operator party (resolved from `ledger-api-user`)
- `expectedDso` — The DSO party (resolved from validator API)

The validator automation accepts the proposal by exercising `AmuletRules_CreateTransferPreapproval`, which:
- Burns a fee from the provider's holdings (proportional to preapproval lifetime, ~90 days)
- Creates the `TransferPreapproval` contract signed by all three parties (receiver, provider, dso)

### Idempotency

Before creating a proposal, the script checks if a `TransferPreapproval` already exists for each party via the validator API. Existing preapprovals are skipped.

### Output

`transfer-preapprovals.json`:

```json
{
  "generatedAt": "2026-03-30T...",
  "participantJsonApi": "http://localhost:2975",
  "providerParty": "app_user_quickstart-...::1220...",
  "dsoParty": "DSO::1220...",
  "preapprovals": [
    {
      "partyHint": "trader-0",
      "partyId": "trader-0::1220...",
      "userId": "trader-0",
      "transferPreapprovalCid": "00..."
    }
  ]
}
```

---

## Script 3: `03-distribute-amulet.sh`

Transfers Amulet (CC) from the node's participant party (sender) to recipients using `TransferPreapproval_Send`. Recipients must have `TransferPreapproval` contracts (created by script 02).

The sender's Amulet holdings are consumed as inputs. After each transfer, the sender receives a change Amulet (minus fees), which is tracked and reused for subsequent transfers.

### Input File

`transfers.json` (see `transfers.example.json` for format):

```json
[
  { "recipient": "trader-0::1220...", "amount": "100.0" },
  { "recipient": "trader-0::1220...", "amount": "50.0" },
  { "recipient": "trader-1::1220...", "amount": "200.0" }
]
```

A recipient can appear multiple times — each entry creates a separate Amulet holding.

### Usage

```bash
# Distribute using default transfers.json
./03-distribute-amulet.sh

# Use a custom transfers file
TRANSFERS_FILE=my-transfers.json ./03-distribute-amulet.sh
```

### Prerequisites

- `02-create-transfer-preapprovals.sh` completed (all recipients need `TransferPreapproval`)
- The sender (participant's validator party) must have sufficient Amulet holdings

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PARTICIPANT_JSON_API` | `http://localhost:2975` | Canton JSON API URL |
| `VALIDATOR_API` | `http://localhost:2903` | Validator Admin API (for DSO party, AmuletRules, OpenMiningRound) |
| `ADMIN_USER` | `ledger-api-user` | Canton admin user ID for resolving sender party |
| `AUTH_MODE` | `shared-secret` | Authentication mode: `shared-secret` or `oauth2` |
| `TRANSFERS_FILE` | `./transfers.json` | Path to input JSON file |
| `PREAPPROVALS_FILE` | `./transfer-preapprovals.json` | Path to preapprovals from script 02 |

### What It Does

| Step | Action | Details |
|------|--------|---------|
| 0 | Pre-flight | Resolves sender party, DSO party, synchronizer ID. Validates all recipients have TransferPreapprovals |
| 1 | Fetch scan-proxy contracts | Fetches `AmuletRules` + `OpenMiningRound` from validator's scan-proxy API with `createdEventBlob` for disclosed contracts |
| 2 | Query sender holdings | Queries sender's active Amulet contracts, sorted by amount descending |
| 3 | Transfer | For each entry: exercises `TransferPreapproval_Send` on the recipient's TransferPreapproval contract with `actAs: [sender]`. Consumes sender's Amulet holding as input, tracks change Amulet for subsequent transfers |

### Transfer Mechanism

Each transfer exercises the `TransferPreapproval_Send` choice:

- **Template**: `#splice-amulet:Splice.AmuletRules:TransferPreapproval`
- **Controller**: `sender` (the participant's validator party)
- **Arguments**: `sender`, `context` (AmuletRules + OpenMiningRound), `inputs` (sender's Amulet holding), `amount`, `description`
- **Result**: Creates a new Amulet for the receiver and a change Amulet for the sender (minus transfer fees)
- **Disclosed contracts**: AmuletRules + OpenMiningRound (from scan-proxy on validator API)

### UTXO Handling

Before each transfer, the script re-queries the sender's active Amulet holdings from the ledger to get the latest state. This ensures consumed holdings are excluded and change Amulets from previous transfers are available. The script picks the first holding with sufficient balance for each transfer.

### Output

`distributed-amulet.json`:

```json
{
  "generatedAt": "2026-03-30T...",
  "participantJsonApi": "http://localhost:2975",
  "senderParty": "app_user_quickstart-...::1220...",
  "dsoParty": "DSO::1220...",
  "inputFile": "./transfers.json",
  "transfers": [
    {
      "index": 0,
      "recipient": "trader-0::1220...",
      "amount": "100.0",
      "amuletContractId": "00...",
      "inputHoldingCid": "00...",
      "changeCid": "00...",
      "changeAmount": "899.5"
    }
  ]
}
```

---

## Script 4: `04-faucet-amulet.sh`

**DevNet only.** Directly taps Amulet (CC) to each internal party in `transfers.json` using the `AmuletRules_DevNet_Tap` choice. No sender holdings required — tokens are minted from the network.

This is the simplest way to fund internal parties on a DevNet localnet. It bypasses `TransferPreapproval` and does not require scripts 02 or 03 to have been run.

Unlike `utxo-handling/03-request-faucet-amulet.sh` which uses **interactive submission** for external parties, this script uses **regular `submit-and-wait`** because the parties are internal (hosted on the participant).

### Prerequisites

- `01-allocate-internal-parties.sh` completed (parties onboarded with Canton users)
- `transfers.json` populated with recipient party IDs and amounts
- Quickstart running in **DevNet mode** (`AmuletRules_DevNet_Tap` is disabled on MainNet)

### Input File

Reads from `transfers.json` (same format as script 03):

```json
[
  { "recipient": "trading-partner-0::1220...", "amount": "10000.0" },
  { "recipient": "trading-partner-1::1220...", "amount": "5000.0" }
]
```

The `recipient` field must be a fully-qualified party ID. The user ID is derived from the hint portion (before `::`).

### Usage

```bash
# Tap using default transfers.json
./04-faucet-amulet.sh

# Use a custom transfers file
TRANSFERS_FILE=my-transfers.json ./04-faucet-amulet.sh
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PARTICIPANT_JSON_API` | `http://localhost:1975` (from `internal-parties.json`) | Canton JSON API URL of the participant hosting the parties |
| `VALIDATOR_API` | `http://localhost:1903` | Validator Admin API URL (for scan-proxy to fetch AmuletRules + OpenMiningRound) |
| `AUTH_MODE` | `shared-secret` | Authentication mode: `shared-secret` or `oauth2` |
| `TRANSFERS_FILE` | `./transfers.json` | Path to transfers input file |

### What It Does

| Step | Action | Details |
|------|--------|---------|
| 1 | Fetch AmuletRules + OpenMiningRound | Calls the validator scan-proxy (`/api/validator/v0/scan-proxy/registry/allocation-instruction/v1/allocation-factory`) to get AmuletRules CID, OpenMiningRound CID, and disclosed contracts |
| 2 | Tap Amulet per recipient | For each entry in `transfers.json`: submits `AmuletRules_DevNet_Tap` via `submit-and-wait-for-transaction` with `actAs: [recipient]`. Generates a per-user token (`get_user_token <userId>`) |
| 3 | Write results | Writes all tapped Amulet contract IDs and total CC to `fauceted-amulet.json` |

### Script 03 vs Script 04

| Aspect | `03-distribute-amulet.sh` | `04-faucet-amulet.sh` |
|--------|--------------------------|----------------------|
| Token source | Sender's existing Amulet holdings | Minted from network (DevNet only) |
| Requires TransferPreapproval | Yes (for each recipient) | No |
| Works on MainNet | Yes | No |
| Submission type | `submit-and-wait` as sender | `submit-and-wait` as each recipient |
| Multiple holdings per party | Yes (one per `transfers.json` entry) | One per entry |

### Output

`fauceted-amulet.json`:

```json
{
  "generatedAt": "2026-04-10T00:00:00Z",
  "transfersFile": "/path/to/transfers.json",
  "totalRecipients": 10,
  "totalAmountCC": 33000.0,
  "recipients": [
    {
      "partyId": "trading-partner-0::1220...",
      "userId": "trading-partner-0",
      "amount": "10000.0",
      "amuletCid": "00abcd..."
    }
  ]
}
```
