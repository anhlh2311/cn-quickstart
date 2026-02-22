import 'reflect-metadata';
import express from 'express';
import cors from 'cors';
import { config } from './config/index.js';
import { logger } from './lib/logger.js';
import { errorHandler } from './middleware/error-handler.js';
import { healthRouter } from './modules/health/health.controller.js';
import { authRouter } from './modules/auth/auth.controller.js';
import { onboardingRouter } from './modules/onboarding/onboarding.controller.js';
import { balanceRouter } from './modules/balance/balance.controller.js';
import { transferRouter } from './modules/transfer/transfer.controller.js';
import { amuletTransferRouter } from './modules/amulet-transfer/amulet-transfer.controller.js';
import { autoApprovalRouter } from './modules/auto-approval/auto-approval.controller.js';
import { faucetRouter } from './modules/faucet/faucet.controller.js';
import { activityRouter } from './modules/activity/activity.controller.js';
import { transferPreapprovalRouter } from './modules/transfer-preapproval/transfer-preapproval.controller.js';
import { initDatabase } from './config/database.js';
import { initWalletSDK } from './modules/gateway/wallet-sdk.js';

const app = express();

app.use(cors());
app.use(express.json());

// Health checks (no auth)
app.use(healthRouter);

// Auth routes (mixed auth)
app.use('/auth', authRouter);

// Protected routes
app.use('/external-party/onboarding', onboardingRouter);
app.use('/wallet', balanceRouter);
app.use('/transfer-token-standard', transferRouter);
app.use('/external-party/transfer-amulet', amuletTransferRouter);
app.use('/auto-approval', autoApprovalRouter);
app.use('/transfer-preapproval', transferPreapprovalRouter);
app.use('/external-party', faucetRouter);
app.use('/external-party', activityRouter);

// Error handler
app.use(errorHandler);

async function start() {
  logger.info('Starting dapp-core...');

  // Initialize database
  await initDatabase();
  logger.info('Database initialized');

  // Initialize Wallet SDK (connects to Canton Participant + Validator)
  try {
    await initWalletSDK();
    logger.info('Wallet SDK initialized');
  } catch (err) {
    logger.warn({ err }, 'Wallet SDK init failed (will retry on first use)');
  }

  app.listen(config.port, () => {
    logger.info({ port: config.port }, 'dapp-core listening');
    logger.info({ gatewayUserApi: config.gatewayUserApiUrl }, 'Wallet Gateway User API');
    logger.info({ gatewayDappApi: config.gatewayDappApiUrl }, 'Wallet Gateway dApp API');
  });
}

start().catch((err) => {
  logger.fatal({ err }, 'Failed to start dapp-core');
  process.exit(1);
});
