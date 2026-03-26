# Trading Partner Validator Setup

Scripts for setting up the trading-partner validator node on the quickstart localnet. This prepares the environment for testing the `trading-js-sdk` and `partner-api` from the `canton-exchange-backend`.

## Prerequisites

- Quickstart running with all profiles (including `trading-partner`): `cd quickstart && make start`
- Exchange backend setup completed (`setup-exchange/01-setup-exchange.sh` through `04`)
- DAR files present in `quickstart/daml/dars/`

## Setup

```bash
cp .env.example .env
# Edit .env if needed (defaults work for standard quickstart)
./01-setup-trading-partner.sh
```

## What It Does

1. Detects auth mode from quickstart `.env.local`
2. Uploads `kairo-dex-simple-escrow-v3` and all utility-related DARs to the trading-partner participant (port 1975)
3. Resolves trading-partner party ID, DSO party, and synchronizer ID
4. Outputs `trading-partner-config.json` with all configuration needed for `trading-js-sdk`

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

## Output

`trading-partner-config.json` — Contains party IDs, synchronizer ID, and connection details for configuring `KairoExchangeClient` from the `trading-js-sdk`.
