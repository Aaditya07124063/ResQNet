# ResQNet — Implementation Plan

Status: **plan/tracking document**. Checkboxes are updated as work actually
lands — see `docs/DONE.md` for the dated completion log and evidence
(tests/lint/build results) behind each checked item. Nothing below is checked
off by writing this file; this is the plan, not a claim of completion.

Order matters. Each phase should be reviewed before the next starts, per the
project rule: **AUDIT → DESIGN → REVIEW → IMPLEMENT → TEST → MIGRATE → REMOVE
OLD DEPENDENCY** — never implement → break → try to fix.

- [x] **Phase 0 — Complete audit.** See `docs/AUDIT.md`.
- [x] **Phase 1 — Architecture + PostgreSQL schema.** `backend/src/database/migrations/001_init_schema.sql`, 29 tables. Verified against a real local PostgreSQL 16 instance (all DDL applies cleanly; identity/self-report/duplicate-report constraints and `updated_at` triggers functionally confirmed) — not yet applied to a persistent/production database.
- [ ] **Phase 2 — PostgreSQL deployment.** `resqnet-db` container on the VPS, private network only, backup/restore tested before real data lands in it. Blocked on VPS/domain details (§ open questions).
- [x] **Phase 3 — Database repository/data-access layer.** `backend/src/database/pool.ts` (`pg` pool + `withTransaction`), `userService.ts`, `auditLogService.ts`. Parameterized queries only, throughout.
- [~] **Phase 4 — Google Sign-In V2 + phone sign-in.** Backend done: current official flow researched and confirmed (`google-auth-library`, `OAuth2Client.verifyIdToken()`); `googleAuthService.ts`, `sessionService.ts` (JWT access + rotating hashed refresh token), `authMiddleware.ts`, `POST /auth/google`, `/auth/refresh`, `/auth/logout`, audit-logged, tested. Flutter: added `lib/core/network/` client infra + new additive `signInWithGoogleBackend()`/`signOutBackend()` methods on `AuthService`, using the existing v6 `google_sign_in` API's idToken. **Still open, deliberately deferred**: (a) `google_sign_in` v6→v7 upgrade (the likely real meaning of "V2") — breaking API change to the working sign-in button, planned as its own isolated step; (b) wiring the new methods into the live login UI / `app.dart`'s `_AuthGate` — held back until there's a deployed backend to test against; (c) phone-OTP endpoints — depend on Phase 8/9's SMS provider system to actually deliver a code.
- [~] **Phase 5 — User/profile system.** Backend done: `profileService.ts`/`trustedContactsService.ts`, ownership-scoped CRUD routes, tests. **Not done**: applying the schema to a live database; Flutter `profile_service.dart` still on Firestore (not migrated yet — will follow once auth cutover timing is decided).
- [ ] **Phase 6 — MinIO storage.** `resqnet-minio` deployed; profile-picture upload/visibility moved off Firebase Storage.
- [ ] **Phase 7 — Email provider system.** `EmailProvider` interface + at least Zoho ZeptoMail and Brevo adapters + admin CRUD.
- [ ] **Phase 8 — SMS provider system.** `SmsProvider` interface + adapters (current official docs pulled first per provider).
- [ ] **Phase 9 — Phone/email verification.** OTP generation/expiry/attempt-limits/rate-limiting; SMS-fails-to-email fallback.
- [ ] **Phase 10 — Message migration.** `messages`/`conversations`/`message_recipients`/`message_status` live.
- [~] **Phase 11 — Groups/SOS migration.** SOS done: `sos_events`/`sos_recipients` live — `POST/GET /api/v1/sos`, `PATCH /api/v1/sos/:id` (status transitions), event-id idempotency for offline retries, trusted-contact fan-out (Phase 5) as pending SMS recipients, tests (mocked + a live-Postgres sanity run), ownership-scoped. **Groups explicitly deferred**: no group-chat/group-SOS feature exists anywhere in the Flutter app yet (`groups`/`group_members` are schema-only) — building it now would mean inventing product behavior with no spec, so it was scoped out rather than guessed (see `docs/AUDIT.md`). Not yet applied to production; Flutter SOS UI still writes to Firestore (`sos_dispatch_service.dart`/`sos_history_screen.dart`) — wiring is a later, separate step once cutover timing is decided (same reasoning as Phase 5's Flutter side).
- [~] **Phase 12 — WebSocket realtime communication.** `wsServer.ts`/`wsAuth.ts` (carried over from the pre-pivot scaffold, already JWT-authenticated) now actually deliver events: SOS creation/status-updates broadcast to the reporting user's OWN other connected devices (self-broadcast only — no new authorization surface). Deliberately NOT implemented: pushing an SOS to `sos_recipients.recipient_user_id` (other users) — the schema supports it but the channel/consent/data-shape semantics aren't specified anywhere (would collide with `sos_recipients.channel` being SMS-only today); real-time chat/message delivery — Phase 10 doesn't exist yet. See `docs/AUDIT.md`.
- [ ] **Phase 13 — MapLibre integration/offline tiles.** Exact use case supplied by project owner before this phase starts (per instruction — do not assume it).
- [~] **Phase 14 — Reporting system.** Backend done: `POST /api/v1/reports`, dedup via the existing partial-unique-index, threshold-triggered `review_cases` creation + `users.account_status` promotion to `review_required` — but only fires once `admin_settings.report_threshold`/`report_window_days` are actually configured (no seed/admin API exists yet, so this currently never fires in practice — schema-faithful, not a stub). No read endpoint added (deliberately, see `reportRoutes.ts`). Not yet applied to production; Flutter reporting UI not started.
- [~] **Phase 15 — Employee portal (backend infrastructure only).** Employee identity/login (`employees.password_hash` + bcrypt, own JWT secret pair, own `employee_sessions` table — separate identity space from consumer `users`), granular RBAC (`employee_permissions`, `SUPER_ADMIN` implicit-all-permissions bypass, `ADMIN`/`EMPLOYEE` need explicit grants), employee-account management (bootstraps the permission table — there was no other way to populate it), and `admin_settings` CRUD (unblocks Phase 14's dormant `report_threshold` logic). **Not built**: the review queue / moderation actions themselves (Phase 16's explicit job — `moderationService.ts` per `docs/AUDIT.md` §Q) and the Flutter Web employee UI (`docs/AUDIT.md`'s Decision 5 names the technology, but no employee UI of any kind exists yet and nothing in this phase's own one-line spec calls for it — see `docs/AUDIT.md`). No employee-facing SOS access was specified anywhere, so none was built.
- [~] **Phase 16 — Moderation/review workflow (review-case + moderation-action workflow; last-100-messages deferred).** `GET/POST /api/v1/employee/review-cases[/:id][/actions]` — lists/views `review_cases` (auto-opened by Phase 14's dormant threshold logic, now actually configurable via Phase 15's `admin_settings`), shows every `user_reports` row against that case's target (no `review_case_id` FK exists on `user_reports`, so this is every report ever filed against the target, not a fixed snapshot), and lets a permitted employee take a `moderation_actions` action. Every action except `escalate` closes the case, resolves all currently-open reports against the target (`dismissed` for `dismiss`, `actioned` otherwise), and — only for `suspend_temporary`/`suspend_permanent`/`delete` — flips `users.account_status` to the identically-named value the schema already enumerates (`suspended`/`deleted`; `delete` is a soft marker, never a physical row delete). `escalate` only records the action — no reassignment/routing/notification is specified anywhere, so none was built. Verified end-to-end against real Postgres: threshold-configured reports → auto-opened case → employee views it → takes action → case closes, reports resolve, account suspends, a duplicate action against the closed case is safely rejected (409). **Not built**: last-100-messages access (`MESSAGE_REVIEW` permission reserved, `message_review_access_log` table unused) — blocked on Phase 10 (chat/messages), which doesn't exist; a general raw-report browser independent of a review case (PLAN.md says "review queue", which maps to `review_cases`, not `user_reports` directly); any UI (no employee UI exists at all yet, see Phase 15's note). Permission names (`USER_VIEW`, `USER_SUSPEND`) reuse the exact vocabulary the schema's own `employee_permissions` comment proposed.
- [~] **Phase 17 — Push notification migration (backend infrastructure + SOS integration; Flutter/device testing deferred).** Decision made after inspecting `docs/AUDIT.md` §F: **keep FCM as the delivery mechanism** (already the app's only push provider; `devices.push_provider` is free-text specifically so this schema doesn't pre-commit — see its own comment), moving notification-TRIGGERING ownership from Firebase Cloud Functions to this backend (`firebase-admin`'s messaging API, called server-side). `functions/index.js` is untouched — Firebase is not removed (Phase 20's job). `POST/GET/DELETE /api/v1/devices` (own device-token CRUD, ownership-scoped). SOS integration migrates the current Firebase behavior exactly: broadcast to all other active users (mirrors `sendSosNotification`) + targeted push to trusted contacts who are ResQNet users via a new `channel='push'` `sos_recipients` row alongside the existing (unchanged) SMS row (mirrors `notifyTrustedContacts`'s intent, fixing its known phone-matching bug as a side effect of using the correct `recipient_user_id` link). **Blocked on real credentials/device**: no `FIREBASE_SERVICE_ACCOUNT_JSON` exists in this dev environment (real, sensitive, per-environment material this project can't fabricate) — the send path degrades to a safe, tested no-op; actual delivery to a real device has not been verified, matching Phase 4C's own real-device blocker. **Not built**: Flutter-side token registration/wiring (deferred, same backend-first pattern as every other phase), employee/moderation notifications (not specified anywhere, explicitly not invented), geographic scoping (schema has no device location, matches today's limitation).
- [~] **Phase 18 — CI/CD authored; production deployment NOT performed (blocked on host-operator inputs).** `.github/workflows/backend-ci.yml` (typecheck/lint/test/build + a Docker-build validation + a migration-apply-and-reapply check, on every push/PR, gates a GHCR image push on push-to-main only) and `deploy.yml` (manual-only `workflow_dispatch`, SSH + `docker/deploy.sh` + an HTTPS smoke test). `docker-compose.reference.yml`'s `api` service now deploys the CI-built image (`${RESQNET_API_IMAGE}`) instead of rebuilding from source on the host — the actual point of CI/CD. `docker/deploy.sh`/`rollback.sh` added (recreate ONLY the api container; db/minio/volumes untouched; migrations run against the live db; health-polled; rollback redeploys the previously-recorded image). Found and fixed two real production-readiness gaps while inspecting: `node:20-alpine` was past its 2026-04-30 end-of-life → bumped to `node:22-alpine` (current Active LTS); `minio/minio:latest` → pinned to `RELEASE.2025-10-15T17-29-55Z`, the last tag MinIO ever published before archiving its own GitHub repo in April 2026 (real, current finding, not assumed — see docs/DONE.md). **Deployment itself did not happen**: the VPS IP, GHCR namespace (GitHub org/repo), free port, and domain/DNS are still the exact open items this section already listed below, and this environment has no SSH access to any VPS at all — `deploy.yml` is authored and ready but was never triggered.
- [x] **Phase 19 — Security audit.** Fresh code inspection across all 12 required categories (see docs/DONE.md for the full findings table). No CRITICAL/HIGH found. Fixed: JWT `algorithms`/`algorithm` pinned explicitly (both consumer and employee token verify/sign); a real account-status-downgrade bug in `moderationService.ts` (a later, less-severe action on a new case could un-delete an already-deleted account back to merely suspended); WebSocket `maxPayload` (was unset, defaulting to 100MiB); a from-scratch in-memory rate limiter for the WebSocket upgrade path (previously completely unlimited — it runs outside Express, below every existing rate limiter). 7 new regression tests. Documented, not force-fixed: several moderate `npm audit` findings transitively pulled in by `express`/`minio`/`firebase-admin` with no available non-breaking upgrade path.
- [~] **Phase 20 — Firebase removal (every feature with a real backend equivalent migrated; genuinely un-migratable pieces documented as gaps, not invented around).** Flutter cut over to backend REST for: profile (`profile_service.dart` → `GET/PUT /api/v1/profile`), trusted contacts (`trusted_contacts_service.dart` → `GET/POST/PUT/DELETE /api/v1/profile/trusted-contacts`), profile picture (`profile_screen.dart` → `PUT/GET /api/v1/profile/image`, MinIO signed URLs replacing permanent Firebase Storage URLs), SOS creation/history (`sos_service.dart`/`sos_history_screen.dart` → `POST/GET /api/v1/sos`; SOS-history delete/clear-all removed — no backend DELETE endpoint exists, by Phase 11's own deliberate audit-trail design), device push-token registration (`notification_service.dart` → `POST /api/v1/devices`, superseding Firestore `user_tokens/{uid}`). Removed: `firebase_storage` package (confirmed unused after the profile-picture migration; `flutter pub get` removed exactly its 3 packages, nothing else); `lib/core/services/firebase_service.dart` (a pure stub, confirmed unused); the dead pre-Phase-4C `signInWithGoogle()` method on `AuthService`; `functions/index.js`'s `sendSosNotification`/`notifyTrustedContacts` Cloud Functions (both permanently orphaned — nothing writes to their Firestore trigger collections `sos_broadcasts`/`sos_dispatch` any more). **Firebase is NOT fully removed — cannot be, given what's actually built** (this is Phase 20's own central, honest finding, not a shortfall to silently work around): (1) phone-OTP login (`AuthService.sendOtp`/`verifyOtp`) has zero backend replacement — Phase 8/9's SMS provider system was never built; (2) `firebase_messaging` is structurally required client-side to receive FCM pushes and obtain device tokens regardless of who triggers sends server-side (Phase 17 already decided to keep FCM as the provider); (3) `earthquake_correlation_service.dart`'s Firestore `seismic_events` collection has no Postgres/backend equivalent (no such table was ever speced); (4) `firebase_core`/`firebase_options.dart` bootstrap all of the above. A real, new side-effect gap surfaced by this phase's own device-token migration: `functions/index.js`'s `correlateSeismicEvent` (kept — still needed for #3) reads Firestore `user_tokens` to notify nearby users once an earthquake is corroborated; since device tokens now live in backend Postgres instead, that read now finds nothing and the notify-fanout step silently no-ops — the correlation math itself (writing `corroboratingDeviceCount`/`corroborated` back onto the Firestore event for the app to read) is unaffected. Documented in code and here, not fixed (would require either exposing backend device tokens to Cloud Functions or migrating seismic correlation off Firestore, neither of which is specified). Also NOT touched (deliberately, out of this phase's scope): `mesh_screen.dart`/`dashboard_screen.dart`'s remaining `FirebaseAuth.instance.currentUser?.uid ?? 'anonymous'` reads for mesh message `senderId` — a pre-existing identity-resolution gap for backend-Google-authenticated users, same shape as the still-unapproved Phase 4C/4D work, not something this phase's scope required touching. Verified: `flutter analyze` 62 issues (down from the ~64 baseline, zero new — all remaining are pre-existing `withOpacity`/`prefer_const_constructors`/deprecation infos and 2 known pre-existing warnings), `flutter test` 85/85 passing, `flutter build apk --debug` succeeds, backend `npm test` 310/310 / `typecheck`/`lint`/`build` all clean (unchanged — no backend file touched), repo-wide grep confirms every remaining Flutter Firebase import has a documented, still-necessary reason. See docs/DONE.md for full detail.
- [x] **Phase 21 closure — Seismic push path fixed.** `functions/index.js`'s `correlateSeismicEvent` no longer reads Firestore `user_tokens` (removed entirely) — once corroborated, it now calls the new `POST /api/v1/internal/seismic-alerts` (backend, webhook-secret-gated: `seismicWebhookAuth.ts`, `SEISMIC_WEBHOOK_SECRET`), which calls `pushNotificationService.notifySeismicCorroboration()` — a thin composer reusing `notifyAllOtherActiveUsers`/`notifyUsersDevices` (Phase 17, unchanged) against real Postgres `devices` rows. `notifyAllOtherActiveUsers`'s `excludeUserId` now accepts `null` (broadcast to all active users, no exclusion) for this caller specifically, since `seismic_events.userId` is a Firebase Auth uid with no mapping to a backend `users.id` — a disclosed simplification, not an invented behavior (matches the function's own pre-existing "not geographically or otherwise scoped" broadcast). Detection/correlation math untouched. 13 new backend tests (`seismicWebhookAuth.test.ts`, `internalRoutes.test.ts`, 3 added to `pushNotificationService.test.ts`); found and fixed a real secret-logging leak during live verification (`app.ts`'s `pinoHttp` has its OWN `redact` option, separate from `logger.ts`'s — the webhook secret header was appearing in cleartext in the HTTP access log until added there too). 328/328 backend tests, typecheck/lint/build all clean; `functions/index.js` still 2 pre-existing lint issues, zero new. See docs/DONE.md.
- [~] **Phase 21 — Final comprehensive testing.** Full-repo, from-scratch validation across 21 subsystems against a real local Postgres + a real running backend server (not just mocked unit tests) — see docs/DONE.md for the full subsystem-by-subsystem table. One real bug found and fixed: `errorHandler.ts` mapped a malformed-JSON request body to a leaking, miscategorized 500 instead of 400 (body-parser's `entity.parse.failed` had no case, unlike its sibling `entity.too.large`) — fixed, regression-tested (4 new tests), reverified live. Everything else already built passed as designed: profile/trusted-contacts/devices/SOS CRUD + IDOR (cross-user 404s) live-tested against real Postgres; SOS idempotency (duplicate `eventId` retry returns the same event) confirmed live; SOS-specific rate limiting (5/60s) confirmed live (6th request 429s); WebSocket `sos_created` self-delivery confirmed live over a real socket; the full reporting→threshold→review-case→employee-RBAC→moderation-action→account-suspension pipeline confirmed live end-to-end against real Postgres, including a negative RBAC check (action correctly 403s once `USER_SUSPEND` is revoked, 201s once restored); both migrations re-applied idempotently against the live dev database. Still genuinely **NOT VERIFIED** (real device/credentials/production access required, none available in this sandbox, unchanged from every prior phase's identical disclosure): Phase 4C's Google ID-token audience check on a real Android device; Phase 17's actual FCM delivery to a real device (no `FIREBASE_SERVICE_ACCOUNT_JSON` exists here); actual Docker image build/push and VPS deployment/rollback execution (scripts and YAML are syntax-valid and logic-reviewed, never run against real infra). One finding corrected from the Phase 20 report: `functions/index.js`'s `correlateSeismicEvent` still genuinely depends on the now-unpopulated Firestore `user_tokens` collection for its nearby-user push step (documented as a gap in Phase 20, confirmed still true and still NOT fixed here — inventing a fix would mean building new, unspecified backend-to-Cloud-Functions infrastructure, out of scope for a testing-only phase). Dependency advisories unchanged: same 13 moderate `npm audit` findings as Phase 19, still no safe non-breaking fix path.

## Firebase removal order (do not remove out of sequence)

Each dependency is removed only after its replacement has verified parity in
production-like conditions — not on a fixed schedule. Updated 2026-09-06
(Phase 20) with what actually landed vs. what's still structurally blocked:

1. Firebase Storage → **done** (`firebase_storage` package removed from
   `pubspec.yaml`; `profile_screen.dart` now uploads via
   `PUT /api/v1/profile/image`, MinIO/Phase 6).
2. Cloud Functions (`functions/index.js`) → **partially done**.
   `sendSosNotification`/`notifyTrustedContacts` removed (orphaned once
   `sos_service.dart`/`sos_dispatch_service.dart` stopped writing to their
   Firestore trigger collections — Phases 11/17/20). `correlateSeismicEvent`
   **stays** — no backend/Postgres equivalent for seismic correlation was
   ever built (Phase 10/13 never covered this), so its Firestore
   `seismic_events` trigger is still required. Its own detection/
   correlation math is unchanged. Its notify-nearby-users push step —
   previously a functional no-op reading the now-defunct Firestore
   `user_tokens` (Phase 20 finding) — was fixed in the Phase 21 closure:
   it now calls the backend's own `POST /api/v1/internal/seismic-alerts`
   (webhook-secret-gated), which reuses `notifyAllOtherActiveUsers`/
   `notifyUsersDevices` (Phase 17, unchanged) against real Postgres
   `devices` rows. See docs/DONE.md's "Phase 21 closure" entry.
3. Cloud Firestore → **partially done**. `user_profiles`, trusted-contacts
   subcollection, `sos_history`, `sos_dispatch`, `sos_broadcasts`,
   `user_tokens` (write side) all migrated off Firestore onto Postgres/the
   backend. `seismic_events` **cannot** move — no backend equivalent exists
   (see #2). `cloud_firestore` therefore stays a real Flutter dependency,
   used by exactly one file (`earthquake_correlation_service.dart`).
4. Firebase Cloud Messaging → **kept, by design** (Phase 17's decision
   stands: FCM remains the delivery provider). `firebase_messaging` is a
   structural client-side requirement (receiving pushes, obtaining device
   tokens) independent of who triggers sends — this was never going to be
   removable under the current architecture, not a Phase 20 shortfall.
5. Firebase Authentication → **cannot be removed**. Google Sign-In V2 is
   already the primary path (`signInWithGoogleBackend()`, Phase 4C — still
   not device-verified, see its own open item), but `firebase_auth` is also
   the sole mechanism for phone-OTP login (`AuthService.sendOtp`/
   `verifyOtp`), which has no backend replacement (Phase 8/9's SMS provider
   system was never built). Removing `firebase_auth` today would delete
   phone login entirely — not attempted, per Phase 20's own instruction not
   to invent a replacement for a feature with no spec/backend equivalent.
6. `firebase_core` / `firebase_options.dart` → **stays**, since #3, #4, and
   #5 above all still genuinely depend on it.

## Success criteria

### Authentication
- [ ] Google Sign-In V2 works
- [ ] Server verifies Google credentials
- [ ] Users stored in PostgreSQL
- [ ] Firebase Auth not required

### Database
- [ ] PostgreSQL stores users
- [ ] PostgreSQL stores messages
- [ ] PostgreSQL stores groups
- [ ] PostgreSQL stores SOS events
- [ ] PostgreSQL stores reports
- [ ] PostgreSQL stores moderation records
- [ ] Firestore not required

### Storage
- [ ] MinIO stores profile pictures
- [ ] MinIO stores attachments where required
- [ ] Firebase Storage not required
- [ ] Profile-picture privacy enforced server-side

### Email
- [ ] Multiple email providers supported
- [ ] Admin can add providers
- [ ] Admin can enable/disable providers
- [ ] Provider priority supported
- [ ] Provider fallback supported
- [ ] Secrets protected

### SMS
- [ ] Multiple SMS providers supported
- [ ] Sparrow supported if its current API permits
- [ ] MSG91/SMS91 supported
- [ ] 2Factor supported where appropriate
- [ ] SMSCountry supported where appropriate
- [ ] Provider-specific credentials supported
- [ ] SMS fallback supported
- [ ] Email fallback supported

### Maps
- [ ] MapLibre used
- [ ] Tile source is replaceable
- [ ] Offline/downloadable tile architecture supported
- [ ] No unnecessary Google Maps dependency

### Moderation
- [ ] User reporting works
- [ ] Admin defines report threshold X
- [ ] Threshold triggers REVIEW_REQUIRED
- [ ] Employee review queue works
- [ ] Employee can review authorized users
- [ ] Last 100 messages available only for authorized review cases
- [ ] Employee can suspend/delete according to permission
- [ ] Every moderation action audited

### Hosting
- [ ] Hostinger VPS
- [ ] Cloudflare
- [ ] Nginx
- [ ] Docker
- [ ] Dedicated ResQNet network
- [ ] Dedicated ResQNet containers
- [ ] Dedicated volumes
- [ ] PostgreSQL private
- [ ] MinIO private

### Isolation
- [ ] No Orbyatravel dependency
- [ ] No Orbyatravel database sharing
- [ ] No Orbyatravel Docker network sharing
- [ ] No Orbyatravel MinIO sharing
- [ ] No Orbyatravel secrets sharing
- [ ] No Orbyatravel nginx modifications
- [ ] No Orbyatravel deployment changes

## Decisions (resolved 2026-09-04 — see `docs/AUDIT.md` "Decisions")

Full replacement of the old plan; old `backend/` deleted; Firebase App Check
dropped; phone sign-in kept as an independent login method alongside Google
Sign-In V2 (Phase 4 covers both); Employee Portal on Flutter Web (Phase 15);
JWT access+refresh session model (Phase 4).

Domain deferred until app store / Play Store submission — VPS testing uses
direct IP:port over HTTP instead (`ResQNetEnvironment.vps` in
`lib/core/network/api_config.dart`); `production` still requires a real
HTTPS domain before it will resolve.

## Still open — needed before Phase 18, not before Phase 1

GitHub org (GHCR namespace), the VPS's actual IP address, currently-free VPS
port block, and Orbyatravel's actual VPS footprint (for verifying isolation
rather than assuming it). See `docs/AUDIT.md`.
