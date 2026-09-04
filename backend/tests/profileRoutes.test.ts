import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
  findOrCreateUserByGoogleSubject: jest.fn(),
  touchLastLogin: jest.fn(),
}));
jest.mock('../src/services/profileService', () => ({
  getProfile: jest.fn(),
  upsertProfile: jest.fn(),
}));
jest.mock('../src/services/trustedContactsService', () => ({
  listTrustedContacts: jest.fn(),
  createTrustedContact: jest.fn(),
  updateTrustedContact: jest.fn(),
  deleteTrustedContact: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { getProfile, upsertProfile } from '../src/services/profileService';
import {
  createTrustedContact,
  deleteTrustedContact,
  updateTrustedContact,
} from '../src/services/trustedContactsService';
import { HttpError } from '../src/utils/httpError';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();

const activeUser: AuthenticatedUser = {
  id: 'user-1',
  googleSubject: 'g-1',
  email: 'a@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'A',
  accountStatus: 'active',
};

function authenticateAs(user: AuthenticatedUser | null) {
  (verifyAccessToken as jest.Mock).mockReturnValue(user?.id ?? 'user-1');
  (getUserById as jest.Mock).mockResolvedValue(user);
}

describe('GET/PUT /api/v1/profile', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/profile');
    expect(res.status).toBe(401);
  });

  it('returns null when no profile row exists yet', async () => {
    authenticateAs(activeUser);
    (getProfile as jest.Mock).mockResolvedValue(null);
    const res = await request(app).get('/api/v1/profile').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
    expect(res.body.profile).toBeNull();
  });

  it('rejects an invalid update body (bad blood group)', async () => {
    authenticateAs(activeUser);
    const res = await request(app)
      .put('/api/v1/profile')
      .set('Authorization', 'Bearer t')
      .send({ bloodGroup: 'not-a-blood-group' });
    expect(res.status).toBe(400);
  });

  it('upserts using only the authenticated user id, never a client-supplied one', async () => {
    authenticateAs(activeUser);
    (upsertProfile as jest.Mock).mockImplementation(async (userId: string) => ({
      userId,
      updatedAt: new Date().toISOString(),
    }));
    const res = await request(app)
      .put('/api/v1/profile')
      .set('Authorization', 'Bearer t')
      .send({ city: 'Kathmandu', userId: 'someone-elses-id' });
    expect(res.status).toBe(200);
    expect((upsertProfile as jest.Mock).mock.calls[0][0]).toBe('user-1');
    expect(res.body.profile.userId).toBe('user-1');
  });
});

describe('trusted contacts', () => {
  it('rejects an invalid phone number', async () => {
    authenticateAs(activeUser);
    const res = await request(app)
      .post('/api/v1/profile/trusted-contacts')
      .set('Authorization', 'Bearer t')
      .send({ name: 'Mom', phoneNumber: 'not-a-number' });
    expect(res.status).toBe(400);
  });

  it('creates a contact scoped to the authenticated owner', async () => {
    authenticateAs(activeUser);
    (createTrustedContact as jest.Mock).mockImplementation(async (ownerUserId: string) => ({
      id: 'contact-1',
      ownerUserId,
    }));
    const res = await request(app)
      .post('/api/v1/profile/trusted-contacts')
      .set('Authorization', 'Bearer t')
      .send({ name: 'Mom', phoneNumber: '+15551234567' });
    expect(res.status).toBe(201);
    expect((createTrustedContact as jest.Mock).mock.calls[0][0]).toBe('user-1');
  });

  it('rejects a non-UUID contact id on update', async () => {
    authenticateAs(activeUser);
    const res = await request(app)
      .put('/api/v1/profile/trusted-contacts/not-a-uuid')
      .set('Authorization', 'Bearer t')
      .send({ name: 'Mom', phoneNumber: '+15551234567' });
    expect(res.status).toBe(400);
  });

  it('returns 404 (not 403) when updating a contact that is not owned by the caller', async () => {
    authenticateAs(activeUser);
    (updateTrustedContact as jest.Mock).mockRejectedValue(HttpError.notFound('Trusted contact not found'));
    const res = await request(app)
      .put('/api/v1/profile/trusted-contacts/11111111-1111-1111-1111-111111111111')
      .set('Authorization', 'Bearer t')
      .send({ name: 'Mom', phoneNumber: '+15551234567' });
    expect(res.status).toBe(404);
  });

  it('returns 404 when deleting a contact that does not belong to the caller', async () => {
    authenticateAs(activeUser);
    (deleteTrustedContact as jest.Mock).mockRejectedValue(HttpError.notFound('Trusted contact not found'));
    const res = await request(app)
      .delete('/api/v1/profile/trusted-contacts/11111111-1111-1111-1111-111111111111')
      .set('Authorization', 'Bearer t');
    expect(res.status).toBe(404);
  });
});
