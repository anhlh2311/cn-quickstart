import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as transferService from './transfer.service.js';
import { getPartyId } from '../auth/auth.service.js';

export const transferRouter = Router();

// All transfer routes require auth
transferRouter.use(authMiddleware);

/**
 * POST /transfer-token-standard/prepare
 */
transferRouter.post('/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { sender, receiver, amount, tokenId, instrumentId } = req.body;
    if (!sender || !receiver || !amount) {
      err(res, 400, 'Missing required fields: sender, receiver, amount');
      return;
    }
    const result = await transferService.prepareTransfer({
      sender, receiver, amount, tokenId, instrumentId,
    });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /transfer-token-standard/submit
 *
 * Accepts client-side signed transaction from the wallet extension.
 * Body: { preparedTransaction, signature }
 */
transferRouter.post('/submit', async (req: AuthRequest, res, next) => {
  try {
    const { preparedTransaction, signature } = req.body;
    if (!preparedTransaction || !signature) {
      err(res, 400, 'Missing required fields: preparedTransaction, signature');
      return;
    }
    const result = await transferService.submitSignedTransaction({ preparedTransaction, signature });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /transfer-token-standard/incoming-requests?page=1&limit=10&tokenName=CBTC
 */
transferRouter.get('/incoming-requests', async (req: AuthRequest, res, next) => {
  try {
    const partyId = await getPartyId(req.userId!);
    if (!partyId) {
      err(res, 400, 'User has no party');
      return;
    }
    const page = parseInt(req.query.page as string) || 1;
    const limit = parseInt(req.query.limit as string) || 10;
    const tokenName = req.query.tokenName as string | undefined;
    const result = await transferService.getIncomingRequests(partyId, page, limit, tokenName);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /transfer-token-standard/outgoing-requests?page=1&limit=10&tokenName=CBTC
 */
transferRouter.get('/outgoing-requests', async (req: AuthRequest, res, next) => {
  try {
    const partyId = await getPartyId(req.userId!);
    if (!partyId) {
      err(res, 400, 'User has no party');
      return;
    }
    const page = parseInt(req.query.page as string) || 1;
    const limit = parseInt(req.query.limit as string) || 10;
    const tokenName = req.query.tokenName as string | undefined;
    const result = await transferService.getOutgoingRequests(partyId, page, limit, tokenName);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /transfer-token-standard/history?page=1&limit=10&tokenName=CBTC&sender=X&receiver=Y
 */
transferRouter.get('/history', async (req: AuthRequest, res, next) => {
  try {
    const partyId = await getPartyId(req.userId!);
    if (!partyId) {
      err(res, 400, 'User has no party');
      return;
    }
    const page = parseInt(req.query.page as string) || 1;
    const limit = parseInt(req.query.limit as string) || 10;
    const tokenName = req.query.tokenName as string | undefined;
    const sender = req.query.sender as string | undefined;
    const receiver = req.query.receiver as string | undefined;
    const result = await transferService.getTransferHistory(partyId, page, limit, tokenName, sender, receiver);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /transfer-token-standard/approve/prepare
 *
 * Extension sends: { contractId, tokenId }
 */
transferRouter.post('/approve/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { contractId, tokenId } = req.body;
    if (!contractId) {
      err(res, 400, 'Missing required field: contractId');
      return;
    }
    const result = await transferService.prepareApprove({ contractId, tokenId });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /transfer-token-standard/approve/submit
 *
 * Accepts client-side signed approval from the wallet extension.
 * Body: { preparedTransaction, signature }
 */
transferRouter.post('/approve/submit', async (req: AuthRequest, res, next) => {
  try {
    const { preparedTransaction, signature } = req.body;
    if (!preparedTransaction || !signature) {
      err(res, 400, 'Missing required fields: preparedTransaction, signature');
      return;
    }
    const result = await transferService.submitSignedTransaction({ preparedTransaction, signature });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /transfer-token-standard/reject/prepare
 *
 * Extension sends: { contractId, tokenId }
 */
transferRouter.post('/reject/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { contractId, tokenId } = req.body;
    if (!contractId) {
      err(res, 400, 'Missing required field: contractId');
      return;
    }
    const result = await transferService.prepareReject({ contractId, tokenId });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /transfer-token-standard/reject/submit
 *
 * Accepts client-side signed rejection from the wallet extension.
 * Body: { preparedTransaction, signature }
 */
transferRouter.post('/reject/submit', async (req: AuthRequest, res, next) => {
  try {
    const { preparedTransaction, signature } = req.body;
    if (!preparedTransaction || !signature) {
      err(res, 400, 'Missing required fields: preparedTransaction, signature');
      return;
    }
    const result = await transferService.submitSignedTransaction({ preparedTransaction, signature });
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
