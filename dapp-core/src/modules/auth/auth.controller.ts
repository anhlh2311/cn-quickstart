import { Router } from 'express';
import { authMiddleware, type AuthRequest } from '../../middleware/auth.js';
import { ok, err } from '../../lib/response.js';
import * as authService from './auth.service.js';

export const authRouter = Router();

/**
 * POST /auth/login-with-google
 * Body: { credential: string }
 */
authRouter.post('/login-with-google', async (req, res, next) => {
  try {
    const { credential } = req.body;
    if (!credential) {
      err(res, 400, 'Missing credential');
      return;
    }
    const result = await authService.loginWithGoogle(credential);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * POST /auth/refresh-token
 * Body: { refreshToken: string }
 */
authRouter.post('/refresh-token', async (req, res, next) => {
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) {
      err(res, 400, 'Missing refreshToken');
      return;
    }
    const result = await authService.refreshToken(refreshToken);
    ok(res, result);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /auth/me
 * Requires: Bearer JWT
 */
authRouter.get('/me', authMiddleware, async (req: AuthRequest, res, next) => {
  try {
    const user = await authService.getMe(req.userId!);
    ok(res, user);
  } catch (e) {
    next(e);
  }
});

/**
 * GET /auth/canton-access-token
 * Requires: Bearer JWT
 */
authRouter.get('/canton-access-token', authMiddleware, async (_req, res, next) => {
  try {
    const result = await authService.getCantonAccessToken();
    ok(res, result);
  } catch (e) {
    next(e);
  }
});
