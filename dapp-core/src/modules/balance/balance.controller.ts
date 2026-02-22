import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as balanceService from './balance.service.js';

export const balanceRouter = Router();

// All balance routes require auth
balanceRouter.use(authMiddleware);

/**
 * GET /wallet/token-balance?partyId=X
 */
balanceRouter.get('/token-balance', async (req: AuthRequest, res, next) => {
  try {
    const partyId = req.query.partyId as string;
    if (!partyId) {
      err(res, 400, 'Missing partyId query parameter');
      return;
    }
    const result = await balanceService.getTokenBalance(partyId);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /wallet/token-prices
 */
balanceRouter.get('/token-prices', async (_req: AuthRequest, res, next) => {
  try {
    const result = await balanceService.getTokenPrices();
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
