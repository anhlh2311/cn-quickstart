import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  UpdateDateColumn,
  Index,
} from 'typeorm';

export enum TransferHistoryStatus {
  LOCKED = 'LOCKED',
  CANCELLED = 'CANCELLED',
  REJECTED = 'REJECTED',
  APPROVED = 'APPROVED',
}

@Entity('transfer_history')
@Index(['sender', 'status'])
@Index(['receiver', 'status'])
@Index(['sender', 'offset'])
@Index(['receiver', 'offset'])
@Index(['tokenName', 'status'])
export class TransferHistory {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column({ name: 'contract_id', unique: true })
  contractId!: string;

  @Column({ type: 'bigint' })
  offset!: string;

  @Column({
    type: 'enum',
    enum: TransferHistoryStatus,
  })
  status!: TransferHistoryStatus;

  @Column({ nullable: true })
  sender?: string;

  @Column({ nullable: true })
  receiver?: string;

  @Column({ nullable: true })
  amount?: string;

  @Column({ name: 'token_name', nullable: true })
  @Index()
  tokenName?: string;

  @Column({ name: 'instrument_id', type: 'jsonb', nullable: true })
  instrumentId?: { admin: string; id: string };

  @Column({ name: 'effective_at', type: 'timestamp' })
  effectiveAt!: Date;

  @Column({ name: 'record_time', type: 'timestamp' })
  recordTime!: Date;

  @Column({ name: 'update_id' })
  updateId!: string;

  @Column({ name: 'event_id' })
  eventId!: string;

  @CreateDateColumn({ name: 'created_at' })
  createdAt!: Date;

  @UpdateDateColumn({ name: 'updated_at' })
  updatedAt!: Date;
}
