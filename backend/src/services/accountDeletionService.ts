import { withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import { deleteProfileImage } from './storageService';

// Civilian account deletion (DELETE /api/v1/me). Deleting an account is
// not the same as deleting every record the person appears in:
// - Refused while they have an SOS that responders have not closed (an
//   active emergency must never vanish), or one under a retention hold.
// - Their closed SOS incidents keep the minimum operational record
//   (category, times, responder actions) but lose, immediately, the
//   message, location, raw envelope, delivery log, responder note text and
//   every link to the account or device.
// - Groups they own pass to another member (admins first, then longest
//   membership) or are deleted when nobody else is in them.
// - The account row is then removed; sessions, devices and device keys,
//   the profile (including medical details), trusted contacts,
//   memberships, messages they sent, seismic reports, OTP rows and
//   nearby-alert data go with it through their foreign keys.
// - Audit entries keep the action and time but lose the account link
//   (actor_user_id is set to NULL by its foreign key).
// Copies already on other people's phones (mesh relays, notifications,
// chat history they received) are outside the server and are not affected.

export interface AccountDeletionResult {
  incidentsDeidentified: number;
  groupsTransferred: number;
  groupsDeleted: number;
}

const OPEN = "ops_status NOT IN ('resolved', 'stood_down')";

export async function deleteAccount(userId: string): Promise<AccountDeletionResult> {
  let imageKey: string | null = null;
  const result = await withTransaction(async (client) => {
    const user = await client.query<{ image: string | null }>(
      `SELECT p.profile_image_object_key AS image
         FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id
        WHERE u.id = $1 FOR UPDATE OF u`,
      [userId],
    );
    if (user.rowCount === 0) throw HttpError.notFound('Account not found');
    imageKey = user.rows[0]!.image;

    const mine = '(user_id = $1 OR origin_claimed_user_id = $1)';
    const open = await client.query(`SELECT 1 FROM sos_events WHERE ${mine} AND ${OPEN} LIMIT 1`, [userId]);
    if ((open.rowCount ?? 0) > 0) {
      throw new HttpError(
        409,
        'ACTIVE_INCIDENT',
        'You have an SOS that responders have not closed yet. The account can be deleted once it is resolved.',
      );
    }
    const held = await client.query(`SELECT 1 FROM sos_events WHERE ${mine} AND retention_hold_at IS NOT NULL LIMIT 1`, [userId]);
    if ((held.rowCount ?? 0) > 0) {
      throw new HttpError(
        409,
        'RETENTION_HOLD',
        'One of your SOS records is under review and cannot be removed yet. Contact ResQNet support.',
      );
    }

    // Closed incidents: keep the operational record, drop everything personal now.
    await client.query(
      `UPDATE sos_incident_updates SET note = NULL, note_redacted_at = now()
        WHERE note IS NOT NULL AND sos_event_id IN (SELECT id FROM sos_events WHERE ${mine})`,
      [userId],
    );
    await client.query(`DELETE FROM sos_recipients WHERE sos_event_id IN (SELECT id FROM sos_events WHERE ${mine})`, [userId]);
    await client.query(`DELETE FROM locations WHERE sos_event_id IN (SELECT id FROM sos_events WHERE ${mine})`, [userId]);
    const deidentified = await client.query(
      `UPDATE sos_events SET message = NULL, latitude = NULL, longitude = NULL, location_accuracy_m = NULL,
              origin_envelope_raw = NULL, origin_signature = NULL,
              sensitive_redacted_at = COALESCE(sensitive_redacted_at, now()),
              deidentified_at = COALESCE(deidentified_at, now()),
              user_id = NULL, origin_claimed_user_id = NULL, origin_device_id = NULL, origin_key_id = NULL
        WHERE ${mine}`,
      [userId],
    );

    // Groups they own: hand over, or delete when they are the only member.
    let transferred = 0;
    let deleted = 0;
    const owned = await client.query<{ id: string }>('SELECT id FROM groups WHERE owner_user_id = $1 FOR UPDATE', [userId]);
    for (const { id: groupId } of owned.rows) {
      const next = await client.query<{ user_id: string }>(
        `SELECT user_id FROM group_members WHERE group_id = $1 AND user_id <> $2
          ORDER BY (role = 'admin') DESC, joined_at ASC LIMIT 1`,
        [groupId, userId],
      );
      const successor = next.rows[0]?.user_id;
      if (successor) {
        await client.query("UPDATE group_members SET role = 'admin' WHERE group_id = $1 AND user_id = $2", [groupId, userId]);
        await client.query("UPDATE group_members SET role = 'owner' WHERE group_id = $1 AND user_id = $2", [groupId, successor]);
        await client.query('UPDATE groups SET owner_user_id = $1 WHERE id = $2', [successor, groupId]);
        transferred++;
      } else {
        await client.query('DELETE FROM groups WHERE id = $1', [groupId]);
        deleted++;
      }
    }

    await client.query('DELETE FROM users WHERE id = $1', [userId]);
    return { incidentsDeidentified: deidentified.rowCount ?? 0, groupsTransferred: transferred, groupsDeleted: deleted };
  });

  // Object storage is outside the transaction: best effort, after commit.
  if (imageKey) {
    await deleteProfileImage(imageKey).catch((err: unknown) =>
      logger.error({ job: 'account_deletion', errorCode: (err as { code?: string }).code ?? 'error' }, 'Profile image removal failed; remove it manually'),
    );
  }
  return result;
}
