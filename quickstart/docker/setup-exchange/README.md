# Canton Exchange Backend Setup Scripts

Automated setup and registration scripts for the Canton Exchange Backend (`canton-exchange-backend`) on the local Canton Network Quickstart environment.

## Scripts Overview

| Script | Purpose | Run Order |
|--------|---------|-----------|
| `01-setup-exchange.sh` | Upload DARs, create on-ledger contracts, generate backend `.env`, start DB | 1st (required) |
| `02-register-featured-app-right.sh` | Register the FeaturedAppRight contract in the backend database | 2nd (after backend is running) |
| `03-register-cbtc-token.sh` | Onboard CBTC external party, create AllocationFactory + TransferFactory, register token issuer | 3rd (after backend is running) |

## Quick Start

```bash
# 1. Copy and configure the environment file
cp .env.example .env
# Edit .env: set EXCHANGE_BACKEND_DIR, DB credentials, and other values

# 2. Run the setup script (uploads DARs, creates contracts, starts DB)
./01-setup-exchange.sh

# 3. Start the exchange backend (in a separate terminal)
cd /path/to/canton-exchange-backend
yarn start:dev

# 4. Register FeaturedAppRight in the backend DB
./02-register-featured-app-right.sh

# 5. Register CBTC token (external party + AllocationFactory + TransferFactory + token issuer)
./03-register-cbtc-token.sh
```

## Prerequisites

1. **Quickstart running** - Start it first:

   ```bash
   cd quickstart
   make setup   # first time only
   make build
   make start
   ```

   Wait until all 23+ containers are healthy.

2. **DAR files** in `quickstart/daml/dars/` (configurable via `DAR_FILES` in `.env`):
   - `kairo-dex-2.5.0.dar`
   - `kairo-dex-simple-escrow-v3-1.0.0.dar`
   - `kairo-featured-app-proxies-1.0.1.dar`
   - `splice-util-batched-markers-1.0.0.dar`
   - `fungible-token-1.0.2.dar`
   - `splice-util-token-standard-wallet-1.0.0.dar`

3. **`canton-exchange-backend`** cloned at the path configured in `.env` (`EXCHANGE_BACKEND_DIR`). Required for all three scripts.

4. **Tools** installed: `curl`, `jq`, `openssl`, `docker`. Script 03 also requires `node` (for Ed25519 key generation and signing via `@canton-network/core-signing-lib`).

## Configuration

### `.env` file

All scripts source `$SCRIPT_DIR/.env` for shared configuration. Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

Key variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `EXCHANGE_BACKEND_DIR` | Absolute path to `canton-exchange-backend` repo | `/Users/you/canton-exchange-backend` |
| `BACKEND_PORT` | Port the exchange backend runs on | `3003` |
| `BACKEND_URL` | Full URL to the running backend | `http://localhost:3003` |
| `APP_PROVIDER_JSON_API` | App Provider participant JSON API | `http://localhost:3975` |
| `APP_USER_JSON_API` | App User participant JSON API | `http://localhost:2975` |
| `SV_JSON_API` | Super Validator participant JSON API | `http://localhost:4975` |
| `DAR_FILES` | Comma-separated list of DAR filenames to upload | `kairo-dex-2.5.0.dar,...` |
| `EXCHANGE_DB_*` | PostgreSQL credentials for the exchange backend DB | host, port, user, pass, name |
| `BACKEND_JWT_SECRET` | JWT signing secret used by the exchange backend | From `jwt.config.ts` |
| `FEATURE_APP_RIGHT_TYPE` | Type string for the FeaturedAppRight registration | `angelhack` |

### `cbtc-config.json`

CBTC token configuration used by `03-register-cbtc-token.sh`:

```json
{
  "networkUserId": "cbtc-network-user",
  "partyHint": "CBTC-NETWORK",
  "tokenId": "CBTC",
  "displayName": "Canton BTC",
  "symbol": "CBTC",
  "priceSourceId": "1"
}
```

---

## Script 1: `01-setup-exchange.sh`

Performs the full initial setup for the exchange backend on the local quickstart network.

### Usage

```bash
./01-setup-exchange.sh
```

### What It Does

| Step | Action | Details |
|------|--------|---------|
| 1 | Detect auth & get tokens | Reads `AUTH_MODE` from `quickstart/.env.local`; obtains JWTs |
| 2 | Verify DAR files | Checks all required `.dar` files exist in `quickstart/daml/dars/` |
| 3 | Upload DARs | Uploads to both App Provider (`:3975`) and App User (`:2975`) participants. Skips if all packages already present |
| 4 | Resolve network info | Resolves party IDs (App Provider, App User, DSO) and the global synchronizer ID. Grants `CanReadAsAnyParty` to admin user |
| 5 | Create FeaturedAppRight | Exercises `AmuletRules_DevNet_FeatureApp` on the ledger for the app-user party (idempotent -- skips if contract exists) |
| 6 | Create BatchedMarkersProxy | Creates a `BatchedMarkersProxy` contract for the app-user party (idempotent -- skips if contract exists) |
| 7 | Generate `.env.local` | Writes backend configuration to `$EXCHANGE_BACKEND_DIR/.env.local` and activates it as `.env` |
| 8 | Start PostgreSQL & migrate | Starts the exchange backend's own PostgreSQL (port 5433) via Docker Compose and runs TypeORM migrations |

### Idempotency

- DAR uploads are skipped if all packages are already present on both participants (checked via package ID in the DAR manifest).
- FeaturedAppRight and BatchedMarkersProxy creation queries for existing contracts before creating new ones.
- Re-running the script is safe, though it will overwrite the generated `.env.local`.

### How FeaturedAppRight Creation Works

Creating a `FeaturedAppRight` requires exercising the `AmuletRules_DevNet_FeatureApp` choice on the `AmuletRules` contract. This is a DevNet-only operation.

The challenge is that `AmuletRules` is owned by the DSO party on the Super Validator participant -- not the app-user participant. The script solves this with the **disclosed contract** pattern:

1. Fetch the `AmuletRules` contract from the SV participant (`:4975`), including its `createdEventBlob`.
2. Submit an `ExerciseCommand` from the app-user participant (`:2975`), passing the fetched contract as a `disclosedContracts` entry.
3. The `actAs` is set to the app-user party (required as the choice's authorizer), not the DSO party.

### How BatchedMarkersProxy Creation Works

`BatchedMarkersProxy` is a simpler contract from the `splice-util-batched-markers` package. It has two fields (`provider` and `dso`) and is signed only by the `provider`. The script creates it with a `CreateCommand` directly from the app-user participant.

---

## Script 2: `02-register-featured-app-right.sh`

Registers the on-ledger FeaturedAppRight contract in the exchange backend's database so the backend can use it at runtime.

```bash
# Requires: 01-setup-exchange.sh completed AND backend is running
./02-register-featured-app-right.sh
```

**Prerequisites**: `01-setup-exchange.sh` has been run (DARs uploaded, contracts created, DB migrated). The exchange backend is running (`yarn start:dev` in the backend directory).

**Steps performed**:

| Step | Action | Details |
|------|--------|---------|
| 1 | Check backend is running | Verifies the backend is reachable at `$BACKEND_URL` |
| 2 | Check existing registration | Queries `GET /feature-app-right/type/{type}` to see if already registered |
| 3 | Query FeaturedAppRight from ledger | Queries Canton active contracts for the `FeaturedAppRight` contract owned by the app-user party |
| 4 | Register in backend | `POST /feature-app-right` with the contract ID, validator party, type, and beneficiaries |

**Idempotency**: If the FeaturedAppRight is already registered for the configured type (`FEATURE_APP_RIGHT_TYPE`), the script exits early with no changes. The backend API returns HTTP 409 if the type already exists, which the script handles gracefully.

**Backend authentication**: The script creates a "setup user" in the backend's PostgreSQL database (via direct SQL `INSERT ... ON CONFLICT DO NOTHING`) and generates a backend JWT (`HS256` signed with `BACKEND_JWT_SECRET`) to authenticate API calls.

**Verify registration**:

```bash
curl -s http://localhost:3003/feature-app-right | jq
```

---

## Script 3: `03-register-cbtc-token.sh`

Onboards a CBTC (Canton BTC) external party, creates `TokenAllocationFactory` and `TokenTransferFactory` contracts, and registers the token issuer in the exchange backend.

```bash
# Requires: 01-setup-exchange.sh completed AND backend is running
./03-register-cbtc-token.sh
```

**Prerequisites**: `01-setup-exchange.sh` has been run. The exchange backend is running. `@canton-network/core-signing-lib` must be installed in the exchange backend (used for Ed25519 key generation and signing).

**Steps performed**:

| Step | Action | Details |
|------|--------|---------|
| 1 | Generate Ed25519 keypair | Creates a NaCl keypair and computes the Canton fingerprint. Stored in `cbtc-network-keypair.json`. Skips if file exists |
| 2 | Onboard external party | Uses the Canton JSON API v2 external party flow: `generate-topology` -> sign multiHash -> `allocate`. Skips if party already exists |
| 3 | Create Canton user & grant rights | Creates a dedicated Canton user (`cbtc-network-user`) with `ActAs`/`ReadAs` rights for the external party. Also grants the admin user rights over the external party |
| 4 | Create TokenAllocationFactory | Uses **interactive submission** (`prepare` -> sign -> `executeAndWaitForTransaction`) since external parties require explicit signing. Skips if contract exists |
| 5 | Create TokenTransferFactory | Same interactive submission pattern. Creates the factory needed for token transfers and UTXO merging. Skips if contract exists |
| 6 | Acquire factory disclosures | Re-queries both factories with `includeCreatedEventBlob: true` to get disclosure blobs |
| 7 | Write `cbtc-factories.json` | Stores both factory contract IDs, template names, template IDs, and disclosures |
| 8 | Register AllocationFactory in backend | `POST /allocation-factory` with factory ID, type `"cbtc"`, and disclosed contracts |
| 9 | Register token issuer in backend | `POST /token-issuer` with admin party, token ID, registrar, factory contract ID, symbol, display name, and price source |

**Idempotency**: Every step checks for existing state before creating:

- Keypair file reused if `cbtc-network-keypair.json` exists.
- External party checked via `GET /v2/parties/party?parties=...`.
- Canton user checked via `GET /v2/users/{userId}` (HTTP 200 = exists).
- AllocationFactory and TransferFactory queried from active contracts before creating.
- Backend registrations checked via `GET /allocation-factory/type/cbtc` and `GET /token-issuer/token/CBTC`.

### External Party Onboarding Flow

External parties (parties not hosted by any participant) require a special onboarding flow:

1. **Generate topology** (`POST /v2/parties/external/generate-topology`): Provide the public key, party hint, and synchronizer. Returns topology transactions and a `multiHash` to sign.
2. **Sign multiHash**: Sign the hash with the party's Ed25519 private key using `@canton-network/core-signing-lib`.
3. **Allocate** (`POST /v2/parties/external/allocate`): Submit the signed topology transactions. Returns the allocated `partyId`.

### Interactive Submission Flow

External parties cannot use the standard `submit-and-wait` endpoint. Instead, they use the interactive submission protocol:

1. **Prepare** (`POST /v2/interactive-submission/prepare`): Sends the command and receives a `preparedTransaction` and `preparedTransactionHash`.
2. **Sign**: Sign the prepared transaction hash with the external party's private key.
3. **Execute** (`POST /v2/interactive-submission/executeAndWaitForTransaction`): Submit the signed prepared transaction. Returns the committed transaction with events.

### Output Files

- `cbtc-network-keypair.json`: Stores the generated keypair, fingerprint, and resolved party ID. Keep this file for future runs.
- `cbtc-factories.json`: Stores AllocationFactory and TransferFactory contract IDs, template names, template IDs, and disclosure blobs. Used by `utxo-handling/farming-wallet-utxo-merging.sh`.

**Verify registration**:

```bash
curl -s http://localhost:3003/allocation-factory/type/cbtc -H 'Authorization: Bearer <token>' | jq
curl -s http://localhost:3003/token-issuer/token/CBTC -H 'Authorization: Bearer <token>' | jq
```

---

## Authentication Modes

All scripts auto-detect the auth mode from `quickstart/.env.local`:

- **`shared-secret`** (default): Generates HS256 JWTs locally using the secret `"unsafe"` with audience `https://canton.network.global`.
- **`oauth2`**: Obtains tokens from Keycloak at `keycloak.localhost:8082` using pre-configured client credentials from the quickstart keycloak module.

The Super Validator (SV) participant always uses shared-secret auth, even in oauth2 mode, because there is no Keycloak realm for SV in the quickstart environment.

Scripts 02 and 03 also generate **backend JWTs** (separate from Canton JWTs) to authenticate against the exchange backend's REST API. These use `BACKEND_JWT_SECRET` from `.env`.

## Canton JSON API v2 Reference

Key endpoints used by the scripts:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v2/packages` | GET/POST | List/upload DAR files (binary `application/octet-stream`) |
| `/v2/users/{userId}` | GET | Resolve party ID from user |
| `/v2/users/{userId}/rights` | POST | Grant `CanActAs`/`CanReadAs`/`CanReadAsAnyParty` rights |
| `/v2/users` | POST | Create a new Canton user |
| `/v2/state/connected-synchronizers` | GET | Get the global synchronizer ID |
| `/v2/state/ledger-end` | GET | Get the current ledger offset |
| `/v2/state/active-contracts` | POST | Query active contracts by party and template |
| `/v2/commands/submit-and-wait-for-transaction` | POST | Submit a command and wait for the full transaction |
| `/v2/parties/party` | GET | Look up party details by party ID |
| `/v2/parties/external/generate-topology` | POST | Generate topology for an external party |
| `/v2/parties/external/allocate` | POST | Allocate an external party after signing |
| `/v2/interactive-submission/prepare` | POST | Prepare a command for interactive (external party) signing |
| `/v2/interactive-submission/executeAndWaitForTransaction` | POST | Execute a signed prepared transaction |

### Command Body Format

Commands submitted via `/v2/commands/submit-and-wait-for-transaction` must be wrapped:

```json
{
  "commands": {
    "commands": [{ "CreateCommand": {...} }],
    "workflowId": "...",
    "applicationId": "...",
    "commandId": "unique-id",
    "deduplicationPeriod": { "Empty": {} },
    "actAs": ["party-id"],
    "readAs": [],
    "submissionId": "...",
    "disclosedContracts": [],
    "domainId": "",
    "packageIdSelectionPreference": []
  }
}
```

Choice arguments and create arguments use **plain JSON** (not verbose Daml-LF `Record`/`fields` encoding).

## Quickstart Port Scheme

| Participant | Ledger API | Admin API | Validator API | JSON API |
|-------------|-----------|-----------|---------------|----------|
| Super Validator (SV) | 4901 | 4902 | 4903 | 4975 |
| App Provider | 3901 | 3902 | 3903 | 3975 |
| App User | 2901 | 2902 | 2903 | 2975 |

## Troubleshooting

**DAR upload returns 503**: The participant is busy processing a previous upload. The script retries automatically (3 attempts, 10-second delay). If it still fails, wait a minute and re-run.

**FeaturedAppRight creation fails with "security-sensitive error"**: The app-user participant doesn't have visibility on the AmuletRules contract. This usually means the SV participant (`:4975`) is not reachable. Verify the quickstart is fully up.

**Docker network error**: If `docker compose up -d postgres` fails with "network splice-validator_splice_validator not found", the script auto-creates it. If this still fails, run manually: `docker network create splice-validator_splice_validator`.

**PostgreSQL not ready**: The script waits up to 60 seconds. If it times out, check `docker compose logs postgres` in the exchange backend directory.

**Migrations fail**: Ensure the `canton-exchange-backend` has its dependencies installed (`yarn install`) and that the database is accessible at `localhost:5433`.

**Keypair generation fails (script 03)**: Ensure `@canton-network/core-signing-lib` is installed in the exchange backend (`yarn install` or `npm install`). The script uses Node.js to call this library.

**External party allocation fails**: The Canton participant must support external parties. Verify the quickstart is running the correct Canton version (3.4.10+).

**Interactive submission fails**: The external party's public key must match the one used during `generate-topology`. If you regenerated keys, delete `cbtc-network-keypair.json` and re-run.

## After Setup

Start the exchange backend:

```bash
cd /path/to/canton-exchange-backend
yarn start:dev
```

The backend will be available at `http://localhost:3003`.
