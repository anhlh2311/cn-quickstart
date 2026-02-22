import { randomUUID } from 'crypto';
import { getSDK, initWalletSDK, getSynchronizerId } from '../gateway/wallet-sdk.js';
import { gatewayService } from '../gateway/gateway.service.js';
import { config } from '../../config/index.js';
import { logger } from '../../lib/logger.js';

/**
 * Prepare an Amulet transfer via the Wallet SDK + interactive submission.
 *
 * Uses the SDK's `createTransfer()` to build the ExerciseCommand (which
 * internally fetches sender holdings, transfer factory context, etc.),
 * then submits it to Canton's `/v2/interactive-submission/prepare`.
 *
 * Returns the prepared transaction for client-side signing by the extension.
 */
export async function prepareAmuletTransfer(params: {
  senderPartyId: string;
  receiverPartyId: string;
  amount: string;
  reason?: string;
}) {
  let sdk;
  try {
    sdk = getSDK();
  } catch {
    sdk = await initWalletSDK();
  }

  const synchronizerId = await getSynchronizerId();

  // Configure SDK with sender context so it can query their holdings
  sdk.tokenStandard!.setPartyId(params.senderPartyId);
  sdk.tokenStandard!.setSynchronizerId(synchronizerId);

  logger.info(
    { sender: params.senderPartyId, receiver: params.receiverPartyId, amount: params.amount },
    'Preparing Amulet transfer',
  );

  const [transferCmd, disclosedContracts] = await sdk.tokenStandard!.createTransfer(
    params.senderPartyId,
    params.receiverPartyId,
    params.amount,
    { instrumentId: 'Amulet' },
    undefined, // inputUtxos — let SDK select
    params.reason || 'Transfer from Canton Wallet',
  );

  // Prepare via interactive submission
  const commandId = randomUUID();
  const adminToken = await gatewayService.getAdminToken();
  const prepareUrl = `${config.participantLedgerApiUrl}/v2/interactive-submission/prepare`;

  const prepareParams = {
    commands: [transferCmd],
    commandId,
    userId: config.canton.adminUser,
    actAs: [params.senderPartyId],
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
    logger.error({ status: res.status, body: text }, 'Amulet transfer prepare failed');
    throw new Error(`Amulet transfer prepare failed: ${res.status}: ${text}`);
  }

  const prepared = (await res.json()) as {
    preparedTransaction: string;
    preparedTransactionHash: string;
    hashingSchemeVersion?: string;
  };

  logger.info(
    { sender: params.senderPartyId, receiver: params.receiverPartyId, commandId },
    'Amulet transfer prepared',
  );

  return {
    preparedTransaction: prepared.preparedTransaction,
    preparedTransactionHash: prepared.preparedTransactionHash,
    hashingSchemeVersion: prepared.hashingSchemeVersion || 'HASHING_SCHEME_VERSION_V2',
    senderPartyId: params.senderPartyId,
    receiverPartyId: params.receiverPartyId,
    amount: params.amount,
  };
}

/**
 * Submit a signed Amulet transfer via interactive submission.
 *
 * The wallet extension signs the prepared transaction hash and sends
 * the signature back. We construct the proper partySignatures format
 * and call Canton's `/v2/interactive-submission/execute`.
 */
export async function submitAmuletTransfer(params: {
  preparedTransaction: string;
  hashingSchemeVersion: string;
  signature: string;
  senderPartyId: string;
}) {
  const fingerprint = params.senderPartyId.split('::')[1];
  if (!fingerprint) {
    throw new Error('Invalid senderPartyId format — expected <hint>::<fingerprint>');
  }

  const adminToken = await gatewayService.getAdminToken();
  const executeUrl = `${config.participantLedgerApiUrl}/v2/interactive-submission/execute`;

  const request = {
    userId: config.canton.adminUser,
    preparedTransaction: params.preparedTransaction,
    hashingSchemeVersion: params.hashingSchemeVersion,
    submissionId: randomUUID(),
    deduplicationPeriod: { Empty: {} },
    partySignatures: {
      signatures: [
        {
          party: params.senderPartyId,
          signatures: [
            {
              signature: params.signature,
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
    logger.error({ status: res.status, body: text }, 'Amulet transfer submit failed');
    throw new Error(`Amulet transfer submit failed: ${res.status}: ${text}`);
  }

  const result = await res.json();
  logger.info({ sender: params.senderPartyId }, 'Amulet transfer submitted');
  return result;
}
