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
- [ ] **Phase 11 — Groups/SOS migration.** `groups`/`group_members`/`sos_events`/`sos_recipients` live; parity-tested against today's `sos_dispatch` path before cutover.
- [ ] **Phase 12 — WebSocket realtime communication.** Realtime message/SOS-status delivery over the backend's WebSocket server.
- [ ] **Phase 13 — MapLibre integration/offline tiles.** Exact use case supplied by project owner before this phase starts (per instruction — do not assume it).
- [ ] **Phase 14 — Reporting system.** `user_reports`, admin-configurable threshold `X` and window `Y`.
- [ ] **Phase 15 — Employee portal.** Separate privileged surface, `SUPER_ADMIN`/`ADMIN`/`EMPLOYEE` roles, granular permission table.
- [ ] **Phase 16 — Moderation/review workflow.** Review queue, last-100-messages access (permission + active case only), full audit trail.
- [ ] **Phase 17 — Push notification migration.** FCM usage inspected first (`docs/AUDIT.md` §F) before any provider swap decision.
- [ ] **Phase 18 — Cloudflare + Hostinger deployment.** Domains, DNS, nginx (host-operator-executed), Docker Compose, GHCR, CI/CD.
- [ ] **Phase 19 — Security audit.** Full pass across auth, authorization, rate limiting, secret handling, employee-portal access control.
- [ ] **Phase 20 — Remove remaining unnecessary Firebase dependencies.** Only after each replaced service has verified parity — see removal order below.
- [ ] **Phase 21 — Production testing.** Full success-criteria checklist below, plus `flutter analyze` / `flutter test` / Android release build.

## Firebase removal order (do not remove out of sequence)

Each dependency is removed only after its replacement has verified parity in
production-like conditions — not on a fixed schedule:

1. Firebase Storage → after MinIO profile-picture parity confirmed (Phase 6)
2. Cloud Functions (`functions/index.js`) → after backend-side equivalents of
   `sendSosNotification`/`notifyTrustedContacts`/`correlateSeismicEvent` are
   live and tested (spans Phases 10-12)
3. Cloud Firestore → after all 7 collections' data/read/write paths have
   verified PostgreSQL equivalents (spans Phases 5, 10, 11)
4. Firebase Cloud Messaging → only after the push-notification architecture
   decision in Phase 17 is made and implemented
5. Firebase Authentication → last, and only after Google Sign-In V2 has been
   the sole login path in production for a verified soak period (Phase 4,
   cutover confirmed in Phase 20)
6. `firebase_core` / `firebase_options.dart` → removed only once nothing
   above still depends on them

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

## Still open — needed before Phase 18, not before Phase 1

Production domain, GitHub org (GHCR namespace), currently-free VPS port
block, and Orbyatravel's actual VPS footprint (for verifying isolation
rather than assuming it). See `docs/AUDIT.md`.
