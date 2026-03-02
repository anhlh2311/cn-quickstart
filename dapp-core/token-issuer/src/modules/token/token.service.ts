import { AppDataSource } from '../../config/database.js';
import { Token, TokenStatus } from '../../entities/token.entity.js';
import { TokenAdminParty, PartyStatus } from '../../entities/token-admin-party.entity.js';
import { config } from '../../config/index.js';
import { logger } from '../../lib/logger.js';
import {
  submitAndWait,
  queryActiveContracts,
  type CreateCommand,
} from '../../lib/canton-api.js';

const tokenRepo = () => AppDataSource.getRepository(Token);
const partyRepo = () => AppDataSource.getRepository(TokenAdminParty);

/**
 * Extract contract ID from a submit-and-wait transaction response.
 * Canton v2 returns events in `transaction.events[]`, each with a `created` or `CreatedEvent`.
 */
function extractContractId(result: unknown, templateSubstring: string): string | null {
  const tx = (result as Record<string, unknown>)?.transaction as Record<string, unknown> | undefined;
  if (!tx?.events) return null;

  const events = tx.events as Array<Record<string, unknown>>;
  for (const event of events) {
    // Canton v2 can return events in different shapes
    const created = (event.CreatedEvent || event.created || event) as Record<string, unknown>;
    const templateId = String(created?.templateId || '');
    if (templateId.includes(templateSubstring) && created?.contractId) {
      return String(created.contractId);
    }
  }
  return null;
}

export async function createToken(
  adminPartyId: string,
  tokenId: string,
  displayName: string,
  symbol: string,
): Promise<Token> {
  // Check if token already exists
  const existing = await tokenRepo().findOneBy({ tokenId });
  if (existing) {
    throw new Error(`Token "${tokenId}" already exists`);
  }

  // Look up admin party
  const adminParty = await partyRepo().findOneBy({ id: adminPartyId });
  if (!adminParty) {
    throw new Error(`Admin party "${adminPartyId}" not found`);
  }
  if (adminParty.status !== PartyStatus.ACTIVE) {
    throw new Error(`Admin party "${adminPartyId}" is not active (status: ${adminParty.status})`);
  }

  const cantonPartyId = adminParty.partyId;

  // Create DB record in PENDING state
  const token = tokenRepo().create({
    tokenId,
    displayName,
    symbol,
    adminPartyId,
    cantonPartyId,
    status: TokenStatus.PENDING,
  });
  await tokenRepo().save(token);

  try {
    // Step 1: Check for existing InstrumentConfiguration
    logger.info({ tokenId, cantonPartyId }, 'Checking for existing InstrumentConfiguration');
    let instrumentConfigCid: string | null = null;

    const existingIC = await queryActiveContracts(
      cantonPartyId,
      config.templates.instrumentConfiguration,
    );
    if (existingIC.length > 0) {
      instrumentConfigCid = existingIC[0].contractId;
      logger.info({ contractId: instrumentConfigCid }, 'InstrumentConfiguration already exists');
    } else {
      // Create InstrumentConfiguration
      logger.info('Creating InstrumentConfiguration contract');
      const icCommand: CreateCommand = {
        CreateCommand: {
          templateId: config.templates.instrumentConfiguration,
          createArguments: {
            operator: cantonPartyId,
            provider: cantonPartyId,
            registrar: cantonPartyId,
            defaultIdentifier: {
              source: cantonPartyId,
              id: tokenId,
              scheme: 'RegistrarInternalScheme',
            },
            additionalIdentifiers: [],
            issuerRequirements: [],
            holderRequirements: [],
            providerAppRewardBeneficiaries: null,
          },
        },
      };

      const icResult = await submitAndWait([icCommand], [cantonPartyId]);
      instrumentConfigCid = extractContractId(icResult, 'InstrumentConfiguration');

      if (!instrumentConfigCid) {
        logger.error({ result: icResult }, 'Failed to extract InstrumentConfiguration contract ID');
        throw new Error('InstrumentConfiguration created but could not extract contract ID');
      }
      logger.info({ contractId: instrumentConfigCid }, 'InstrumentConfiguration created');
    }

    // Step 2: Check for existing AllocationFactory
    logger.info({ tokenId, cantonPartyId }, 'Checking for existing AllocationFactory');
    let allocationFactoryCid: string | null = null;

    const existingAF = await queryActiveContracts(
      cantonPartyId,
      config.templates.allocationFactory,
    );
    if (existingAF.length > 0) {
      allocationFactoryCid = existingAF[0].contractId;
      logger.info({ contractId: allocationFactoryCid }, 'AllocationFactory already exists');
    } else {
      // Create AllocationFactory
      logger.info('Creating AllocationFactory contract');
      const afCommand: CreateCommand = {
        CreateCommand: {
          templateId: config.templates.allocationFactory,
          createArguments: {
            provider: cantonPartyId,
            registrar: cantonPartyId,
            operator: cantonPartyId,
          },
        },
      };

      const afResult = await submitAndWait([afCommand], [cantonPartyId]);
      allocationFactoryCid = extractContractId(afResult, 'AllocationFactory');

      if (!allocationFactoryCid) {
        logger.error({ result: afResult }, 'Failed to extract AllocationFactory contract ID');
        throw new Error('AllocationFactory created but could not extract contract ID');
      }
      logger.info({ contractId: allocationFactoryCid }, 'AllocationFactory created');
    }

    // Update DB record
    token.instrumentConfigCid = instrumentConfigCid;
    token.allocationFactoryCid = allocationFactoryCid;
    token.status = TokenStatus.ACTIVE;
    await tokenRepo().save(token);

    return token;
  } catch (error) {
    token.status = TokenStatus.FAILED;
    await tokenRepo().save(token);
    throw error;
  }
}

export async function listTokens(): Promise<Token[]> {
  return tokenRepo().find({
    relations: ['adminParty'],
    order: { createdAt: 'DESC' },
  });
}

export async function getTokenById(id: string): Promise<Token | null> {
  return tokenRepo().findOne({
    where: { id },
    relations: ['adminParty'],
  });
}

export async function getTokenByTokenId(tokenId: string): Promise<Token | null> {
  return tokenRepo().findOne({
    where: { tokenId },
    relations: ['adminParty'],
  });
}
