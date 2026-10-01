import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({ verifyAccessToken: jest.fn() }));
jest.mock('../src/services/userService', () => ({ getUserById: jest.fn() }));
jest.mock('../src/services/accountDeletionService', () => ({ deleteAccount: jest.fn() }));
jest.mock('../src/services/auditLogService', () => ({ recordAuditEvent: jest.fn().mockResolvedValue(undefined) }));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { deleteAccount } from '../src/services/accountDeletionService';
import { recordAuditEvent } from '../src/services/auditLogService';
import { HttpError } from '../src/utils/httpError';

const app = createApp();
const USER = '22222222-2222-2222-2222-222222222222';
const signedIn = () => {
  (verifyAccessToken as jest.Mock).mockReturnValue(USER);
  (getUserById as jest.Mock).mockResolvedValue({ id: USER, accountStatus: 'active' });
};
const del = (body: object) => request(app).delete('/api/v1/me').set('Authorization', 'Bearer t').send(body);

beforeEach(() => jest.clearAllMocks());

describe('DELETE /api/v1/me', () => {
  it('requires a session', async () => {
    expect((await request(app).delete('/api/v1/me').send({ confirm: 'DELETE_MY_ACCOUNT' })).status).toBe(401);
    expect(deleteAccount).not.toHaveBeenCalled();
  });

  it('requires the explicit confirmation string', async () => {
    signedIn();
    expect((await del({})).status).toBe(400);
    expect((await del({ confirm: 'yes' })).status).toBe(400);
    expect(deleteAccount).not.toHaveBeenCalled();
  });

  it('deletes and audits with counts only', async () => {
    signedIn();
    (deleteAccount as jest.Mock).mockResolvedValue({ incidentsDeidentified: 2, groupsTransferred: 1, groupsDeleted: 0 });
    const res = await del({ confirm: 'DELETE_MY_ACCOUNT' });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ deleted: true, incidentsDeidentified: 2, groupsTransferred: 1, groupsDeleted: 0 });
    expect(recordAuditEvent).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'account.delete', resourceId: USER, metadata: { incidentsDeidentified: 2, groupsTransferred: 1, groupsDeleted: 0 } }),
    );
  });

  it('an open incident blocks deletion with a clear 409', async () => {
    signedIn();
    (deleteAccount as jest.Mock).mockRejectedValue(new HttpError(409, 'ACTIVE_INCIDENT', 'You have an SOS that responders have not closed yet.'));
    const res = await del({ confirm: 'DELETE_MY_ACCOUNT' });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('ACTIVE_INCIDENT');
    expect(recordAuditEvent).not.toHaveBeenCalled();
  });
});
