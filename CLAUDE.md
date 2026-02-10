# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Canton Network Quickstart - a scaffolding template for developing Canton Network applications using the Global Synchronizer. Multi-language, Docker Compose-based, with Daml smart contracts, a Spring Boot Java backend, and a React TypeScript frontend.

**Key versions**: Daml SDK 3.4.10, Splice 0.5.3, Canton 3.4.10, Java 21, Spring Boot 3.4.2, React 18.3.1

## Repository Structure

- `quickstart/` - Main application (all `make` commands run from here)
  - `daml/` - Daml smart contracts (licensing, iou, exchange models)
  - `backend/` - Spring Boot Java service (gRPC + REST via OpenAPI)
  - `frontend/` - React + TypeScript + Vite application
  - `integration-test/` - Playwright E2E tests
  - `docker/` - Docker Compose modules (localnet, keycloak, pqs, observability, splice-onboarding)
  - `buildSrc/` - Gradle build logic (Dependencies.kt, VersionFiles.kt)
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

# Backend remote debugging (port 5005)
export DEBUG_ENABLED=true && make restart-backend
```

## Testing

```bash
# Daml unit tests
make test-daml

# All unit tests
make test

# Playwright E2E tests (requires TEST_MODE=on and AUTH_MODE=oauth2 via make setup)
make integration-test

# View E2E test report
make show-integration-test-report
```

Integration tests are in `quickstart/integration-test/tests/` using Playwright with page object pattern (`pages/` directory).

## Architecture

### Licensing Workflow (Core Business Logic)

The app implements a licensing system between App Providers and App Users on the Canton Network. The workflow is: `AppInstallRequest` -> `AppInstall` -> `License` -> `LicenseRenewalRequest` + `AppPaymentRequest` -> `AcceptedAppPayment` -> renewed `License`. Payments use Amulet (CC) cryptocurrency. Full workflow documentation in `quickstart/daml/licensing/WORKFLOW.md`.

### Service Topology

Docker Compose orchestrates modular services. The `Makefile` dynamically assembles compose files from `docker/modules/` based on configuration:

- **Canton** container: Ledger with 3 participant nodes (App Provider :3901, App User :2901, Super Validator :4901)
- **Splice** container: Validator services for each participant
- **PostgreSQL**: Multi-database instance for all services
- **Backend Service** (Spring Boot :8080): REST API for the licensing workflow, connects to Canton via gRPC
- **Nginx**: Reverse proxy for frontend UIs and backend
- **Keycloak** (optional, :8082): OAuth2 identity provider with pre-configured realms (AppProvider, AppUser)
- **PQS**: Participant Query Service instances
- **Observability** (optional): Grafana :3030, Prometheus, Loki, Tempo, cAdvisor

Port scheme: prefix `4xxx`=SV, `3xxx`=App Provider, `2xxx`=App User; suffix `901`=Ledger API, `902`=Admin API, `903`=Validator API, `975`=JSON API.

### Code Generation Pipeline

- **OpenAPI** (`common/openapi.yaml`): Generates Spring server interfaces (`backend/build/generated-spring/`) and TypeScript client types (`frontend/src/openapi.d.ts` via `npm run gen:openapi`)
- **Daml codegen**: Java bindings from Daml contracts (`backend/build/generated-daml-bindings/`)
- **Protobuf/gRPC**: Canton ledger API bindings for the Java backend
- **Token standard OpenAPI**: Additional Java clients from vendored specs (`token-metadata-v1.yaml`, `allocation-v1.yaml`)

### Dynamic Configuration via splice-onboarding

The `splice-onboarding` service initializes Canton/Splice, uploads DARs, and shares runtime values (like `APP_PROVIDER_PARTY`) to other services via a shared Docker volume. Custom scripts can be mounted into `/app/scripts/on/` and use the `share_file` utility function.

### Authentication Modes

Configurable via `make setup`:
- **OAuth2** (default): Keycloak with pre-configured realms, users (`app-provider`, `app-user`), and clients
- **Shared-secret**: Simpler auth mode from Splice LocalNet

### Frontend URLs (after `make start`)

- App frontend: `http://app-provider.localhost:3000`
- App User wallet: `http://wallet.localhost:2000`
- Vite dev server: `http://app-provider.localhost:5173`

## Key Configuration Files

- `quickstart/.env` - Default versions and environment variables
- `quickstart/.env.local` - Local overrides (generated by `make setup`, not committed)
- `quickstart/buildSrc/src/main/kotlin/Dependencies.kt` - Centralized dependency versions for Gradle
- `quickstart/daml/multi-package.yaml` - Daml multi-package build configuration
