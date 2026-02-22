import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  UpdateDateColumn,
} from 'typeorm';

@Entity('tx_history_offset')
export class TxHistoryOffset {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column()
  type!: string;

  @Column({ name: 'current_offset', type: 'bigint', default: 0 })
  currentOffset!: string;

  @UpdateDateColumn({ name: 'updated_at' })
  updatedAt!: Date;
}
