import { SignJWT } from 'jose';
import { config } from '../../config/index.js';
import { jsonRpcCall } from '../../lib/jsonrpc.js';
import { logger } from '../../lib/logger.js';

/**
 * GatewayService wraps JSON-RPC 2.0 calls to the Wallet Gateway's User API and dApp API.
 *
 * The Gateway handles all Canton Ledger operations: party allocation, signing,
 * wallet sync, and ledger API proxying.
 */
class GatewayService {
  private userApiUrl: string;
  private dappApiUrl: string;
  private cachedAdminToken: string | null = null;
  private tokenExpiresAt = 0;
  private sessionActive = false;

  constructor() {
    this.userApiUrl = config.gatewayUserApiUrl;
    this.dappApiUrl = config.gatewayDappApiUrl;
    logger.info({ userApiUrl: this.userApiUrl, dappApiUrl: this.dappApiUrl }, 'GatewayService init');
  }

  /**
   * Generate a self-signed Canton JWT for admin operations.
   * This matches the shared-secret auth pattern used by canton-exchange-backend.
   */
  async getAdminToken(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (this.cachedAdminToken && now < this.tokenExpiresAt - 60) {
      return this.cachedAdminToken;
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

    this.cachedAdminToken = token;
    this.tokenExpiresAt = now + expiresIn;
    // Reset session when token changes — Gateway ties sessions to JWT identity
    this.sessionActive = false;
    return token;
  }

  /**
   * Ensure an active session exists with the Gateway.
   * The Gateway requires addSession() before any User API call.
   */
  async ensureSession(token: string): Promise<void> {
    if (this.sessionActive) return;
    try {
      await jsonRpcCall(this.userApiUrl, 'addSession', { networkId: 'canton:localnet' }, token);
      this.sessionActive = true;
      logger.info('Gateway session established');
    } catch (e: unknown) {
      // Session may already exist — that's fine
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes('already') || msg.includes('exists')) {
        this.sessionActive = true;
        return;
      }
      throw e;
    }
  }

  // --- User API methods ---

  async addSession(networkId: string, token: string): Promise<unknown> {
    return jsonRpcCall(this.userApiUrl, 'addSession', { networkId }, token);
  }

  async removeSession(token: string): Promise<unknown> {
    return jsonRpcCall(this.userApiUrl, 'removeSession', {}, token);
  }

  async getUser(token: string): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'getUser', {}, token);
  }

  async listNetworks(token: string): Promise<unknown> {
    return jsonRpcCall(this.userApiUrl, 'listNetworks', {}, token);
  }

  async createWallet(
    params: {
      networkId: string;
      partyHint: string;
      signingProviderId: string;
      primary?: boolean;
    },
    token: string,
  ): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'createWallet', params, token);
  }

  async listWallets(token: string, filter?: Record<string, unknown>): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'listWallets', filter || {}, token);
  }

  async syncWallets(token: string): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'syncWallets', {}, token);
  }

  async sign(
    commandId: string,
    partyId: string,
    token: string,
  ): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'sign', { commandId, partyId }, token);
  }

  async execute(
    commandId: string,
    signature: string,
    partyId: string,
    token: string,
  ): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'execute', { commandId, signature, partyId }, token);
  }

  async getTransaction(commandId: string, token: string): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'getTransaction', { commandId }, token);
  }

  async listTransactions(token: string): Promise<unknown> {
    await this.ensureSession(token);
    return jsonRpcCall(this.userApiUrl, 'listTransactions', {}, token);
  }

  // --- dApp API methods ---

  async ledgerApiGet(resource: string, token: string): Promise<unknown> {
    return jsonRpcCall(this.dappApiUrl, 'ledgerApi', { requestMethod: 'GET', resource }, token);
  }

  async ledgerApiPost(resource: string, body: unknown, token: string): Promise<unknown> {
    return jsonRpcCall(this.dappApiUrl, 'ledgerApi', {
      requestMethod: 'POST',
      resource,
      body: JSON.stringify(body),
    }, token);
  }

  async connect(token: string): Promise<unknown> {
    return jsonRpcCall(this.dappApiUrl, 'connect', {}, token);
  }

  async status(token: string): Promise<unknown> {
    return jsonRpcCall(this.dappApiUrl, 'status', {}, token);
  }
}

// Singleton instance
export const gatewayService = new GatewayService();
