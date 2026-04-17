# Canton Exchange Backend Setup Scripts

Automated setup and registration scripts for the Canton Exchange Backend (`canton-exchange-backend`) on the local Canton Network Quickstart environment.

## Scripts Overview

| Script | Purpose | Run Order |
|--------|---------|-----------|
| `01-setup-exchange.sh` | Upload DARs, create on-ledger contracts, generate backend `.env`, start DB | 1st (required) |
| `02-register-featured-app-right.sh` | Register the FeaturedAppRight contract in the backend database | 2nd (after backend is running) |
| `03-register-cbtc-token.sh` | Onboard CBTC external party, create InstrumentConfiguration + AllocationFactory (utility), register token issuer | 3rd (after backend is running) |
| `04-register-amulet-token.sh` | Register Amulet (CC) token issuer in backend (DSO-managed, dynamic factory) | 4th (after backend is running) |
| `05-setup-liquidity-provider.sh` | Upload DARs to app-provider, create internal party, register as LP in backend | 5th (after backend is running) |
| `06-fund-liquidity-provider.sh` | Mint CBTC and faucet Amulet tokens to the LP party | 6th (after 03 + 05 completed) |
| `07-create-trade-proposal-factory.sh` | Create (or find) a `TradeProposalFactory` contract on the app-user node and write `trade-proposal-factory.json` | Any time after `01-setup-exchange.sh` |

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

# 5. Register CBTC token (external party + InstrumentConfiguration + AllocationFactory + token issuer)
BACKEND_ADMIN_PASSWORD=<password> ./03-register-cbtc-token.sh

# 6. Register Amulet token (DSO-managed, dynamic factory — just token issuer DB entry)
BACKEND_ADMIN_PASSWORD=<password> ./04-register-amulet-token.sh

# 7. Setup Liquidity Provider on app-provider node
BACKEND_ADMIN_PASSWORD=<password> ./05-setup-liquidity-provider.sh

# 8. Fund LP with CBTC and Amulet tokens
./06-fund-liquidity-provider.sh

# 9. Create TradeProposalFactory (needed for partner trade-request flow)
./07-create-trade-proposal-factory.sh
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
   - `kairo-dex-v3-1.0.0.dar`
   - `kairo-dex-simple-escrow-v4-1.0.0.dar`
   - `kairo-dex-simple-marketquote-v2-1.0.0.dar`
   - `kairo-featured-app-proxies-1.0.1.dar`
   - `splice-util-batched-markers-1.0.0.dar`
   - `splice-util-token-standard-wallet-1.0.0.dar`
   - `utility-collateral-app-v1-1.0.0.dar`
   - `utility-commercials-v0-0.4.1.dar`
   - `utility-credential-app-v0-0.4.1.dar`
   - `utility-credential-v0-0.1.0.dar`
   - `utility-registry-app-v0-0.7.0.dar`
   - `utility-registry-holding-v0-0.2.1.dar`
   - `utility-registry-v0-0.6.0.dar`
   - `utility-settlement-app-v1-1.2.0.dar`
   - `utility-version-v0-0.0.1.dar`

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
| `BACKEND_ADMIN_USERNAME` | Superadmin username for the exchange backend (scripts 04, 05) | `superadmin` (default) |
| `BACKEND_ADMIN_PASSWORD` | Superadmin password for the exchange backend (scripts 04, 05) | Required — set via inline env var |
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

### `amulet-config.json`

Amulet token configuration used by `04-register-amulet-token.sh`:

```json
{
  "tokenId": "Amulet",
  "displayName": "Amulet",
  "symbol": "CC",
  "priceSourceId": ""
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

Onboards a CBTC (Canton BTC) external party, creates `InstrumentConfiguration`, `AllocationFactory`, `TransferRule`, and `AppRewardConfiguration` contracts from the **utility** packages, and registers the token issuer in the exchange backend.

The utility `AllocationFactory` is a single contract that implements three interfaces: `AllocationFactory`, `TransferFactory`, and `BurnMintFactory` — replacing the separate `TokenAllocationFactory` + `TokenTransferFactory` contracts from the fungible-token package.

> **Note**: The previous fungible-token version is preserved as `03-register-cbtc-token-using-fungible-token.sh`.

```bash
# Requires: 01-setup-exchange.sh completed AND backend is running
BACKEND_ADMIN_PASSWORD=<password> ./03-register-cbtc-token.sh
```

**Prerequisites**: `01-setup-exchange.sh` has been run (including utility DARs uploaded). The exchange backend is running. `@canton-network/core-signing-lib` must be installed in the exchange backend (used for Ed25519 key generation and signing). `BACKEND_ADMIN_PASSWORD` must be provided.

**Steps performed**:

| Step | Action | Details |
|------|--------|---------|
| 0 | Admin login | Authenticates with the backend via `POST /admin/auth/login` using `BACKEND_ADMIN_USERNAME`/`BACKEND_ADMIN_PASSWORD`. Obtains an `accessToken` for subsequent API calls |
| 1 | Generate Ed25519 keypair | Creates a NaCl keypair and computes the Canton fingerprint. Stored in `cbtc-network-keypair.json`. Skips if file exists |
| 2 | Onboard external party | Uses the Canton JSON API v2 external party flow: `generate-topology` -> sign multiHash -> `allocate`. Skips if party already exists |
| 3 | Create Canton user & grant rights | Creates a dedicated Canton user (`cbtc-network-user`) with `ActAs`/`ReadAs` rights for the external party. Also grants the admin user rights over the external party |
| 4 | Create InstrumentConfiguration | Creates the instrument config for CBTC (`utility-registry-v0`) via **interactive submission**. Defines the token identifier, scheme, and credential requirements. Skips if contract exists |
| 5 | Create AllocationFactory | Creates the multi-purpose factory (`utility-registry-app-v0`) via **interactive submission**. Implements AllocationFactory, TransferFactory, and BurnMintFactory interfaces. Skips if contract exists |
| 5b | Create TransferRule | Creates a `TransferRule` contract (`utility-registry-v0`) via **interactive submission** signed by the CBTC-NETWORK external party. Must be disclosed during transfers. Skips if contract exists |
| 5c | Create AppRewardConfiguration | Creates an `AppRewardConfiguration` contract (`utility-registry-v0`) via **submit-and-wait** signed by the executor party (APP_USER_PARTY). Defines the operator/provider app reward split (50/50 default). DSO party resolved from validator scan-proxy. Skips if contract exists |
| 6 | Acquire disclosures | Re-queries all four contracts (AllocationFactory, InstrumentConfiguration, TransferRule, AppRewardConfiguration) with `includeCreatedEventBlob: true` to get disclosure blobs |
| 7 | Write `cbtc-factories.json` | Stores all four contract IDs, template names, template IDs, and disclosures |
| 8 | Register token issuer in backend | `GET /token-issuer/token/CBTC` to check; `POST /token-issuer` if new; `PATCH /token-issuer/token/CBTC` if already registered (updates factory CID + disclosed contracts) |

**Idempotency**: Every step checks for existing state before creating:

- Keypair file reused if `cbtc-network-keypair.json` exists.
- External party checked via `GET /v2/parties/party?parties=...`.
- Canton user checked via `GET /v2/users/{userId}` (HTTP 200 = exists).
- InstrumentConfiguration, AllocationFactory, TransferRule, and AppRewardConfiguration queried from active contracts before creating.
- Backend registration: existing issuers are updated via `PATCH` (re-running after new factory contracts always refreshes the stored data).

### Utility Package Contracts

**InstrumentConfiguration** (`utility-registry-v0`):

- Template: `Utility.Registry.V0.Configuration.Instrument:InstrumentConfiguration`
- Fields: `operator`, `provider`, `registrar` (all set to CBTC-NETWORK party), `defaultIdentifier` (source=CBTC-NETWORK, id="CBTC", scheme="RegistrarInternalScheme")
- Signatories: `provider`, `registrar`

**AllocationFactory** (`utility-registry-app-v0`):

- Template: `Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory`
- Fields: `provider`, `registrar`, `operator` (all set to CBTC-NETWORK party)
- Signatories: `provider`, `registrar`; Observer: `operator`
- Implements: `AllocationFactory`, `TransferFactory`, `BurnMintFactory` interfaces

**TransferRule** (`utility-registry-v0`):

- Template: `Utility.Registry.V0.Rule.Transfer:TransferRule`
- Fields: `operator` (APP_USER_PARTY / executor), `provider` (CBTC-NETWORK), `registrar` (CBTC-NETWORK)
- Signatories: `provider`, `registrar` (both CBTC-NETWORK); Observer: `operator`
- Must be explicitly disclosed to users during transfer operations

**AppRewardConfiguration** (`utility-registry-v0`):

- Template: `Utility.Registry.V0.Configuration.AppReward:AppRewardConfiguration`
- Fields: `operator` (APP_USER_PARTY), `provider` (CBTC-NETWORK), `details.dso` (DSO party), `details.operatorAppRewardBeneficiary` (`{beneficiary: operator, weight: "0.5"}`)
- Signatory: `operator` (APP_USER_PARTY); Observer: `provider`
- Defines how featured app rewards are split: 50% to operator, 50% to provider (configurable)

### Backend Registration Format

The backend `POST /token-issuer` body includes:

- `discloseContracts`: Array of 2 disclosed contracts (AllocationFactory + InstrumentConfiguration) — each with `contractId`, `templateId`, `createdEventBlob`, `synchronizerId`
- `choiceContextData`: Tagged metadata values including `instrument-configuration` (contract ID reference) and empty credential lists

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
- `cbtc-factories.json`: Stores AllocationFactory, InstrumentConfiguration, TransferRule, and AppRewardConfiguration contract IDs, template names, template IDs, and disclosure blobs.

**Verify registration**:

```bash
curl -s http://localhost:3003/token-issuer/token/CBTC -H 'Authorization: Bearer <token>' | jq
jq '.' cbtc-factories.json
```

---

## Script 4: `04-register-amulet-token.sh`

Registers the Amulet (CC) token issuer in the exchange backend. Unlike CBTC which requires external party onboarding and on-ledger contract creation, Amulet is the **native Canton Network cryptocurrency managed by the DSO** (Designated Sponsoring Organization).

The Amulet allocation factory is fetched **dynamically** from the validator's scan-proxy registry at runtime, so no allocation-factory database entry or contract creation is needed.

```bash
# Requires: 01-setup-exchange.sh completed AND backend is running
BACKEND_ADMIN_PASSWORD=<password> ./04-register-amulet-token.sh
```

**Prerequisites**: `01-setup-exchange.sh` has been run. The exchange backend is running. `BACKEND_ADMIN_PASSWORD` must be provided (either inline or set in the environment).

**Steps performed**:

| Step | Action | Details |
|------|--------|---------|
| 0 | Admin login | Authenticates with the backend via `POST /admin/auth/login` using `BACKEND_ADMIN_USERNAME`/`BACKEND_ADMIN_PASSWORD`. Obtains an `accessToken` for subsequent API calls |
| 1 | Resolve DSO party | Reads DSO party from backend `.env`, or falls back to the validator API (`/v0/scan-proxy/dso-party-id`) |
| 2 | Register token issuer | `POST /token-issuer` with admin=DSO party, tokenId="Amulet", symbol="CC". `discloseContracts` and `choiceContextData` are empty (overridden at runtime with live data) |

**Idempotency**: The script checks if the Amulet token issuer already exists (`GET /token-issuer/token/Amulet`) before registering. Backend returns HTTP 409 if already registered, handled gracefully.

### How Amulet Differs from CBTC

| Aspect | CBTC (Script 03) | Amulet (Script 04) |
|--------|-------------------|---------------------|
| Admin party | External party (CBTC-NETWORK) | DSO party (pre-existing) |
| Party onboarding | Ed25519 keypair + external party allocation | Not needed |
| Contract creation | InstrumentConfiguration + AllocationFactory | Not needed (DSO-managed) |
| Allocation factory | Stored in backend DB | Fetched dynamically from scan-proxy |
| Disclosed contracts | 2 contracts (AllocationFactory + InstrumentConfiguration) | 3 contracts (ExternalPartyAmuletRules + AmuletRules + OpenMiningRound) — provided at runtime |
| `choiceContextData` | instrument-configuration + credentials | amulet-rules + open-round — provided at runtime |
| Token issuer | Stored with factory details | Stored with empty factory details (enriched at runtime) |

### Dynamic Factory Contracts

When the backend receives a request for `GET /allocation-factory/type/amulet`, it calls the validator's scan-proxy registry:

```
POST /v0/scan-proxy/registry/allocation-instruction/v1/allocation-factory
Body: { "choiceArguments": {}, "excludeDebugFields": true }
```

The response includes:

- **`factoryId`**: Contract ID of the `ExternalPartyAmuletRules` contract
- **`disclosedContracts`**: 3 contracts (ExternalPartyAmuletRules, AmuletRules, OpenMiningRound)
- **`choiceContextData`**: `amulet-rules` (AmuletRules CID) and `open-round` (OpenMiningRound CID)

These values change as rounds advance, which is why they must be fetched dynamically.

**Verify registration**:

```bash
curl -s http://localhost:3003/token-issuer/token/Amulet -H 'Authorization: Bearer <token>' | jq
curl -s http://localhost:3003/allocation-factory/type/amulet -H 'Authorization: Bearer <token>' | jq
```

---

## Script 5: `05-setup-liquidity-provider.sh`

Sets up a Liquidity Provider on the app-provider node. Uploads DARs, creates an internal party, and registers it as an LP in the exchange backend.

### Usage

```bash
# Default: self-LP with party hint "lp-provider"
BACKEND_ADMIN_PASSWORD=<password> ./05-setup-liquidity-provider.sh

# Custom party hint and name
BACKEND_ADMIN_PASSWORD=<password> LP_PARTY_HINT=my-lp LP_NAME="My Custom LP" ./05-setup-liquidity-provider.sh

# External LP (with LP backend API)
BACKEND_ADMIN_PASSWORD=<password> LP_SELF=false LP_API=http://lp-backend:3001 LP_TOKEN=secret ./05-setup-liquidity-provider.sh

# Custom supported tokens
BACKEND_ADMIN_PASSWORD=<password> LP_SUPPORT_TOKENS=Amulet,CBTC,USDCx ./05-setup-liquidity-provider.sh
```

**Prerequisites**: `01-setup-exchange.sh` has been run. The exchange backend is running. A `SUPER_ADMIN` account exists in the backend.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LP_PARTY_HINT` | `lp-provider` | PartyHint prefix for the new Canton party |
| `LP_NAME` | `Local LP` | Human-readable LP name |
| `LP_SELF` | `true` | `true` for self-LP (no external API), `false` for external LP |
| `LP_TYPE` | `public` | `public` or `private` |
| `LP_SUPPORT_TOKENS` | `Amulet,CBTC` | Comma-separated list of supported token IDs |
| `LP_API` | `http://localhost:3001` | External LP backend URL (only when `LP_SELF=false`) |
| `LP_TOKEN` | `local-lp-token` | External LP API key (only when `LP_SELF=false`) |
| `BACKEND_ADMIN_USERNAME` | `superadmin` | Backend admin username for API login |
| `BACKEND_ADMIN_PASSWORD` | _(required)_ | Backend admin password for API login |
| `LP_BACKEND_DIR` | _(from .env)_ | Absolute path to `kairo-dex-lp-backend` repo. If set, generates `.env.local` for the LP backend |
| `LP_BACKEND_PORT` | `3002` | Port for the LP backend |
| `LP_BACKEND_API_KEY` | `local-lp-api-key` | API key protecting the LP backend's REST API |

### Steps Performed

| Step | Action | Details |
|------|--------|---------|
| 1 | Upload DARs | Uploads all DAR files from `.env` to app-provider (`:3975`). Skips if already present |
| 2 | Create internal party | Allocates a party on the app-provider node with the given `LP_PARTY_HINT`. Grants `actAs`/`readAs` rights to the admin user. Skips if party already exists |
| 3 | Register LP in backend | Logs into the backend as admin and calls `POST /liquidity-provider` with the party ID and configuration |
| 4 | Generate LP backend `.env` | Writes `.env.local` for `kairo-dex-lp-backend` with Canton participant, auth, party IDs, template IDs. Activates as `.env`. Skips if `LP_BACKEND_DIR` not set |
| 5 | Write result JSON | Exports LP details to `liquidity-provider.json` |

### Self-LP vs External LP

| Aspect | Self-LP (`LP_SELF=true`) | External LP (`LP_SELF=false`) |
|--------|------------------------|------------------------------|
| Backend field | `isSelfLp: true` | `isSelfLp: false` |
| Required fields | `lpPartyId` only | `lpPartyId`, `lpApi`, `lpToken`, `burnPartyId` |
| Trade settlement | Executor selects holdings inline | Calls external LP backend API |
| Load balancing | Not auto-selected | Selected by `lastUsed` (public type) |

### Generated LP Backend `.env.local`

When `LP_BACKEND_DIR` is set, the script generates a `.env.local` for `kairo-dex-lp-backend` with:

| Variable | Source |
|----------|--------|
| `PARTICIPANT_LEDGER_API` | App Provider JSON API from `.env` |
| `VALIDATOR_API` | App Provider Validator API from `.env` |
| `ADMIN_USER` | Auth-mode-dependent admin user |
| `GLOBAL_SYNCHRONIZER_ID` | Resolved from app-provider participant |
| `API_KEYS` | `LP_BACKEND_API_KEY` env var |
| `AUTH_MODE` / `AUTH0_*` | Detected from quickstart auth mode |
| `EXECUTOR_PARTY_ID` | From exchange backend `.env` |
| `VALIDATOR_PARTY_ID` | Newly created LP party ID |
| `KAIRO_CLIENT_API_URL` | Exchange backend URL |
| `KAIRO_CLIENT_API_KEY` | `LP_BACKEND_API_KEY` env var |
| Template IDs | Matching uploaded DAR versions |

The existing `.env` is backed up before overwriting.

### Idempotency

- DAR uploads are skipped if all packages are already present.
- Party allocation gracefully handles existing parties (falls back to lookup).
- Backend LP registration returns HTTP 409 if the LP already exists, handled gracefully.

### Output

`liquidity-provider.json`:

```json
{
  "generatedAt": "2026-04-08T05:00:00Z",
  "liquidityProvider": {
    "id": "uuid",
    "lpPartyId": "lp-provider::1220abc...",
    "lpName": "Local LP",
    "isSelfLp": true,
    "type": "public",
    "partyHint": "lp-provider",
    "supportTokens": ["Amulet", "CBTC"]
  },
  "registrationResponse": { ... }
}
```

**Verify registration:**

```bash
curl -s http://localhost:3003/liquidity-provider -H 'Authorization: Bearer <token>' | jq
cat liquidity-provider.json | jq
```

---

## Script 6: `06-fund-liquidity-provider.sh`

Funds the LP party with CBTC and Amulet tokens so it has liquidity for trade settlement.

### Usage

```bash
# Default: 10,000 CBTC + 100,000,000 Amulet
./06-fund-liquidity-provider.sh

# Custom amounts
CBTC_TOTAL_AMOUNT=50000 AMULET_TOTAL_AMOUNT=500000000 ./06-fund-liquidity-provider.sh

# Custom number of holdings
CBTC_NUM_HOLDINGS=20 AMULET_NUM_HOLDINGS=50 ./06-fund-liquidity-provider.sh
```

**Prerequisites**: Scripts 01, 03, and 05 must have been run. The quickstart must be in DevNet mode (for Amulet faucet).

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CBTC_TOTAL_AMOUNT` | `10000` | Total CBTC to mint |
| `CBTC_NUM_HOLDINGS` | `10` | Number of CBTC holdings (amount split evenly) |
| `AMULET_TOTAL_AMOUNT` | `100000000` | Total Amulet (CC) to tap |
| `AMULET_NUM_HOLDINGS` | `100` | Number of Amulet holdings (amount split evenly) |

### Steps Performed

| Step | Action | Details |
|------|--------|---------|
| 1a | Create CBTC mint requests | LP party exercises `AllocationFactory_RequestMint` via `submit-and-wait` on app-provider. Creates `MintRequest` contracts |
| 1b | Accept mint requests | CBTC-NETWORK exercises `MintRequest_Accept` via interactive submission on app-user. Creates `Holding` contracts |
| 2 | Tap Amulet | LP party exercises `AmuletRules_DevNet_Tap` via `submit-and-wait` on app-provider. Disclosed contracts (AmuletRules + OpenMiningRound) fetched from SV |
| 3 | Write holdings report | Exports all holding contract IDs and amounts to `lp-holdings.json` |

### How It Works

**CBTC minting** follows a two-step flow across two participants:

1. **RequestMint** (app-provider): LP party is internal here, so regular `submit-and-wait` works. AllocationFactory + InstrumentConfiguration are passed as disclosed contracts (from `cbtc-factories.json`).
2. **Accept** (app-user): CBTC-NETWORK is an external party hosted on app-user, so interactive submission with Ed25519 signing is used.

**Amulet faucet** is a single-step DevNet operation:

- LP party exercises `AmuletRules_DevNet_Tap` from app-provider with AmuletRules + OpenMiningRound as disclosed contracts (fetched from SV participant).

### Output

`lp-holdings.json`:

```json
{
  "generatedAt": "2026-04-08T12:00:00Z",
  "lpPartyId": "liquidity-provider::1220...",
  "lpName": "Local LP",
  "cbtc": {
    "totalAmount": 10000,
    "holdings": [
      { "contractId": "00abcd...", "amount": 1000 }
    ]
  },
  "amulet": {
    "totalAmount": 100000000,
    "holdings": [
      { "contractId": "00efgh...", "amount": 1000000 }
    ]
  }
}
```

---

## Script 7: `07-create-trade-proposal-factory.sh`

Creates (or finds) a `TradeProposalFactory` contract on the app-user (Kairo) node, then writes `trade-proposal-factory.json` with the contract's disclosure data. Trading partners use this file to fetch the factory's `createdEventBlob` when creating `TradeProposal` contracts on their own nodes.

```bash
# Requires: 01-setup-exchange.sh completed (DARs uploaded)
./07-create-trade-proposal-factory.sh
```

**Prerequisites**: `01-setup-exchange.sh` has been run (DARs uploaded, including `kairo-dex-simple-escrow-v4`). The quickstart localnet must be running.

**Steps performed**:

| Step | Action | Details |
|------|--------|---------|
| 1 | Query existing factory | Queries the app-user node for an active `TradeProposalFactory` contract owned by the executor party (`includeCreatedEventBlob: true`) |
| 2 | Create if not found | Submits a `CreateCommand` via `submit-and-wait-for-transaction` with `admin: executorPartyId`. Waits 2 seconds, then re-queries for the disclosure blob |
| 3 | Write `trade-proposal-factory.json` | Stores the contract ID, template ID, `createdEventBlob`, synchronizer ID, and executor party ID |

**Idempotency**: If a `TradeProposalFactory` already exists on the ledger for the executor party, the script reuses it and skips creation.

### Contract Details

**TradeProposalFactory** (`kairo-dex-simple-escrow-v4`):

- Template: `Kairo.Escrow.TradeProposalFactory:TradeProposalFactory`
- Field: `admin` — the executor party ID (Kairo's app-user validator party)
- Signatory: `admin`

### Output File

`trade-proposal-factory.json`:

```json
{
  "generatedAt": "2026-04-10T00:00:00Z",
  "tradeProposalFactory": {
    "contractId": "00abcd...",
    "templateId": "a1b2c3...:Kairo.Escrow.TradeProposalFactory:TradeProposalFactory",
    "createdEventBlob": "<base64>",
    "synchronizerId": "global-domain::122..."
  },
  "executorPartyId": "kairo::1220..."
}
```

### How Partners Use This

When a trading partner wants to create a `TradeProposal`, they must disclose the `TradeProposalFactory` to the exchange's executor party. The `createdEventBlob` from this file is the disclosure payload required for `ExerciseCommand.disclosedContracts` in the partner's submission.

The exchange backend exposes this data via `GET /partner-api/trade-proposal-factory`, which reads it directly from the ledger at request time.

**Verify**:

```bash
# Check the output file
jq '.' trade-proposal-factory.json

# Or query the partner API endpoint (requires backend running)
curl -s http://localhost:3003/partner-api/trade-proposal-factory | jq
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
| Trading Partner | 1901 | 1902 | 1903 | 1975 |

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
