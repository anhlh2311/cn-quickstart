import { Router } from 'express';
import type { Request, Response } from 'express';
import { ok, created, err } from '../../lib/response.js';
import { logger } from '../../lib/logger.js';
import * as partyService from './party.service.js';

export const partyRouter = Router();

// POST /parties — Allocate a new internal party
partyRouter.post('/', async (req: Request, res: Response) => {
  try {
    const { partyHint, displayName } = req.body;
    if (!partyHint || !displayName) {
      return err(res, 400, 'partyHint and displayName are required');
    }

    const party = await partyService.createParty(partyHint, displayName);
    created(res, party);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to create party');
    if (msg.includes('already exists')) {
      return err(res, 409, msg);
    }
    err(res, 500, msg);
  }
});

// GET /parties — List all parties
partyRouter.get('/', async (_req: Request, res: Response) => {
  try {
    const parties = await partyService.listParties();
    ok(res, parties);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to list parties');
    err(res, 500, msg);
  }
});

// GET /parties/:id — Get party by ID
partyRouter.get('/:id', async (req: Request, res: Response) => {
  try {
    const party = await partyService.getPartyById(req.params.id as string);
    if (!party) {
      return err(res, 404, 'Party not found');
    }
    ok(res, party);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    logger.error({ error: msg }, 'Failed to get party');
    err(res, 500, msg);
  }
});
