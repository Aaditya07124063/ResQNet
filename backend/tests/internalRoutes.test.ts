process.env.SEISMIC_WEBHOOK_SECRET = 'test-seismic-webhook-secret';

import request from 'supertest';

jest.mock('../src/services/pushNotificationService', () => ({
  notifySeismicCorroboration: jest.fn(),
}));

import { createApp } from '../src/app';
import { notifySeismicCorroboration } from '../src/services/pushNotificationService';

const app = createApp();

const VALID_BODY = { latitude: 12.9, longitude: 77.6, deviceCount: 4 };

describe('POST /api/v1/internal/seismic-alerts', () => {
  it('rejects a request with no webhook secret header at all (401)', async () => {
    const res = await request(app).post('/api/v1/internal/seismic-alerts').send(VALID_BODY);
    expect(res.status).toBe(401);
    expect(notifySeismicCorroboration).not.toHaveBeenCalled();
  });

  it('rejects a request with the wrong webhook secret (401)', async () => {
    const res = await request(app)
      .post('/api/v1/internal/seismic-alerts')
      .set('X-Seismic-Webhook-Secret', 'wrong-secret')
      .send(VALID_BODY);
    expect(res.status).toBe(401);
    expect(notifySeismicCorroboration).not.toHaveBeenCalled();
  });

  it('rejects an invalid body even with a correct secret (400) — e.g. deviceCount below the 3-device correlation minimum is still a valid positive int, but a non-positive one is not', async () => {
    const res = await request(app)
      .post('/api/v1/internal/seismic-alerts')
      .set('X-Seismic-Webhook-Secret', 'test-seismic-webhook-secret')
      .send({ ...VALID_BODY, deviceCount: 0 });
    expect(res.status).toBe(400);
    expect(notifySeismicCorroboration).not.toHaveBeenCalled();
  });

  it('accepts a correctly-authenticated, valid request and delegates to notifySeismicCorroboration', async () => {
    (notifySeismicCorroboration as jest.Mock).mockResolvedValueOnce(undefined);
    const res = await request(app)
      .post('/api/v1/internal/seismic-alerts')
      .set('X-Seismic-Webhook-Secret', 'test-seismic-webhook-secret')
      .send(VALID_BODY);
    expect(res.status).toBe(202);
    expect(notifySeismicCorroboration).toHaveBeenCalledWith(VALID_BODY);
  });

  it('never leaks the webhook secret or a stack trace when notifySeismicCorroboration itself throws', async () => {
    (notifySeismicCorroboration as jest.Mock).mockRejectedValueOnce(new Error('unexpected'));
    const res = await request(app)
      .post('/api/v1/internal/seismic-alerts')
      .set('X-Seismic-Webhook-Secret', 'test-seismic-webhook-secret')
      .send(VALID_BODY);
    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toMatch(/test-seismic-webhook-secret/);
  });
});
