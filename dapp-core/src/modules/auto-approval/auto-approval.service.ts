import { validatorPost, validatorGet } from '../../lib/canton-api.js';
import { gatewayService } from '../gateway/gateway.service.js';
import { logger } from '../../lib/logger.js';

/**
 * Template ID for ExternalPartySetupProposal (used to check if one already exists).
 */
const SETUP_PROPOSAL_TEMPLATE =
  '#splice-amulet:Splice.AmuletRules:ExternalPartySetupProposal';

/**
 * Prepare an auto-approval (ExternalPartySetupProposal) transaction.
 *
 * Flow:
 * 1. Check if an ExternalPartySetupProposal contract already exists for this party.
 * 2. If not, create one via the Validator Internal API.
 * 3. Prepare the accept transaction — returns tx_hash for client-side signing.
 */
export async function prepareAutoApproval(partyId: string) {
  logger.info({ partyId }, 'Preparing auto-approval');

  // Step 1: Check for existing ExternalPartySetupProposal contract
  let contractId = await getActiveContractByTemplate(partyId, SETUP_PROPOSAL_TEMPLATE);

  if (contractId) {
    logger.info({ partyId, contractId }, 'Reusing existing ExternalPartySetupProposal');
  } else {
    // Step 2: Create a new setup proposal
    logger.info({ partyId }, 'Creating new ExternalPartySetupProposal');
    const created = (await validatorPost('/v0/admin/external-party/setup-proposal', {
      user_party_id: partyId,
    })) as { contract_id: string };
    contractId = created.contract_id;
    logger.info({ partyId, contractId }, 'Setup proposal created');
  }

  // Step 3: Prepare accept
  const prepared = (await validatorPost('/v0/admin/external-party/setup-proposal/prepare-accept', {
    contract_id: contractId,
    user_party_id: partyId,
  })) as { transaction: string; tx_hash: string };

  logger.info({ partyId, contractId }, 'Auto-approval prepared');

  return {
    contractId,
    preparedTransaction: prepared.transaction,
    preparedTransactionHash: Buffer.from(prepared.tx_hash, 'hex').toString('base64'),
  };
}

/**
 * Submit a signed auto-approval transaction.
 *
 * The client signs the tx_hash with their Ed25519 private key and sends
 * the signature + publicKey back here. We forward to the Validator API.
 */
export async function submitAutoApproval(params: {
  partyId: string;
  contractId: string;
  publicKey: string;
  signature: string;
  preparedTransaction: string;
}) {
  logger.info({ partyId: params.partyId, contractId: params.contractId }, 'Submitting auto-approval');

  // Convert base64 publicKey and signature to hex (Validator API expects hex)
  const publicKeyHex = Buffer.from(params.publicKey, 'base64').toString('hex');
  const signedHashHex = Buffer.from(params.signature, 'base64').toString('hex');

  const result = await validatorPost('/v0/admin/external-party/setup-proposal/submit-accept', {
    submission: {
      public_key: publicKeyHex,
      signed_tx_hash: signedHashHex,
      transaction: params.preparedTransaction,
      party_id: params.partyId,
    },
  });

  logger.info({ partyId: params.partyId }, 'Auto-approval submitted');

  return {
    success: true,
    message: 'Party proposal submitted successfully',
    data: result,
  };
}

/**
 * Get preapproval status for a party via the Validator Internal API.
 */
export async function getPreapprovalStatus(partyId: string) {
  try {
    const result = await validatorGet(
      `/v0/admin/transfer-preapprovals/by-party/${encodeURIComponent(partyId)}`,
    );
    return result;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Find an active contract by template ID for a given party.
 * Uses the Gateway's ledgerApi proxy to query the Participant Ledger API.
 */
async function getActiveContractByTemplate(
  partyId: string,
  templateId: string,
): Promise<string | null> {
  try {
    const token = await gatewayService.getAdminToken();

    // Get ledger end offset
    const endResult = (await gatewayService.ledgerApiGet('/v2/state/ledger-end', token)) as {
      offset?: number;
    };
    const endOffset = endResult?.offset ?? 0;

    const filter = {
      filter: {
        filtersByParty: {
          [partyId]: {
            cumulative: [
              {
                identifierFilter: {
                  TemplateFilter: {
                    value: {
                      templateId,
                      includeCreatedEventBlob: false,
                    },
                  },
                },
              },
            ],
          },
        },
      },
      verbose: true,
      activeAtOffset: endOffset.toString(),
    };

    const response = await gatewayService.ledgerApiPost('/v2/state/active-contracts', filter, token);

    // Handle multiple response formats
    let entries: unknown[] = [];
    if (Array.isArray(response)) {
      entries = response;
    } else {
      const r = response as Record<string, unknown>;
      if (Array.isArray(r.contractEntries)) entries = r.contractEntries;
      else if (Array.isArray(r.contract_entries)) entries = r.contract_entries;
      else if (r.contractEntry) entries = [r.contractEntry];
    }

    if (entries.length === 0) return null;

    // Extract contract ID — multiple possible paths
    const entry = entries[0] as Record<string, unknown>;
    const contractId =
      extractNestedProp(entry, 'contractEntry.JsActiveContract.createdEvent.contractId') ??
      extractNestedProp(entry, 'contractEntry.activeContract.createdEvent.contractId') ??
      extractNestedProp(entry, 'activeContract.createdEvent.contractId') ??
      extractNestedProp(entry, 'createdEvent.contractId') ??
      extractNestedProp(entry, 'contractId') ??
      extractNestedProp(entry, 'contract_id');

    return (contractId as string) ?? null;
  } catch {
    return null;
  }
}

function extractNestedProp(obj: unknown, path: string): unknown {
  let current: unknown = obj;
  for (const key of path.split('.')) {
    if (current == null || typeof current !== 'object') return undefined;
    current = (current as Record<string, unknown>)[key];
  }
  return current;
}
