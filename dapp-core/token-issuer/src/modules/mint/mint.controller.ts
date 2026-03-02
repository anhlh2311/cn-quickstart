import { Router } from 'express';
import type { Request, Response } from 'express';
import { ok, err } from '../../lib/response.js';
import { logger } from '../../lib/logger.js';
import * as mintService from './mint.service.js';

export const mintRouter = Router();

// POST /tokens/:tokenId/mint — Mint tokens to recipients
mintRouter.post('/:tokenId/mint', async (req: Request, res: Response) => {
  try {
    const tokenId = req.params.tokenId as string;
    const { recipients } = req.body;

    if (!recipients || !Array.isArray(recipients) || recipients.length === 0) {
      return err(res, 400, 'recipients array is required and must not be empty');
    }

    // Validate each recipient
    for (const r of recipients) {
      if (!r.partyId || !r.amount) {
        return err(res, 400, 'Each recipient must have partyId and amount');
      }
    }

    const results = await mintService.mintTokens(tokenId, recipients);
    ok(res, { tokenId, results });
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to mint tokens');
    if (msg.includes('not found')) {
      return err(res, 404, msg);
    }
    if (msg.includes('not active') || msg.includes('missing factory')) {
      return err(res, 400, msg);
    }
    err(res, 500, msg);
  }
});

// GET /tokens/:tokenId/mint-records — List mint records for a token
mintRouter.get('/:tokenId/mint-records', async (req: Request, res: Response) => {
  try {
    const records = await mintService.listMintRecords(req.params.tokenId as string);
    ok(res, records);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to list mint records');
    err(res, 500, msg);
  }
});
