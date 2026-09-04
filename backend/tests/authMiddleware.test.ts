import type { Request, Response } from 'express';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));

import { requireAuth } from '../src/middleware/authMiddleware';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import type { AuthenticatedUser } from '../src/models/User';

const mockVerifyAccessToken = verifyAccessToken as jest.Mock;
const mockGetUserById = getUserById as jest.Mock;

function makeReq(authorization?: string): Partial<Request> {
  return { headers: authorization ? { authorization } : {} };
}

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

async function run(req: Partial<Request>) {
  const next = jest.fn();
  await requireAuth(req as Request, {} as Response, next);
  return next;
}

describe('requireAuth', () => {
  it('denies a request with no Authorization header', async () => {
    const next = await run(makeReq());
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies a malformed Authorization header (not Bearer)', async () => {
    const next = await run(makeReq('Basic abc123'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies when the token fails verification', async () => {
    mockVerifyAccessToken.mockImplementation(() => {
      throw Object.assign(new Error('bad token'), { status: 401 });
    });
    const next = await run(makeReq('Bearer some-invalid-token'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies when the token is valid but the user no longer exists', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue(null);
    const next = await run(makeReq('Bearer valid-token'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 401 }));
  });

  it('denies a suspended account', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue({ ...activeUser, accountStatus: 'suspended' });
    const next = await run(makeReq('Bearer valid-token'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 403 }));
  });

  it('denies a deleted account', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue({ ...activeUser, accountStatus: 'deleted' });
    const next = await run(makeReq('Bearer valid-token'));
    expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 403 }));
  });

  it('allows an active account and attaches req.authUser', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue(activeUser);
    const req = makeReq('Bearer valid-token');
    const next = await run(req);
    expect(next).toHaveBeenCalledWith(); // called with no error
    expect((req as Request).authUser).toEqual(activeUser);
  });

  it('allows a review_required account through (review status is not a login block)', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue({ ...activeUser, accountStatus: 'review_required' });
    const req = makeReq('Bearer valid-token');
    const next = await run(req);
    expect(next).toHaveBeenCalledWith();
    expect((req as Request).authUser?.accountStatus).toBe('review_required');
  });
});
