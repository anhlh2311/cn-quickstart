import { AppDataSource } from '../../config/database.js';
import { TxHistory } from '../../entities/tx-history.entity.js';

const txHistoryRepo = () => AppDataSource.getRepository(TxHistory);

/**
 * Get paginated transaction history for a party.
 *
 * Returns { data, page, total, totalPages } matching the existing backend format.
 */
export async function getTxHistory(partyId: string, page = 1, limit = 20) {
  const skip = (page - 1) * limit;

  const [data, total] = await txHistoryRepo().findAndCount({
    where: [{ sender: partyId }, { receiver: partyId }],
    order: { timestamp: 'DESC' },
    take: limit,
    skip,
  });

  const totalPages = Math.ceil(total / limit);

  return {
    data,
    page,
    total,
    totalPages,
  };
}
