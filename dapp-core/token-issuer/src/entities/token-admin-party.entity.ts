import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
} from 'typeorm';

export enum PartyStatus {
  PENDING = 'PENDING',
  ACTIVE = 'ACTIVE',
  FAILED = 'FAILED',
}

@Entity('token_admin_parties')
export class TokenAdminParty {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column({ type: 'varchar', unique: true })
  partyId!: string;

  @Column({ type: 'varchar', unique: true })
  partyHint!: string;

  @Column({ type: 'varchar' })
  displayName!: string;

  @Column({ type: 'enum', enum: PartyStatus, default: PartyStatus.PENDING })
  status!: PartyStatus;

  @CreateDateColumn()
  createdAt!: Date;
}
