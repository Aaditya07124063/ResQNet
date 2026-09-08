import type { Request, Response } from 'express';
import { errorHandler } from '../src/middleware/errorHandler';
import { HttpError } from '../src/utils/httpError';

function mockRes() {
  const res: Partial<Response> = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res as Response;
}

describe('errorHandler', () => {
  it('maps a malformed-JSON body-parser error (entity.parse.failed) to 400, not 500', () => {
    const res = mockRes();
    // Phase 21 regression: express.json() throws this shape (status 400,
    // type 'entity.parse.failed', instanceof SyntaxError) for an invalid
    // JSON body — confirmed via a live request against the running server
    // returning a raw 500 before this fix.
    const err = Object.assign(new SyntaxError('Unexpected token'), {
      status: 400,
      statusCode: 400,
      type: 'entity.parse.failed',
      body: '{bad',
    });

    errorHandler(err, {} as Request, res, jest.fn());

    expect(res.status).toHaveBeenCalledWith(400);
    expect(res.json).toHaveBeenCalledWith({
      error: { code: 'INVALID_JSON', message: 'Malformed JSON body' },
    });
  });

  it('still maps an oversized-payload error (entity.too.large) to 413', () => {
    const res = mockRes();
    const err = Object.assign(new Error('too big'), { type: 'entity.too.large' });

    errorHandler(err, {} as Request, res, jest.fn());

    expect(res.status).toHaveBeenCalledWith(413);
  });

  it('still maps a thrown HttpError to its own status/code/message', () => {
    const res = mockRes();
    const err = new HttpError(404, 'NOT_FOUND', 'nope');

    errorHandler(err, {} as Request, res, jest.fn());

    expect(res.status).toHaveBeenCalledWith(404);
    expect(res.json).toHaveBeenCalledWith({ error: { code: 'NOT_FOUND', message: 'nope' } });
  });

  it('still falls back to a generic 500 for a truly unexpected error', () => {
    const res = mockRes();
    const err = new Error('unexpected');

    errorHandler(err, {} as Request, res, jest.fn());

    expect(res.status).toHaveBeenCalledWith(500);
  });
});
