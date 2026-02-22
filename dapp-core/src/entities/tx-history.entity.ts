import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  UpdateDateColumn,
  Index,
} from 'typeorm';

@Entity('tx_histories')
@Index(['sender', 'timestamp'])
@Index(['receiver', 'timestamp'])
export class TxHistory {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column()
  type!: string;

  @Column({ name: 'instrument_id', type: 'jsonb' })
  instrumentId!: { admin: string; id: string };

  @Column({ type: 'timestamp' })
  timestamp!: Date;

  @Column({ name: 'record_time', type: 'timestamp' })
  recordTime!: Date;

  @Column({ type: 'bigint' })
  offset!: string;

  @Column({ nullable: true })
  sender?: string;

  @Column({ nullable: true })
  receiver?: string;

  @Column({ nullable: true })
  amount?: string;

  @Column({ name: 'update_id' })
  @Index()
  updateId!: string;

  @Column({ name: 'event_id' })
  eventId!: string;

  @Column({ name: 'contract_id', nullable: true })
  contractId?: string;

  @Column({ name: 'output_fee', nullable: true })
  outputFee?: string;

  @Column({ nullable: true })
  owner?: string;

  @Column({ name: 'result_holding_cid', nullable: true })
  resultHoldingCid?: string;

  @CreateDateColumn({ name: 'created_at' })
  createdAt!: Date;

  @UpdateDateColumn({ name: 'updated_at' })
  updatedAt!: Date;
}
