import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as activityService from './activity.service.js';

export const activityRouter = Router();

// All activity routes require auth
activityRouter.use(authMiddleware);

/**
 * GET /external-party/tx-history?partyId=X&page=1&limit=20
 */
activityRouter.get('/tx-history', async (req: AuthRequest, res, next) => {
  try {
    const partyId = req.query.partyId as string;
    if (!partyId) {
      err(res, 400, 'Missing partyId');
      return;
    }
    const page = parseInt(req.query.page as string) || 1;
    const limit = parseInt(req.query.limit as string) || 20;
    const result = await activityService.getTxHistory(partyId, page, limit);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
