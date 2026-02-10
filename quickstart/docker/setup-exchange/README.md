# Canton Exchange Backend Setup Script

Automated setup for the Canton Exchange Backend (`canton-exchange-backend`) on the local Canton Network Quickstart environment.

## What It Does

The script performs 8 steps in sequence:

| Step | Action | Details |
|------|--------|---------|
| 1 | Verify DAR files | Checks all required `.dar` files exist in `quickstart/daml/dars/` |
| 2 | Upload DARs | Uploads to both App Provider (`:3975`) and App User (`:2975`) participants |
| 3 | Resolve network info | Resolves party IDs (App Provider, App User, DSO) and the global synchronizer ID |
| 4 | Create FeaturedAppRight | Exercises `AmuletRules_DevNet_FeatureApp` on the ledger for the app-user party |
| 5 | Create BatchedMarkersProxy | Creates a `BatchedMarkersProxy` contract for the app-user party |
| 6 | Generate `.env.local` | Writes backend configuration pointing to the local quickstart network |
| 7 | Start PostgreSQL | Starts the exchange backend's own PostgreSQL (port 5433) and runs TypeORM migrations |
| 8 | Register FeaturedAppRight | *(optional)* Prints a `curl` command to register the contract in the backend DB |

## Prerequisites

1. **Quickstart running** - Start it first:

   ```bash
   cd quickstart
   make setup   # first time only - configures auth mode, test mode, etc.
   make build
   make start
   ```

   Wait until all 23+ containers are healthy.

2. **DAR files** in `quickstart/daml/dars/`:
   - `kairo-dex-2.5.0.dar`
   - `kairo-dex-simple-escrow-v3-1.0.0.dar`
   - `kairo-featured-app-proxies-1.0.1.dar`
   - `splice-util-batched-markers-1.0.0.dar`
   - `fungible-token-1.0.2.dar`

3. **`canton-exchange-backend`** cloned at the path configured in the script (default: `/Users/lehoanganh/Working/FETCH/Angelhack/Canton/canton-exchange-backend`). Edit the `EXCHANGE_BACKEND_DIR` variable at the top of the script to change this.

4. **Tools** installed: `curl`, `jq`, `openssl`, `docker`.

## Usage

```bash
cd quickstart/docker/setup-exchange
./setup-exchange.sh
```

The script is idempotent for DAR uploads (re-uploading the same DAR is a no-op). However, each run creates new FeaturedAppRight and BatchedMarkersProxy contracts on the ledger.

## Authentication

The script auto-detects the auth mode from `quickstart/.env.local`:

- **`shared-secret`** (default) - Generates HS256 JWTs locally using the secret `"unsafe"` with audience `https://canton.network.global`.
- **`oauth2`** - Obtains tokens from Keycloak at `keycloak.localhost:8082` using pre-configured client credentials from the quickstart keycloak module.

The Super Validator (SV) participant always uses shared-secret auth, even in oauth2 mode, because there is no Keycloak realm for SV in the quickstart environment.

## How It Works

### DAR Upload

DARs are uploaded as binary `application/octet-stream` POST requests to the Canton JSON API v2 endpoint `/v2/packages`. Each upload has retry logic (3 attempts, 10-second delay) to handle transient 503 timeouts on large DARs.

### FeaturedAppRight Creation

Creating a `FeaturedAppRight` requires exercising the `AmuletRules_DevNet_FeatureApp` choice on the `AmuletRules` contract. This is a DevNet-only operation.

The challenge is that `AmuletRules` is owned by the DSO party, which lives on the Super Validator participant -- not the app-user participant. The script solves this with the **disclosed contract** pattern:

1. Fetch the `AmuletRules` contract from the SV participant (`:4975`), including its `createdEventBlob`.
2. Submit an `ExerciseCommand` from the app-user participant (`:2975`), passing the fetched contract as a `disclosedContracts` entry.
3. The `actAs` is set to the app-user party (required as the choice's authorizer), not the DSO party.

### BatchedMarkersProxy Creation

`BatchedMarkersProxy` is a simpler contract from the `splice-util-batched-markers` package. It has two fields (`provider` and `dso`) and is signed only by the `provider`. The script creates it with a `CreateCommand` directly from the app-user participant.

### Backend Configuration

The generated `.env.local` configures the `canton-exchange-backend` NestJS application to connect to:

- The App Provider participant's JSON API (`:3975`) as the ledger endpoint
- The App Provider's Validator API (`:3903`)
- Its own PostgreSQL database on port 5433
- Auth credentials matching the detected auth mode

### Docker Network

The exchange backend's `docker-compose.yml` references an external network `splice-validator_splice_validator`. The script auto-creates this network if it doesn't exist, since the quickstart uses a different network name (`quickstart`).

## Canton JSON API v2 Reference

Key endpoints used by the script:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v2/packages` | POST | Upload DAR files (binary) |
| `/v2/users/{userId}` | GET | Resolve party ID from user |
| `/v2/state/connected-synchronizers` | GET | Get the global synchronizer ID |
| `/v2/state/ledger-end` | GET | Get the current ledger offset |
| `/v2/state/active-contracts` | POST | Query active contracts by party and template |
| `/v2/commands/submit-and-wait` | POST | Submit a command and wait for completion |

### Command Body Format

All commands submitted via `/v2/commands/submit-and-wait` use this structure:

```json
{
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
```

Choice arguments and create arguments use **plain JSON** (not verbose Daml-LF `Record`/`fields` encoding).

## Quickstart Port Scheme

| Participant | Ledger API | Admin API | Validator API | JSON API |
|-------------|-----------|-----------|---------------|----------|
| Super Validator (SV) | 4901 | 4902 | 4903 | 4975 |
| App Provider | 3901 | 3902 | 3903 | 3975 |
| App User | 2901 | 2902 | 2903 | 2975 |

## Troubleshooting

**DAR upload returns 503**: The participant is busy processing a previous upload. The script retries automatically (3 attempts). If it still fails, wait a minute and re-run.

**FeaturedAppRight creation fails with "security-sensitive error"**: The app-user participant doesn't have visibility on the AmuletRules contract. This usually means the SV participant (`:4975`) is not reachable. Verify the quickstart is fully up.

**Docker network error**: If `docker compose up -d postgres` fails with "network splice-validator_splice_validator not found", the script should auto-create it. If this still fails, run manually: `docker network create splice-validator_splice_validator`.

**PostgreSQL not ready**: The script waits up to 60 seconds. If it times out, check `docker compose logs postgres` in the exchange backend directory.

**Migrations fail**: Ensure the `canton-exchange-backend` has its dependencies installed (`yarn install`) and that the database is accessible at `localhost:5433`.

## After Setup

Start the exchange backend:

```bash
cd /path/to/canton-exchange-backend
yarn start:dev
```

The backend will be available at `http://localhost:3003`.

To register the FeaturedAppRight in the backend database, use the `curl` command printed at the end of the setup script output (Step 8).
