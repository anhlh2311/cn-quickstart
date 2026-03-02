import { Router } from 'express';
import type { Request, Response } from 'express';
import { ok, created, err } from '../../lib/response.js';
import { logger } from '../../lib/logger.js';
import * as tokenService from './token.service.js';

export const tokenRouter = Router();

// POST /tokens — Create a new token (InstrumentConfiguration + AllocationFactory)
tokenRouter.post('/', async (req: Request, res: Response) => {
  try {
    const { adminPartyId, tokenId, displayName, symbol } = req.body;
    if (!adminPartyId || !tokenId || !displayName || !symbol) {
      return err(res, 400, 'adminPartyId, tokenId, displayName, and symbol are required');
    }

    const token = await tokenService.createToken(adminPartyId, tokenId, displayName, symbol);
    created(res, token);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to create token');
    if (msg.includes('already exists')) {
      return err(res, 409, msg);
    }
    if (msg.includes('not found') || msg.includes('not active')) {
      return err(res, 400, msg);
    }
    err(res, 500, msg);
  }
});

// GET /tokens — List all tokens
tokenRouter.get('/', async (_req: Request, res: Response) => {
  try {
    const tokens = await tokenService.listTokens();
    ok(res, tokens);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to list tokens');
    err(res, 500, msg);
  }
});

// GET /tokens/:id — Get token by ID or tokenId
tokenRouter.get('/:id', async (req: Request, res: Response) => {
  try {
    // Try tokenId first (more common), then UUID
    const id = req.params.id as string;
    let token = await tokenService.getTokenByTokenId(id);
    if (!token) {
      // Only try UUID if it looks like one
      const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      if (uuidRegex.test(id)) {
        token = await tokenService.getTokenById(id);
      }
    }
    if (!token) {
      return err(res, 404, 'Token not found');
    }
    ok(res, token);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to get token');
    err(res, 500, msg);
  }
});
