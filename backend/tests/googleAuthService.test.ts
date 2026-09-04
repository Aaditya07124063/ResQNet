const mockVerifyIdToken = jest.fn();

jest.mock('google-auth-library', () => ({
  OAuth2Client: jest.fn().mockImplementation(() => ({
    verifyIdToken: mockVerifyIdToken,
  })),
}));

import { verifyGoogleIdToken } from '../src/services/googleAuthService';

describe('verifyGoogleIdToken', () => {
  it('returns the verified identity for a valid token', async () => {
    mockVerifyIdToken.mockResolvedValueOnce({
      getPayload: () => ({
        sub: 'google-subject-123',
        email: 'person@example.com',
        email_verified: true,
        name: 'Person Example',
      }),
    });

    const identity = await verifyGoogleIdToken('valid-token');

    expect(identity).toEqual({
      subject: 'google-subject-123',
      email: 'person@example.com',
      emailVerified: true,
      displayName: 'Person Example',
    });
  });

  it('rejects when Google rejects the token (bad signature/audience/expired)', async () => {
    mockVerifyIdToken.mockRejectedValueOnce(new Error('Wrong recipient'));
    await expect(verifyGoogleIdToken('bad-token')).rejects.toThrow(
      /Invalid or expired Google ID token/,
    );
  });

  it('rejects a payload missing the subject claim', async () => {
    mockVerifyIdToken.mockResolvedValueOnce({ getPayload: () => ({ email: 'no-sub@example.com' }) });
    await expect(verifyGoogleIdToken('weird-token')).rejects.toThrow(
      /missing subject claim/,
    );
  });

  it('rejects when there is no payload at all', async () => {
    mockVerifyIdToken.mockResolvedValueOnce({ getPayload: () => undefined });
    await expect(verifyGoogleIdToken('empty-token')).rejects.toThrow(
      /missing subject claim/,
    );
  });
});
