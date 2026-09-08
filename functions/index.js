const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

// Phase 20 (Firebase removal): `sendSosNotification` (triggered on
// Firestore `sos_broadcasts/{alertId}`) and `notifyTrustedContacts`
// (triggered on Firestore `sos_dispatch/{alertId}`) have been removed.
// Both are permanently orphaned now: sos_service.dart and
// sos_dispatch_service.dart no longer write to either collection —
// SOS creation and trusted-contact push fan-out are handled server-side
// by the backend itself (`POST /api/v1/sos`, Phases 11 and 17), which
// triggers FCM sends directly via `firebase-admin` in Node rather than
// through a Firestore-triggered Cloud Function. Confirmed via
// repository-wide grep that nothing writes to `sos_broadcasts` or
// `sos_dispatch` any more before removing these.

function haversineKm(lat1, lon1, lat2, lon2) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 +
      Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// SeismicService.EarthquakeCorrelationService writes one of these per
// local seismic candidate (see
// lib/core/services/earthquake_correlation_service.dart). This clusters
// candidates the same way Seismic-Network does: multiple devices,
// reporting within a short time window, close together geographically
// — mirroring its reference numbers (3+ devices, ~50km radius, 5s
// window). This NEVER gates the local device's own alert (that already
// fired before this runs); it only raises confidence and, once
// corroborated, notifies nearby ResQNet users who haven't felt it
// themselves yet.
const SEISMIC_CORRELATION_RADIUS_KM = 50;
const SEISMIC_CORRELATION_WINDOW_MS = 5000;
const SEISMIC_MIN_DEVICES = 3;

exports.correlateSeismicEvent = functions.firestore
    .document("seismic_events/{eventId}")
    .onCreate(async (snap, context) => {
      const event = snap.data();
      if (event.latitude == null || event.longitude == null) return null;

      const eventTime = new Date(event.timestamp).getTime();
      const windowStart = new Date(eventTime - 60000).toISOString();

      const recentSnap = await admin.firestore()
          .collection("seismic_events")
          .where("timestamp", ">=", windowStart)
          .get();

      const corroborating = [];
      recentSnap.forEach((doc) => {
        if (doc.id === context.params.eventId) return;
        const other = doc.data();
        if (other.latitude == null || other.longitude == null) return;
        const timeDiff = Math.abs(new Date(other.timestamp).getTime() - eventTime);
        if (timeDiff > SEISMIC_CORRELATION_WINDOW_MS) return;
        const distKm = haversineKm(
            event.latitude, event.longitude, other.latitude, other.longitude);
        if (distKm > SEISMIC_CORRELATION_RADIUS_KM) return;
        corroborating.push({id: doc.id, userId: other.userId});
      });

      const deviceCount = corroborating.length + 1; // + this event itself

      await snap.ref.update({
        corroboratingDeviceCount: deviceCount,
        corroborated: deviceCount >= SEISMIC_MIN_DEVICES,
      });

      if (deviceCount < SEISMIC_MIN_DEVICES) return null;

      // Corroborated by enough nearby devices — notify other ResQNet
      // users so people who haven't felt it (or don't have the app open)
      // get an early local warning ahead of any official USGS/EMSC
      // report. NOTE: no device stores a location today, so this
      // broadcasts to all users rather than filtering by distance — same
      // limitation this had before.
      //
      // Phase 21 closure: this used to read Firestore `user_tokens`
      // directly and call `admin.messaging()` itself — dead since Phase
      // 20 moved device-token registration to the backend's
      // `POST /api/v1/devices` (Postgres `devices`), which nothing here
      // could read. Fixed by calling the backend's own already-built
      // device-token + FCM path instead
      // (`pushNotificationService.notifySeismicCorroboration`,
      // `POST /api/v1/internal/seismic-alerts`) — this function still
      // owns 100% of the detection/correlation math above; only the
      // "send a push" step moved, and it sends no push itself any more.
      //
      // No per-device exclusion is sent: `event.userId` (and the
      // corroborating events' `userId`s) are Firebase Auth uids, which
      // have no mapping to a backend `users.id` (Google Sign-In stores
      // the Google `sub`, not a Firebase uid; phone sign-in records no
      // linkage either) — the backend already handles a `null`/no
      // exclusion by broadcasting to every active user, matching this
      // function's own pre-existing "not scoped, broadcasts to all
      // users" behavior.
      const backendUrl = process.env.RESQNET_BACKEND_URL;
      const webhookSecret = process.env.SEISMIC_WEBHOOK_SECRET;
      if (!backendUrl || !webhookSecret) {
        console.warn("Seismic corroboration alert skipped: " +
          "RESQNET_BACKEND_URL/SEISMIC_WEBHOOK_SECRET not configured");
        return null;
      }

      try {
        const url = `${backendUrl}/api/v1/internal/seismic-alerts`;
        const response = await fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Seismic-Webhook-Secret": webhookSecret,
          },
          body: JSON.stringify({
            latitude: event.latitude,
            longitude: event.longitude,
            deviceCount,
          }),
        });
        if (!response.ok) {
          console.error(
              `Seismic alert failed: backend responded ${response.status}`);
        } else {
          console.log(`Seismic alert sent (${deviceCount} devices)`);
        }
      } catch (e) {
        // Never log `e` directly — a network-layer error object can
        // sometimes carry request headers/URLs; log only its message.
        console.error("Seismic corroboration alert failed:", e.message);
      }

      return null;
    });
