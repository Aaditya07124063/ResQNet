import { pool, withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import { broadcastToUser } from '../websocket/wsServer';
import { getOtherParticipantIds, requireParticipant } from './conversationService';
import { toMessage, type DbMessageRow, type Message } from '../models/Message';
import type {
  ListMessagesQuery,
  SendMessageInput,
} from '../validation/communicationSchemas';

interface PgError {
  code?: string;
}

function pgErrorCode(err: unknown): string | undefined {
  return typeof err === 'object' && err !== null ? (err as PgError).code : undefined;
}

/** Best-effort realtime push — a socket-send failure must never fail the
 * (already-persisted) write that triggered it, matching sosService.ts's
 * broadcastSosEvent. */
function pushEvent(userId: string, payload: unknown): void {
  try {
    broadcastToUser(userId, payload);
  } catch (err) {
    logger.warn({ err, userId }, 'Communication realtime broadcast failed');
  }
}

/**
 * Sends a message. Idempotent on (conversation_id, client_message_id) —
 * see uq_messages_conversation_client_id (001_init_schema.sql): a client
 * retrying an offline-queued send after connectivity returns resolves to
 * the SAME message row rather than creating a duplicate. `senderUserId`
 * must come from req.authUser.id (route layer enforces this) — never a
 * client-supplied field (Section 6).
 *
 * Recipients (every OTHER current participant, snapshotted into
 * message_recipients at send time — see 001_init_schema.sql's comment on
 * that table) each get a message_status row starting at 'sent', and a
 * targeted `message_created` WebSocket event. A recipient who is offline
 * simply doesn't have a live socket to receive that push — the message is
 * already durably persisted by the time this runs, and they'll see it via
 * listMessages on reconnect (Section 5's offline-recipient flow).
 */
export async function sendMessage(
  conversationId: string,
  senderUserId: string,
  input: SendMessageInput,
): Promise<Message> {
  await requireParticipant(conversationId, senderUserId);

  let row: DbMessageRow;
  let isNewMessage = true;
  try {
    row = await withTransaction(async (client) => {
      const { rows } = await client.query<DbMessageRow>(
        input.messageType === 'text'
          ? `INSERT INTO messages
               (conversation_id, sender_user_id, client_message_id, message_type, body, client_created_at)
             VALUES ($1, $2, $3, 'text', $4, $5)
             RETURNING *`
          : `INSERT INTO messages
               (conversation_id, sender_user_id, client_message_id, message_type, latitude, longitude, location_accuracy_m, client_created_at)
             VALUES ($1, $2, $3, 'location', $4, $5, $6, $7)
             RETURNING *`,
        input.messageType === 'text'
          ? [conversationId, senderUserId, input.clientMessageId, input.body, input.clientCreatedAt]
          : [
              conversationId,
              senderUserId,
              input.clientMessageId,
              input.latitude,
              input.longitude,
              input.locationAccuracyM,
              input.clientCreatedAt,
            ],
      );
      const message = rows[0]!;

      const recipientIds = await getOtherParticipantIdsTx(client, conversationId, senderUserId);
      for (const recipientId of recipientIds) {
        await client.query(
          'INSERT INTO message_recipients (message_id, recipient_user_id) VALUES ($1, $2)',
          [message.id, recipientId],
        );
        await client.query(
          'INSERT INTO message_status (message_id, recipient_user_id, status) VALUES ($1, $2, $3)',
          [message.id, recipientId, 'sent'],
        );
      }
      return message;
    });
  } catch (err) {
    if (pgErrorCode(err) === '23505') {
      // uq_messages_conversation_client_id — a retried send. Resolve to
      // the existing row rather than erroring or duplicating.
      const { rows } = await pool.query<DbMessageRow>(
        'SELECT * FROM messages WHERE conversation_id = $1 AND client_message_id = $2',
        [conversationId, input.clientMessageId],
      );
      const existing = rows[0];
      if (!existing) throw err; // shouldn't happen — the conflict implies a row exists
      if (existing.sender_user_id !== senderUserId) {
        // A client_message_id collision across different senders in the
        // same conversation must never resolve to the other sender's
        // message (same reasoning as sosService's cross-user event_id
        // check).
        throw HttpError.conflict('This message id is already in use');
      }
      row = existing;
      isNewMessage = false;
    } else {
      throw err;
    }
  }

  const message = toMessage(row);

  if (isNewMessage) {
    const recipientIds = await getOtherParticipantIds(conversationId, senderUserId);
    for (const recipientId of recipientIds) {
      pushEvent(recipientId, { type: 'message_created', conversationId, message });
      pushEvent(recipientId, { type: 'conversation_updated', conversationId, lastMessage: message });
    }
    // The sender's OTHER devices should also see conversation_updated
    // (their own message list should reflect it without a manual refresh)
    // — never message_created for their own message, they already have it
    // from this request's own response.
    pushEvent(senderUserId, { type: 'conversation_updated', conversationId, lastMessage: message });
  }

  return message;
}

async function getOtherParticipantIdsTx(
  client: { query: (sql: string, params: unknown[]) => Promise<{ rows: { user_id: string }[] }> },
  conversationId: string,
  excludeUserId: string,
): Promise<string[]> {
  const { rows } = await client.query(
    'SELECT user_id FROM conversation_participants WHERE conversation_id = $1 AND user_id != $2',
    [conversationId, excludeUserId],
  );
  return rows.map((r) => r.user_id);
}

/** Cursor-paginated, newest-first-then-reversed-for-display is a Flutter
 * UI concern — this returns newest-first (matches idx_messages_conversation_created's
 * natural scan order), consistent with sosService.listSosEvents's
 * newest-first convention. */
export async function listMessages(
  conversationId: string,
  userId: string,
  query: ListMessagesQuery,
): Promise<Message[]> {
  await requireParticipant(conversationId, userId);

  const { rows } = await pool.query<DbMessageRow>(
    query.before
      ? `SELECT * FROM messages
         WHERE conversation_id = $1 AND deleted_at IS NULL AND server_received_at < $2
         ORDER BY server_received_at DESC
         LIMIT $3`
      : `SELECT * FROM messages
         WHERE conversation_id = $1 AND deleted_at IS NULL
         ORDER BY server_received_at DESC
         LIMIT $2`,
    query.before ? [conversationId, query.before, query.limit] : [conversationId, query.limit],
  );
  return rows.map(toMessage);
}

/**
 * Updates ONE message's delivery/read status for the calling user, who
 * must be that message's recipient (never the sender, and never a
 * different recipient in a group conversation than the caller — IDOR
 * protection: this can only ever update the caller's OWN
 * message_status row).
 */
export async function updateMessageStatus(
  conversationId: string,
  userId: string,
  messageId: string,
  status: 'delivered' | 'read',
): Promise<void> {
  await requireParticipant(conversationId, userId);

  const { rows } = await pool.query<{ sender_user_id: string; status: string }>(
    `UPDATE message_status ms
     SET status = $1,
         delivered_at = CASE WHEN $1 IN ('delivered', 'read') THEN COALESCE(ms.delivered_at, now()) ELSE ms.delivered_at END,
         read_at = CASE WHEN $1 = 'read' THEN now() ELSE ms.read_at END
     FROM messages m
     WHERE ms.message_id = m.id
       AND ms.message_id = $2
       AND ms.recipient_user_id = $3
       AND m.conversation_id = $4
       -- Never regress a status backwards (read -> delivered is meaningless).
       AND (ms.status != 'read' OR $1 = 'read')
     RETURNING m.sender_user_id, ms.status`,
    [status, messageId, userId, conversationId],
  );
  const row = rows[0];
  if (!row) {
    // Either the message doesn't exist, doesn't belong to this
    // conversation, or the caller isn't its recipient — same 404 for all
    // three, never revealing which (IDOR-safe).
    throw HttpError.notFound('Message not found');
  }

  pushEvent(row.sender_user_id, {
    type: status === 'delivered' ? 'message_delivered' : 'message_read',
    conversationId,
    messageId,
    readerUserId: userId,
  });
}

/**
 * Marks every not-yet-read message up to and including `upToMessageId` as
 * read for the caller, in one call — the practical shape a chat UI
 * actually needs (marking each visible message read one API call at a
 * time would be needlessly chatty). Broadcasts a single aggregated
 * `message_read` event rather than one per message.
 */
export async function markConversationRead(
  conversationId: string,
  userId: string,
  upToMessageId: string,
): Promise<void> {
  await requireParticipant(conversationId, userId);

  const { rows: cutoffRows } = await pool.query<{ server_received_at: Date; sender_user_id: string }>(
    'SELECT server_received_at, sender_user_id FROM messages WHERE id = $1 AND conversation_id = $2',
    [upToMessageId, conversationId],
  );
  const cutoff = cutoffRows[0];
  if (!cutoff) {
    throw HttpError.notFound('Message not found');
  }

  await pool.query(
    `UPDATE message_status ms
     SET status = 'read', read_at = now(), delivered_at = COALESCE(ms.delivered_at, now())
     FROM messages m
     WHERE ms.message_id = m.id
       AND m.conversation_id = $1
       AND m.server_received_at <= $2
       AND ms.recipient_user_id = $3
       AND ms.status != 'read'`,
    [conversationId, cutoff.server_received_at, userId],
  );

  const otherParticipantIds = await getOtherParticipantIds(conversationId, userId);
  for (const participantId of otherParticipantIds) {
    pushEvent(participantId, {
      type: 'message_read',
      conversationId,
      upToMessageId,
      readerUserId: userId,
    });
  }
}
