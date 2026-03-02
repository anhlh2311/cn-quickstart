import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  ManyToOne,
  JoinColumn,
} from 'typeorm';
import { TokenAdminParty } from './token-admin-party.entity.js';

export enum TokenStatus {
  PENDING = 'PENDING',
  ACTIVE = 'ACTIVE',
  FAILED = 'FAILED',
}

@Entity('tokens')
export class Token {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column({ type: 'varchar', unique: true })
  tokenId!: string;

  @Column({ type: 'varchar' })
  displayName!: string;

  @Column({ type: 'varchar' })
  symbol!: string;

  @Column({ type: 'uuid' })
  adminPartyId!: string;

  @ManyToOne(() => TokenAdminParty)
  @JoinColumn({ name: 'adminPartyId' })
  adminParty!: TokenAdminParty;

  @Column({ type: 'varchar' })
  cantonPartyId!: string;

  @Column({ type: 'varchar', nullable: true })
  instrumentConfigCid!: string | null;

  @Column({ type: 'varchar', nullable: true })
  allocationFactoryCid!: string | null;

  @Column({ type: 'enum', enum: TokenStatus, default: TokenStatus.PENDING })
  status!: TokenStatus;

  @CreateDateColumn()
  createdAt!: Date;
}
