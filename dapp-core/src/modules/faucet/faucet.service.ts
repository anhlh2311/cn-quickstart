import { randomUUID } from 'crypto';
import { getSDK, initWalletSDK, getSynchronizerId } from '../gateway/wallet-sdk.js';
import { gatewayService } from '../gateway/gateway.service.js';
import { config } from '../../config/index.js';
import { logger } from '../../lib/logger.js';

/**
 * Prepare a DevNet Tap faucet transaction.
 *
 * Uses the Wallet SDK's `createTap()` to build the AmuletRules_DevNet_Tap
 * ExerciseCommand, then submits it to the Canton interactive-submission/prepare
 * endpoint. Returns the prepared transaction for client-side signing.
 *
 * The DevNet Tap choice requires the receiver party as an authorizer.
 * Since external parties' signing keys are held by the wallet extension (not
 * the participant), the extension must sign the transaction.
 *
 * Flow:
 * 1. Backend: createTap() → ExerciseCommand + DisclosedContracts
 * 2. Backend: /v2/interactive-submission/prepare → preparedTransaction + hash
 * 3. Extension: signTransactionHash(hash, privateKey)
 * 4. Backend: /v2/interactive-submission/execute with partySignatures
 */
export async function prepareFaucetTap(partyId: string, amount?: string) {
  let sdk;
  try {
    sdk = getSDK();
  } catch {
    sdk = await initWalletSDK();
  }

  const tapAmount = amount || '10.0';
  logger.info({ partyId, amount: tapAmount }, 'Preparing faucet tap');

  // Get the tap command (only needs transferFactoryRegistryUrl, set during init)
  const [tapCmd, disclosedContracts] = await sdk.tokenStandard!.createTap(
    partyId,
    tapAmount,
    { instrumentId: 'Amulet' },
  );

  // Prepare via interactive submission
  const synchronizerId = await getSynchronizerId();
  const commandId = randomUUID();
  const adminToken = await gatewayService.getAdminToken();
  const prepareUrl = `${config.participantLedgerApiUrl}/v2/interactive-submission/prepare`;

  const prepareParams = {
    commands: [tapCmd],
    commandId,
    userId: config.canton.adminUser,
    actAs: [partyId],
    readAs: [],
    disclosedContracts: disclosedContracts.map((dc) => ({
      templateId: dc.templateId,
      contractId: dc.contractId,
      createdEventBlob: dc.createdEventBlob,
      synchronizerId: dc.synchronizerId,
    })),
    synchronizerId,
    verboseHashing: false,
    packageIdSelectionPreference: [],
  };

  const res = await fetch(prepareUrl, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${adminToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(prepareParams),
  });

  if (!res.ok) {
    const text = await res.text();
    logger.error({ status: res.status, body: text }, 'Faucet tap prepare failed');
    throw new Error(`Faucet tap prepare failed: ${res.status}: ${text}`);
  }

  const prepared = (await res.json()) as {
    preparedTransaction: string;
    preparedTransactionHash: string;
    hashingSchemeVersion?: string;
  };

  logger.info({ partyId, commandId }, 'Faucet tap prepared');

  return {
    preparedTransaction: prepared.preparedTransaction,
    preparedTransactionHash: prepared.preparedTransactionHash,
    hashingSchemeVersion: prepared.hashingSchemeVersion || 'HASHING_SCHEME_VERSION_V2',
  };
}

/**
 * Submit a signed DevNet Tap faucet transaction.
 *
 * The wallet extension signs the prepared transaction hash and sends
 * the signature back. We construct the proper partySignatures format
 * and call the Canton interactive-submission/execute endpoint.
 */
export async function submitFaucetTap(
  preparedTransaction: string,
  signature: string,
  partyId: string,
) {
  const fingerprint = partyId.split('::')[1];
  if (!fingerprint) {
    throw new Error('Invalid partyId format — expected <hint>::<fingerprint>');
  }

  const adminToken = await gatewayService.getAdminToken();
  const executeUrl = `${config.participantLedgerApiUrl}/v2/interactive-submission/execute`;

  const request = {
    userId: config.canton.adminUser,
    preparedTransaction,
    hashingSchemeVersion: 'HASHING_SCHEME_VERSION_V2',
    submissionId: randomUUID(),
    deduplicationPeriod: { Empty: {} },
    partySignatures: {
      signatures: [
        {
          party: partyId,
          signatures: [
            {
              signature,
              signedBy: fingerprint,
              format: 'SIGNATURE_FORMAT_CONCAT',
              signingAlgorithmSpec: 'SIGNING_ALGORITHM_SPEC_ED25519',
            },
          ],
        },
      ],
    },
  };

  const res = await fetch(executeUrl, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${adminToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(request),
  });

  if (!res.ok) {
    const text = await res.text();
    logger.error({ status: res.status, body: text }, 'Faucet tap submit failed');
    throw new Error(`Faucet tap submit failed: ${res.status}: ${text}`);
  }

  const result = await res.json();
  logger.info({ partyId }, 'Faucet tap submitted successfully');
  return result;
}
