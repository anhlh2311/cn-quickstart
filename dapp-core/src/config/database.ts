import { DataSource } from 'typeorm';
import { config } from './index.js';
import { User } from '../entities/user.entity.js';
import { Party } from '../entities/party.entity.js';
import { TxHistory } from '../entities/tx-history.entity.js';
import { TransferHistory } from '../entities/transfer-history.entity.js';
import { TxHistoryOffset } from '../entities/tx-history-offset.entity.js';

export const AppDataSource = new DataSource({
  type: 'postgres',
  host: config.db.host,
  port: config.db.port,
  username: config.db.username,
  password: config.db.password,
  database: config.db.database,
  synchronize: config.nodeEnv === 'development',
  logging: config.nodeEnv === 'development',
  entities: [User, Party, TxHistory, TransferHistory, TxHistoryOffset],
});

export async function initDatabase(): Promise<DataSource> {
  return AppDataSource.initialize();
}
