import { AppDataSource } from '../../config/database.js';
import { Party, OnboardingStatus } from '../../entities/party.entity.js';
import { User } from '../../entities/user.entity.js';
import { getSDK, initWalletSDK } from '../gateway/wallet-sdk.js';
import { validatorGet } from '../../lib/canton-api.js';
import { config } from '../../config/index.js';
import { logger } from '../../lib/logger.js';

const partyRepo = () => AppDataSource.getRepository(Party);
const userRepo = () => AppDataSource.getRepository(User);

// Cache provider party for synchronizerId resolution
let cachedProviderParty: string | null = null;

async function getProviderParty(): Promise<string> {
  if (cachedProviderParty) return cachedProviderParty;
  const result = (await validatorGet('/v0/validator-user')) as { party_id?: string };
  if (!result.party_id) throw new Error('Could not get validator operator party');
  cachedProviderParty = result.party_id;
  return cachedProviderParty;
}

/**
 * Ensure the SDK is ready and has a synchronizerId set.
 * Uses the validator operator party to resolve the synchronizerId.
 */
async function ensureSDKReady() {
  let sdk;
  try {
    sdk = getSDK();
  } catch {
    sdk = await initWalletSDK();
  }

  // Resolve synchronizerId via an existing party on the network
  const providerParty = await getProviderParty();
  await sdk.setPartyId(providerParty);

  return sdk;
}

/**
 * Prepare external party onboarding.
 *
 * Uses the SDK's generateExternalParty to create topology transactions
 * for the user's own public key. Returns the multiHash for client-side signing.
 */
export async function prepareOnboarding(userId: string, publicKey: string) {
  const sdk = await ensureSDKReady();

  // Generate external party topology with the user's public key
  const preparedParty = await sdk.userLedger!.generateExternalParty(
    publicKey,
    config.canton.partyIdPrefix,
  );

  logger.info(
    { userId, partyId: preparedParty.partyId, fingerprint: preparedParty.publicKeyFingerprint },
    'Party topology generated via SDK',
  );

  // Save party in dapp-core database
  let party = await partyRepo().findOneBy({ publicKey });
  if (!party) {
    party = partyRepo().create({
      publicKey,
      partyId: preparedParty.partyId,
      onboardingStatus: OnboardingStatus.PENDING,
      userId,
    });
    party = await partyRepo().save(party);
  }

  // Link party to user
  await userRepo().update({ id: userId }, { partyId: party.id });

  return {
    partyId: preparedParty.partyId,
    namespace: preparedParty.publicKeyFingerprint,
    multiHash: preparedParty.multiHash,
    topologyTransactions: preparedParty.topologyTransactions || [],
  };
}

/**
 * Submit signed onboarding topology.
 *
 * The client signs the multiHash and sends it back with the preparedParty data.
 * Uses the SDK's allocateExternalParty to submit the signed topology to Canton.
 */
export async function submitOnboarding(
  userId: string,
  signedHash: string,
  preparedParty: {
    partyId: string;
    namespace: string;
    multiHash: string;
    topologyTransactions: string[];
  },
) {
  const sdk = await ensureSDKReady();

  logger.info(
    { userId, partyId: preparedParty.partyId },
    'Submitting onboarding topology via SDK',
  );

  // Allocate the external party using the signed topology
  await sdk.userLedger!.allocateExternalParty(
    signedHash,
    {
      partyId: preparedParty.partyId,
      publicKeyFingerprint: preparedParty.namespace,
      multiHash: preparedParty.multiHash,
      topologyTransactions: preparedParty.topologyTransactions,
    },
    true, // grantUserRights
  );

  logger.info(
    { userId, partyId: preparedParty.partyId },
    'Party allocated on Canton via SDK',
  );

  // Update party status
  const user = await userRepo().findOne({
    where: { id: userId },
    relations: ['party'],
  });
  if (user?.party) {
    await partyRepo().update({ id: user.party.id }, {
      onboardingStatus: OnboardingStatus.SUCCESSFULLY,
    });
  }

  return {
    partyId: preparedParty.partyId,
    onboardingStatus: OnboardingStatus.SUCCESSFULLY,
  };
}
