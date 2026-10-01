import type { PoolClient } from 'pg';
import { pool, withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';
import type { CreateGroupInput } from '../validation/groupSchemas';

// Groups (family, trekking party, rescue team, …) built on the existing
// schema: `groups` + `group_members` for membership and roles, and ONE
// `conversations` row (type='group') whose `conversation_participants`
// mirror the members — so group chat reuses the existing message routes,
// idempotency, read status, and realtime fan-out unchanged.
//
// Membership rules:
// - owner: everything; must transfer ownership to another member before
//   leaving (transferGroupOwnership), so a group is never orphaned.
// - admin: add/remove members (not the owner or other admins).
// - member: read/send, leave.
// A user can only be added by someone who has them as a trusted contact
// linked to their ResQNet account — there is no user search, so groups
// cannot be used to reach strangers or enumerate accounts.

export type GroupRole = 'owner' | 'admin' | 'member';

export interface GroupMember {
  userId: string;
  displayName: string | null;
  role: GroupRole;
  joinedAt: string;
}

export interface GroupSummary {
  id: string;
  name: string;
  description: string | null;
  kind: string;
  conversationId: string;
  myRole: GroupRole;
  memberCount: number;
  createdAt: string;
}

export interface GroupDetail extends GroupSummary {
  members: GroupMember[];
}

interface DbGroupRow {
  id: string;
  name: string;
  description: string | null;
  kind: string;
  conversation_id: string;
  my_role: GroupRole;
  member_count: string;
  created_at: Date;
}

const toSummary = (row: DbGroupRow): GroupSummary => ({
  id: row.id,
  name: row.name,
  description: row.description,
  kind: row.kind,
  conversationId: row.conversation_id,
  myRole: row.my_role,
  memberCount: Number(row.member_count),
  createdAt: row.created_at.toISOString(),
});

const GROUP_SELECT = `
  SELECT g.id, g.name, g.description, g.kind, c.id AS conversation_id, me.role AS my_role,
         (SELECT COUNT(*)::text FROM group_members gm WHERE gm.group_id = g.id) AS member_count,
         g.created_at
  FROM groups g
  JOIN group_members me ON me.group_id = g.id AND me.user_id = $1
  JOIN conversations c ON c.group_id = g.id`;

export async function createGroup(ownerUserId: string, input: CreateGroupInput): Promise<GroupSummary> {
  const groupId = await withTransaction(async (client) => {
    const created = await client.query<{ id: string }>(
      'INSERT INTO groups (name, description, kind, owner_user_id) VALUES ($1, $2, $3, $4) RETURNING id',
      [input.name, input.description ?? null, input.kind, ownerUserId],
    );
    const id = created.rows[0]!.id;
    await client.query("INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'owner')", [id, ownerUserId]);
    const conversation = await client.query<{ id: string }>(
      "INSERT INTO conversations (type, group_id) VALUES ('group', $1) RETURNING id",
      [id],
    );
    await client.query('INSERT INTO conversation_participants (conversation_id, user_id) VALUES ($1, $2)', [
      conversation.rows[0]!.id,
      ownerUserId,
    ]);
    return id;
  });
  return (await getGroupSummary(ownerUserId, groupId))!;
}

export async function listGroupsForUser(userId: string): Promise<GroupSummary[]> {
  const { rows } = await pool.query<DbGroupRow>(`${GROUP_SELECT} ORDER BY g.created_at DESC`, [userId]);
  return rows.map(toSummary);
}

async function getGroupSummary(userId: string, groupId: string): Promise<GroupSummary | null> {
  const { rows } = await pool.query<DbGroupRow>(`${GROUP_SELECT} WHERE g.id = $2`, [userId, groupId]);
  return rows[0] ? toSummary(rows[0]) : null;
}

/** Same 404 whether the group does not exist or the caller is not a member. */
export async function getGroup(userId: string, groupId: string): Promise<GroupDetail> {
  const summary = await getGroupSummary(userId, groupId);
  if (!summary) throw HttpError.notFound('Group not found');
  const { rows } = await pool.query<{ user_id: string; display_name: string | null; role: GroupRole; joined_at: Date }>(
    `SELECT gm.user_id, u.display_name, gm.role, gm.joined_at
     FROM group_members gm JOIN users u ON u.id = gm.user_id
     WHERE gm.group_id = $1
     ORDER BY CASE gm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, gm.joined_at`,
    [groupId],
  );
  return {
    ...summary,
    members: rows.map((r) => ({
      userId: r.user_id,
      displayName: r.display_name,
      role: r.role,
      joinedAt: r.joined_at.toISOString(),
    })),
  };
}

async function lockedRole(client: PoolClient, groupId: string, userId: string): Promise<GroupRole | null> {
  const { rows } = await client.query<{ role: GroupRole }>(
    'SELECT role FROM group_members WHERE group_id = $1 AND user_id = $2 FOR UPDATE',
    [groupId, userId],
  );
  return rows[0]?.role ?? null;
}

async function conversationIdFor(client: PoolClient, groupId: string): Promise<string> {
  const { rows } = await client.query<{ id: string }>('SELECT id FROM conversations WHERE group_id = $1', [groupId]);
  return rows[0]!.id;
}

export async function addGroupMember(actorUserId: string, groupId: string, newUserId: string): Promise<void> {
  await withTransaction(async (client) => {
    const actorRole = await lockedRole(client, groupId, actorUserId);
    if (!actorRole) throw HttpError.notFound('Group not found');
    if (actorRole === 'member') throw HttpError.forbidden('Only the group owner or an admin can add members');

    const contact = await client.query(
      `SELECT 1 FROM trusted_contacts tc JOIN users u ON u.id = tc.contact_user_id
       WHERE tc.owner_user_id = $1 AND tc.contact_user_id = $2 AND u.account_status = 'active'`,
      [actorUserId, newUserId],
    );
    if (contact.rowCount === 0) {
      throw HttpError.badRequest('You can only add your trusted contacts who use ResQNet');
    }

    const inserted = await client.query(
      "INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'member') ON CONFLICT DO NOTHING",
      [groupId, newUserId],
    );
    if (inserted.rowCount === 0) return; // already a member — idempotent
    await client.query(
      'INSERT INTO conversation_participants (conversation_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING',
      [await conversationIdFor(client, groupId), newUserId],
    );
  });
}

/** Removes [targetUserId]; when actor and target are the same, this is "leave". */
export async function removeGroupMember(actorUserId: string, groupId: string, targetUserId: string): Promise<void> {
  await withTransaction(async (client) => {
    const actorRole = await lockedRole(client, groupId, actorUserId);
    if (!actorRole) throw HttpError.notFound('Group not found');
    const targetRole = await lockedRole(client, groupId, targetUserId);
    if (!targetRole) throw HttpError.notFound('Member not found');

    const leaving = actorUserId === targetUserId;
    if (leaving && actorRole === 'owner') {
      throw HttpError.conflict('Transfer ownership to another member before leaving the group');
    }
    if (!leaving) {
      if (targetRole === 'owner') throw HttpError.forbidden('The group owner cannot be removed');
      if (actorRole === 'member') throw HttpError.forbidden('Only the group owner or an admin can remove members');
      if (actorRole === 'admin' && targetRole === 'admin') {
        throw HttpError.forbidden('Only the group owner can remove an admin');
      }
    }

    await client.query('DELETE FROM group_members WHERE group_id = $1 AND user_id = $2', [groupId, targetUserId]);
    await client.query('DELETE FROM conversation_participants WHERE conversation_id = $1 AND user_id = $2', [
      await conversationIdFor(client, groupId),
      targetUserId,
    ]);
  });
}

export async function setGroupMemberRole(
  actorUserId: string,
  groupId: string,
  targetUserId: string,
  role: 'admin' | 'member',
): Promise<void> {
  await withTransaction(async (client) => {
    const actorRole = await lockedRole(client, groupId, actorUserId);
    if (!actorRole) throw HttpError.notFound('Group not found');
    if (actorRole !== 'owner') throw HttpError.forbidden('Only the group owner can change roles');
    const targetRole = await lockedRole(client, groupId, targetUserId);
    if (!targetRole) throw HttpError.notFound('Member not found');
    if (targetRole === 'owner') throw HttpError.forbidden("The owner's role cannot be changed");
    await client.query('UPDATE group_members SET role = $1 WHERE group_id = $2 AND user_id = $3', [
      role,
      groupId,
      targetUserId,
    ]);
  });
}

/**
 * Hands the group to another current member. The former owner stays in the
 * group as an admin and can then leave — this is how an owner leaves
 * without orphaning the group.
 */
export async function transferGroupOwnership(
  actorUserId: string,
  groupId: string,
  newOwnerUserId: string,
): Promise<void> {
  await withTransaction(async (client) => {
    const actorRole = await lockedRole(client, groupId, actorUserId);
    if (!actorRole) throw HttpError.notFound('Group not found');
    if (actorRole !== 'owner') throw HttpError.forbidden('Only the group owner can transfer ownership');
    if (newOwnerUserId === actorUserId) throw HttpError.badRequest('You already own this group');
    const targetRole = await lockedRole(client, groupId, newOwnerUserId);
    if (!targetRole) throw HttpError.badRequest('The new owner must already be a member of the group');
    // Demote first so there is never more than one owner row.
    await client.query("UPDATE group_members SET role = 'admin' WHERE group_id = $1 AND user_id = $2", [
      groupId,
      actorUserId,
    ]);
    await client.query("UPDATE group_members SET role = 'owner' WHERE group_id = $1 AND user_id = $2", [
      groupId,
      newOwnerUserId,
    ]);
    await client.query('UPDATE groups SET owner_user_id = $1 WHERE id = $2', [newOwnerUserId, groupId]);
  });
}
