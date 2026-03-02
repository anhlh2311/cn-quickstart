import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
} from 'typeorm';

export enum MintStatus {
  PENDING = 'PENDING',
  SUCCESS = 'SUCCESS',
  FAILED = 'FAILED',
}

@Entity('mint_records')
export class MintRecord {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column({ type: 'varchar' })
  tokenId!: string;

  @Column({ type: 'varchar' })
  recipientPartyId!: string;

  @Column({ type: 'varchar' })
  amount!: string;

  @Column({ type: 'enum', enum: MintStatus, default: MintStatus.PENDING })
  status!: MintStatus;

  @Column({ type: 'varchar', nullable: true })
  transactionId!: string | null;

  @Column({ type: 'varchar', nullable: true })
  errorMessage!: string | null;

  @CreateDateColumn()
  createdAt!: Date;
}
