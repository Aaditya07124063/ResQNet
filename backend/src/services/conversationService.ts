import { pool, withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';
import type { ConversationSummary } from '../models/Conversation';

/**
 * Finds or creates a direct (1:1) conversation between the caller and
 * `otherUserId`. Race-safe: `direct_user_a_id`/`direct_user_b_id` are
 * stored sorted (a < b) with a partial unique index
 * (uq_conversations_direct_pair, 003_communication_and_nearby_alerts.sql),
 * so two concurrent "start a conversation with X" calls for the same pair
 * resolve to the exact same row via ON CONFLICT — never two conversations
 * for one pair.
 */
export async function findOrCreateDirectConversation(
  callerUserId: string,
  otherUserId: string,
): Promise<string> {
  if (callerUserId === otherUserId) {
    throw HttpError.badRequest('Cannot start a conversation with yourself');
  }
  const [userA, userB] = [callerUserId, otherUserId].sort();

  return withTransaction(async (client) => {
    const { rows: existing } = await client.query<{ id: string }>(
      'SELECT id FROM conversations WHERE direct_user_a_id = $1 AND direct_user_b_id = $2',
      [userA, userB],
    );
    if (existing[0]) return existing[0].id;

    const { rows } = await client.query<{ id: string }>(
      `INSERT INTO conversations (type, direct_user_a_id, direct_user_b_id)
       VALUES ('direct', $1, $2)
       ON CONFLICT (direct_user_a_id, direct_user_b_id) WHERE type = 'direct' DO NOTHING
       RETURNING id`,
      [userA, userB],
    );
    let conversationId = rows[0]?.id;
    if (!conversationId) {
      // Lost the race to a concurrent identical request — its INSERT won,
      // ours hit the conflict and returned nothing; look the row up.
      const { rows: refetched } = await client.query<{ id: string }>(
        'SELECT id FROM conversations WHERE direct_user_a_id = $1 AND direct_user_b_id = $2',
        [userA, userB],
      );
      conversationId = refetched[0]?.id;
    }
    if (!conversationId) {
      throw HttpError.internal('Failed to create conversation');
    }

    await client.query(
      `INSERT INTO conversation_participants (conversation_id, user_id)
       VALUES ($1, $2), ($1, $3)
       ON CONFLICT DO NOTHING`,
      [conversationId, userA, userB],
    );
    return conversationId;
  });
}

/** Throws 404 (never 403 — see the ownership-scoping convention used
 * throughout this codebase, e.g. sosService.updateSosEventStatus) if the
 * given user is not a participant of the given conversation. This is the
 * ONE authorization check every conversation/message operation must pass
 * through — a conversation id alone is never sufficient. */
export async function requireParticipant(conversationId: string, userId: string): Promise<void> {
  const { rows } = await pool.query(
    'SELECT 1 FROM conversation_participants WHERE conversation_id = $1 AND user_id = $2',
    [conversationId, userId],
  );
  if (rows.length === 0) {
    throw HttpError.notFound('Conversation not found');
  }
}

export async function getOtherParticipantIds(conversationId: string, excludeUserId: string): Promise<string[]> {
  const { rows } = await pool.query<{ user_id: string }>(
    'SELECT user_id FROM conversation_participants WHERE conversation_id = $1 AND user_id != $2',
    [conversationId, excludeUserId],
  );
  return rows.map((r) => r.user_id);
}

interface DbConversationSummaryRow {
  id: string;
  type: 'direct' | 'group';
  other_user_id: string | null;
  other_display_name: string | null;
  last_message_id: string | null;
  last_message_type: 'text' | 'location' | null;
  last_message_body: string | null;
  last_message_sender_id: string | null;
  last_message_created_at: Date | null;
  unread_count: string; // COUNT(*) comes back as a string from pg
  updated_at: Date;
}

/**
 * Lists every conversation the caller participates in, most recently
 * active first, each with its other participant (direct only — V1's only
 * conversation type a normal user can create) and last message inlined so
 * the Flutter conversations-list screen never needs a second round-trip
 * per row (Section 16A).
 */
export async function listConversationsForUser(userId: string): Promise<ConversationSummary[]> {
  const { rows } = await pool.query<DbConversationSummaryRow>(
    `SELECT
       c.id,
       c.type,
       other.user_id AS other_user_id,
       u.display_name AS other_display_name,
       lm.id AS last_message_id,
       lm.message_type AS last_message_type,
       lm.body AS last_message_body,
       lm.sender_user_id AS last_message_sender_id,
       lm.server_received_at AS last_message_created_at,
       -- '0' (text), not 0 (integer) — unread.count is already cast to
       -- text in its own subquery below, and COALESCE requires both
       -- branches to be the same type. Caught only by a real Postgres
       -- run (a mocked pool.query in a unit test never parses SQL) —
       -- confirmed live against a local dev database before this fix.
       COALESCE(unread.count, '0') AS unread_count,
       COALESCE(lm.server_received_at, c.created_at) AS updated_at
     FROM conversation_participants cp
     JOIN conversations c ON c.id = cp.conversation_id
     LEFT JOIN conversation_participants other
       ON other.conversation_id = c.id AND other.user_id != $1 AND c.type = 'direct'
     LEFT JOIN users u ON u.id = other.user_id
     LEFT JOIN LATERAL (
       SELECT id, message_type, body, sender_user_id, server_received_at
       FROM messages
       WHERE conversation_id = c.id AND deleted_at IS NULL
       ORDER BY server_received_at DESC
       LIMIT 1
     ) lm ON TRUE
     LEFT JOIN LATERAL (
       SELECT COUNT(*)::text AS count
       FROM message_status ms
       JOIN messages m ON m.id = ms.message_id
       WHERE m.conversation_id = c.id AND ms.recipient_user_id = $1 AND ms.status != 'read'
     ) unread ON TRUE
     WHERE cp.user_id = $1
     ORDER BY updated_at DESC`,
    [userId],
  );

  return rows.map((row) => ({
    id: row.id,
    type: row.type,
    otherParticipant: row.other_user_id
      ? { id: row.other_user_id, displayName: row.other_display_name }
      : null,
    lastMessage: row.last_message_id
      ? {
          id: row.last_message_id,
          messageType: row.last_message_type!,
          body: row.last_message_body,
          senderUserId: row.last_message_sender_id!,
          createdAt: row.last_message_created_at!.toISOString(),
        }
      : null,
    unreadCount: Number(row.unread_count),
    updatedAt: row.updated_at.toISOString(),
  }));
}
