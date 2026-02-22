import type { Request, Response, NextFunction } from 'express';
import { jwtVerify } from 'jose';
import { config } from '../config/index.js';
import { err } from '../lib/response.js';

export interface AuthRequest extends Request {
  userId?: string;
  userEmail?: string;
}

const secret = new TextEncoder().encode(config.jwt.secret);

export async function authMiddleware(
  req: AuthRequest,
  res: Response,
  next: NextFunction,
): Promise<void> {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    err(res, 401, 'Missing or invalid authorization header');
    return;
  }

  const token = authHeader.slice(7);

  try {
    const { payload } = await jwtVerify(token, secret);
    req.userId = payload.sub as string;
    req.userEmail = payload.email as string;
    next();
  } catch {
    err(res, 401, 'Invalid or expired token');
  }
}
