import 'dotenv/config';

export const config = {
  port: parseInt(process.env.PORT || '3003', 10),
  nodeEnv: process.env.NODE_ENV || 'development',

  // Wallet Gateway
  gatewayUserApiUrl: process.env.GATEWAY_USER_API_URL || 'http://localhost:3030/api/v0/user',
  gatewayDappApiUrl: process.env.GATEWAY_DAPP_API_URL || 'http://localhost:3030/api/v0/dapp',

  // Canton Participant Ledger API (direct access, not through Gateway)
  participantLedgerApiUrl: process.env.PARTICIPANT_LEDGER_API_URL || 'http://canton:3975',

  // Splice Validator Internal API
  validatorApiUrl: process.env.VALIDATOR_API_URL || 'http://splice:3903/api/validator',

  // Database
  db: {
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT || '5432', 10),
    username: process.env.DB_USERNAME || 'cnadmin',
    password: process.env.DB_PASSWORD || 'supersafe',
    database: process.env.DB_NAME || 'dapp-core',
  },

  // JWT
  jwt: {
    secret: process.env.JWT_SECRET || 'dapp-core-jwt-secret-change-me',
    accessTokenExpiresIn: process.env.JWT_ACCESS_TOKEN_EXPIRES_IN || '1d',
    refreshTokenExpiresIn: process.env.JWT_REFRESH_TOKEN_EXPIRES_IN || '7d',
  },

  // Canton auth
  canton: {
    authMode: process.env.CANTON_AUTH_MODE || 'self_signed',
    unsafeSecret: process.env.CANTON_UNSAFE_SECRET || 'unsafe',
    audience: process.env.CANTON_AUDIENCE || 'https://canton.network.global',
    adminUser: process.env.CANTON_ADMIN_USER || 'ledger-api-user',
    partyIdPrefix: process.env.PARTY_ID_PREFIX || 'dapp-user',
  },

  // Google OAuth
  google: {
    clientId: process.env.GOOGLE_CLIENT_ID || '',
    clientSecret: process.env.GOOGLE_CLIENT_SECRET || '',
  },
} as const;
