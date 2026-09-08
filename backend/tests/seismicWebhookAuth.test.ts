import type { NextFunction, Request, Response } from 'express';

const ORIGINAL_SECRET = process.env.SEISMIC_WEBHOOK_SECRET;

async function freshImport() {
  jest.resetModules();
  return import('../src/middleware/seismicWebhookAuth');
}

afterEach(() => {
  if (ORIGINAL_SECRET === undefined) {
    delete process.env.SEISMIC_WEBHOOK_SECRET;
  } else {
    process.env.SEISMIC_WEBHOOK_SECRET = ORIGINAL_SECRET;
  }
});

function mockReq(headerValue?: string): Request {
  return { header: (name: string) => (name === 'x-seismic-webhook-secret' ? headerValue : undefined) } as unknown as Request;
}

describe('requireSeismicWebhookAuth', () => {
  it('503s (never 401) when SEISMIC_WEBHOOK_SECRET is not configured at all', async () => {
    delete process.env.SEISMIC_WEBHOOK_SECRET;
    const { requireSeismicWebhookAuth } = await freshImport();
    const next = jest.fn() as NextFunction;
    requireSeismicWebhookAuth(mockReq('anything'), {} as Response, next);
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 503 }));
  });

  it('401s when configured but no header is sent', async () => {
    process.env.SEISMIC_WEBHOOK_SECRET = 'a-real-secret-value';
    const { requireSeismicWebhookAuth } = await freshImport();
    const next = jest.fn() as NextFunction;
    requireSeismicWebhookAuth(mockReq(undefined), {} as Response, next);
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('401s when the header value does not match', async () => {
    process.env.SEISMIC_WEBHOOK_SECRET = 'a-real-secret-value';
    const { requireSeismicWebhookAuth } = await freshImport();
    const next = jest.fn() as NextFunction;
    requireSeismicWebhookAuth(mockReq('wrong-value'), {} as Response, next);
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('401s on a value of a different length than the real secret (exercises the length-mismatch branch)', async () => {
    process.env.SEISMIC_WEBHOOK_SECRET = 'a-real-secret-value';
    const { requireSeismicWebhookAuth } = await freshImport();
    const next = jest.fn() as NextFunction;
    requireSeismicWebhookAuth(mockReq('short'), {} as Response, next);
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('calls next() with no error when the header exactly matches the configured secret', async () => {
    process.env.SEISMIC_WEBHOOK_SECRET = 'a-real-secret-value';
    const { requireSeismicWebhookAuth } = await freshImport();
    const next = jest.fn() as NextFunction;
    requireSeismicWebhookAuth(mockReq('a-real-secret-value'), {} as Response, next);
    expect(next).toHaveBeenCalledWith();
  });
});
