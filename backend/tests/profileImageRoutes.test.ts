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
  setProfileImageKey: jest.fn(),
  clearProfileImageKey: jest.fn(),
}));
jest.mock('../src/services/storageService', () => ({
  uploadProfileImage: jest.fn(),
  getSignedProfileImageUrl: jest.fn(),
  deleteProfileImage: jest.fn(),
}));
jest.mock('../src/services/profileImageAccessService', () => ({
  canViewProfileImage: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { clearProfileImageKey, getProfile, setProfileImageKey } from '../src/services/profileService';
import {
  deleteProfileImage,
  getSignedProfileImageUrl,
  uploadProfileImage,
} from '../src/services/storageService';
import { canViewProfileImage } from '../src/services/profileImageAccessService';
import type { AuthenticatedUser } from '../src/models/User';
import type { UserProfile } from '../src/models/Profile';

const app = createApp();

const OWNER_ID = '11111111-1111-1111-1111-111111111111';
const OTHER_ID = '22222222-2222-2222-2222-222222222222';

const ownerUser: AuthenticatedUser = {
  id: OWNER_ID,
  googleSubject: 'g-1',
  email: 'owner@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'Owner',
  accountStatus: 'active',
};

function authenticateAs(user: AuthenticatedUser) {
  (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
  (getUserById as jest.Mock).mockResolvedValue(user);
}

function profileWith(overrides: Partial<UserProfile>): UserProfile {
  return {
    userId: OWNER_ID,
    fatherName: null,
    age: null,
    address: null,
    bloodGroup: null,
    allergies: null,
    medications: null,
    emergencyContact: null,
    country: null,
    state: null,
    city: null,
    profileImageObjectKey: null,
    profilePictureVisibility: 'private',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

// Real magic bytes, padded out — content after the signature is irrelevant.
const VALID_JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(100, 1)]);
const SPOOFED_JPEG = Buffer.from('this is definitely not a real jpeg, just text pretending to be one');

describe('PUT /api/v1/profile/image (upload/replace)', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app)
      .put('/api/v1/profile/image')
      .set('Content-Type', 'image/jpeg')
      .send(VALID_JPEG);
    expect(res.status).toBe(401);
  });

  it('uploads successfully and stores only the object key returned by storageService', async () => {
    authenticateAs(ownerUser);
    (uploadProfileImage as jest.Mock).mockResolvedValue(`profile-images/${OWNER_ID}.jpg`);
    (setProfileImageKey as jest.Mock).mockResolvedValue(profileWith({}));

    const res = await request(app)
      .put('/api/v1/profile/image')
      .set('Authorization', 'Bearer t')
      .set('Content-Type', 'image/jpeg')
      .send(VALID_JPEG);

    expect(res.status).toBe(200);
    // Cross-user-upload structural check: the uploaded-for id can only
    // ever be the authenticated user's own id — there is no request field
    // that could smuggle a different target.
    expect((uploadProfileImage as jest.Mock).mock.calls[0][0]).toBe(OWNER_ID);
    expect((uploadProfileImage as jest.Mock).mock.calls[0][2]).toBe('jpeg');
    expect((setProfileImageKey as jest.Mock).mock.calls[0]).toEqual([
      OWNER_ID,
      `profile-images/${OWNER_ID}.jpg`,
    ]);
  });

  it('replacing an existing image re-uploads to the same deterministic key', async () => {
    authenticateAs(ownerUser);
    (uploadProfileImage as jest.Mock).mockResolvedValue(`profile-images/${OWNER_ID}.jpg`);
    (setProfileImageKey as jest.Mock).mockResolvedValue(profileWith({}));

    await request(app)
      .put('/api/v1/profile/image')
      .set('Authorization', 'Bearer t')
      .set('Content-Type', 'image/jpeg')
      .send(VALID_JPEG);
    const res = await request(app)
      .put('/api/v1/profile/image')
      .set('Authorization', 'Bearer t')
      .set('Content-Type', 'image/jpeg')
      .send(VALID_JPEG);

    expect(res.status).toBe(200);
    expect(uploadProfileImage).toHaveBeenCalledTimes(2);
  });

  it('rejects an oversized upload with 413', async () => {
    authenticateAs(ownerUser);
    const oversized = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(6 * 1024 * 1024)]);

    const res = await request(app)
      .put('/api/v1/profile/image')
      .set('Authorization', 'Bearer t')
      .set('Content-Type', 'image/jpeg')
      .send(oversized);

    expect(res.status).toBe(413);
    expect(uploadProfileImage).not.toHaveBeenCalled();
  });

  it('rejects a spoofed file (declared image/jpeg, real bytes are not an image)', async () => {
    authenticateAs(ownerUser);
    const res = await request(app)
      .put('/api/v1/profile/image')
      .set('Authorization', 'Bearer t')
      .set('Content-Type', 'image/jpeg')
      .send(SPOOFED_JPEG);

    expect(res.status).toBe(400);
    expect(uploadProfileImage).not.toHaveBeenCalled();
  });

  it('rejects a request with no image body at all (unsupported/non-image Content-Type)', async () => {
    authenticateAs(ownerUser);
    const res = await request(app)
      .put('/api/v1/profile/image')
      .set('Authorization', 'Bearer t')
      .set('Content-Type', 'text/plain')
      .send('hello');

    expect(res.status).toBe(400);
    expect(uploadProfileImage).not.toHaveBeenCalled();
  });

  it('surfaces a storage failure as a safe error without storing a stale key', async () => {
    authenticateAs(ownerUser);
    (uploadProfileImage as jest.Mock).mockRejectedValue(new Error('minio: connection refused'));

    const res = await request(app)
      .put('/api/v1/profile/image')
      .set('Authorization', 'Bearer t')
      .set('Content-Type', 'image/jpeg')
      .send(VALID_JPEG);

    expect(res.status).toBe(500);
    expect(res.body.error.message).not.toMatch(/minio/i);
    expect(setProfileImageKey).not.toHaveBeenCalled();
  });
});

describe('DELETE /api/v1/profile/image', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).delete('/api/v1/profile/image');
    expect(res.status).toBe(401);
  });

  it('deletes the stored object and clears the key when one exists', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({ profileImageObjectKey: `profile-images/${OWNER_ID}.jpg` }),
    );

    const res = await request(app).delete('/api/v1/profile/image').set('Authorization', 'Bearer t');

    expect(res.status).toBe(204);
    expect(deleteProfileImage).toHaveBeenCalledWith(`profile-images/${OWNER_ID}.jpg`);
    expect(clearProfileImageKey).toHaveBeenCalledWith(OWNER_ID);
  });

  it('is a safe no-op when there is no image to delete', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(profileWith({ profileImageObjectKey: null }));

    const res = await request(app).delete('/api/v1/profile/image').set('Authorization', 'Bearer t');

    expect(res.status).toBe(204);
    expect(deleteProfileImage).not.toHaveBeenCalled();
  });
});

describe('GET /api/v1/profile/image (own)', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/profile/image');
    expect(res.status).toBe(401);
  });

  it('returns a signed URL for the owner regardless of visibility', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({ profileImageObjectKey: `profile-images/${OWNER_ID}.jpg`, profilePictureVisibility: 'private' }),
    );
    (getSignedProfileImageUrl as jest.Mock).mockResolvedValue('https://minio.internal/signed-url');

    const res = await request(app).get('/api/v1/profile/image').set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect(res.body.url).toBe('https://minio.internal/signed-url');
  });

  it('404s when no image is set', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(profileWith({ profileImageObjectKey: null }));

    const res = await request(app).get('/api/v1/profile/image').set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
    expect(getSignedProfileImageUrl).not.toHaveBeenCalled();
  });
});

describe('GET /api/v1/profile/:userId/image (viewing another user)', () => {
  it('rejects a non-UUID target id', async () => {
    authenticateAs(ownerUser);
    const res = await request(app)
      .get('/api/v1/profile/not-a-uuid/image')
      .set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
  });

  it('404s when the target has no image at all (no authorization check needed)', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(profileWith({ profileImageObjectKey: null }));

    const res = await request(app)
      .get(`/api/v1/profile/${OTHER_ID}/image`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
    expect(canViewProfileImage).not.toHaveBeenCalled();
  });

  it('grants access and returns a signed URL for a public image', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({ profileImageObjectKey: `profile-images/${OTHER_ID}.jpg`, profilePictureVisibility: 'public' }),
    );
    (canViewProfileImage as jest.Mock).mockResolvedValue(true);
    (getSignedProfileImageUrl as jest.Mock).mockResolvedValue('https://minio.internal/signed-url');

    const res = await request(app)
      .get(`/api/v1/profile/${OTHER_ID}/image`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect(res.body.url).toBe('https://minio.internal/signed-url');
  });

  it('denies (404, not 403) a private image, and never issues a signed URL', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({ profileImageObjectKey: `profile-images/${OTHER_ID}.jpg`, profilePictureVisibility: 'private' }),
    );
    (canViewProfileImage as jest.Mock).mockResolvedValue(false);

    const res = await request(app)
      .get(`/api/v1/profile/${OTHER_ID}/image`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
    expect(getSignedProfileImageUrl).not.toHaveBeenCalled();
  });

  it('grants access to a contacts_only image for a mutual contact', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({
        profileImageObjectKey: `profile-images/${OTHER_ID}.jpg`,
        profilePictureVisibility: 'contacts_only',
      }),
    );
    (canViewProfileImage as jest.Mock).mockResolvedValue(true);
    (getSignedProfileImageUrl as jest.Mock).mockResolvedValue('https://minio.internal/signed-url');

    const res = await request(app)
      .get(`/api/v1/profile/${OTHER_ID}/image`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect(canViewProfileImage).toHaveBeenCalledWith(OWNER_ID, OTHER_ID, 'contacts_only');
  });

  it('denies a contacts_only image to a non-contact', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({
        profileImageObjectKey: `profile-images/${OTHER_ID}.jpg`,
        profilePictureVisibility: 'contacts_only',
      }),
    );
    (canViewProfileImage as jest.Mock).mockResolvedValue(false);

    const res = await request(app)
      .get(`/api/v1/profile/${OTHER_ID}/image`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
    expect(getSignedProfileImageUrl).not.toHaveBeenCalled();
  });

  it('denies a groups_only image to a non-owner (documented owner-only fallback)', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({
        profileImageObjectKey: `profile-images/${OTHER_ID}.jpg`,
        profilePictureVisibility: 'groups_only',
      }),
    );
    (canViewProfileImage as jest.Mock).mockResolvedValue(false);

    const res = await request(app)
      .get(`/api/v1/profile/${OTHER_ID}/image`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
    expect(getSignedProfileImageUrl).not.toHaveBeenCalled();
  });

  it('surfaces a signed-URL generation failure as a safe error', async () => {
    authenticateAs(ownerUser);
    (getProfile as jest.Mock).mockResolvedValue(
      profileWith({ profileImageObjectKey: `profile-images/${OTHER_ID}.jpg`, profilePictureVisibility: 'public' }),
    );
    (canViewProfileImage as jest.Mock).mockResolvedValue(true);
    (getSignedProfileImageUrl as jest.Mock).mockRejectedValue(new Error('minio: bucket unreachable'));

    const res = await request(app)
      .get(`/api/v1/profile/${OTHER_ID}/image`)
      .set('Authorization', 'Bearer t');

    expect(res.status).toBe(500);
    expect(res.body.error.message).not.toMatch(/minio/i);
  });
});
