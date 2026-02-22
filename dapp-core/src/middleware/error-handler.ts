import type { Request, Response, NextFunction } from 'express';
import { logger } from '../lib/logger.js';
import { JsonRpcError } from '../lib/jsonrpc.js';

export function errorHandler(err: Error, _req: Request, res: Response, _next: NextFunction): void {
  logger.error({ err }, 'Unhandled error');

  if (err instanceof JsonRpcError) {
    res.status(502).json({
      code: 502,
      data: { message: `Gateway error: ${err.message}`, rpcCode: err.code },
    });
    return;
  }

  res.status(500).json({
    code: 500,
    data: { message: err.message || 'Internal server error' },
  });
}
