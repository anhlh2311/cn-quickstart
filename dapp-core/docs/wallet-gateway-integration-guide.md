# Wallet Gateway & Wallet SDK Integration Guide

**Date:** 2026-02-22
**Status:** Active
**Packages:**
- `@canton-network/wallet-gateway-remote` v0.18.0 — HTTP server (JSON-RPC 2.0)
- `@canton-network/wallet-sdk` — Node.js SDK for command construction
- `@canton-network/dapp-sdk` — Browser SDK for dApps (CIP-103)

**Reference docs:**
- `splice-wallet-kernel/docs/dapp-building/wallet-gateway/` — Gateway configuration, APIs, signing providers
- `splice-wallet-kernel/docs/dapp-building/dapp-sdk/` — dApp SDK usage and API reference
- [DA Integration Guide](https://docs.digitalasset.com/integrate/devnet/index.html) — Official wallet integration docs

---

## Overview

The Wallet Gateway + Wallet SDK already provide everything our `dapp-core` backend needs. Our current implementation bypasses the Gateway for three operations (balance, auto-approval, faucet) via direct calls to the Participant Ledger API and Splice Validator Internal API. This document explains how to eliminate those bypasses.

### Current Architecture (3 API connections)

```
                                         ┌──────────────────────┐
                                    ┌───→│ Wallet Gateway       │ User API + dApp API
                   ┌──────────┐     │    └───────────┬──────────┘
Wallet Extension──→│ dapp-core│─────┤                │
                   └──────────┘     │    ┌───────────▼──────────┐
                                    ├───→│ Canton Participant   │ Ledger API v2 (balance)
                                    │    └──────────────────────┘
                                    │    ┌──────────────────────┐
                                    └───→│ Splice Validator     │ Internal API (faucet, auto-approval)
                                         └──────────────────────┘
```

### Target Architecture (1 connection)

```
                                         ┌──────────────────────────────────┐
                   ┌──────────┐          │         Wallet Gateway           │
Wallet Extension──→│ dapp-core│─────────→│  User API    │    dApp API      │
                   │ (+ SDK)  │          │              │   (ledgerApi     │
                   └──────────┘          │              │    proxy)        │
                                         │  ┌───────────┴──────────────┐   │
                                         │  │ Routes internally to:    │   │
                                         │  │ • Participant Ledger API │   │
                                         │  │ • Signing Store          │   │
                                         │  └──────────────────────────┘   │
                                         └──────────────────────────────────┘
```

---

## What the Gateway Already Provides

### dApp API (`/api/v0/dapp`) — JSON-RPC 2.0

| Method | Description | Relevant to |
|--------|-------------|-------------|
| `ledgerApi` | **Proxy any Ledger API call** (GET/POST). Injects auth automatically. | Balance queries, contract lookups |
| `prepareExecute` | Prepare → sign → execute any Daml command. Full transaction lifecycle. | Auto-approval, faucet, transfers |
| `connect` / `disconnect` / `status` | Connection management | — |
| `listAccounts` / `getPrimaryAccount` | Account listing | — |
| `signMessage` | Sign arbitrary message | — |

### User API (`/api/v0/user`) — JSON-RPC 2.0

| Method | Description | Relevant to |
|--------|-------------|-------------|
| `createWallet` | Allocate party with chosen signing provider | Onboarding |
| `sign` | Sign a prepared transaction using the wallet's signing provider | Auto-approval, faucet |
| `execute` | Submit a signed transaction to the ledger | Auto-approval, faucet |
| `listWallets` / `syncWallets` | Wallet management | — |
| `addSession` / `removeSession` | Session lifecycle | Auth |
| `getTransaction` / `listTransactions` | Transaction history | Activity |

### Key Insight: `ledgerApi` Proxy

The Gateway's `ledgerApi` method forwards **any** request to the Participant Ledger API (`network.ledgerApi.baseUrl`). It handles auth injection automatically. This means:

```typescript
// Current: Direct HTTP to Participant (bypasses Gateway)
const res = await fetch('http://canton:3975/v2/state/active-contracts', {
  method: 'POST',
  headers: { Authorization: `Bearer ${adminToken}` },
  body: JSON.stringify(filter),
});

// Target: Through Gateway's ledgerApi proxy (single connection)
const res = await jsonRpcCall(dappApiUrl, 'ledgerApi', {
  requestMethod: 'POST',
  resource: '/v2/state/active-contracts',
  body: JSON.stringify(filter),
}, token);
```

### Key Insight: Wallet SDK for Command Construction

The Wallet SDK (`@canton-network/wallet-sdk`) is a **Node.js** library that knows how to construct the correct Daml commands for Canton operations. Since `dapp-core` is a Node.js backend, we can use it directly:

| SDK Method | What It Produces | Submitted Via |
|-----------|------------------|---------------|
| `tokenStandard.createTap()` | ExerciseCommand for DevNet/LocalNet faucet | `prepareExecute` or `sign`+`execute` |
| `tokenStandard.listHoldingUtxos()` | Query to `/v2/state/active-contracts` with proper filters | Direct SDK call (handles parsing) |
| `tokenStandard.createTransfer()` | ExerciseCommand for token transfer | `prepareExecute` or `sign`+`execute` |
| `ledger.createTransferPreapprovalCommand()` | CreateCommand for transfer pre-approval | `prepareExecute` or `sign`+`execute` |

---

## Migration Plan: Eliminate Direct API Bypasses

### 1. Balance Queries → Gateway `ledgerApi` proxy

**Current:** Direct HTTP POST to `http://canton:3975/v2/state/active-contracts`
**Target:** Gateway `ledgerApi` proxy OR Wallet SDK `listHoldingUtxos()`

**Option A — Gateway ledgerApi proxy (minimal change):**

dapp-core constructs the filter payload and sends it through the Gateway. This eliminates the direct Participant connection but keeps the filter/parsing logic.

```typescript
// balance.service.ts
import { gatewayService } from '../gateway/gateway.service.js';

export async function getTokenBalance(partyId: string) {
  const token = await gatewayService.getAdminToken();

  // Get ledger offset through Gateway proxy
  const endResult = await gatewayService.ledgerApiGet('/v2/state/ledger-end', token);
  const offset = JSON.parse(endResult.response).offset;

  // Query active contracts through Gateway proxy
  const filter = {
    filter: {
      filtersByParty: {
        [partyId]: {
          cumulative: [{
            identifierFilter: {
              InterfaceFilter: {
                value: {
                  interfaceId: '#splice-api-token-holding-v1:Splice.Api.Token.HoldingV1:Holding',
                  includeInterfaceView: true,
                  includeCreatedEventBlob: true,
                },
              },
            },
          }],
        },
      },
    },
    verbose: false,
    activeAtOffset: Number(offset),
  };

  const result = await gatewayService.ledgerApiPost('/v2/state/active-contracts', filter, token);
  const contracts = JSON.parse(result.response);
  // ... parse holdings into balances (same logic as today)
}
```

**Option B — Wallet SDK (recommended, eliminates filter construction):**

Use the SDK's `listHoldingUtxos()` which handles filter construction AND response parsing:

```typescript
// balance.service.ts
import { sdk } from '../gateway/wallet-sdk.js'; // initialized WalletSDK instance

export async function getTokenBalance(partyId: string) {
  sdk.setPartyId(partyId);
  const holdings = await sdk.tokenStandard.listHoldingUtxos(true);

  // Holdings are already parsed PrettyContract<Holding> objects
  const balanceMap: Record<string, { amount: number; locked: number }> = {};
  for (const h of holdings) {
    const tokenId = h.payload.instrumentId.id;
    const amount = parseFloat(h.payload.amount);
    const isLocked = !!h.payload.lock;
    if (!balanceMap[tokenId]) balanceMap[tokenId] = { amount: 0, locked: 0 };
    balanceMap[tokenId][isLocked ? 'locked' : 'amount'] += amount;
  }

  return {
    balances: Object.entries(balanceMap).map(([tokenId, b]) => ({
      tokenId,
      balance: b.amount.toString(),
      lockedBalance: b.locked.toString(),
    })),
  };
}
```

**What's eliminated:**
- `PARTICIPANT_LEDGER_API_URL` config entry
- Direct HTTP calls to Canton Participant
- InterfaceFilter payload construction (Option B)
- Response structure normalization (Option B)

---

### 2. Auto-Approval → Gateway `prepareExecute` + Wallet SDK commands

**Current:** Direct HTTP to Splice Validator Internal API
- `POST /v0/admin/external-party/setup-proposal`
- `POST /v0/admin/external-party/setup-proposal/prepare-accept`
- `POST /v0/admin/external-party/setup-proposal/submit-accept`

**Target:** Wallet SDK constructs the Daml command → Gateway's `prepareExecute` handles prepare/sign/execute

The Wallet SDK's `createTransferPreapprovalCommand()` generates a CreateCommand for the `TransferPreapprovalProposal` template. This goes through the standard Ledger API (interactive submission), not the Validator Internal API.

```typescript
// auto-approval.service.ts
import { sdk } from '../gateway/wallet-sdk.js';

export async function prepareAutoApproval(partyId: string) {
  // SDK constructs the proper Daml CreateCommand
  const validatorOperatorParty = await getValidatorOperatorParty(); // from scan-proxy or config
  const command = await sdk.userLedger.createTransferPreapprovalCommand(
    validatorOperatorParty,
    partyId,
    dsoParty, // DSO party from network config
  );

  // Submit through Gateway's prepare/sign/execute flow
  const token = await gatewayService.getAdminToken();
  const result = await gatewayService.prepareExecute({
    commands: [command],
    actAs: [partyId],
  }, token);

  return result;
}
```

**What's eliminated:**
- `VALIDATOR_API_URL` config entry
- Direct HTTP calls to Splice Validator Internal API
- Manual hex/base64 encoding conversions
- Contract existence checking via raw Ledger API queries
- The 3-step Validator API flow (setup-proposal → prepare-accept → submit-accept)

---

### 3. Faucet → Wallet SDK `createTap()` + Gateway signing

**Current:** Direct HTTP to Splice Validator Internal API + admin wallet private key in env vars
- `GET /v0/scan-proxy/transfer-command-counter/{partyId}`
- `POST /v0/admin/external-party/transfer-preapproval/prepare-send`
- Server-side Ed25519 signing with `ADMIN_WALLET_PRIVATE_KEY`
- `POST /v0/admin/external-party/transfer-preapproval/submit-send`

**Target:** Wallet SDK `createTap()` generates the Daml command → Gateway signs with its internal `wallet-kernel` provider

The SDK's `createTap()` is a DevNet/LocalNet operation that **mints** tokens (no admin wallet balance needed). It creates an ExerciseCommand against AmuletRules that goes through the standard Ledger API.

```typescript
// faucet.service.ts
import { sdk } from '../gateway/wallet-sdk.js';

export async function requestFaucet(partyId: string, amount?: string) {
  sdk.setPartyId(partyId);

  // SDK's createTap constructs the proper ExerciseCommand
  const [command, disclosedContracts] = await sdk.tokenStandard.createTap(
    partyId,
    amount || '10.0',
    { instrumentId: 'Amulet', instrumentAdmin: dsoParty },
  );

  // Submit through Gateway (signs with wallet-kernel provider)
  const token = await gatewayService.getAdminToken();
  await gatewayService.prepareExecuteWithContracts({
    commands: [command],
    actAs: [partyId],
    disclosedContracts,
  }, token);

  return { success: true };
}
```

**What's eliminated:**
- `ADMIN_WALLET_PARTY_ID`, `ADMIN_WALLET_PRIVATE_KEY`, `ADMIN_WALLET_PUBLIC_KEY` env vars
- Server-side Ed25519 signing (`signTransactionHash`)
- `node:crypto` import for PKCS8 DER key wrapping
- Transfer command counter / nonce management
- The entire `adminWallet` config section
- Direct HTTP calls to Validator Internal API
- The most significant security improvement: **admin private keys never leave the Gateway's signing store**

---

## Implementation Steps

### Step 1: Add Wallet SDK dependency

```bash
cd Quickstart/dapp-core
npm install @canton-network/wallet-sdk
```

### Step 2: Initialize Wallet SDK in dapp-core

Create `src/modules/gateway/wallet-sdk.ts`:

```typescript
import { WalletSDKImpl } from '@canton-network/wallet-sdk';
import { config } from '../../config/index.js';

// The SDK connects to the same Participant Ledger API as the Gateway
const sdk = new WalletSDKImpl();

export async function initWalletSDK() {
  await sdk.configure({
    authFactory: localNetAuthDefault(config.canton.adminUser, config.canton.unsafeSecret),
    ledgerFactory: new LedgerController(config.participantLedgerApiUrl),
    tokenStandardFactory: new TokenStandardController(config.participantLedgerApiUrl),
    // ... see SDK configuration docs
  });
  await sdk.connect();
  return sdk;
}

export { sdk };
```

### Step 3: Rewrite balance.service.ts

Use `sdk.tokenStandard.listHoldingUtxos()` — see code above in section 1.

### Step 4: Rewrite auto-approval.service.ts

Use `sdk.userLedger.createTransferPreapprovalCommand()` + Gateway submit — see section 2.

### Step 5: Rewrite faucet.service.ts

Use `sdk.tokenStandard.createTap()` + Gateway submit — see section 3.

### Step 6: Remove direct API helpers

- Delete `lib/canton-api.ts` (all 120 lines)
- Remove `participantLedgerApiUrl` and `validatorApiUrl` from config
- Remove `adminWallet` section from config
- Remove `ADMIN_WALLET_*` env vars from `dapp-core.env` and `compose.yaml`
- Remove `VALIDATOR_API_URL` and `PARTICIPANT_LEDGER_API_URL` from `compose.yaml`

---

## Summary of Changes

| Component | Before | After |
|-----------|--------|-------|
| **API connections** | 3 (Gateway + Participant + Validator) | 1 (Gateway only) + SDK |
| **Balance** | Direct POST to Participant `/v2/state/active-contracts` | SDK `listHoldingUtxos()` |
| **Auto-approval** | Direct POST to Validator `/v0/admin/external-party/setup-proposal/*` | SDK `createTransferPreapprovalCommand()` → Gateway |
| **Faucet** | Direct POST to Validator + admin key signing | SDK `createTap()` → Gateway signing |
| **Admin wallet keys** | Stored in env vars (security risk) | Managed by Gateway signing store |
| **lib/canton-api.ts** | 120 lines of direct HTTP + Ed25519 signing | Deleted |
| **Config entries** | 3 API URLs + 3 admin wallet vars | 0 extra entries |

### What the Gateway Provides Out of the Box

| Feature | Gateway Method | Notes |
|---------|---------------|-------|
| Ledger API proxy | `ledgerApi(requestMethod, resource, body)` | Proxies any Participant API call with auth |
| Transaction lifecycle | `prepareExecute(commands)` / `sign()` / `execute()` | Full prepare→sign→submit |
| Party allocation | `createWallet(partyHint, signingProviderId)` | With pluggable signing providers |
| Wallet management | `listWallets()` / `syncWallets()` / `setPrimaryWallet()` | Multi-wallet per user |
| Session management | `addSession()` / `removeSession()` | JWT-authenticated sessions |
| Real-time events | SSE at `/api/v0/dapp/events` | `txChanged`, `accountsChanged`, `statusChanged` |
| Web UI | Served at Gateway root URL | Login, wallets, transactions, approve |

### What the Wallet SDK Adds (Node.js only)

| Feature | SDK Method | Notes |
|---------|-----------|-------|
| Faucet/tap | `tokenStandard.createTap()` | DevNet/LocalNet only, mints tokens |
| Holdings query | `tokenStandard.listHoldingUtxos()` | Handles filter construction + parsing |
| Transfer | `tokenStandard.createTransfer()` | 2-step or 1-step (with preapproval) |
| Transfer preapproval | `ledger.createTransferPreapprovalCommand()` | Enables auto-accept |
| Pending transfers | `tokenStandard.fetchPendingTransferInstructionView()` | Accept/Reject/Withdraw |
| Party allocation | `topology.signAndAllocateExternalParty()` | Combined sign + allocate |
| Transaction parsing | `tokenStandard.listHoldingTransactions()` | Pretty-printed events |
