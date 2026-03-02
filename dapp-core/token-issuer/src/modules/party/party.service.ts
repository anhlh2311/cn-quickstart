import { AppDataSource } from '../../config/database.js';
import { TokenAdminParty, PartyStatus } from '../../entities/token-admin-party.entity.js';
import { allocateInternalParty, grantUserRights } from '../../lib/canton-api.js';
import { config } from '../../config/index.js';
import { logger } from '../../lib/logger.js';

const partyRepo = () => AppDataSource.getRepository(TokenAdminParty);

export async function createParty(partyHint: string, displayName: string): Promise<TokenAdminParty> {
  // Check if party hint already exists
  const existing = await partyRepo().findOneBy({ partyHint });
  if (existing) {
    throw new Error(`Party with hint "${partyHint}" already exists`);
  }

  // Create DB record in PENDING state
  const party = partyRepo().create({
    partyHint,
    displayName,
    partyId: '', // will be filled after allocation
    status: PartyStatus.PENDING,
  });
  await partyRepo().save(party);

  try {
    // Allocate internal party on Canton participant
    logger.info({ partyHint, displayName }, 'Allocating internal party');
    const details = await allocateInternalParty(partyHint, displayName);
    logger.info({ partyId: details.party }, 'Party allocated');

    // Save partyId immediately (so it's persisted even if rights grant fails)
    party.partyId = details.party;
    await partyRepo().save(party);

    // Grant CanActAs + CanReadAs to admin user
    logger.info({ userId: config.canton.adminUser, partyId: details.party }, 'Granting user rights');
    await grantUserRights(config.canton.adminUser, details.party);
    logger.info('User rights granted');

    // Mark as active
    party.status = PartyStatus.ACTIVE;
    await partyRepo().save(party);

    return party;
  } catch (error) {
    party.status = PartyStatus.FAILED;
    await partyRepo().save(party);
    throw error;
  }
}

export async function listParties(): Promise<TokenAdminParty[]> {
  return partyRepo().find({ order: { createdAt: 'DESC' } });
}

export async function getPartyById(id: string): Promise<TokenAdminParty | null> {
  return partyRepo().findOneBy({ id });
}
