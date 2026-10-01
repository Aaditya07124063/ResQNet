# Notifications

Every ResQNet notification goes through one pipeline. The mapping from an event to its channel, priority, deduplication key, and deep link is defined in one place, `lib/core/notifications/notification_catalog.dart`. `lib/core/services/notification_service.dart` then displays it and handles taps.

## Inventory

| Kind | Source | Title (example) | Channel / priority | Deep link | Offline | Dedup key · display slot |
| --- | --- | --- | --- | --- | --- | --- |
| Mesh SOS | Offline mesh (`MeshService.incomingMessages`) | 🚨 SOS nearby — Asha needs help | `resqnet_sos` · max | Received emergency detail | Yes, needs no internet | `sos:<eventId>` · same |
| Trusted-contact SOS | Backend push `sos_trusted_contact` (body: "Asha needs emergency assistance — open ResQNet."; never the SOS message) | 🚨 Asha needs you — SOS (medical) | `resqnet_sos` · max | Alert detail (name, category, location from the push) | Delivered by push once online | `sos:<eventId>` · same |
| Nearby SOS | Backend push `sos_nearby` (+ in-app socket banner) | 🚨 Emergency nearby | `resqnet_sos` · max | Nearby-emergency view (category + distance only) | Delivered by push once online | `sos:<eventId>` · same |
| SOS resolved | Backend push `sos_resolved`, or a verified mesh cancellation | ✅ Nearby SOS cancelled | `resqnet_updates` · default | Home, or received emergency detail | Mesh copy works offline | `sos-resolved:<eventId>` · `sos:<eventId>` (replaces the original alert) |
| Crash / earthquake auto-SOS countdown | This device's detectors | 🚗 Possible crash detected | `resqnet_emergency` · max | Home (countdown dialog) | Yes | per detection per minute; dismissed when the countdown ends |
| Earthquake alert | Backend push `earthquake_corroborated` | 🌍 Possible earthquake detected | `resqnet_alerts` · high | Alert detail (approximate area) | Delivered by push once online | per area per hour |
| Hazard / medium mesh alert | Offline mesh | ⚠️ Alert from a nearby device | `resqnet_alerts` · high | Received emergency detail | Yes | `mesh:<eventId>` |
| Low-priority mesh ("I am safe") | Offline mesh | — | not notified, shown in app only | — | — | — |
| Messages | Channel reserved (`resqnet_messages`) | — | default | Conversations | — | — (the backend does not push chat messages yet) |

## Rules

- **Priority:** only emergencies (SOS, detection countdowns) use maximum importance. Alerts are high, and updates and messages are default.
- **One alert per event:**
  - A persisted, bounded store (`NotificationDedupStore`, 300 keys, 48 h) stops the same event from notifying twice. This covers mesh + push + socket copies, reconnect re-delivery, and restarts.
  - Backend pushes for an SOS carry the Android tag / APNs collapse id `sos:<eventId>`. The app uses the same tag, so the OS-displayed push and the app's mesh notification occupy one slot. A later "resolved" update replaces the original alert.
- **Push display:**
  - When the app is backgrounded, the OS displays pushes. The background handler never re-displays them.
  - In the foreground, the OS presentation is disabled and the app displays the push itself, with dedup.
- **Untrusted payloads:** ids must be UUIDs and coordinates must be in range. Anything unrecognised opens Home.
- **Cancellations:** a mesh cancellation only produces an "all clear" when it is signed by the same key as the original SOS (`MeshService.cancellationFor(...).verified`).

## Platform setup

- **Android:** channels are created on every start (idempotent, fixed ids). `default_notification_channel_id` is `resqnet_alerts`.
- **iOS:**
  - Notification permission is requested through the app's explained permission flow, not at plugin start.
  - Emergencies use the `timeSensitive` interruption level, which only takes effect once the Time Sensitive Notifications capability is enabled in Xcode.
  - ResQNet does not claim Critical Alerts (that needs Apple's entitlement approval).
  - Push delivery on iOS also requires the Push Notifications capability (aps-environment entitlement) and an APNs key in Firebase. The repository has no entitlements file yet.
