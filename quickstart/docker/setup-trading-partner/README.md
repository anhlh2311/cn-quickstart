# Trading Partner Validator Setup

Scripts for setting up the trading-partner validator node on the quickstart localnet. This prepares the environment for testing the `trading-js-sdk` and `partner-api` from the `canton-exchange-backend`.

## Prerequisites

- Quickstart running with all profiles (including `trading-partner`): `cd quickstart && make start`
- Exchange backend setup completed (`setup-exchange/01` through `07`)
- DAR files present in `quickstart/daml/dars/`

## Setup

```bash
cp .env.example .env
# Edit .env if needed (defaults work for standard quickstart)
./01-setup-trading-partner.sh
./02-request-partner-api-key.sh
```

## Scripts

| Script | Description |
|--------|-------------|
| `01-setup-trading-partner.sh` | Upload DARs, resolve party IDs, write `trading-partner-config.json` |
| `02-request-partner-api-key.sh` | Issue a partner API key from the exchange backend, write `partner-api-key.json` + `trade-request-config.json` |
| `test-trade-request.sh` | End-to-end test: create TradeProposal on trading-partner node → call `POST /trading-partner/trade-request` |

---

## Script 1: `01-setup-trading-partner.sh`

### What It Does

1. Detects auth mode from quickstart `.env.local`
2. Uploads `kairo-dex-simple-escrow-v3` and all utility-related DARs to the trading-partner participant (port 1975)
3. Resolves trading-partner party ID, DSO party, and synchronizer ID
4. Writes `trading-partner-config.json` with all configuration needed for `trading-js-sdk`

## Trading Partner Node Info

### Port Scheme

The trading-partner uses port prefix `1xxx`:

| Port | Service |
|------|---------|
| 1901 | Ledger API (gRPC) |
| 1902 | Admin API (gRPC) |
| 1975 | JSON API v2 (HTTP) |
| 1903 | Validator Admin API |
| 1000 | Wallet/ANS UI (via nginx) |

### URLs

| URL | Description |
|-----|-------------|
| `http://localhost:1975` | JSON API v2 (direct) |
| `http://localhost:1903` | Validator Admin API (direct) |
| `http://wallet.localhost:1000` | Wallet Web UI |
| `http://ans.localhost:1000` | ANS Web UI |
| `http://canton.localhost:1000` | JSON API v2 (via nginx) |
| `http://json-ledger-api.localhost:1000` | JSON API v2 (via nginx) |
| `grpc://grpc-ledger-api.localhost:1000` | Ledger API gRPC (via nginx) |

### Infrastructure

| Component | Details |
|-----------|---------|
| Canton participant ID | `trading-partner` |
| Splice validator node name | `tp-validator_backend` (max 30 chars enforced by Splice) |
| Party hint | `trading_partner_${PARTY_HINT}` |
| Databases | `participant-trading-partner`, `validator-trading-partner` |
| Docker profile | `trading-partner` (enabled by default) |
| Auth mode | Shared-secret only (HS256, secret `unsafe`, audience `https://canton.network.global`) |
| Onboarding secret | `trading-partner-validator-onboarding-secret` (registered in SV's `expected-validator-onboardings`) |
| Docker containers | `wallet-web-ui-trading-partner`, `ans-web-ui-trading-partner` |

### Auth

The trading-partner always uses shared-secret auth (no Keycloak realm configured). Generate a JWT with:
- **sub**: `ledger-api-user`
- **aud**: `https://canton.network.global`
- **secret**: `unsafe`
- **algorithm**: HS256

### Comparison with Other Participants

| Participant | Prefix | Ledger API | JSON API | Validator API | UI Port |
|-------------|--------|-----------|----------|---------------|---------|
| Trading Partner | `1xxx` | 1901 | 1975 | 1903 | 1000 |
| App User | `2xxx` | 2901 | 2975 | 2903 | 2000 |
| App Provider | `3xxx` | 3901 | 3975 | 3903 | 3000 |
| Super Validator | `4xxx` | 4901 | 4975 | 4903 | 4000 |

### Output

`trading-partner-config.json` — Contains party IDs, synchronizer ID, and connection details for configuring `KairoExchangeClient` from the `trading-js-sdk`.

```json
{
  "tradingPartnerParty": "trading_partner_quickstart-...",
  "dsoParty": "DSO::1220...",
  "synchronizerId": "global-domain::1220...",
  "ledgerApiUrl": "http://localhost:1975",
  "validatorApiUrl": "http://localhost:1903",
  "authMode": "share-secret",
  "authConfig": { "secret": "unsafe", "audience": "https://canton.network.global", "userId": "ledger-api-user" },
  "ports": { "ledgerApi": 1901, "adminApi": 1902, "jsonApi": 1975, "validatorApi": 1903 }
}
```

---

## Script 2: `02-request-partner-api-key.sh`

Issues a partner API key from the canton-exchange-backend for use by the trading partner. Also writes a `trade-request-config.json` with default trade parameters that `test-trade-request.sh` reads.

### Prerequisites

- `01-setup-trading-partner.sh` completed (`trading-partner-config.json` exists)
- Exchange backend running (`BACKEND_URL` configured in `setup-exchange/.env`)
- Admin credentials set in `setup-exchange/.env`: `BACKEND_ADMIN_USERNAME` + `BACKEND_ADMIN_PASSWORD`

### Configuration

The script sources both `.env` files:

| Variable | Source | Default | Description |
|----------|--------|---------|-------------|
| `BACKEND_URL` | `setup-exchange/.env` | `http://localhost:3003` | Exchange backend URL |
| `BACKEND_ADMIN_USERNAME` | `setup-exchange/.env` | `superadmin` | Backend admin username |
| `BACKEND_ADMIN_PASSWORD` | `setup-exchange/.env` | _(required)_ | Backend admin password |

### What It Does

| Step | Action |
|------|--------|
| 1 | Reads `trading-partner-config.json` for the trading partner party ID |
| 2 | Logs into the backend via `POST /admin/auth/login` |
| 3 | Issues a new partner API key via `POST /admin/partner-api-keys` |
| 4 | Writes `partner-api-key.json` with the raw key and metadata |
| 5 | Writes `trade-request-config.json` with default trade parameters |

### Output

**`partner-api-key.json`**:

```json
{
  "generatedAt": "2026-04-10T00:00:00Z",
  "backendUrl": "http://localhost:3003",
  "tradingPartnerParty": "trading_partner_quickstart-...",
  "partnerApiKey": {
    "id": "uuid...",
    "prefix": "kex_...",
    "name": "Trading Partner - trading_partner_quickstart-...",
    "rawKey": "kex_..."
  }
}
```

**`trade-request-config.json`**:

```json
{
  "generatedAt": "2026-04-10T00:00:00Z",
  "backendUrl": "http://localhost:3003",
  "partnerApiKey": "kex_...",
  "tradingPartnerParty": "trading_partner_quickstart-...",
  "traderPartyId": "trader-0::1220...",
  "traderUserId": "trader-0",
  "tradeRequest": {
    "inputAmount": "10",
    "inputTokenType": "Amulet",
    "outputTokenType": "CBTC"
  }
}
```

Edit `trade-request-config.json` to change the swap amount or token types before running `test-trade-request.sh`.

---

## Script 3: `test-trade-request.sh`

End-to-end test for `POST /trading-partner/trade-request`. Simulates the full partner trade flow from the trading-partner node's perspective.

### Prerequisites

- `01-setup-trading-partner.sh` completed
- `02-request-partner-api-key.sh` completed (`partner-api-key.json` and `trade-request-config.json` exist)
- Exchange backend running and fully configured (scripts 01–07 in `setup-exchange/`)
- Trader party onboarded with Amulet holdings on the trading-partner node:
  ```bash
  # Onboard traders (setup-internal-parties/)
  cd ../setup-internal-parties
  ./01-allocate-internal-parties.sh
  ./04-faucet-amulet.sh
  ```

### Configuration

Config is loaded automatically from `trade-request-config.json`. All values can be overridden via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PARTNER_API_KEY` | from `partner-api-key.json` | `x-api-key` for the exchange backend partner API |
| `TRADER_PARTY_ID` | first party in `internal-parties.json` | Fully qualified trader party ID |
| `TRADER_USER_ID` | from `internal-parties.json` | Trader's Canton user ID |
| `INPUT_AMOUNT` | `10` (from `trade-request-config.json`) | Amount of input token to swap |
| `INPUT_TOKEN_TYPE` | `Amulet` | Input token (`Amulet` or `CBTC`) |
| `OUTPUT_TOKEN_TYPE` | `CBTC` | Output token |

### What It Does

| Step | Action |
|------|--------|
| 1 | Fetches `TradeProposalFactory` disclosure from `GET /partner-api/trade-proposal-factory` |
| 2 | Fetches Amulet allocation factory from the validator scan-proxy |
| 3 | Queries the trader's Amulet holdings from the trading-partner node |
| 4 | Creates a `TradeProposal` on the trading-partner node via `submit-and-wait` |
| 5 | Queries disclosures for the created `TradeProposal` contract |
| 6 | Calls `POST /trading-partner/trade-request` with the proposal CID and disclosures |
| 7 | Verifies the response `status == "SUCCEEDED"` |

### Usage

```bash
# Run with defaults from trade-request-config.json
./test-trade-request.sh

# Override trade amount
INPUT_AMOUNT=50 ./test-trade-request.sh

# Override trader
TRADER_PARTY_ID="trader-1::1220..." TRADER_USER_ID="trader-1" ./test-trade-request.sh
```

---

## Full End-to-End Flow

```bash
# 1. Exchange backend setup (setup-exchange/)
cd ../setup-exchange
./01-setup-exchange.sh
./02-register-featured-app-right.sh
./03-register-cbtc-token.sh
./04-register-amulet-token.sh
./05-setup-liquidity-provider.sh
./06-fund-liquidity-provider.sh
./07-create-trade-proposal-factory.sh

# 2. Onboard traders on the trading-partner node (setup-internal-parties/)
cd ../setup-internal-parties
cp .env.example .env
# Edit .env: set PARTICIPANT_JSON_API=http://localhost:1975, VALIDATOR_API=http://localhost:1903
./01-allocate-internal-parties.sh
# Edit transfers.json with trader party IDs and desired amounts
./04-faucet-amulet.sh

# 3. Trading partner setup
cd ../setup-trading-partner
./01-setup-trading-partner.sh
./02-request-partner-api-key.sh
# Optionally edit trade-request-config.json to change swap amount/tokens

# 4. Run the test
./test-trade-request.sh
```
