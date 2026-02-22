import { v4 as uuid } from 'uuid';
import { getSDK, initWalletSDK } from '../gateway/wallet-sdk.js';
import { TopologyController } from '@canton-network/wallet-sdk';
import { validatorGet } from '../../lib/canton-api.js';
import { logger } from '../../lib/logger.js';

/**
 * Transfer Preapproval via Wallet SDK.
 *
 * Creates a TransferPreapprovalProposal contract on the ledger using the SDK's
 * `createTransferPreapprovalCommand()` + standard interactive submission.
 *
 * This is an alternative to the auto-approval flow (which uses the Validator
 * Internal API's setup-proposal mechanism). The SDK approach:
 * - Creates the TransferPreapproval directly via Ledger API
 * - Uses the standard prepare → sign → execute interactive submission flow
 * - Does NOT bundle the additional setup that the Validator's setup-proposal does
 */

// Cache for providerParty and dsoParty (don't change frequently)
let cachedProviderParty: string | null = null;
let cachedDsoParty: string | null = null;

/**
 * Get the validator operator party (provider for transfer preapprovals).
 */
async function getProviderParty(): Promise<string> {
  if (cachedProviderParty) return cachedProviderParty;

  const result = (await validatorGet('/v0/validator-user')) as {
    party_id?: string;
  };
  if (!result.party_id) {
    throw new Error('Could not get validator operator party from /v0/validator-user');
  }
  cachedProviderParty = result.party_id;
  logger.info({ providerParty: cachedProviderParty }, 'Cached validator operator party');
  return cachedProviderParty;
}

/**
 * Get the DSO party (required for splice-wallet >= 0.1.11).
 */
async function getDsoParty(): Promise<string> {
  if (cachedDsoParty) return cachedDsoParty;

  const result = await validatorGet('/v0/scan-proxy/dso-party-id');
  // Defensive parsing — the response format varies
  const raw = result as Record<string, unknown>;
  const dsoParty =
    (raw.dsoPartyId as string) ??
    (raw.dso_party_id as string) ??
    (raw.dso as string) ??
    (typeof raw.data === 'string' ? raw.data : null) ??
    ((raw.data as Record<string, unknown>)?.dsoPartyId as string) ??
    ((raw.data as Record<string, unknown>)?.dso as string);

  if (!dsoParty || typeof dsoParty !== 'string') {
    throw new Error(`Could not extract DSO party ID from response: ${JSON.stringify(result)}`);
  }
  cachedDsoParty = dsoParty;
  logger.info({ dsoParty: cachedDsoParty }, 'Cached DSO party');
  return cachedDsoParty;
}

/**
 * Prepare a TransferPreapproval via the Wallet SDK.
 *
 * Flow:
 * 1. Fetch providerParty (validator operator) and dsoParty
 * 2. Set the party on the SDK's userLedger
 * 3. Use SDK to create the TransferPreapprovalProposal CreateCommand
 * 4. Use SDK's prepareSubmission to prepare the interactive submission
 * 5. Return preparedTransaction + hash for client-side signing
 */
export async function prepareTransferPreapproval(partyId: string) {
  logger.info({ partyId }, 'Preparing transfer preapproval via SDK');

  // Ensure SDK is initialized
  let sdk;
  try {
    sdk = getSDK();
  } catch {
    sdk = await initWalletSDK();
  }

  // Fetch provider and DSO parties
  const [providerParty, dsoParty] = await Promise.all([
    getProviderParty(),
    getDsoParty(),
  ]);

  // Set the party on the SDK (this also resolves the synchronizerId)
  await sdk.setPartyId(partyId);

  // Create the TransferPreapprovalProposal command
  const command = await sdk.userLedger!.createTransferPreapprovalCommand(
    providerParty,
    partyId,
    dsoParty,
  );

  if (!command) {
    throw new Error('Failed to create TransferPreapprovalProposal command (dsoParty may be undefined)');
  }

  // Prepare the interactive submission
  const commandId = uuid();
  const prepared = await sdk.userLedger!.prepareSubmission(command, commandId);

  logger.info(
    { partyId, commandId, hashLength: prepared.preparedTransactionHash?.length },
    'Transfer preapproval prepared via SDK',
  );

  return {
    preparedTransaction: prepared.preparedTransaction,
    preparedTransactionHash: prepared.preparedTransactionHash,
    commandId,
  };
}

/**
 * Submit a signed TransferPreapproval transaction.
 *
 * Uses the SDK's executeSubmission (SIGNATURE_FORMAT_CONCAT + fingerprint
 * computed from the public key via TopologyController).
 */
export async function submitTransferPreapproval(params: {
  partyId: string;
  preparedTransaction: string;
  preparedTransactionHash: string;
  signature: string;
  publicKey: string;
  commandId: string;
}) {
  logger.info({ partyId: params.partyId, commandId: params.commandId }, 'Submitting transfer preapproval via SDK');

  // --- Diagnostic: compare fingerprints ---
  const partyIdFingerprint = params.partyId.split('::')[1] ?? '(none)';
  const sdkFingerprint = TopologyController.createFingerprintFromPublicKey(params.publicKey);
  const fingerprintsMatch = partyIdFingerprint === sdkFingerprint;
  logger.info(
    {
      partyId: params.partyId,
      publicKey: params.publicKey,
      partyIdFingerprint,
      sdkFingerprint,
      fingerprintsMatch,
      signatureLength: params.signature?.length,
      hashLength: params.preparedTransactionHash?.length,
    },
    'Fingerprint comparison before executeSubmission',
  );

  if (!fingerprintsMatch) {
    logger.warn(
      { partyIdFingerprint, sdkFingerprint },
      'FINGERPRINT MISMATCH: the public key does not match the partyId fingerprint. ' +
      'This will likely cause Canton to reject the signature.',
    );
  }

  // Ensure SDK is initialized and set party
  let sdk;
  try {
    sdk = getSDK();
  } catch {
    sdk = await initWalletSDK();
  }
  await sdk.setPartyId(params.partyId);

  const prepared = {
    preparedTransaction: params.preparedTransaction,
    preparedTransactionHash: params.preparedTransactionHash,
  };

  const userLedger = sdk.userLedger!;
  const submissionId = await userLedger.executeSubmission(
    prepared as Parameters<typeof userLedger.executeSubmission>[0],
    params.signature,
    params.publicKey,
    params.commandId,
  );

  logger.info({ partyId: params.partyId, submissionId }, 'Transfer preapproval submitted via SDK');
  return {
    success: true,
    submissionId,
    message: 'Transfer preapproval submitted successfully',
  };
}

/**
 * Get transfer preapproval status for a party.
 * Uses the SDK's ValidatorController to query the scan proxy.
 */
export async function getTransferPreapprovalStatus(partyId: string) {
  try {
    let sdk;
    try {
      sdk = getSDK();
    } catch {
      sdk = await initWalletSDK();
    }

    const result = await sdk.validator!.getTransferPreApprovalByParty(partyId);
    return {
      partyId,
      exists: true,
      ...result,
    };
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    // No preapproval found is a valid state
    if (msg.includes('404') || msg.includes('not found') || msg.includes('NOT_FOUND')) {
      return { partyId, exists: false };
    }
    logger.error({ partyId, error: msg }, 'Error checking transfer preapproval status');
    return { partyId, exists: false, error: msg };
  }
}
