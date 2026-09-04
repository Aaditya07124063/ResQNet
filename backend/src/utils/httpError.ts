export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: unknown;

  constructor(status: number, code: string, message: string, details?: unknown) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
    this.details = details;
  }

  static badRequest(message: string, details?: unknown): HttpError {
    return new HttpError(400, 'BAD_REQUEST', message, details);
  }

  static unauthorized(message = 'Authentication required'): HttpError {
    return new HttpError(401, 'UNAUTHORIZED', message);
  }

  static forbidden(message = 'You are not authorized to perform this action'): HttpError {
    return new HttpError(403, 'FORBIDDEN', message);
  }

  static notFound(message = 'Resource not found'): HttpError {
    return new HttpError(404, 'NOT_FOUND', message);
  }

  static conflict(message: string): HttpError {
    return new HttpError(409, 'CONFLICT', message);
  }

  static payloadTooLarge(message = 'Payload too large'): HttpError {
    return new HttpError(413, 'PAYLOAD_TOO_LARGE', message);
  }

  static tooManyRequests(message = 'Too many requests'): HttpError {
    return new HttpError(429, 'TOO_MANY_REQUESTS', message);
  }

  static internal(message = 'Internal server error'): HttpError {
    return new HttpError(500, 'INTERNAL_ERROR', message);
  }
}
