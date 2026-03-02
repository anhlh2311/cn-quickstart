import 'dotenv/config';

export const config = {
  port: parseInt(process.env.PORT || '3004', 10),
  nodeEnv: process.env.NODE_ENV || 'development',

  // Canton Participant Ledger API (direct access, not through Gateway)
  participantLedgerApiUrl: process.env.PARTICIPANT_LEDGER_API_URL || 'http://localhost:3975',

  // Database
  db: {
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT || '5432', 10),
    username: process.env.DB_USERNAME || 'cnadmin',
    password: process.env.DB_PASSWORD || 'supersafe',
    database: process.env.DB_NAME || 'token-issuer',
  },

  // Canton auth (self-signed JWT for Ledger API)
  canton: {
    unsafeSecret: process.env.CANTON_UNSAFE_SECRET || 'unsafe',
    audience: process.env.CANTON_AUDIENCE || 'https://canton.network.global',
    adminUser: process.env.CANTON_ADMIN_USER || 'ledger-api-user',
  },

  // Template IDs for Utility packages
  templates: {
    instrumentConfiguration:
      process.env.INSTRUMENT_CONFIG_TEMPLATE ||
      '#utility-registry-v0:Utility.Registry.V0.Configuration.Instrument:InstrumentConfiguration',
    allocationFactory:
      process.env.ALLOCATION_FACTORY_TEMPLATE ||
      '#utility-registry-app-v0:Utility.Registry.App.V0.Service.AllocationFactory:AllocationFactory',
  },
} as const;
