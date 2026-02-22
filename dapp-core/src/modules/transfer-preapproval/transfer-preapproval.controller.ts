import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as transferPreapprovalService from './transfer-preapproval.service.js';

export const transferPreapprovalRouter = Router();

// All routes require auth
transferPreapprovalRouter.use(authMiddleware);

/**
 * POST /transfer-preapproval/prepare
 *
 * Creates a TransferPreapprovalProposal via the Wallet SDK and prepares
 * it for interactive submission. Returns the preparedTransactionHash
 * for client-side signing.
 *
 * Body: { partyId: string }
 * Response: { preparedTransaction, preparedTransactionHash, commandId }
 */
transferPreapprovalRouter.post('/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { partyId } = req.body;
    if (!partyId) {
      err(res, 400, 'Missing required field: partyId');
      return;
    }
    const result = await transferPreapprovalService.prepareTransferPreapproval(partyId);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /transfer-preapproval/submit
 *
 * Submits a client-side signed TransferPreapproval transaction.
 * The wallet extension signs the preparedTransactionHash and sends
 * the signature back here.
 *
 * Body: { partyId, preparedTransaction, preparedTransactionHash, signature, publicKey, commandId }
 */
transferPreapprovalRouter.post('/submit', async (req: AuthRequest, res, next) => {
  try {
    const { partyId, preparedTransaction, preparedTransactionHash, signature, publicKey, commandId } = req.body;
    if (!partyId || !preparedTransaction || !preparedTransactionHash || !signature || !publicKey || !commandId) {
      err(res, 400, 'Missing required fields: partyId, preparedTransaction, preparedTransactionHash, signature, publicKey, commandId');
      return;
    }
    const result = await transferPreapprovalService.submitTransferPreapproval({
      partyId, preparedTransaction, preparedTransactionHash, signature, publicKey, commandId,
    });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /transfer-preapproval/status?partyId=X
 *
 * Check if a TransferPreapproval exists for the given party.
 */
transferPreapprovalRouter.get('/status', async (req: AuthRequest, res, next) => {
  try {
    const partyId = req.query.partyId as string;
    if (!partyId) {
      err(res, 400, 'Missing partyId');
      return;
    }
    const result = await transferPreapprovalService.getTransferPreapprovalStatus(partyId);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
