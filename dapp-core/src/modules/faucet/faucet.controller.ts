import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as faucetService from './faucet.service.js';

export const faucetRouter = Router();

// All faucet routes require auth
faucetRouter.use(authMiddleware);

/**
 * POST /external-party/devnet-tap/prepare
 * Body: { partyId: string, amount?: string }
 *
 * Prepares a DevNet Tap faucet command via interactive submission.
 * Returns { preparedTransaction, preparedTransactionHash, hashingSchemeVersion }
 * for the wallet extension to sign.
 */
faucetRouter.post('/devnet-tap/prepare', async (req: AuthRequest, res, next) => {
  try {
    const { partyId, amount } = req.body;
    if (!partyId) {
      err(res, 400, 'Missing partyId');
      return;
    }
    if (amount !== undefined && (isNaN(Number(amount)) || Number(amount) <= 0 || Number(amount) > 10000)) {
      err(res, 400, 'Amount must be between 0 and 10000');
      return;
    }
    const result = await faucetService.prepareFaucetTap(partyId, amount);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /external-party/devnet-tap/submit
 * Body: { preparedTransaction: string, signature: string, partyId: string }
 *
 * Submits a signed DevNet Tap faucet transaction.
 * The wallet extension signs preparedTransactionHash and sends the signature.
 */
faucetRouter.post('/devnet-tap/submit', async (req: AuthRequest, res, next) => {
  try {
    const { preparedTransaction, signature, partyId } = req.body;
    if (!preparedTransaction || !signature || !partyId) {
      err(res, 400, 'Missing preparedTransaction, signature, or partyId');
      return;
    }
    const result = await faucetService.submitFaucetTap(
      preparedTransaction,
      signature,
      partyId,
    );
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /external-party/request-faucet
 * Body: { partyId: string, amount?: string }
 *
 * Legacy endpoint — redirects to the prepare step.
 * The DevNet Tap requires the receiver to sign, so this returns the
 * prepared transaction for signing instead of completing the tap directly.
 */
faucetRouter.post('/request-faucet', async (req: AuthRequest, res, next) => {
  try {
    const { partyId, amount } = req.body;
    if (!partyId) {
      err(res, 400, 'Missing partyId');
      return;
    }
    if (amount !== undefined && (isNaN(Number(amount)) || Number(amount) <= 0 || Number(amount) > 10000)) {
      err(res, 400, 'Amount must be between 0 and 10000');
      return;
    }
    // Return prepared data — extension must sign and call /devnet-tap/submit
    const result = await faucetService.prepareFaucetTap(partyId, amount);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
