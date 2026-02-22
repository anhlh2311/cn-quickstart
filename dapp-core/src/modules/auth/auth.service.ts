import { SignJWT, jwtVerify } from 'jose';
import bcryptjs from 'bcryptjs';
const { hash, compare } = bcryptjs;
import { OAuth2Client } from 'google-auth-library';
import { AppDataSource } from '../../config/database.js';
import { config } from '../../config/index.js';
import { User } from '../../entities/user.entity.js';
import { logger } from '../../lib/logger.js';
import { gatewayService } from '../gateway/gateway.service.js';

const userRepo = () => AppDataSource.getRepository(User);
const jwtSecret = new TextEncoder().encode(config.jwt.secret);
const googleClient = new OAuth2Client(config.google.clientId);

async function generateTokens(user: User) {
  const now = Math.floor(Date.now() / 1000);

  const token = await new SignJWT({
    sub: user.id,
    email: user.email,
    iat: now,
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setExpirationTime(config.jwt.accessTokenExpiresIn)
    .sign(jwtSecret);

  const refreshToken = await new SignJWT({
    sub: user.id,
    type: 'refresh',
    iat: now,
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setExpirationTime(config.jwt.refreshTokenExpiresIn)
    .sign(jwtSecret);

  return { token, refreshToken };
}

export async function loginWithGoogle(credential: string) {
  // Verify Google ID token
  const ticket = await googleClient.verifyIdToken({
    idToken: credential,
    audience: config.google.clientId,
  });
  const payload = ticket.getPayload();
  if (!payload?.email) {
    throw new Error('Invalid Google credential');
  }

  const { email, given_name: firstName, family_name: lastName } = payload;

  // Find or create user
  let user = await userRepo().findOne({
    where: { email },
    relations: ['party'],
  });

  if (!user) {
    const passwordHash = await hash(email + Date.now(), 10);
    user = userRepo().create({
      email,
      username: email.split('@')[0],
      password: passwordHash,
      firstName: firstName || '',
      lastName: lastName || '',
      isActive: true,
    });
    user = await userRepo().save(user);
    logger.info({ userId: user.id, email }, 'New user created via Google OAuth');
  }

  const tokens = await generateTokens(user);

  return {
    user: {
      id: user.id,
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      isActive: user.isActive,
    },
    ...tokens,
  };
}

export async function refreshToken(token: string) {
  try {
    const { payload } = await jwtVerify(token, jwtSecret);
    if (payload.type !== 'refresh') {
      throw new Error('Not a refresh token');
    }

    const user = await userRepo().findOneBy({ id: payload.sub as string });
    if (!user) {
      throw new Error('User not found');
    }

    return generateTokens(user);
  } catch {
    throw new Error('Invalid refresh token');
  }
}

export async function getMe(userId: string) {
  const user = await userRepo().findOne({
    where: { id: userId },
    relations: ['party'],
  });

  if (!user) {
    throw new Error('User not found');
  }

  // Return user without password
  const { password: _, ...userWithoutPassword } = user;
  return userWithoutPassword;
}

export async function getPartyId(userId: string): Promise<string | null> {
  const user = await userRepo().findOne({
    where: { id: userId },
    relations: ['party'],
  });
  return user?.party?.partyId ?? null;
}

export async function getCantonAccessToken() {
  return { cantonToken: await gatewayService.getAdminToken() };
}
