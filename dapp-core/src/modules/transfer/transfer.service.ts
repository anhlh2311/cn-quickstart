import { AppDataSource } from '../../config/database.js';
import { TransferHistory, TransferHistoryStatus } from '../../entities/transfer-history.entity.js';
import { gatewayService } from '../gateway/gateway.service.js';
import { logger } from '../../lib/logger.js';
import { FindOptionsWhere } from 'typeorm';

const transferRepo = () => AppDataSource.getRepository(TransferHistory);

/**
 * Prepare a token transfer via the Gateway's ledger API proxy.
 * Uses the Canton interactive-submission prepare endpoint.
 */
export async function prepareTransfer(params: {
  sender: string;
  receiver: string;
  amount: string;
  tokenId: string;
  instrumentId?: { admin: string; id: string };
}) {
  const adminToken = await gatewayService.getAdminToken();

  const result = await gatewayService.ledgerApiPost(
    '/v2/interactive-submission/prepare',
    {
      // The exact payload depends on the token standard transfer template
      // This will be refined during integration testing
      type: 'transfer',
      ...params,
    },
    adminToken,
  );

  logger.info({ sender: params.sender, receiver: params.receiver }, 'Transfer prepared');
  return result;
}

/**
 * Submit a client-side signed transaction via the Gateway's ledger API proxy.
 *
 * The wallet extension signs the prepared transaction hash locally,
 * then sends { preparedTransaction, signature } to dapp-core.
 * We proxy this to Canton's interactive-submission execute endpoint.
 */
export async function submitSignedTransaction(params: {
  preparedTransaction: string;
  signature: string;
}) {
  const adminToken = await gatewayService.getAdminToken();

  const result = await gatewayService.ledgerApiPost(
    '/v2/interactive-submission/execute',
    {
      preparedTransaction: params.preparedTransaction,
      signature: params.signature,
    },
    adminToken,
  );

  logger.info('Signed transaction submitted');
  return result;
}

/**
 * Prepare an approve action for a transfer instruction.
 */
export async function prepareApprove(params: {
  contractId: string;
  tokenId?: string;
}) {
  const adminToken = await gatewayService.getAdminToken();

  const result = await gatewayService.ledgerApiPost(
    '/v2/interactive-submission/prepare',
    {
      type: 'approve',
      ...params,
    },
    adminToken,
  );

  return result;
}

/**
 * Prepare a reject action for a transfer instruction.
 */
export async function prepareReject(params: {
  contractId: string;
  tokenId?: string;
}) {
  const adminToken = await gatewayService.getAdminToken();

  const result = await gatewayService.ledgerApiPost(
    '/v2/interactive-submission/prepare',
    {
      type: 'reject',
      ...params,
    },
    adminToken,
  );

  return result;
}

/**
 * Get paginated incoming transfer requests for a party.
 * Returns { incomingRequestes, total, page, limit, totalPages } matching the existing backend.
 */
export async function getIncomingRequests(
  partyId: string,
  page = 1,
  limit = 10,
  tokenName?: string,
) {
  const where: FindOptionsWhere<TransferHistory> = {
    receiver: partyId,
    status: TransferHistoryStatus.LOCKED,
  };
  if (tokenName) {
    where.tokenName = tokenName;
  }

  const [incomingRequestes, total] = await transferRepo().findAndCount({
    where,
    order: { offset: 'DESC' },
    skip: (page - 1) * limit,
    take: limit,
  });

  return {
    incomingRequestes,
    total,
    page,
    limit,
    totalPages: Math.ceil(total / limit),
  };
}

/**
 * Get paginated outgoing transfer requests for a party.
 * Returns { outgoingRequestes, total, page, limit, totalPages } matching the existing backend.
 */
export async function getOutgoingRequests(
  partyId: string,
  page = 1,
  limit = 10,
  tokenName?: string,
) {
  const where: FindOptionsWhere<TransferHistory> = {
    sender: partyId,
    status: TransferHistoryStatus.LOCKED,
  };
  if (tokenName) {
    where.tokenName = tokenName;
  }

  const [outgoingRequestes, total] = await transferRepo().findAndCount({
    where,
    order: { offset: 'DESC' },
    skip: (page - 1) * limit,
    take: limit,
  });

  return {
    outgoingRequestes,
    total,
    page,
    limit,
    totalPages: Math.ceil(total / limit),
  };
}

/**
 * Get paginated transfer history for a party.
 * Returns { transferHistories, total, page, limit, totalPages } matching the existing backend.
 */
export async function getTransferHistory(
  partyId: string,
  page = 1,
  limit = 10,
  tokenName?: string,
  sender?: string,
  receiver?: string,
) {
  const queryBuilder = transferRepo().createQueryBuilder('transfer_history');

  queryBuilder.where(
    '(transfer_history.sender = :partyId OR transfer_history.receiver = :partyId)',
    { partyId },
  );

  if (sender) {
    queryBuilder.andWhere('transfer_history.sender = :sender', { sender });
  }
  if (receiver) {
    queryBuilder.andWhere('transfer_history.receiver = :receiver', { receiver });
  }
  if (tokenName) {
    queryBuilder.andWhere('transfer_history.token_name = :tokenName', { tokenName });
  }

  queryBuilder.orderBy('transfer_history.offset', 'DESC');

  const total = await queryBuilder.getCount();
  queryBuilder.skip((page - 1) * limit).take(limit);
  const transferHistories = await queryBuilder.getMany();

  return {
    transferHistories,
    total,
    page,
    limit,
    totalPages: Math.ceil(total / limit),
  };
}
