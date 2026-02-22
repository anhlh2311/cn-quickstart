import { config } from '../config/index.js';
import { gatewayService } from '../modules/gateway/gateway.service.js';
import { logger } from './logger.js';

/**
 * Direct HTTP client for the Splice Validator Internal API.
 *
 * Used for operations that the Wallet SDK doesn't expose:
 * - Auto-approval via setup-proposal flow (/v0/admin/external-party/setup-proposal/*)
 * - Transfer-preapproval status queries (/v0/admin/external-party/transfer-preapproval/*)
 * - Scan proxy queries (/v0/scan-proxy/*)
 *
 * Balance queries use the Wallet SDK (tokenStandard.listHoldingUtxos).
 * Faucet uses the Wallet SDK (tokenStandard.createAndSubmitTapInternal).
 */

// ---------------------------------------------------------------------------
// Splice Validator Internal API
// ---------------------------------------------------------------------------

export async function validatorGet(path: string): Promise<unknown> {
  const token = await gatewayService.getAdminToken();
  const url = `${config.validatorApiUrl}${path}`;

  const res = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
  });

  if (!res.ok) {
    const text = await res.text();
    logger.error({ url, status: res.status, body: text }, 'Validator API GET failed');
    throw new Error(`Validator API GET ${path} — ${res.status}: ${text}`);
  }

  return res.json();
}

export async function validatorPost(path: string, body: unknown): Promise<unknown> {
  const token = await gatewayService.getAdminToken();
  const url = `${config.validatorApiUrl}${path}`;

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    logger.error({ url, status: res.status, body: text }, 'Validator API POST failed');
    throw new Error(`Validator API POST ${path} — ${res.status}: ${text}`);
  }

  return res.json();
}
