import { SignJWT } from 'jose';
import { config } from '../config/index.js';

let cachedToken: string | null = null;
let tokenExpiresAt = 0;

/**
 * Generate a self-signed Canton JWT for admin operations.
 * HS256 signed with the unsafe secret — same pattern as dapp-core's GatewayService.
 */
export async function getAdminToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now < tokenExpiresAt - 60) {
    return cachedToken;
  }

  const expiresIn = 24 * 60 * 60; // 24 hours
  const secret = new TextEncoder().encode(config.canton.unsafeSecret);

  const token = await new SignJWT({
    sub: config.canton.adminUser,
    aud: config.canton.audience,
    scope: 'openid daml_ledger_api offline_access',
    iat: now,
    exp: now + expiresIn,
    iss: 'unsafe-auth',
  })
    .setProtectedHeader({ alg: 'HS256' })
    .sign(secret);

  cachedToken = token;
  tokenExpiresAt = now + expiresIn;
  return token;
}
