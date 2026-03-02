import 'reflect-metadata';
import express from 'express';
import cors from 'cors';
import swaggerUi from 'swagger-ui-express';
import { config } from './config/index.js';
import { logger } from './lib/logger.js';
import { swaggerSpec } from './swagger.js';
import { initDatabase } from './config/database.js';
import { healthRouter } from './modules/health/health.controller.js';
import { partyRouter } from './modules/party/party.controller.js';
import { tokenRouter } from './modules/token/token.controller.js';
import { mintRouter } from './modules/mint/mint.controller.js';

const app = express();

app.use(cors());
app.use(express.json());

// Health check (no prefix)
app.use(healthRouter);

// API docs
app.use('/api-docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec));

// API routes
app.use('/parties', partyRouter);
app.use('/tokens', tokenRouter);
app.use('/tokens', mintRouter);

async function start() {
  logger.info('Starting token-issuer...');

  // Initialize database
  await initDatabase();
  logger.info('Database initialized');

  app.listen(config.port, () => {
    logger.info({ port: config.port }, 'token-issuer listening');
    logger.info({ participantApi: config.participantLedgerApiUrl }, 'Canton Participant API');
    logger.info(`Swagger UI: http://localhost:${config.port}/api-docs`);
  });
}

start().catch((err) => {
  logger.fatal({ err }, 'Failed to start token-issuer');
  process.exit(1);
});
