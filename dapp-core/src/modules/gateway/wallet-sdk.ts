import {
  WalletSDKImpl,
  UnsafeAuthController,
  AuthTokenProvider,
  LedgerController,
  TokenStandardController,
  ValidatorController,
} from '@canton-network/wallet-sdk';
import { config } from '../../config/index.js';
import { logger } from '../../lib/logger.js';
import { validatorGet } from '../../lib/canton-api.js';
import { gatewayService } from './gateway.service.js';

let sdk: WalletSDKImpl | null = null;
let initialized = false;
let cachedSynchronizerId: string | null = null;
let adminRightsGranted = false;

/**
 * Fetch the active synchronizer ID from the scan proxy.
 * Extracts it from AmuletRules contract payload. Cached after first call.
 */
async function fetchSynchronizerId(): Promise<string> {
  if (cachedSynchronizerId) return cachedSynchronizerId;

  const resp = (await validatorGet('/v0/scan-proxy/amulet-rules')) as {
    amulet_rules?: {
      contract?: {
        payload?: {
          configSchedule?: {
            initialValue?: {
              decentralizedSynchronizer?: {
                activeSynchronizer?: string;
              };
            };
            futureValues?: Array<{
              decentralizedSynchronizer?: {
                activeSynchronizer?: string;
              };
            }>;
          };
        };
      };
    };
  };

  const payload = resp?.amulet_rules?.contract?.payload;
  const initSync =
    payload?.configSchedule?.initialValue?.decentralizedSynchronizer?.activeSynchronizer;
  const futureValues = payload?.configSchedule?.futureValues;

  let synchronizerId = initSync;
  if (Array.isArray(futureValues) && futureValues.length > 0) {
    for (const value of futureValues) {
      if (value?.decentralizedSynchronizer?.activeSynchronizer) {
        synchronizerId = value.decentralizedSynchronizer.activeSynchronizer;
      }
    }
  }

  if (!synchronizerId) {
    throw new Error('Could not resolve synchronizerId from scan proxy amulet-rules');
  }

  cachedSynchronizerId = synchronizerId;
  logger.info({ synchronizerId }, 'Resolved Canton synchronizer ID');
  return synchronizerId;
}

/**
 * Grant CanReadAsAnyParty to the admin user on the participant.
 * This allows the SDK to read contracts (AmuletRules, OpenMiningRound, etc.)
 * belonging to any party (e.g., the DSO party). Idempotent — safe to call multiple times.
 */
async function grantAdminRights(): Promise<void> {
  if (adminRightsGranted) return;

  const token = await gatewayService.getAdminToken();
  const userId = config.canton.adminUser;
  const url = `${config.participantLedgerApiUrl}/v2/users/${userId}/rights`;

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        userId,
        identityProviderId: '',
        rights: [{ kind: { CanReadAsAnyParty: { value: {} } } }],
      }),
    });

    if (res.ok || res.status === 409) {
      // 409 = already granted
      adminRightsGranted = true;
      logger.info({ userId }, 'CanReadAsAnyParty granted to admin user');
    } else {
      const text = await res.text();
      logger.warn({ userId, status: res.status, body: text }, 'Failed to grant CanReadAsAnyParty (non-fatal)');
    }
  } catch (err) {
    logger.warn({ err }, 'Failed to grant CanReadAsAnyParty (non-fatal)');
  }
}

/**
 * Initialize the Wallet SDK with our Canton config.
 *
 * Creates an UnsafeAuthController (self-signed JWT) and custom factory functions
 * that point to our Quickstart Docker network URLs (canton:3975, splice:3903).
 *
 * After connecting, configures tokenStandard with the transfer factory registry URL
 * (required for tap and transfer operations).
 */
export async function initWalletSDK(): Promise<WalletSDKImpl> {
  if (sdk && initialized) return sdk;

  const ledgerUrl = new URL(config.participantLedgerApiUrl);
  const validatorUrl = new URL(config.validatorApiUrl);

  sdk = new WalletSDKImpl();
  sdk.configure({
    authFactory: () => {
      const auth = new UnsafeAuthController();
      auth.userId = config.canton.adminUser;
      auth.adminId = config.canton.adminUser;
      auth.audience = config.canton.audience;
      auth.unsafeSecret = config.canton.unsafeSecret;
      return auth;
    },
    ledgerFactory: (userId: string, authTokenProvider: AuthTokenProvider, isAdmin: boolean) => {
      return new LedgerController(userId, ledgerUrl, '', isAdmin, authTokenProvider);
    },
    tokenStandardFactory: (userId: string, authTokenProvider: AuthTokenProvider, isAdmin: boolean) => {
      return new TokenStandardController(
        userId,
        ledgerUrl,
        validatorUrl,
        '',
        authTokenProvider,
        isAdmin,
      );
    },
    validatorFactory: (userId: string, authTokenProvider: AuthTokenProvider) => {
      return new ValidatorController(userId, validatorUrl, authTokenProvider);
    },
  });

  await sdk.connect();
  await sdk.connectAdmin();

  // Grant CanReadAsAnyParty to admin user (idempotent)
  // Required for reading contracts belonging to any party (AmuletRules, OpenMiningRound, etc.)
  await grantAdminRights();

  // Configure tokenStandard with the scan proxy registry URL
  // (SDK pattern: validatorApiUrl + '/v0/scan-proxy')
  const registryUrl = new URL(config.validatorApiUrl + '/v0/scan-proxy');
  sdk.tokenStandard!.setTransferFactoryRegistryUrl(registryUrl);
  logger.info({ registryUrl: registryUrl.href }, 'Set transferFactoryRegistryUrl on tokenStandard');

  initialized = true;
  logger.info('Wallet SDK initialized');
  return sdk;
}

/**
 * Get the initialized Wallet SDK instance.
 * Throws if initWalletSDK() hasn't been called yet.
 */
export function getSDK(): WalletSDKImpl {
  if (!sdk || !initialized) {
    throw new Error('Wallet SDK not initialized. Call initWalletSDK() first.');
  }
  return sdk;
}

/**
 * Get the cached synchronizer ID, fetching from scan proxy if needed.
 */
export async function getSynchronizerId(): Promise<string> {
  return fetchSynchronizerId();
}
