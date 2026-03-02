import { DataSource } from 'typeorm';
import { config } from './index.js';
import { TokenAdminParty } from '../entities/token-admin-party.entity.js';
import { Token } from '../entities/token.entity.js';
import { MintRecord } from '../entities/mint-record.entity.js';

export const AppDataSource = new DataSource({
  type: 'postgres',
  host: config.db.host,
  port: config.db.port,
  username: config.db.username,
  password: config.db.password,
  database: config.db.database,
  synchronize: true,
  logging: config.nodeEnv === 'development',
  entities: [TokenAdminParty, Token, MintRecord],
});

export async function initDatabase(): Promise<DataSource> {
  return AppDataSource.initialize();
}
