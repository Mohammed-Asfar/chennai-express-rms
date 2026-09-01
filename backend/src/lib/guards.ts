import type { FastifyReply, FastifyRequest } from 'fastify'
import { AppError } from './errors.js'
import { extractBearerToken, verifyToken, type Role, type TokenPayload } from './auth.js'

declare module 'fastify' {
  interface FastifyRequest {
    user?: TokenPayload
  }
}

/**
 * Rejects a request without a valid token.
 *
 * Roles are enforced here, on the server, not by hiding buttons in the UI — a
 * cashier who reaches an admin endpoint directly must still be refused.
 */
export async function requireAuth(request: FastifyRequest, _reply: FastifyReply): Promise<void> {
  const token = extractBearerToken(request.headers.authorization)
  if (!token) {
    throw new AppError(401, 'UNAUTHENTICATED', 'Authentication required')
  }

  const payload = verifyToken(token, request.server.env.JWT_SECRET)

  // A user deactivated mid-shift must stop working immediately, so the token is
  // checked against the live row rather than trusted on its own.
  const user = request.server.db
    .prepare('SELECT is_active, role FROM users WHERE id = ? AND deleted_at IS NULL')
    .get(payload.sub) as { is_active: number; role: Role } | undefined

  if (!user) throw new AppError(401, 'USER_NOT_FOUND', 'Account no longer exists')
  if (user.is_active !== 1) throw new AppError(403, 'ACCOUNT_DISABLED', 'Account has been disabled')

  // Trust the database over the token if the role changed since it was issued.
  request.user = { ...payload, role: user.role }
}

export function requireRole(...roles: Role[]) {
  return async function roleGuard(request: FastifyRequest, reply: FastifyReply): Promise<void> {
    await requireAuth(request, reply)
    if (!request.user || !roles.includes(request.user.role)) {
      throw new AppError(403, 'FORBIDDEN', 'You do not have permission to perform this action')
    }
  }
}

/** The authenticated user, or a 401 if the guard did not run. */
export function currentUser(request: FastifyRequest): TokenPayload {
  if (!request.user) throw new AppError(401, 'UNAUTHENTICATED', 'Authentication required')
  return request.user
}
