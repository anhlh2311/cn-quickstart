import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as autoApprovalService from './auto-approval.service.js';

export const autoApprovalRouter = Router();

// All routes require auth
autoApprovalRouter.use(authMiddleware);

/**
 * POST /auto-approval/prepare
 *
 * Prepare an auto-approval (transfer preapproval) for the party.
 */
autoApprovalRouter.post('/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { partyId } = req.body;
    if (!partyId) {
      err(res, 400, 'Missing required field: partyId');
      return;
    }
    const result = await autoApprovalService.prepareAutoApproval(partyId);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /auto-approval/submit
 *
 * Submit a signed auto-approval transaction.
 */
autoApprovalRouter.post('/submit', async (req: AuthRequest, res, next) => {
  try {
    const { partyId, contractId, publicKey, signature, preparedTransaction } = req.body;
    if (!partyId || !contractId || !publicKey || !signature || !preparedTransaction) {
      err(res, 400, 'Missing required fields: partyId, contractId, publicKey, signature, preparedTransaction');
      return;
    }
    const result = await autoApprovalService.submitAutoApproval({
      partyId,
      contractId,
      publicKey,
      signature,
      preparedTransaction,
    });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /auto-approval/:partyId
 *
 * Check if a party has an active transfer preapproval.
 */
autoApprovalRouter.get('/:partyId', async (req: AuthRequest, res, next) => {
  try {
    const partyId = req.params.partyId as string;
    const result = await autoApprovalService.getPreapprovalStatus(partyId);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
