import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as onboardingService from './onboarding.service.js';

export const onboardingRouter = Router();

// All onboarding routes require auth
onboardingRouter.use(authMiddleware);

/**
 * POST /external-party/onboarding/prepare
 * Body: { publicKey: string }
 */
onboardingRouter.post('/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { publicKey } = req.body;
    if (!publicKey) {
      err(res, 400, 'Missing publicKey');
      return;
    }
    const result = await onboardingService.prepareOnboarding(req.userId!, publicKey);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /external-party/onboarding/submit
 * Body: { signedHash: string, preparedParty: { partyId, namespace, multiHash, topologyTransactions } }
 */
onboardingRouter.post('/submit', async (req: AuthRequest, res, next) => {
  try {
    const { signedHash, preparedParty } = req.body;
    if (!signedHash || !preparedParty) {
      err(res, 400, 'Missing signedHash or preparedParty');
      return;
    }
    const result = await onboardingService.submitOnboarding(req.userId!, signedHash, preparedParty);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
