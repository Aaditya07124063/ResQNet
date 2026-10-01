# ResQNet feature status

Audited from the code, not from documentation. "Automated" means unit, widget, or simulated tests only — none of it proves real radio, SMS, push, iOS, or production behaviour.

**Statuses:**

- **WORKING:** implemented, tested, and nothing physical left to prove.
- **PARTIAL:** some of the feature exists.
- **MISSING:** not implemented.
- **PHYSICAL-TEST-REQUIRED:** implemented and automated-tested, but needs real devices.
- **PRODUCTION-UNVERIFIED:** implemented, but depends on production configuration or deployment.

| # | Feature | Status | Evidence | Action |
|---|---|---|---|---|
| 1 | One-tap SOS | WORKING | `features/home/widgets/sos_home_panel.dart`, `sos_actions.dart`; `test/home_sos_widget_test.dart` | — |
| 2 | SOS countdown | WORKING | `SosCountdownDialog` (5 s, send now, cancel); widget tests | — |
| 3 | SOS cancellation | WORKING (local + mesh) / PRODUCTION-UNVERIFIED (server) | `SosService.cancelActiveSos`, `sos_resolution_sync.dart`, `PATCH /sos/:id` accepts eventId; `test/sos_lifecycle_test.dart` | Deploy backend |
| 4 | No-sign-in SOS | WORKING (mesh + SMS path) | `features/emergency/emergency_access_screen.dart` | — |
| 5 | GPS | PHYSICAL-TEST-REQUIRED | `LocationService` (status, best-effort fix) | Field test |
| 6 | SOS offline storage | WORKING | `EmergencyOutboxStore` (persisted before any transport) | — |
| 7 | SOS mesh broadcast | PHYSICAL-TEST-REQUIRED | `MeshService.broadcastMessage(retainForNewPeers)`; `test/mesh_sos_delivery_test.dart` | Physical test plan |
| 8 | SOS mesh relay | PHYSICAL-TEST-REQUIRED | relay queue + hop increment; `test/mesh_multi_device_test.dart` | Physical test plan |
| 9 | SOS store-and-forward | PHYSICAL-TEST-REQUIRED | **New:** `MeshRelayStore` — relays keep others' events and forward to peers that connect later; `test/store_and_forward_chain_test.dart` (A→E simulated) | Physical test plan |
| 10 | Mesh deduplication | WORKING (logic) | in-memory + persisted ledger, race-safe; tests | — |
| 11 | Mesh persistence | WORKING (logic) | dedup ledger, own outbox, **new** relay store survive restart | — |
| 12 | Mesh hop limits | WORKING (logic) | signed `maxHops`, loop avoidance via relay path; tests | — |
| 13 | Online gateway sync | PHYSICAL-TEST-REQUIRED / PRODUCTION-UNVERIFIED | **New:** `EmergencyCommunicationService._uploadRelayedEvents` → `POST /sos` with origin envelope (backend verifies signature, attributes to origin) | Physical + production test |
| 14 | Ordinary messaging (1:1) | PARTIAL | `CommunicationService` + `/conversations` (online, idempotent `client_message_id`, persisted outbox, WebSocket) | — |
| 15 | Offline messaging | MISSING | chat messages never use the mesh; they wait in the outbox for Internet | Transport abstraction (future) |
| 16–18 | Groups: create / membership / messaging | PRODUCTION-UNVERIFIED | `/api/v1/groups` (owner/admin/member roles, add only your trusted contacts who use ResQNet, leave, audit log) + migration 006; group chat reuses conversations/messages; app `GroupsScreen`/`GroupDetailScreen`; **owner leaves by transferring ownership first** (`POST /groups/:id/owner`, app button); unit + real-PostgreSQL tests | Deploy migration 006 |
| 19 | Emergency group | MISSING | — | After groups |
| 20 | Message priority | PARTIAL | mesh relay queue and outbox sync are priority-ordered; chat has no priority | — |
| 21 | Message acknowledgements | PARTIAL | chat delivered/read status route; no mesh-level ACK | — |
| 22 | WebSocket | PRODUCTION-UNVERIFIED | `backend/src/websocket/wsServer.ts`, `ResQNetWebSocketClient` | — |
| 23 | Push notifications | PRODUCTION-UNVERIFIED | FCM via backend `fcm.ts`; app Firebase options were registered for the old package id — must be verified on a device | Device test |
| 24 | Crash detection | PHYSICAL-TEST-REQUIRED | `CrashDetectionService` + countdown; detector score is not a validated probability | Field test |
| 25 | Earthquake detection | PHYSICAL-TEST-REQUIRED | `SeismicService`; backend corroboration `POST /seismic/reports` (migration 005, not deployed) | Field test + deploy |
| 26 | Hazard events | PARTIAL | `HazardService`; server alerts on the map with source labels; a hazard relayed over the mesh keeps an official label **only if its server signature verifies** (pinned P-256 key), with replay protection; `test/alert_signature_test.dart` | Physical mesh test |
| 27 | Emergency map | PARTIAL | `flutter_map` screen with hazards, safe zones, SOS | — |
| 28 | Offline map | PARTIAL — licensing blocker | viewed-tile cache works; **changed:** region download and automatic prefetch are disabled unless a licensed tile source is configured, because the OSM tile policy prohibits offline use of `tile.openstreetmap.org` | Licensed tiles or ResQNet-hosted Nepal package |
| 29 | Offline routing | MISSING | only manually drawn "safe routes" | See `docs/OFFLINE_MAPS_AND_ROUTING.md` |
| 30 | Emergency map overlays | PARTIAL | hazards/safe zones/SOS markers; no source/expiry labels from a backend | — |
| 31 | Disaster feeds | PARTIAL | adapter architecture + ingestion (`disasterSources.ts`) with provenance (`source_url`, `retrieved_at`, `international_public` type; migration 009); ingestion verified on real PostgreSQL; **no source connected** (none verified) — see `docs/DISASTER_SOURCES.md` | Verify sources |
| 32 | Official-source labeling | WORKING (logic) / PRODUCTION-UNVERIFIED | `source_type` on every alert (official / verified partner / public international / ResQNet / community / sensor); official only when fetched from the server or when the server signature verifies offline; cross-language fixture tests | Set `OFFICIAL_ALERT_SIGNING_KEY` + app `RESQNET_ALERT_PUBLIC_KEY` |
| 33 | Government portal | MISSING | — | Future phase |
| 34 | Responder portal | PARTIAL — portal UI built, not deployed or physically verified | employee login, permissions, SMS provider admin in the app; incident queue + responder workflow API (`/api/v1/employee/incidents`): enforced state machine (reported → acknowledged → assigned → en route → arrived → assisting → resolved, reassignment, stand-down with a reason; resolved/stood-down are terminal); the queue keeps an incident until a responder closes it, even if the reporter marks themselves safe or cancels (shown as `civilianState` and on the timeline); cursor pagination; `SOS_MONITOR`/`SOS_RESPOND`/`SOS_ASSIGN`; database CHECKs for assignment integrity (migrations 008, 010); unit + real-PostgreSQL tests; **new:** operations portal (Flutter; mobile app and a web build via `lib/main_operations.dart`): dashboard, queue, detail and workflow, assignment, map, alerts, disaster sources, responders, SMS providers, audit log, all permission-aware; widget tests; **not deployed, no realtime/push to staff, not tested with real screen readers** | Portal UI; deploy |
| 35 | RBAC | PARTIAL | roles super_admin/admin/employee + per-permission grants; enforced server-side | Authority roles |
| 36 | Audit logging | WORKING | `audit_logs`, `recordAuditEvent` on employee/admin actions | — |
| 37 | Organization management | MISSING | — | — |
| 38 | Emergency (official) alerts | PRODUCTION-UNVERIFIED (API only) | migration 007, `POST/PATCH /api/v1/employee/alerts` with per-source publish permissions and audit log, public `GET /api/v1/alerts` (signed when a key is configured); no portal UI yet. `GET /alerts` serves active alerts only, so phones offline when an alert is resolved keep showing it until it expires | Portal UI; deploy |
| 39 | SMS | PRODUCTION-UNVERIFIED | provider registry, encrypted credentials, fallback; no real provider configured | Credentials + test send |
| 40 | Website | PARTIAL | Next.js site, SEO, no range/partner claims; interactive store-and-forward demo on /how-it-works labelled "Interactive simulation — not a live emergency network."; security headers documented (server-side, not in repo); full redesign not done | Redesign; headers on server |
| 41 | Security | PARTIAL | JWT + rotating refresh, signed mesh origin, rate limits, RBAC, encrypted provider creds; no mesh payload encryption | — |
| 42 | Privacy / data retention | PARTIAL — implemented, CONFIGURATION REQUIRED | nearby **push** recipients see category + approximate distance only; phones receiving an SOS over the mesh see name, message and exact location (signed, not encrypted); trusted-contact pushes are generic; ordinary mesh messages carry no medical data; medical details only via the opt-in (off by default, reset on sign-out) automatic-SOS setting, inside the signed message; data inventory and retention policy (`docs/PRIVACY_AND_RETENTION.md`); retention job (migration 011, `services/retention/`: SOS personal data redacted 90 d after closure, de-identified at 730 d, sessions, OTP, nearby, seismic, chat location, devices, keys, audit IP/entries, alerts; bounded, idempotent, locked, dry-run); read-time masking; retention hold; account deletion API (no app screen); sign-out clears personal caches; local expiry of outbox and sensor recordings; real-PostgreSQL tests | Schedule the job (gated first run); product/legal decisions listed in the doc |
| 43 | Android | PHYSICAL-TEST-REQUIRED | debug APK builds (`com.resqnet.app`) | Device testing |
| 44 | iOS | UNTESTED | MultipeerConnectivity plugin exists; no Xcode/CocoaPods in this environment; `UIBackgroundModes` has only `fetch` (no background mesh) | Xcode build + devices |
| 45 | Automated testing | WORKING | Flutter + backend unit suites; **new:** opt-in real-PostgreSQL suite (`npm run test:integration`) covering seismic, groups, alerts/adapters, relayed SOS, incidents, OTP, SMS providers; migrations verified clean, rerun, upgrade and failure rollback | — |
| 46 | Physical testing | NOT PERFORMED | `docs/PHYSICAL_TEST_PLAN.md` | Run it |

## Platform limitations known from the code

- **Android** uses Google Nearby Connections (`P2P_CLUSTER`). Detection keeps running in a foreground service. Mesh discovery while the app is backgrounded depends on OS power management and must be measured.
- **iOS** uses MultipeerConnectivity with no background mode for it. Expect mesh to work only while ResQNet is in the foreground.
- **Range** depends on hardware, radio conditions, OS behaviour, terrain, and interference. No range is claimed anywhere until it has been measured in field tests.
