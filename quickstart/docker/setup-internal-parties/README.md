# Internal Party Setup

Scripts for allocating **internal parties** on a Canton participant node and setting up their Transfer Preapproval contracts.

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

- Quickstart running: `cd quickstart && make start`

## Setup

```bash
cp .env.example .env
# Edit .env if needed (defaults allocate 10 parties on app-user participant)
./01-allocate-internal-parties.sh
```

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
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PARTICIPANT_JSON_API` | `http://localhost:2975` | Canton JSON API URL of the target participant |
| `NUM_PARTIES` | `10` | Number of internal parties to allocate |
| `PARTY_HINT_PREFIX` | `trader` | Prefix for party hints (`<prefix>-0`, `<prefix>-1`, ...) |
| `SHARED_SECRET` | `unsafe` | Shared secret for JWT generation |
| `SHARED_SECRET_AUDIENCE` | `https://canton.network.global` | JWT audience |
| `SHARED_SECRET_USER` | `ledger-api-user` | Canton admin user |
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
| `VALIDATOR_API` | `http://localhost:2903` | Validator Admin API (for DSO party resolution) |
| `SV_JSON_API` | `http://localhost:4975` | SV JSON API (for AmuletRules + OpenMiningRound) |
| `TRANSFERS_FILE` | `./transfers.json` | Path to input JSON file |
| `PREAPPROVALS_FILE` | `./transfer-preapprovals.json` | Path to preapprovals from script 02 |

### What It Does

| Step | Action | Details |
|------|--------|---------|
| 0 | Pre-flight | Resolves sender party, DSO party, synchronizer ID. Validates all recipients have TransferPreapprovals |
| 1 | Fetch SV contracts | Fetches `AmuletRules` + `OpenMiningRound` from SV with `createdEventBlob` for disclosed contracts |
| 2 | Query sender holdings | Queries sender's active Amulet contracts, sorted by amount descending |
| 3 | Transfer | For each entry: exercises `TransferPreapproval_Send` on the recipient's TransferPreapproval contract with `actAs: [sender]`. Consumes sender's Amulet holding as input, tracks change Amulet for subsequent transfers |

### Transfer Mechanism

Each transfer exercises the `TransferPreapproval_Send` choice:

- **Template**: `#splice-amulet:Splice.AmuletRules:TransferPreapproval`
- **Controller**: `sender` (the participant's validator party)
- **Arguments**: `sender`, `context` (AmuletRules + OpenMiningRound), `inputs` (sender's Amulet holding), `amount`, `description`
- **Result**: Creates a new Amulet for the receiver and a change Amulet for the sender (minus transfer fees)
- **Disclosed contracts**: AmuletRules + OpenMiningRound (from SV)

### UTXO Tracking

The script maintains a sorted list of the sender's available Amulet holdings. After each transfer:

1. The consumed input holding is removed from the list
2. The change Amulet (if any) is added back to the list
3. The next transfer picks the smallest holding that covers the requested amount

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
