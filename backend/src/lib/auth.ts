import bcrypt from 'bcryptjs'
import jwt from 'jsonwebtoken'
import { AppError } from './errors.js'

export type Role = 'admin' | 'cashier'

export interface TokenPayload {
  sub: string // user id
  branchId: string
  username: string
  role: Role
}

/**
 * Cost 10 takes roughly 60ms on a low-end machine. Higher is more resistant to
 * offline cracking but makes login sluggish on the 4GB target PC; 10 is the
 * common default and adequate for a single-restaurant system.
 */
const BCRYPT_ROUNDS = 10

export async function hashPassword(plain: string): Promise<string> {
  return bcrypt.hash(plain, BCRYPT_ROUNDS)
}

export async function verifyPassword(plain: string, hash: string): Promise<boolean> {
  return bcrypt.compare(plain, hash)
}

export function signToken(payload: TokenPayload, secret: string, expiresInSeconds: number): string {
  return jwt.sign(payload, secret, { expiresIn: expiresInSeconds })
}

export function verifyToken(token: string, secret: string): TokenPayload {
  try {
    const decoded = jwt.verify(token, secret)
    if (typeof decoded === 'string') throw new Error('unexpected token shape')

    const { sub, branchId, username, role } = decoded as Record<string, unknown>
    if (
      typeof sub !== 'string' ||
      typeof branchId !== 'string' ||
      typeof username !== 'string' ||
      (role !== 'admin' && role !== 'cashier')
    ) {
      throw new Error('token payload is missing required claims')
    }
    return { sub, branchId, username, role }
  } catch (error) {
    if (error instanceof jwt.TokenExpiredError) {
      throw new AppError(401, 'TOKEN_EXPIRED', 'Session expired, please log in again')
    }
    throw new AppError(401, 'INVALID_TOKEN', 'Invalid authentication token')
  }
}

/** Reads a bearer token from an Authorization header. */
export function extractBearerToken(header: string | undefined): string | null {
  if (!header) return null
  const [scheme, token] = header.split(' ')
  if (scheme?.toLowerCase() !== 'bearer' || !token) return null
  return token
}
