jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));

import { pool, withTransaction } from '../src/database/pool';
import {
  addGroupMember,
  createGroup,
  getGroup,
  removeGroupMember,
  setGroupMemberRole,
  transferGroupOwnership,
} from '../src/services/groupService';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;

const G = 'g1';
/** Transaction whose client answers by SQL shape. roles: userId → role in group. */
function transaction(roles: Record<string, string>, opts: { isContact?: boolean; alreadyMember?: boolean } = {}) {
  const query = jest.fn(async (sql: string, params: unknown[] = []) => {
    if (sql.includes('SELECT role FROM group_members')) {
      const role = roles[params[1] as string];
      return { rows: role ? [{ role }] : [] };
    }
    if (sql.includes('FROM trusted_contacts')) return { rows: [], rowCount: opts.isContact ? 1 : 0 };
    if (sql.includes('INSERT INTO group_members') && sql.includes("'member'")) return { rowCount: opts.alreadyMember ? 0 : 1 };
    if (sql.includes('SELECT id FROM conversations')) return { rows: [{ id: 'conv-1' }] };
    if (sql.includes('INSERT INTO groups')) return { rows: [{ id: G }] };
    if (sql.includes("INSERT INTO conversations")) return { rows: [{ id: 'conv-1' }] };
    return { rows: [], rowCount: 1 };
  });
  mockWithTransaction.mockImplementationOnce(async (work: (c: { query: jest.Mock }) => unknown) => work({ query }));
  return query;
}
const sqls = (q: jest.Mock) => q.mock.calls.map(([sql]) => sql as string);

beforeEach(() => jest.clearAllMocks());

describe('createGroup', () => {
  it('creates the group, the owner membership, and one group conversation with the owner as participant', async () => {
    const q = transaction({});
    mockPoolQuery.mockResolvedValueOnce({
      rows: [{ id: G, name: 'Family', description: null, kind: 'family', conversation_id: 'conv-1', my_role: 'owner', member_count: '1', created_at: new Date() }],
    });
    const group = await createGroup('owner', { name: 'Family', kind: 'family' });
    const statements = sqls(q);
    expect(statements.some((s) => s.includes('INSERT INTO groups'))).toBe(true);
    expect(statements.some((s) => s.includes("'owner'"))).toBe(true);
    expect(statements.some((s) => s.includes("VALUES ('group', $1)"))).toBe(true);
    expect(statements.some((s) => s.includes('INSERT INTO conversation_participants'))).toBe(true);
    expect(group).toMatchObject({ id: G, myRole: 'owner', conversationId: 'conv-1', memberCount: 1 });
  });
});

describe('addGroupMember', () => {
  it('lets an admin add their own ResQNet trusted contact, mirroring them into the group chat', async () => {
    const q = transaction({ admin: 'admin' }, { isContact: true });
    await addGroupMember('admin', G, 'friend');
    expect(q.mock.calls.find(([s]) => s.includes('INSERT INTO conversation_participants'))![1]).toEqual(['conv-1', 'friend']);
  });

  it('refuses anyone who is not the adder\'s trusted contact (no adding strangers by id)', async () => {
    transaction({ owner: 'owner' }, { isContact: false });
    await expect(addGroupMember('owner', G, 'stranger')).rejects.toMatchObject({ status: 400 });
  });

  it('refuses plain members', async () => {
    transaction({ m: 'member' }, { isContact: true });
    await expect(addGroupMember('m', G, 'friend')).rejects.toMatchObject({ status: 403 });
  });

  it('is idempotent for an existing member', async () => {
    const q = transaction({ owner: 'owner' }, { isContact: true, alreadyMember: true });
    await addGroupMember('owner', G, 'friend');
    expect(sqls(q).some((s) => s.includes('INSERT INTO conversation_participants'))).toBe(false);
  });

  it('gives a non-member the same 404 as a missing group', async () => {
    transaction({});
    await expect(addGroupMember('outsider', G, 'friend')).rejects.toMatchObject({ status: 404 });
  });
});

describe('removeGroupMember', () => {
  it('a member can leave; they are removed from the group chat too', async () => {
    const q = transaction({ m: 'member' });
    await removeGroupMember('m', G, 'm');
    expect(sqls(q).some((s) => s.includes('DELETE FROM conversation_participants'))).toBe(true);
  });

  it('the owner cannot leave', async () => {
    transaction({ owner: 'owner' });
    await expect(removeGroupMember('owner', G, 'owner')).rejects.toMatchObject({ status: 409 });
  });

  it.each([
    ['member removes member', { a: 'member', b: 'member' }, 403],
    ['admin removes admin', { a: 'admin', b: 'admin' }, 403],
    ['admin removes owner', { a: 'admin', b: 'owner' }, 403],
  ])('%s is refused', async (_name, roles, status) => {
    transaction(roles);
    await expect(removeGroupMember('a', G, 'b')).rejects.toMatchObject({ status });
  });

  it('an admin can remove a member', async () => {
    transaction({ a: 'admin', b: 'member' });
    await expect(removeGroupMember('a', G, 'b')).resolves.toBeUndefined();
  });
});

describe('setGroupMemberRole', () => {
  it('only the owner changes roles', async () => {
    transaction({ a: 'admin', b: 'member' });
    await expect(setGroupMemberRole('a', G, 'b', 'admin')).rejects.toMatchObject({ status: 403 });
    const q = transaction({ owner: 'owner', b: 'member' });
    await setGroupMemberRole('owner', G, 'b', 'admin');
    expect(q.mock.calls.find(([s]) => s.includes('UPDATE group_members'))![1]).toEqual(['admin', G, 'b']);
  });
});

describe('transferGroupOwnership', () => {
  it('only the owner can transfer, and only to a current member', async () => {
    transaction({ a: 'admin', owner: 'owner' });
    await expect(transferGroupOwnership('a', G, 'a')).rejects.toMatchObject({ status: 403 });
    transaction({ owner: 'owner' });
    await expect(transferGroupOwnership('owner', G, 'stranger')).rejects.toMatchObject({ status: 400 });
    transaction({ owner: 'owner' });
    await expect(transferGroupOwnership('owner', G, 'owner')).rejects.toMatchObject({ status: 400 });
  });

  it('demotes the old owner to admin before promoting the new one', async () => {
    const q = transaction({ owner: 'owner', b: 'member' });
    await transferGroupOwnership('owner', G, 'b');
    const updates = q.mock.calls.filter(([s]) => (s as string).startsWith('UPDATE'));
    expect(updates.map(([s, p]) => [(s as string).includes("'admin'") ? 'admin' : (s as string).includes("'owner'") ? 'owner' : 'groups', p])).toEqual([
      ['admin', [G, 'owner']],
      ['owner', [G, 'b']],
      ['groups', ['b', G]],
    ]);
  });
});

describe('getGroup', () => {
  it('404s for non-members', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await expect(getGroup('outsider', G)).rejects.toMatchObject({ status: 404 });
  });
});
