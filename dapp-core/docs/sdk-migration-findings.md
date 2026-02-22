# SDK Migration Findings: Signature Rejection & Key Ownership

**Date:** 2026-02-22
**Status:** Resolved
**Affected modules:** `onboarding`, `transfer-preapproval`

---

## 1. Problem Statement

After migrating the `transfer-preapproval` module to use the Wallet SDK's interactive submission flow (`prepareSubmission` + `executeSubmission`), Canton rejected every signature with:

```
FAILED_TO_EXECUTE_TRANSACTION:
Received 0 valid signatures from distinct keys (1 invalid),
but expected at least 1 valid for dapp-user::1220e1882142...
```

The SDK's local verification (`verifyTxHash`) passed — confirming the signature was valid for the given hash and key — but Canton still rejected it.

---

## 2. Root Cause: Key Ownership Mismatch

### How Canton identifies signers

Canton uses a **fingerprint** (hex-encoded `0x1220 || SHA256(purpose_prefix || public_key_bytes)`) to identify which key signed a transaction. The fingerprint appears as the second segment of a partyId:

```
dapp-user::1220e1882142f7c08501d01305b185034cab827585e1226e0d9b18ed64a2bc78f209
             ^--- fingerprint derived from the party's registered public key
```

When `executeSubmission` sends a signature to Canton, it includes `signedBy: fingerprint_from_public_key`. Canton compares this fingerprint against the party's registered key. If they don't match, the signature is rejected — even if the signature itself is cryptographically valid.

### What went wrong

The **onboarding** module used `gatewayService.createWallet({ signingProviderId: 'wallet-kernel' })`, which created the party using the **Wallet Gateway's internally-generated key pair**:

```
Wallet Extension key:  78QNdW4lmSC60tNG8/pp9Y6MMyoZ3/UT4yLrqqr2C3w= (base64)
  → SDK fingerprint:   1220d559d804bff69817e726a9ae620ed463e4907d7ab1bc2bc51c1a4837555e7be1

Party created with:    Gateway's internal WALLET_KERNEL key (different, never exposed)
  → Party fingerprint: 1220e1882142f7c08501d01305b185034cab827585e1226e0d9b18ed64a2bc78f209
```

The wallet extension's public key was stored in the dapp-core database but was **not the key used to register the party on Canton**. When the extension later signed a transaction and sent its public key, the SDK correctly computed the fingerprint from that key — but it didn't match the party's registered fingerprint.

### Diagnostic logging that confirmed this

Added to `submitTransferPreapproval`:

```typescript
const partyIdFingerprint = params.partyId.split('::')[1];
const sdkFingerprint = TopologyController.createFingerprintFromPublicKey(params.publicKey);
logger.info({ partyIdFingerprint, sdkFingerprint, fingerprintsMatch: partyIdFingerprint === sdkFingerprint });
```

Output:
```
partyIdFingerprint: "1220e1882142f7c08501d01305b185034cab827585e1226e0d9b18ed64a2bc78f209"
sdkFingerprint:     "1220d559d804bff69817e726a9ae620ed463e4907d7ab1bc2bc51c1a4837555e7be1"
fingerprintsMatch:  false
```

---

## 3. Fix: SDK-Based Party Allocation

### Before (broken)

```
Wallet Extension                    dapp-core                         Wallet Gateway          Canton
     │                                  │                                  │                    │
     │─ POST /onboarding/prepare ──────→│                                  │                    │
     │  { publicKey: "78QN..." }        │─ createWallet(wallet-kernel) ───→│                    │
     │                                  │                                  │─ generate key ────→│
     │                                  │                                  │  (GATEWAY's key)   │
     │                                  │  ← { partyId: "dapp-user::1220e1..." } ──────────────│
     │← { partyId, multiHash } ────────│                                  │                    │
     │                                  │                                  │                    │
     │─ POST /transfer-preapproval/submit ─→│                              │                    │
     │  { signature (signed w/ EXTENSION's key) }                          │                    │
     │                                  │─ executeSubmission ─────────────────────────────────→│
     │                                  │  signedBy: fingerprint(EXTENSION's key)              │
     │                                  │  ← REJECTED: fingerprint ≠ party's registered key ──│
```

The Gateway's `createWallet` with `signingProviderId: 'wallet-kernel'` generates an **internal** Ed25519 key pair. The party's fingerprint is derived from the Gateway's key, not the extension's key.

### After (working)

```
Wallet Extension                    dapp-core (via SDK)                Canton Participant
     │                                  │                                  │
     │─ POST /onboarding/prepare ──────→│                                  │
     │  { publicKey: "78QN..." }        │─ generateExternalParty("78QN...") ─→│
     │                                  │  POST /v2/parties/external/generate-topology
     │                                  │  { publicKey: { keyData: "78QN..." } }
     │                                  │  ← { partyId, multiHash, topologyTransactions } ────│
     │← { partyId, namespace,           │                                  │
     │    multiHash, topologyTxs } ─────│                                  │
     │                                  │                                  │
     │─ sign(multiHash) locally         │                                  │
     │                                  │                                  │
     │─ POST /onboarding/submit ───────→│                                  │
     │  { signedHash, preparedParty }   │─ allocateExternalParty(signedHash, preparedParty) ──→│
     │                                  │  POST /v2/parties/external/allocate                   │
     │                                  │  ← { partyId } ─────────────────────────────────────│
     │                                  │                                  │
     │─ POST /transfer-preapproval/submit ─→│                              │
     │  { signature (signed w/ EXTENSION's key) }                          │
     │                                  │─ executeSubmission ─────────────────────────────────→│
     │                                  │  signedBy: fingerprint(EXTENSION's key)              │
     │                                  │  ← ACCEPTED: fingerprint matches party's key ───────│
```

Now the party is created with the **extension's own public key** via the SDK's `generateExternalParty` → `allocateExternalParty` flow. The fingerprint in the partyId matches the extension's key.

---

## 4. SDK Concepts Reference

### Fingerprint computation

```
fingerprint = hex("0x1220" || SHA256(int32_be(12) || raw_public_key_bytes))
```

- Hash purpose `12` = `PublicKeyFingerprint` (from Canton's `HashPurpose.scala`)
- `raw_public_key_bytes` = 32-byte Ed25519 public key (decoded from base64)
- Result is a hex string like `1220e1882142f7c08501d01305b185034c...`

SDK utility: `TopologyController.createFingerprintFromPublicKey(base64PublicKey)`

### Signature formats

| Format | What it means | Used by |
|--------|---------------|---------|
| `SIGNATURE_FORMAT_CONCAT` | Signature bytes are the raw Ed25519 signature (64 bytes, base64-encoded). The `signedBy` field identifies the key via computed fingerprint. | Wallet SDK `executeSubmission` |
| `SIGNATURE_FORMAT_RAW` | Same signature bytes, but `signedBy` is extracted from partyId (`partyId.split('::')[1]`). | `canton-exchange-backend` direct API calls |

Both formats work — the difference is how `signedBy` is populated. The critical requirement is that **`signedBy` must match the fingerprint of the key that actually signed the data**.

### Interactive submission flow

```
prepare  → SDK constructs Daml command, Canton returns preparedTransaction + hash
sign     → Client signs the hash with Ed25519 private key (via signTransactionHash)
execute  → SDK sends signature + preparedTransaction to Canton
```

SDK methods:
- `prepareSubmission(command, commandId)` → `{ preparedTransaction, preparedTransactionHash }`
- `executeSubmission(prepared, signature, publicKey, commandId)` → `submissionId`

The SDK's `executeSubmission` internally:
1. Verifies the signature locally (`verifyTxHash`) — throws `BAD SIGNATURE` if invalid
2. Computes fingerprint from public key via `TopologyController.createFingerprintFromPublicKey`
3. Sends to `POST /v2/interactive-submission/execute` with `SIGNATURE_FORMAT_CONCAT`

### Party allocation flow (topology)

```
generate  → SDK calls POST /v2/parties/external/generate-topology with user's public key
            Canton returns { partyId, publicKeyFingerprint, multiHash, topologyTransactions }
sign      → Client signs multiHash with private key
allocate  → SDK calls POST /v2/parties/external/allocate with signed topology
            Canton registers the party, grants user rights
```

SDK methods:
- `generateExternalParty(publicKey, partyHint)` → `GenerateTransactionResponse`
- `allocateExternalParty(signedHash, preparedParty, grantUserRights)` → `{ partyId }`
- `signAndAllocateExternalParty(privateKey, partyHint)` — convenience (does all 3 steps)

### synchronizerId bootstrapping

`generateExternalParty` and `allocateExternalParty` both call `getSynchronizerId()` internally. The synchronizerId is resolved when `sdk.setPartyId(someExistingPartyId)` is called. For onboarding (no party exists yet), use the validator operator party:

```typescript
const providerParty = await validatorGet('/v0/validator-user'); // { party_id: "app_provider_..." }
await sdk.setPartyId(providerParty.party_id);                  // resolves synchronizerId
await sdk.userLedger.generateExternalParty(publicKey, hint);   // now getSynchronizerId() works
```

---

## 5. Files Changed

### `onboarding.service.ts` — Rewritten

| Aspect | Before | After |
|--------|--------|-------|
| Party creation | `gatewayService.createWallet({ signingProviderId: 'wallet-kernel' })` | `sdk.userLedger.generateExternalParty(publicKey, partyHint)` |
| Party submission | Status update only (Gateway already created party) | `sdk.userLedger.allocateExternalParty(signedHash, preparedParty)` |
| Key ownership | Gateway's internal key (extension can't sign) | Extension's own key (extension signs) |
| Prepare response | `{ partyId, publicKey, status, multiHash }` (fake multiHash) | `{ partyId, namespace, multiHash, topologyTransactions }` (real topology) |
| Submit input | `{ }` (no signature needed) | `{ signedHash, preparedParty }` |

### `onboarding.controller.ts` — Submit endpoint updated

Now passes `signedHash` and `preparedParty` from request body to `submitOnboarding`.

### `transfer-preapproval.service.ts` — SDK-only

| Aspect | Before | After |
|--------|--------|-------|
| Submit strategy | SDK first, direct API fallback (SIGNATURE_FORMAT_RAW) | SDK only (`executeSubmission` with SIGNATURE_FORMAT_CONCAT) |
| Diagnostics | None | Fingerprint comparison logging before `executeSubmission` |
| Imports | `gatewayService`, `config` (for direct API) | `TopologyController` (for fingerprint comparison) |

---

## 6. Key Lessons

1. **Whoever creates the party owns the signing key.** If the Gateway creates the party with its internal key (`wallet-kernel` provider), only the Gateway can sign for that party. If you want external signing (wallet extension), the party must be created with the external key via `generateExternalParty`.

2. **Fingerprint mismatch = silent rejection.** Canton doesn't tell you "wrong key" — it says "0 valid signatures (1 invalid)". Always compare `partyId.split('::')[1]` with `TopologyController.createFingerprintFromPublicKey(publicKey)` when debugging signature issues.

3. **`SIGNATURE_FORMAT_CONCAT` vs `SIGNATURE_FORMAT_RAW` are both valid.** The format only affects how the `signedBy` field is populated. CONCAT uses a computed fingerprint from the public key; RAW typically uses the fingerprint extracted from the partyId. Both work as long as `signedBy` matches the party's registered key fingerprint.

4. **SDK's `connect()` doesn't resolve `synchronizerId`.** You must call `sdk.setPartyId(existingPartyId)` before using methods that need it (like `generateExternalParty`, `prepareSubmission`, `executeSubmission`). For bootstrapping when no party exists yet, use the validator operator party.

5. **The SDK's `verifyTxHash` passing doesn't mean Canton will accept.** The SDK only verifies the signature is valid for the given hash and key. Canton additionally checks that the key's fingerprint matches the party's registered key — a check the SDK can't do locally.
