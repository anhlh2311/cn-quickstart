# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Canton Network Quickstart - a scaffolding template for developing Canton Network applications using the Global Synchronizer. Multi-language, Docker Compose-based, with Daml smart contracts, a Spring Boot Java backend, and a React TypeScript frontend.

**Key versions** (defined in `quickstart/.env`): Daml SDK 3.4.10, Splice 0.5.3, Canton 3.4.10, Java 21, Spring Boot 3.4.2, React 18.3.1

## Repository Structure

- `quickstart/` - Main application (all `make` commands run from here)
  - `daml/` - Daml smart contracts (licensing workflow + pre-built DARs in `dars/`)
  - `backend/` - Spring Boot Java service (gRPC + REST via OpenAPI)
  - `frontend/` - React + TypeScript + Vite application
  - `integration-test/` - Playwright E2E tests
  - `docker/` - Docker Compose modules, setup scripts, and UTXO handling scripts
  - `buildSrc/` - Gradle build logic (`Dependencies.kt` for centralized versions)
  - `common/openapi.yaml` - Shared OpenAPI spec (generates both Java server stubs and TS client types)
- `sdk/` - Documentation tooling (Sphinx, Vale)
- `exchange/` - Exchange module

## Build & Development Commands

All commands run from `quickstart/` directory:

```bash
# Initial setup (interactive - configures OAuth2/shared-secret, TEST_MODE, Observability)
make setup

# Build everything (frontend, backend, Daml, Docker images)
make build

# Build individual components
make build-frontend    # cd frontend && npm install && npm run build
make build-backend     # ./gradlew :backend:build
make build-daml        # ./gradlew :daml:build distTar

# Start/stop all services
make start
make stop
make restart

# Hot-reload frontend development
make vite-dev          # when already running
make start-vite-dev    # start + vite dev server

# Rebuild and restart individual services
make restart-frontend
make restart-backend
make restart-service SERVICE=<name>   # restart any named service

# Backend remote debugging (port 5005)
export DEBUG_ENABLED=true && make restart-backend

# Interactive Canton/Daml shells
make canton-console    # Canton console (App Provider)
make shell             # Daml Shell (connects to pqs-app-provider)
```

## Testing

```bash
# Daml unit tests
make test-daml         # runs: ./gradlew :daml:testDaml

# All unit tests (currently just Daml)
make test

# Frontend linting
cd frontend && npm run lint    # ESLint

# Playwright E2E tests (requires TEST_MODE=on and AUTH_MODE=oauth2 via make setup)
make integration-test

# Run a specific Playwright test
cd integration-test && npx playwright test tests/workflow.spec.ts

# View E2E test report
make show-integration-test-report
```

Integration tests are in `quickstart/integration-test/tests/` using Playwright with page object pattern (`pages/` directory). Test projects have dependency ordering: `login` → `workflow` → `tenant-registrations`.

## Cleanup Commands

```bash
make clean               # ./gradlew clean (build artifacts only)
make clean-docker        # stop + remove containers and volumes
make clean-application   # like clean-docker but leaves observability running
make clean-all           # full reset: build artifacts + docker containers + volumes
```

## Monitoring Running Services

```bash
make status    # docker-compose ps
make logs      # docker-compose logs (all services)
make tail      # docker-compose logs -f (follow)
make compose-config | tail -n +2 | yq eval '.services.<name>'   # inspect resolved config
```

## Architecture

### Licensing Workflow (Core Business Logic)

The app implements a licensing system between App Providers and App Users on the Canton Network. The workflow is: `AppInstallRequest` → `AppInstall` → `License` → `LicenseRenewalRequest` + `AppPaymentRequest` → `AcceptedAppPayment` → renewed `License`. Payments use Amulet (CC) cryptocurrency.

### Service Topology

Docker Compose orchestrates modular services assembled dynamically from `docker/modules/` based on configuration. Core services:

- **Canton** container: Ledger with 3 participant nodes (App Provider :3901, App User :2901, Super Validator :4901)
- **Splice** container: Validator services for each participant
- **PostgreSQL**: Multi-database instance for all services
- **Backend Service** (Spring Boot :8080): REST API for licensing workflow, connects to Canton via gRPC
- **Nginx**: Reverse proxy for frontend UIs and backend
- **Keycloak** (optional, :8082): OAuth2 identity provider with pre-configured realms
- **PQS**: Participant Query Service instances
- **Observability** (optional): Grafana :3030, Prometheus, Loki, Tempo, cAdvisor

Port scheme: prefix `4xxx`=SV, `3xxx`=App Provider, `2xxx`=App User; suffix `901`=Ledger API, `902`=Admin API, `903`=Validator API, `975`=JSON API.

### Code Generation Pipeline

- **OpenAPI** (`common/openapi.yaml`): Generates Spring server interfaces (`backend/build/generated-spring/`) and TypeScript client types (`frontend/src/openapi.d.ts` via `npm run gen:openapi`)
- **Daml codegen**: Java bindings from `licensing/.daml/dist/quickstart-licensing-0.0.1.dar` → `backend/build/generated-daml-bindings/`
- **Protobuf/gRPC**: Canton ledger API bindings for the Java backend
- **Token standard OpenAPI**: Additional Java clients from vendored specs (`token-metadata-v1.yaml`, `allocation-v1.yaml`) → `backend/build/generated-token-standard-openapi/`

### Gradle Multi-Project Build

- Root `build.gradle.kts`: License reporting + `configureProfiles` task (for `make setup`)
- `settings.gradle.kts`: Includes `backend` and `daml` subprojects
- `buildSrc/Dependencies.kt`: Centralized dependency versions (gRPC 1.67.1, Spring Boot 3.4.2, etc.)
- Key tasks: `:daml:compileDaml`, `:daml:testDaml`, `:daml:codeGen`, `:backend:build`

### Dynamic Configuration via splice-onboarding

The `splice-onboarding` service initializes Canton/Splice, uploads DARs, and shares runtime values (like `APP_PROVIDER_PARTY`) to other services via a shared Docker volume. Custom scripts can be mounted into `/app/scripts/on/` and use the `share_file` utility function. The utility library at `docker/modules/splice-onboarding/docker/utils.sh` provides shell functions for calling JSON Ledger API HTTP endpoints.

### Authentication Modes

Configurable via `make setup`:

- **OAuth2** (default): Keycloak with pre-configured realms, users (`app-provider`, `app-user`), and clients
- **Shared-secret**: Simpler auth with HS256 JWT (secret: `unsafe`, audience: `https://canton.network.global`)

### Docker Compose Module System

Compose files are assembled dynamically in the Makefile from multiple sources:

- `compose.yaml` (main) → `localnet/compose.yaml` → `splice-onboarding/compose.yaml` → `pqs/compose.yaml` → optional `keycloak/compose.yaml` → optional `observability/compose.yaml`

Docker profiles control which services start: `app-provider`, `app-user`, `sv`, `keycloak`, `swagger-ui`, `pqs-app-provider`, etc.

### Exchange Setup Scripts (`docker/setup-exchange/`)

Sequential scripts for setting up the Canton Exchange Backend (`canton-exchange-backend`) on localnet. All scripts are idempotent (safe to re-run). Configured via `docker/setup-exchange/.env` (copy from `.env.example`).

**Run order**: `01` → start backend → `02` → `03` → `04`

1. `01-setup-exchange.sh` - Upload DARs to both participants, create FeaturedAppRight (via disclosed contract from SV) + BatchedMarkersProxy on-ledger, generate backend `.env.local`, start exchange DB (port 5433) + run migrations
2. `02-register-featured-app-right.sh` - Query FeaturedAppRight contract from ledger, register it in exchange backend DB (`POST /feature-app-right`)
3. `03-register-cbtc-token.sh` - Generate Ed25519 keypair → onboard CBTC external party → create InstrumentConfiguration + AllocationFactory (utility packages, via interactive submission) → register allocation factory + token issuer in backend. Outputs: `cbtc-network-keypair.json`, `cbtc-factories.json`
4. `04-register-amulet-token.sh` - Register Amulet (CC) token issuer in backend (DSO-managed, factory fetched dynamically from scan-proxy at runtime — no on-ledger contracts needed)

**Key patterns used**:
- **Disclosed contracts**: FeaturedAppRight creation fetches AmuletRules from SV participant (`:4975`) with `createdEventBlob`, passes it when exercising from app-user participant
- **Interactive submission**: External party contracts (script 03) use prepare → sign → execute flow since external parties can't use `submit-and-wait`
- **Auth auto-detection**: Scripts read `AUTH_MODE` from `quickstart/.env.local`; SV always uses shared-secret regardless of mode

**Prerequisites**: Quickstart running (all containers healthy), DAR files in `quickstart/daml/dars/`, `canton-exchange-backend` repo cloned, `@canton-network/core-signing-lib` installed (for script 03).

See `docker/setup-exchange/README.md` for detailed usage, config reference, and troubleshooting.

### UTXO Handling Scripts (`docker/utxo-handling/`)

Scripts for generating external party wallets, minting/fauceting tokens, and merging UTXO-like holdings. Simulates token distribution for testing exchange operations. Configured via `../setup-exchange/.env` (shared config).

**Run order**: `01` → `02`/`03` (parallel) → `04` → `05`/`06` or `07`→`09` / `08`→`10`

**Phase 1 — Wallet Setup**:
1. `01-generate-user-wallet.sh` - Generate Ed25519 keypairs (default 25, configurable via `NUM_WALLETS`) with random multicultural names → onboard external parties on app-user participant → create Canton users. All wallets share one party hint (default `kairo`, configurable via `PARTY_HINT`). Outputs: `user-wallet-keypairs.json`

**Phase 2 — Token Distribution** (NOT idempotent — re-running creates additional holdings):
2. `02-request-minting-cbtc.sh` - For each wallet, mint CBTC holdings via 2-step `AllocationFactory_RequestMint` (wallet signs) → `MintRequest_Accept` (CBTC-NETWORK signs), both via interactive submission. Default 20 mints/wallet, random 100-1000 CBTC each. Outputs: `user-wallet-holdings-cbtc.json`
3. `03-request-faucet-amulet.sh` - For each wallet, tap Amulet via `AmuletRules_DevNet_Tap` (DevNet only) with AmuletRules + OpenMiningRound as disclosed contracts from SV. Default 20 taps/wallet, random 100-1000 CC each. Outputs: `user-wallet-holdings-amulet.json`

**Phase 3 — Merge Delegation**:
4. `04-create-merge-delegation.sh` - For each wallet: owner creates `MergeDelegationProposal` (interactive submission) → executor accepts (regular submission). Enables the exchange backend's executor party to merge holdings without wallet private keys. Outputs: `user-wallet-merge-delegation.json`

**Phase 4 — UTXO Merging** (two alternative workflows):

*Option A — Live query + merge (scripts 05/06)*:
5. `05-user-wallet-utxo-merging-cbtc.sh` - Query live CBTC holdings → exercise `MergeDelegation_Merge` via regular submission (operator `actAs`, wallet `readAs`). Uses AllocationFactory as TransferFactory for self-transfers. Disclosed contracts: AllocationFactory + InstrumentConfiguration + FeaturedAppRight. Verifies balances. Outputs: `user-wallet-merged-holdings-cbtc.json`
6. `06-user-wallet-utxo-merging-amulet.sh` - Query live Amulet holdings → fetch ExternalPartyAmuletRules + AmuletRules + OpenMiningRound from SV → exercise `MergeDelegation_Merge`. Disclosed contracts: 3 SV contracts + FeaturedAppRight (4 total). Verifies balances. Outputs: `user-wallet-merged-holdings-amulet.json`

*Option B — Separate query then merge (scripts 07-10)*:
7. `07-query-holdings-cbtc.sh` - Query CBTC Holding contracts from ledger → `user-wallet-holdings-cbtc.json`
8. `08-query-holdings-amulet.sh` - Query Amulet contracts from ledger → `user-wallet-holdings-amulet.json`
9. `09-merge-holdings-cbtc.sh` - Read 07's JSON output → merge via `MergeDelegation_Merge` (same logic as 05). Uses `cbtc-factories.json`
10. `10-merge-holdings-amulet.sh` - Read 08's JSON output → merge via `MergeDelegation_Merge` (same logic as 06). Fetches live SV contracts

**Key patterns used**:
- **Interactive submission**: External party operations (minting, fauceting, delegation proposals) use prepare → sign → execute flow
- **Regular submission**: Merge operations use `MergeDelegation_Merge` with `actAs: [operator]`, `readAs: [owner]` — no wallet private keys needed
- **Self-transfer merging**: Both AllocationFactory (CBTC) and ExternalPartyAmuletRules (Amulet) return `Completed` for self-transfers (sender==receiver), enabling atomic single-transaction merges
- **Disclosed contracts**: CBTC merges need AllocationFactory + InstrumentConfiguration + FeaturedAppRight; Amulet merges need ExternalPartyAmuletRules + AmuletRules + OpenMiningRound + FeaturedAppRight

**Prerequisites**: Quickstart running, exchange setup scripts 01-03 completed, exchange backend running, `@canton-network/core-signing-lib` installed.

See `docker/utxo-handling/README.md` for detailed usage, Daml workflow diagrams, and troubleshooting.

### Frontend URLs (after `make start`)

- App frontend: `http://app-provider.localhost:3000`
- App User wallet: `http://wallet.localhost:2000`
- Vite dev server: `http://app-provider.localhost:5173`

## Detailed Documentation

The `docs/` directory contains in-depth architectural documents (generated from codebase analysis):

- `01-ARCHITECTURE-OVERVIEW.md` - High-level architecture, service topology, data flow diagrams
- `02-DAML-CONTRACTS.md` - Daml template details, workflow state machine, token standard integration
- `03-BACKEND-SERVICE.md` - Spring Boot package structure, REST API reference, gRPC integration, PQS queries
- `04-FRONTEND-APP.md` - React component hierarchy, state management, API client layer
- `05-DOCKER-INFRASTRUCTURE.md` - Docker Compose module system, service configuration, networking
- `06-BUILD-SYSTEM.md` - Gradle multi-project build, code generation pipeline, Makefile targets
- `07-EXCHANGE-AND-UTXO-SCRIPTS.md` - Exchange setup and UTXO handling script details

## Key Configuration Files

- `quickstart/.env` - Default versions and environment variables
- `quickstart/.env.local` - Local overrides (generated by `make setup`, not committed)
- `quickstart/buildSrc/src/main/kotlin/Dependencies.kt` - Centralized dependency versions for Gradle
- `quickstart/daml/multi-package.yaml` - Daml multi-package build configuration
- `quickstart/docker/setup-exchange/.env` - Exchange setup configuration (copy from `.env.example`)
