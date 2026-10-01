import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({ verifyAccessToken: jest.fn() }));
jest.mock('../src/services/userService', () => ({ getUserById: jest.fn() }));
jest.mock('../src/services/groupService', () => ({
  createGroup: jest.fn(),
  listGroupsForUser: jest.fn(),
  getGroup: jest.fn(),
  addGroupMember: jest.fn(),
  removeGroupMember: jest.fn(),
  setGroupMemberRole: jest.fn(),
}));
jest.mock('../src/services/auditLogService', () => ({ recordAuditEvent: jest.fn().mockResolvedValue(undefined) }));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { addGroupMember, createGroup, removeGroupMember } from '../src/services/groupService';
import { recordAuditEvent } from '../src/services/auditLogService';

const app = createApp();
const user = {
  id: '11111111-1111-1111-1111-111111111111',
  googleSubject: null,
  email: null,
  emailVerified: false,
  phoneNumber: '+9779812345678',
  phoneVerified: true,
  displayName: 'A',
  accountStatus: 'active',
};
const GROUP = '22222222-2222-2222-2222-222222222222';
const OTHER = '33333333-3333-3333-3333-333333333333';

beforeEach(() => {
  (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
  (getUserById as jest.Mock).mockResolvedValue(user);
});

describe('/api/v1/groups', () => {
  it('requires a session', async () => {
    (verifyAccessToken as jest.Mock).mockReset();
    const res = await request(app).get('/api/v1/groups');
    expect(res.status).toBe(401);
  });

  it('creates a group owned by the session user and audits it', async () => {
    (createGroup as jest.Mock).mockResolvedValue({ id: GROUP });
    const res = await request(app)
      .post('/api/v1/groups')
      .set('Authorization', 'Bearer t')
      .send({ name: 'Trek team', kind: 'trekking', ownerUserId: OTHER });
    expect(res.status).toBe(201);
    expect(createGroup).toHaveBeenCalledWith(user.id, { name: 'Trek team', kind: 'trekking' });
    expect(recordAuditEvent).toHaveBeenCalledWith(expect.objectContaining({ action: 'group.create', actorUserId: user.id }));
  });

  it('rejects an unknown group kind', async () => {
    const res = await request(app).post('/api/v1/groups').set('Authorization', 'Bearer t').send({ name: 'x', kind: 'army' });
    expect(res.status).toBe(400);
  });

  it('adds a member as the session user', async () => {
    const res = await request(app)
      .post(`/api/v1/groups/${GROUP}/members`)
      .set('Authorization', 'Bearer t')
      .send({ userId: OTHER });
    expect(res.status).toBe(204);
    expect(addGroupMember).toHaveBeenCalledWith(user.id, GROUP, OTHER);
  });

  it('removing yourself is audited as leaving', async () => {
    const res = await request(app).delete(`/api/v1/groups/${GROUP}/members/${user.id}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(204);
    expect(removeGroupMember).toHaveBeenCalledWith(user.id, GROUP, user.id);
    expect(recordAuditEvent).toHaveBeenCalledWith(expect.objectContaining({ action: 'group.leave' }));
  });

  it('rejects a malformed group id', async () => {
    const res = await request(app).get('/api/v1/groups/not-a-uuid').set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
  });
});
