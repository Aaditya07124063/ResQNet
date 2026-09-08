import { pool, withTransaction } from '../database/pool';
import { logger } from '../utils/logger';
import { broadcastToUser } from '../websocket/wsServer';
import { getUserById } from './userService';
import { notifyUsersDevices } from './pushNotificationService';
import { approximateDistanceLabel, findNearbyEligibleUsers } from './nearbyAlertService';
import { toSosEvent, type DbSosEventRow, type SosEvent } from '../models/SosEvent';

/**
 * The complete post-creation, identity-dependent processing for an SOS
 * event that HAS a real, known owner: realtime self-delivery, trusted-
 * contact fan-out, and nearby-user discovery/push. Shared by every path
 * that can end up with a real `user_id` on a sos_events row —
 * sosService.ts's direct (authenticated-caller-is-the-reporter) path, its
 * relayed-and-immediately-verified path, and deviceKeyService.ts's
 * reconciliation path (a relayed event that was unverified at creation
 * time and only later gained a verified owner). Extracted into its own
 * module specifically so sosService.ts and deviceKeyService.ts can both
 * depend on it without depending on each other.
 *
 * Must NEVER be called for an event whose origin is not yet
 * cryptographically verified (or not applicable) — see the architecture's
 * explicit "do not trigger identity-dependent fan-out for the unverified
 * event" requirement. Callers are responsible for that gate; this
 * function trusts `reporterUserId` unconditionally, exactly as the
 * pre-existing direct path always has.
 */
export async function runFanOutAndNotify(row: DbSosEventRow, reporterUserId: string): Promise<SosEvent> {
  const event = toSosEvent(row);
  broadcastSosEvent('sos_created', reporterUserId, event);

  // Best-effort: fan-out failing must never fail the SOS event itself —
  // the emergency has already been recorded by the time we get here,
  // which is the part that actually matters.
  let pushRecipients: PendingPushRecipient[] = [];
  try {
    pushRecipients = await fanOutToTrustedContacts(row.id, reporterUserId);
  } catch (err) {
    logger.error({ err, sosEventId: row.id }, 'SOS trusted-contact fan-out failed — the event itself was still recorded');
  }

  if (row.latitude !== null && row.longitude !== null) {
    try {
      const alreadyTrustedUserIds = new Set(pushRecipients.map((r) => r.contactUserId));
      const nearbyRecipients = await fanOutToNearbyUsers(
        row.id,
        reporterUserId,
        Number(row.latitude),
        Number(row.longitude),
        alreadyTrustedUserIds,
      );
      pushRecipients = pushRecipients.concat(nearbyRecipients);
    } catch (err) {
      logger.error({ err, sosEventId: row.id }, 'SOS nearby-user fan-out failed — the event itself was still recorded');
    }
  }

  // Best-effort, and deliberately outside the fan-out transaction above —
  // an external network call (FCM) must never hold a DB transaction open,
  // and a push failure must never roll back or fail anything already
  // recorded (event, SMS-pending recipients).
  try {
    await notifyForNewSosEvent(event, reporterUserId, pushRecipients);
  } catch (err) {
    logger.error({ err, sosEventId: row.id }, 'SOS push notification step failed — the event itself was still recorded');
  }

  return event;
}

/**
 * Realtime delivery of an SOS event to the REPORTING user's own other
 * connected devices only (self-delivery needs no new authorization model —
 * `broadcastToUser` only ever reaches sockets already authenticated as
 * this exact user). Best-effort: a broadcast failure must never fail the
 * underlying write.
 */
export function broadcastSosEvent(type: 'sos_created' | 'sos_status_updated', userId: string, event: SosEvent): void {
  try {
    broadcastToUser(userId, { type, event });
  } catch (err) {
    logger.warn({ err, userId, sosEventId: event.id }, 'SOS realtime broadcast failed');
  }
}

interface PendingPushRecipient {
  sosRecipientId: string;
  contactUserId: string;
  category: 'trusted_contact' | 'nearby';
  distanceM?: number;
}

/**
 * Records fan-out intent to the reporter's own trusted contacts. Every
 * contact gets an SMS-channel row (status='pending', actual delivery is a
 * separate SMS-provider concern not implemented yet). A contact who is
 * ALSO a ResQNet user additionally gets a separate push-channel row.
 */
async function fanOutToTrustedContacts(sosEventId: string, reporterUserId: string): Promise<PendingPushRecipient[]> {
  return withTransaction(async (client) => {
    const { rows: contacts } = await client.query<{ contact_user_id: string | null; phone_number: string }>(
      'SELECT contact_user_id, phone_number FROM trusted_contacts WHERE owner_user_id = $1',
      [reporterUserId],
    );
    const pushRecipients: PendingPushRecipient[] = [];
    for (const contact of contacts) {
      await client.query(
        `INSERT INTO sos_recipients (sos_event_id, recipient_user_id, recipient_phone_number, channel, status)
         VALUES ($1, $2, $3, 'sms', 'pending')`,
        [sosEventId, contact.contact_user_id, contact.phone_number],
      );
      if (contact.contact_user_id) {
        const { rows: pushRows } = await client.query<{ id: string }>(
          `INSERT INTO sos_recipients (sos_event_id, recipient_user_id, channel, status)
           VALUES ($1, $2, 'push', 'pending')
           RETURNING id`,
          [sosEventId, contact.contact_user_id],
        );
        pushRecipients.push({
          sosRecipientId: pushRows[0]!.id,
          contactUserId: contact.contact_user_id,
          category: 'trusted_contact',
        });
      }
    }
    return pushRecipients;
  });
}

/**
 * Records fan-out to nearby ELIGIBLE ResQNet users. Each nearby recipient
 * gets exactly one 'push'-channel sos_recipients row (recipient_category
 * ='nearby'), guarded by uq_sos_recipients_nearby_unique so a duplicated
 * discovery run can never double-insert.
 */
async function fanOutToNearbyUsers(
  sosEventId: string,
  reporterUserId: string,
  latitude: number,
  longitude: number,
  excludeUserIds: Set<string>,
): Promise<PendingPushRecipient[]> {
  const eligible = await findNearbyEligibleUsers(reporterUserId, latitude, longitude);
  const pushRecipients: PendingPushRecipient[] = [];
  for (const candidate of eligible) {
    if (excludeUserIds.has(candidate.userId)) continue;
    const { rows } = await pool.query<{ id: string }>(
      `INSERT INTO sos_recipients (sos_event_id, recipient_user_id, channel, status, recipient_category, distance_m)
       VALUES ($1, $2, 'push', 'pending', 'nearby', $3)
       ON CONFLICT (sos_event_id, recipient_user_id)
         WHERE recipient_category = 'nearby' AND recipient_user_id IS NOT NULL
       DO NOTHING
       RETURNING id`,
      [sosEventId, candidate.userId, candidate.distanceM],
    );
    const sosRecipientId = rows[0]?.id;
    if (!sosRecipientId) continue;
    pushRecipients.push({
      sosRecipientId,
      contactUserId: candidate.userId,
      category: 'nearby',
      distanceM: candidate.distanceM,
    });
  }
  return pushRecipients;
}

/**
 * Sends push notifications for a new SOS to two DISTINCT recipient groups,
 * each with its own privacy level: trusted contacts who are ResQNet users
 * get the fuller alert (reporter name + message); nearby eligible users
 * get category + approximate distance only, never the reporter's identity,
 * message, or exact coordinates.
 */
async function notifyForNewSosEvent(
  event: SosEvent,
  reporterUserId: string,
  pushRecipients: PendingPushRecipient[],
): Promise<void> {
  if (pushRecipients.length === 0) return;

  const reporter = await getUserById(reporterUserId);
  const reporterName = reporter?.displayName ?? 'A ResQNet user';
  const trustedContactData = {
    sosEventId: event.id,
    category: event.category,
    latitude: event.latitude !== null ? String(event.latitude) : '',
    longitude: event.longitude !== null ? String(event.longitude) : '',
  };
  const nearbyData = { sosEventId: event.id, category: event.category };

  const trustedRecipients = pushRecipients.filter((r) => r.category === 'trusted_contact');
  const nearbyRecipients = pushRecipients.filter((r) => r.category === 'nearby');

  const outcomes = new Map<string, string>();

  if (trustedRecipients.length > 0) {
    const trustedOutcomes = await notifyUsersDevices(
      trustedRecipients.map((r) => r.contactUserId),
      {
        title: `🚨 ${reporterName} needs you — SOS (${event.category})`,
        body: event.message || 'Open ResQNet for their location.',
        data: trustedContactData,
      },
    );
    for (const [userId, outcome] of trustedOutcomes) outcomes.set(userId, outcome);
  }

  if (nearbyRecipients.length > 0) {
    for (const recipient of nearbyRecipients) {
      const recipientOutcomes = await notifyUsersDevices([recipient.contactUserId], {
        title: '🚨 Emergency nearby',
        body: `${event.category} — ${approximateDistanceLabel(recipient.distanceM ?? 0)}`,
        data: nearbyData,
      });
      for (const [userId, outcome] of recipientOutcomes) outcomes.set(userId, outcome);
    }

    for (const recipient of nearbyRecipients) {
      try {
        broadcastToUser(recipient.contactUserId, {
          type: 'nearby_sos_created',
          sosEventId: event.id,
          category: event.category,
          approximateDistance: approximateDistanceLabel(recipient.distanceM ?? 0),
          activatedAt: event.serverReceivedAt,
        });
      } catch (err) {
        logger.warn({ err, sosEventId: event.id }, 'nearby_sos_created realtime broadcast failed');
      }
    }
  }

  for (const recipient of pushRecipients) {
    const outcome = outcomes.get(recipient.contactUserId) ?? 'no_device';
    if (outcome === 'no_device') continue;
    await pool.query(
      `UPDATE sos_recipients
       SET status = $1, sent_at = CASE WHEN $2 = 'sent' THEN now() ELSE sent_at END
       WHERE id = $3`,
      [outcome, outcome, recipient.sosRecipientId],
    );
  }
}
