import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as amuletTransferService from './amulet-transfer.service.js';

export const amuletTransferRouter = Router();

// All routes require auth
amuletTransferRouter.use(authMiddleware);

/**
 * POST /external-party/transfer-amulet/prepare
 *
 * Prepare an Amulet (CC) transfer via WalletUserProxy.
 */
amuletTransferRouter.post('/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { senderPartyId, receiverPartyId, amount, reason } = req.body;
    if (!senderPartyId || !receiverPartyId || !amount) {
      err(res, 400, 'Missing required fields: senderPartyId, receiverPartyId, amount');
      return;
    }
    const result = await amuletTransferService.prepareAmuletTransfer({
      senderPartyId,
      receiverPartyId,
      amount,
      reason,
    });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /external-party/transfer-amulet/submit
 *
 * Submit a signed Amulet transfer.
 */
amuletTransferRouter.post('/submit', async (req: AuthRequest, res, next) => {
  try {
    const { preparedTransaction, hashingSchemeVersion, signature, senderPartyId } = req.body;
    if (!preparedTransaction || !hashingSchemeVersion || !signature || !senderPartyId) {
      err(res, 400, 'Missing required fields: preparedTransaction, hashingSchemeVersion, signature, senderPartyId');
      return;
    }
    const result = await amuletTransferService.submitAmuletTransfer({
      preparedTransaction,
      hashingSchemeVersion,
      signature,
      senderPartyId,
    });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
