import type { IncomingMessage } from 'node:http';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));

import { authenticateUpgrade } from '../src/websocket/wsAuth';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import type { AuthenticatedUser } from '../src/models/User';

const mockVerifyAccessToken = verifyAccessToken as jest.Mock;
const mockGetUserById = getUserById as jest.Mock;

function makeUpgradeReq(opts: { authorization?: string; url?: string }): IncomingMessage {
  return { headers: opts.authorization ? { authorization: opts.authorization } : {}, url: opts.url } as IncomingMessage;
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

describe('authenticateUpgrade', () => {
  it('rejects (null) an upgrade request with no token at all (no header, no query param)', async () => {
    const result = await authenticateUpgrade(makeUpgradeReq({ url: '/ws' }));
    expect(result).toBeNull();
    expect(mockVerifyAccessToken).not.toHaveBeenCalled();
  });

  it('reads the token from a Bearer Authorization header (preferred)', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue(activeUser);

    const result = await authenticateUpgrade(makeUpgradeReq({ authorization: 'Bearer good-token' }));

    expect(result).toEqual(activeUser);
    expect(mockVerifyAccessToken).toHaveBeenCalledWith('good-token');
  });

  it('falls back to the access_token query parameter when no header is present', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue(activeUser);

    const result = await authenticateUpgrade(makeUpgradeReq({ url: '/ws?access_token=good-token' }));

    expect(result).toEqual(activeUser);
    expect(mockVerifyAccessToken).toHaveBeenCalledWith('good-token');
  });

  it('prefers the header over the query parameter when both are present', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue(activeUser);

    await authenticateUpgrade(makeUpgradeReq({ authorization: 'Bearer header-token', url: '/ws?access_token=query-token' }));

    expect(mockVerifyAccessToken).toHaveBeenCalledWith('header-token');
  });

  it('rejects a malformed Authorization header (not Bearer) and does not fall back to a token-shaped value from it', async () => {
    const result = await authenticateUpgrade(makeUpgradeReq({ authorization: 'Basic abc123' }));
    expect(result).toBeNull();
    expect(mockVerifyAccessToken).not.toHaveBeenCalled();
  });

  it('rejects when the token fails verification (invalid/expired)', async () => {
    mockVerifyAccessToken.mockImplementation(() => {
      throw Object.assign(new Error('jwt expired'), { status: 401 });
    });
    const result = await authenticateUpgrade(makeUpgradeReq({ authorization: 'Bearer expired-token' }));
    expect(result).toBeNull();
  });

  it('rejects when the verified token refers to a user that no longer exists', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue(null);
    const result = await authenticateUpgrade(makeUpgradeReq({ authorization: 'Bearer good-token' }));
    expect(result).toBeNull();
  });

  it('rejects a suspended account', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue({ ...activeUser, accountStatus: 'suspended' });
    const result = await authenticateUpgrade(makeUpgradeReq({ authorization: 'Bearer good-token' }));
    expect(result).toBeNull();
  });

  it('rejects a deleted account', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue({ ...activeUser, accountStatus: 'deleted' });
    const result = await authenticateUpgrade(makeUpgradeReq({ authorization: 'Bearer good-token' }));
    expect(result).toBeNull();
  });

  it('allows a review_required account through (review status is not a connection block, matches requireAuth)', async () => {
    mockVerifyAccessToken.mockReturnValue('user-1');
    mockGetUserById.mockResolvedValue({ ...activeUser, accountStatus: 'review_required' });
    const result = await authenticateUpgrade(makeUpgradeReq({ authorization: 'Bearer good-token' }));
    expect(result?.accountStatus).toBe('review_required');
  });
});
