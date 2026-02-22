import { Router } from 'express';
import { config } from '../../config/index.js';

export const healthRouter = Router();

healthRouter.get('/healthz', (_req, res) => {
  res.status(200).json({ status: 'ok' });
});

healthRouter.get('/readyz', async (_req, res) => {
  try {
    // Check if Gateway is reachable
    const gatewayHealth = await fetch(
      config.gatewayUserApiUrl.replace('/api/v0/user', '/readyz'),
    );
    if (!gatewayHealth.ok) {
      res.status(503).json({ status: 'not ready', reason: 'gateway not ready' });
      return;
    }
    res.status(200).json({ status: 'ready' });
  } catch {
    res.status(503).json({ status: 'not ready', reason: 'gateway unreachable' });
  }
});
