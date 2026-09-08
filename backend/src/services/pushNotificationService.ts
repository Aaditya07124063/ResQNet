import { pool } from '../database/pool';
import { logger } from '../utils/logger';
import { getPushTokensForUsers, removeDevicesByToken } from './deviceService';
import { sendMulticast, type PushNotificationContent } from './fcm';

/**
 * DB-aware push sending — resolves ResQNet user ids to device tokens,
 * calls FCM, and cleans up tokens FCM itself reports as permanently
 * invalid. Every function here is best-effort: a provider outage, missing
 * FIREBASE_SERVICE_ACCOUNT_JSON, or any other failure is logged and
 * swallowed, never thrown — the same fan-out-must-never-fail-the-primary-
 * write pattern already used for SOS trusted-contact SMS fan-out
 * (sosService.ts) and Phase 14's review-case side effect.
 */

export type PerUserOutcome = 'sent' | 'failed' | 'no_device';

/**
 * Sends one notification to every device of each listed user, batched
 * into as few FCM calls as possible. Returns a per-user outcome (not
 * per-token) so callers that persist delivery status against a specific
 * user (e.g. sos_recipients) can do so without needing FCM's own
 * per-token error taxonomy: 'sent' if at least one of that user's devices
 * accepted the message, 'failed' if the user has devices but all of them
 * failed, 'no_device' if the user has no registered device at all (never
 * attempted, not a failure).
 */
export async function notifyUsersDevices(
  userIds: string[],
  content: PushNotificationContent,
): Promise<Map<string, PerUserOutcome>> {
  const outcome = new Map<string, PerUserOutcome>(userIds.map((id) => [id, 'no_device']));
  if (userIds.length === 0) return outcome;

  const tokenRows = await getPushTokensForUsers(userIds);
  if (tokenRows.length === 0) return outcome;

  try {
    const results = await sendMulticast(
      tokenRows.map((r) => r.token),
      content,
    );
    const tokenToUser = new Map(tokenRows.map((r) => [r.token, r.userId]));
    const invalidTokens: string[] = [];
    for (const result of results) {
      const userId = tokenToUser.get(result.token);
      if (!userId) continue;
      if (result.success) {
        outcome.set(userId, 'sent');
      } else if (outcome.get(userId) !== 'sent') {
        outcome.set(userId, 'failed');
      }
      if (result.shouldRemoveToken) invalidTokens.push(result.token);
    }
    if (invalidTokens.length > 0) {
      await removeDevicesByToken(invalidTokens);
    }
  } catch (err) {
    logger.error({ err }, 'Push notification send/cleanup failed');
    for (const userId of userIds) {
      if (outcome.get(userId) !== 'sent') outcome.set(userId, 'failed');
    }
  }
  return outcome;
}

/**
 * Pushes to every ACTIVE user's devices except `excludeUserId` — mirrors
 * the existing Firebase `sendSosNotification` Cloud Function's behavior
 * exactly (unscoped broadcast to all other registered users; see
 * docs/AUDIT.md §F). Not geographically scoped, same as today — the
 * schema doesn't store device location, and inventing a radius/scoping
 * mechanism isn't specified anywhere.
 *
 * `excludeUserId` is `null` when there is no ResQNet backend user id to
 * exclude at all — used by `notifySeismicCorroboration` below, where the
 * corroborating report only carries a Firebase Auth uid
 * (`seismic_events.userId`) with no mapping to a `users.id` (Google
 * Sign-In stores the Google `sub`, not a Firebase uid; phone sign-in
 * records no linkage either). Broadcasting to literally everyone in that
 * case is not a new behavior invented here — it's the same "not
 * geographically or otherwise scoped" broadcast this function already
 * does, just without an exclusion this caller cannot resolve.
 */
export async function notifyAllOtherActiveUsers(
  excludeUserId: string | null,
  content: PushNotificationContent,
): Promise<void> {
  const { rows } = excludeUserId
    ? await pool.query<{ id: string }>(
        "SELECT id FROM users WHERE id != $1 AND account_status = 'active'",
        [excludeUserId],
      )
    : await pool.query<{ id: string }>("SELECT id FROM users WHERE account_status = 'active'");
  if (rows.length === 0) return;
  await notifyUsersDevices(
    rows.map((r) => r.id),
    content,
  );
}

export interface SeismicCorroborationAlertInput {
  latitude: number;
  longitude: number;
  deviceCount: number;
}

/**
 * Phase 21 closure: this is what `POST /api/v1/internal/seismic-alerts`
 * (internalRoutes.ts, gated by seismicWebhookAuth.ts) calls once
 * `functions/index.js`'s `correlateSeismicEvent` Cloud Function decides a
 * seismic event is corroborated by enough nearby devices. That Cloud
 * Function still owns 100% of the detection/correlation math (clustering
 * over Firestore `seismic_events` — no Postgres equivalent exists) —
 * this replaces only its OWN direct Firestore `user_tokens` read + FCM
 * send, which has been a dead path since Phase 20 moved device-token
 * registration to `POST /api/v1/devices` (Postgres `devices`, nothing
 * writes to Firestore `user_tokens` any more). Reuses
 * `notifyAllOtherActiveUsers`/`notifyUsersDevices` exactly as SOS does —
 * no new push-sending logic, same copy the Cloud Function used to send
 * itself.
 */
export async function notifySeismicCorroboration(input: SeismicCorroborationAlertInput): Promise<void> {
  await notifyAllOtherActiveUsers(null, {
    title: '🌍 Possible earthquake detected',
    body: `Corroborated by ${input.deviceCount} ResQNet devices in the area.`,
    data: {
      latitude: String(input.latitude),
      longitude: String(input.longitude),
      deviceCount: String(input.deviceCount),
    },
  });
}
