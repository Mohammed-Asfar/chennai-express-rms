/** An error with an HTTP status and a stable code the client can branch on. */
export class AppError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message)
    this.name = 'AppError'
  }
}

export const badRequest = (code: string, message: string, details?: unknown) =>
  new AppError(400, code, message, details)

export const notFound = (code: string, message: string) => new AppError(404, code, message)

export const conflict = (code: string, message: string, details?: unknown) =>
  new AppError(409, code, message, details)

export const unprocessable = (code: string, message: string, details?: unknown) =>
  new AppError(422, code, message, details)
