import { AppDataSource } from '../../config/database.js';
import { MintRecord, MintStatus } from '../../entities/mint-record.entity.js';
import { Token, TokenStatus } from '../../entities/token.entity.js';
import { config } from '../../config/index.js';
import { logger } from '../../lib/logger.js';
import {
  submitAndWait,
  queryActiveContracts,
  type ExerciseCommand,
  type DisclosedContract,
} from '../../lib/canton-api.js';

const mintRepo = () => AppDataSource.getRepository(MintRecord);
const tokenRepo = () => AppDataSource.getRepository(Token);

interface MintRecipient {
  partyId: string;
  amount: string;
}

interface MintResult {
  recipientPartyId: string;
  amount: string;
  status: MintStatus;
  transactionId?: string;
  errorMessage?: string;
}

/**
 * Mint/allocate tokens to a list of recipients.
 *
 * Exercises AllocationFactory_Allocate on the AllocationFactory contract.
 * The InstrumentConfiguration is included as a disclosed contract.
 *
 * NOTE: The exact choice argument structure for AllocationFactory_Allocate
 * may need adjustment based on the Utility package version. If Canton returns
 * an error about field names, check the error message for the expected structure.
 */
export async function mintTokens(
  tokenId: string,
  recipients: MintRecipient[],
): Promise<MintResult[]> {
  // Look up token
  const token = await tokenRepo().findOneBy({ tokenId });
  if (!token) {
    throw new Error(`Token "${tokenId}" not found`);
  }
  if (token.status !== TokenStatus.ACTIVE) {
    throw new Error(`Token "${tokenId}" is not active (status: ${token.status})`);
  }
  if (!token.allocationFactoryCid || !token.instrumentConfigCid) {
    throw new Error(`Token "${tokenId}" is missing factory or instrument config contract IDs`);
  }

  const cantonPartyId = token.cantonPartyId;

  // Acquire InstrumentConfiguration disclosure (need createdEventBlob)
  logger.info({ tokenId }, 'Acquiring InstrumentConfiguration disclosure');
  const icContracts = await queryActiveContracts(
    cantonPartyId,
    config.templates.instrumentConfiguration,
    true, // includeCreatedEventBlob
  );

  if (icContracts.length === 0) {
    throw new Error('InstrumentConfiguration contract not found on ledger');
  }

  const icContract = icContracts[0];
  if (!icContract.createdEventBlob) {
    throw new Error('InstrumentConfiguration disclosure missing createdEventBlob');
  }

  // Also get AllocationFactory disclosure
  const afContracts = await queryActiveContracts(
    cantonPartyId,
    config.templates.allocationFactory,
    true,
  );

  const disclosedContracts: DisclosedContract[] = [
    {
      templateId: config.templates.instrumentConfiguration,
      contractId: icContract.contractId,
      createdEventBlob: icContract.createdEventBlob,
    },
  ];

  // Add AllocationFactory disclosure if available
  if (afContracts.length > 0 && afContracts[0].createdEventBlob) {
    disclosedContracts.push({
      templateId: config.templates.allocationFactory,
      contractId: afContracts[0].contractId,
      createdEventBlob: afContracts[0].createdEventBlob,
    });
  }

  // Use the latest contract IDs from the ledger (they may have been updated)
  const allocationFactoryCid = afContracts.length > 0
    ? afContracts[0].contractId
    : token.allocationFactoryCid;

  const results: MintResult[] = [];

  for (const recipient of recipients) {
    // Create DB record
    const record = mintRepo().create({
      tokenId,
      recipientPartyId: recipient.partyId,
      amount: recipient.amount,
      status: MintStatus.PENDING,
    });
    await mintRepo().save(record);

    try {
      logger.info(
        { tokenId, recipient: recipient.partyId, amount: recipient.amount },
        'Minting tokens',
      );

      // Exercise AllocationFactory_Allocate on the AllocationFactory contract
      // This creates a new Holding for the recipient
      const command: ExerciseCommand = {
        ExerciseCommand: {
          templateId: config.templates.allocationFactory,
          contractId: allocationFactoryCid,
          choice: 'AllocationFactory_Allocate',
          choiceArgument: {
            expectedAdmin: cantonPartyId,
            allocation: {
              transferLeg: {
                sender: cantonPartyId,
                receiver: recipient.partyId,
                amount: recipient.amount,
                instrumentId: {
                  admin: cantonPartyId,
                  id: tokenId,
                },
              },
            },
            inputHoldingCids: [],
            requestedAt: new Date().toISOString(),
            extraArgs: {
              context: {
                values: {
                  'instrument-configuration': {
                    tag: 'AV_ContractId',
                    value: icContract.contractId,
                  },
                  'sender-credentials': {
                    tag: 'AV_List',
                    value: [],
                  },
                },
              },
              meta: {
                values: {},
              },
            },
          },
        },
      };

      const result = await submitAndWait(
        [command],
        [cantonPartyId],
        { disclosedContracts },
      );

      // Extract transaction ID
      const tx = (result as Record<string, unknown>)?.transaction as Record<string, unknown>;
      const transactionId = tx?.updateId as string || tx?.transactionId as string || null;

      record.status = MintStatus.SUCCESS;
      record.transactionId = transactionId;
      await mintRepo().save(record);

      logger.info(
        { tokenId, recipient: recipient.partyId, transactionId },
        'Tokens minted successfully',
      );

      results.push({
        recipientPartyId: recipient.partyId,
        amount: recipient.amount,
        status: MintStatus.SUCCESS,
        transactionId: transactionId || undefined,
      });
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      logger.error(
        { tokenId, recipient: recipient.partyId, error: errorMsg },
        'Failed to mint tokens',
      );

      record.status = MintStatus.FAILED;
      record.errorMessage = errorMsg.slice(0, 1000);
      await mintRepo().save(record);

      results.push({
        recipientPartyId: recipient.partyId,
        amount: recipient.amount,
        status: MintStatus.FAILED,
        errorMessage: errorMsg,
      });
    }
  }

  return results;
}

export async function listMintRecords(tokenId?: string): Promise<MintRecord[]> {
  const where = tokenId ? { tokenId } : {};
  return mintRepo().find({ where, order: { createdAt: 'DESC' } });
}
