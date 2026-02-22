import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';

export enum OnboardingStatus {
  PENDING = 'PENDING',
  SUCCESSFULLY = 'SUCCESSFULLY',
  DEACTIVATED = 'DEACTIVATED',
}

@Entity('parties')
export class Party {
  @PrimaryGeneratedColumn('uuid')
  id!: string;

  @Column({ name: 'public_key', unique: true })
  publicKey!: string;

  @Column({ name: 'party_id', unique: true })
  partyId!: string;

  @Column({
    name: 'onboarding_status',
    type: 'enum',
    enum: OnboardingStatus,
    default: OnboardingStatus.PENDING,
  })
  onboardingStatus!: OnboardingStatus;

  @Column({ name: 'user_id', nullable: true })
  userId?: string;

  @Column({ name: 'deactivated_at', type: 'timestamp', nullable: true })
  deactivatedAt?: Date;

  @CreateDateColumn({ name: 'created_at' })
  createdAt!: Date;

  @UpdateDateColumn({ name: 'updated_at' })
  updatedAt!: Date;
}
