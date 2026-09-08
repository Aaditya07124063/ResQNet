import { cert, initializeApp, type App, type ServiceAccount } from 'firebase-admin/app';
import { getMessaging, type SendResponse } from 'firebase-admin/messaging';
import { env } from '../config/env';
import { logger } from '../utils/logger';

/**
 * Thin wrapper around the Firebase Admin SDK's messaging API — the
 * official, current Google-supported way to send FCM notifications from
 * a Node.js server (docs/AUDIT.md §F confirms FCM is already this app's
 * only push provider; this is not introducing a new one, just moving who
 * calls it from Firebase Cloud Functions to this backend). Uses the
 * modular `firebase-admin/app` and `firebase-admin/messaging` submodule
 * imports — the namespaced `admin.app`/`admin.credential` style from
 * older versions is not exported by the currently installed v14.
 *
 * Initialization is lazy and NEVER throws at module load / app boot —
 * FIREBASE_SERVICE_ACCOUNT_JSON is real, sensitive, per-environment
 * credential material this project has no way to fabricate for local
 * dev, so every caller in this file degrades to a safe, logged no-op
 * when it's absent, exactly like storageService.ts's MinIO client would
 * fail loudly only when actually used, not at import time.
 */

let app: App | null | undefined; // undefined = not yet attempted

function getApp(): App | null {
  if (app !== undefined) return app;

  if (!env.FIREBASE_SERVICE_ACCOUNT_JSON) {
    logger.warn('FIREBASE_SERVICE_ACCOUNT_JSON is not configured — push notifications are disabled (no-op)');
    app = null;
    return app;
  }

  try {
    const serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT_JSON) as ServiceAccount;
    app = initializeApp({ credential: cert(serviceAccount) });
  } catch {
    // Never log the caught error directly here — a JSON.parse failure on
    // a malformed credential string could include fragments of the
    // credential in its message. Log only that initialization failed.
    logger.error('Firebase Admin SDK initialization failed — push notifications are disabled (no-op)');
    app = null;
  }
  return app;
}

export interface PushNotificationContent {
  title: string;
  body: string;
  data?: Record<string, string>;
}

export interface TokenSendResult {
  token: string;
  success: boolean;
  /** True when FCM reports the token itself as invalid/unregistered —
   * the caller should delete the corresponding `devices` row. False for
   * any other kind of failure (transient/provider-side), which should
   * NOT cause a token to be deleted. */
  shouldRemoveToken: boolean;
}

// FCM's own hard limit per sendEachForMulticast call.
const FCM_MAX_TOKENS_PER_CALL = 500;

function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) chunks.push(items.slice(i, i + size));
  return chunks;
}

function toTokenResults(tokenChunk: string[], responses: SendResponse[]): TokenSendResult[] {
  return responses.map((r, i) => {
    const token = tokenChunk[i]!;
    if (r.success) return { token, success: true, shouldRemoveToken: false };
    const code = r.error?.code;
    const shouldRemoveToken =
      code === 'messaging/registration-token-not-registered' || code === 'messaging/invalid-registration-token';
    return { token, success: false, shouldRemoveToken };
  });
}

/**
 * Sends one notification to up to many device tokens, chunked to FCM's
 * 500-tokens-per-call limit. Never throws — a provider outage or missing
 * configuration must never corrupt/interrupt the caller's own state
 * (e.g. an SOS event that was already successfully recorded). Returns a
 * per-token result so callers can clean up tokens FCM reports as
 * permanently invalid, without guessing at FCM's error taxonomy itself.
 */
export async function sendMulticast(tokens: string[], content: PushNotificationContent): Promise<TokenSendResult[]> {
  if (tokens.length === 0) return [];

  const firebaseApp = getApp();
  if (!firebaseApp) {
    // Not configured — every token is reported as a (non-removable)
    // failure so callers' own success/failure accounting stays honest
    // rather than silently claiming delivery that never happened.
    return tokens.map((token) => ({ token, success: false, shouldRemoveToken: false }));
  }

  const results: TokenSendResult[] = [];
  for (const tokenChunk of chunk(tokens, FCM_MAX_TOKENS_PER_CALL)) {
    try {
      const response = await getMessaging(firebaseApp).sendEachForMulticast({
        notification: { title: content.title, body: content.body },
        data: content.data,
        tokens: tokenChunk,
      });
      results.push(...toTokenResults(tokenChunk, response.responses));
    } catch (err) {
      logger.error({ err }, 'FCM sendEachForMulticast call failed for a batch of tokens');
      for (const token of tokenChunk) results.push({ token, success: false, shouldRemoveToken: false });
    }
  }
  return results;
}
