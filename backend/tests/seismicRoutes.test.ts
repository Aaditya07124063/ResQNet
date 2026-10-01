import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));
jest.mock('../src/services/seismicService', () => ({
  recordSeismicReport: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { recordSeismicReport } from '../src/services/seismicService';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();
const user: AuthenticatedUser = {
  id: '11111111-1111-1111-1111-111111111111',
  googleSubject: 'g-1',
  email: 'user@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'User',
  accountStatus: 'active',
};
const body = { latitude: 27.7172, longitude: 85.324, detectorScore: 0.8 };

describe('POST /api/v1/seismic/reports', () => {
  it('requires a ResQNet session', async () => {
    const res = await request(app).post('/api/v1/seismic/reports').send(body);
    expect(res.status).toBe(401);
    expect(recordSeismicReport).not.toHaveBeenCalled();
  });

  it('records the report for the session user, ignoring any user id in the body', async () => {
    (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
    (getUserById as jest.Mock).mockResolvedValue(user);
    (recordSeismicReport as jest.Mock).mockResolvedValue({
      reportId: 'r1',
      corroboratingDeviceCount: 1,
      corroborated: false,
      alertSent: false,
    });

    const res = await request(app)
      .post('/api/v1/seismic/reports')
      .set('Authorization', 'Bearer t')
      .send({ ...body, userId: 'someone-else' });

    expect(res.status).toBe(201);
    expect(res.body.result.corroboratingDeviceCount).toBe(1);
    expect(recordSeismicReport).toHaveBeenCalledWith(user.id, body);
  });

  it.each([
    [{ ...body, latitude: 120 }],
    [{ ...body, detectorScore: 3 }],
    [{ longitude: 85.3, detectorScore: 0.5 }],
  ])('rejects invalid input %j', async (invalid) => {
    (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
    (getUserById as jest.Mock).mockResolvedValue(user);
    const res = await request(app).post('/api/v1/seismic/reports').set('Authorization', 'Bearer t').send(invalid);
    expect(res.status).toBe(400);
  });
});
