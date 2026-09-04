import jwt from 'jsonwebtoken';

jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));

import { pool } from '../src/database/pool';
import { env } from '../src/config/env';
import {
  issueSession,
  revokeRefreshToken,
  rotateRefreshToken,
  verifyAccessToken,
} from '../src/services/sessionService';

const mockedQuery = pool.query as jest.Mock;

describe('sessionService', () => {
  describe('issueSession', () => {
    it('signs an access token containing the user id and inserts a hashed refresh token row', async () => {
      mockedQuery.mockResolvedValueOnce({ rows: [] });

      const session = await issueSession('user-1', { userAgent: 'jest', ipAddress: '127.0.0.1' });

      const decoded = jwt.verify(session.accessToken, env.JWT_ACCESS_SECRET) as { sub: string };
      expect(decoded.sub).toBe('user-1');

      expect(mockedQuery).toHaveBeenCalledTimes(1);
      const [sql, params] = mockedQuery.mock.calls[0];
      expect(sql).toMatch(/INSERT INTO sessions/);
      expect(params[0]).toBe('user-1');
      // The raw refresh token itself must never be what's persisted.
      expect(params[1]).not.toBe(session.refreshToken);
      expect(params[1]).toHaveLength(64); // sha256 hex digest
    });
  });

  describe('verifyAccessToken', () => {
    it('returns the subject for a valid token', async () => {
      mockedQuery.mockResolvedValueOnce({ rows: [] });
      const session = await issueSession('user-2', { userAgent: null, ipAddress: null });
      expect(verifyAccessToken(session.accessToken)).toBe('user-2');
    });

    it('rejects a token signed with the wrong secret', () => {
      const forged = jwt.sign({ sub: 'user-3' }, 'not-the-real-secret');
      expect(() => verifyAccessToken(forged)).toThrow(/Invalid or expired session token/);
    });

    it('rejects an expired token', () => {
      const expired = jwt.sign({ sub: 'user-4' }, env.JWT_ACCESS_SECRET, { expiresIn: '-1s' });
      expect(() => verifyAccessToken(expired)).toThrow(/Invalid or expired session token/);
    });

    it('rejects a malformed token', () => {
      expect(() => verifyAccessToken('not-a-jwt')).toThrow(/Invalid or expired session token/);
    });
  });

  describe('rotateRefreshToken', () => {
    it('rejects an unknown/expired/revoked refresh token', async () => {
      mockedQuery.mockResolvedValueOnce({ rows: [] });
      await expect(
        rotateRefreshToken('does-not-exist', { userAgent: null, ipAddress: null }),
      ).rejects.toThrow(/Invalid or expired refresh token/);
    });

    it('revokes the old session and issues a new pair on success', async () => {
      mockedQuery
        .mockResolvedValueOnce({ rows: [{ id: 'session-1', user_id: 'user-5' }] }) // lookup
        .mockResolvedValueOnce({ rows: [] }) // revoke UPDATE
        .mockResolvedValueOnce({ rows: [] }); // new session INSERT

      const session = await rotateRefreshToken('some-refresh-token', {
        userAgent: null,
        ipAddress: null,
      });

      expect(mockedQuery).toHaveBeenCalledTimes(3);
      expect(mockedQuery.mock.calls[1][0]).toMatch(/UPDATE sessions SET revoked_at/);
      const decoded = jwt.verify(session.accessToken, env.JWT_ACCESS_SECRET) as { sub: string };
      expect(decoded.sub).toBe('user-5');
    });
  });

  describe('revokeRefreshToken', () => {
    it('issues an UPDATE keyed on the token hash', async () => {
      mockedQuery.mockResolvedValueOnce({ rows: [] });
      await revokeRefreshToken('some-token');
      expect(mockedQuery.mock.calls[0][0]).toMatch(/UPDATE sessions SET revoked_at/);
      expect(mockedQuery.mock.calls[0][1][0]).toHaveLength(64);
    });
  });
});
