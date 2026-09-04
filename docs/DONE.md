# ResQNet — Completion Log

Dated record of what has actually been built and verified, most recent
first. Only entries backed by a real test/build/lint result go here — this is
evidence, not intent (intent lives in `docs/PLAN.md`).

---

## 2026-09-04 — Phase 1 schema + Phase 2/3 backend foundation + Phase 4 (Google Sign-In V2 backend half)

- **Phase 1 — PostgreSQL schema**: `backend/src/database/migrations/001_init_schema.sql`.
  29 tables: identity (`users`, `devices`, `sessions`, `verification_attempts`),
  profile (`user_profiles`, `trusted_contacts`), Communicate
  (`groups`, `group_members`, `conversations`, `conversation_participants`,
  `messages`, `message_recipients`, `message_status`), SOS/location/incidents
  (`sos_events`, `sos_recipients`, `locations`, `incidents`,
  `official_alerts`), Employee Portal (`employees`, `employee_permissions`,
  `user_reports`, `review_cases`, `moderation_actions`, `employee_actions`,
  `message_review_access_log`), providers/config (`email_providers`,
  `sms_providers`, `admin_settings`), audit (`audit_logs`). Employees are a
  separate identity space from `users` by design. Not yet applied to a real
  database (no PostgreSQL instance provisioned yet).
- **Phase 2/3 — backend foundation**: fresh `backend/` (Express + TypeScript
  + `pg`), reusing the general Express/logging/rate-limiting/error-handling
  shape from the deleted MySQL scaffold but with every auth/DB-specific
  piece rewritten. Verified: `npm run typecheck`, `npm run lint`, `npm run
  build` all pass clean.
- **Phase 4 (backend half) — Google Sign-In V2 verification + session
  issuance**: researched current official guidance first (see below) rather
  than assuming — `google-auth-library`'s `OAuth2Client.verifyIdToken()`
  confirmed as the current recommended server-side verification method,
  checking signature/`aud`/`iss`/`exp`, keyed on the `sub` claim (not
  email). Implemented: `googleAuthService.ts` (token verification),
  `sessionService.ts` (JWT access token + hashed, rotating refresh token in
  `sessions`), `authMiddleware.ts` (`requireAuth`, replaces the old Firebase
  version), `POST /api/v1/auth/google`, `POST /api/v1/auth/refresh`,
  `POST /api/v1/auth/logout`, all rate-limited and audit-logged
  (`audit_logs` via `auditLogService.ts`). WebSocket upgrade auth
  (`wsAuth.ts`) updated to verify the same ResQNet access token.
  **Phone-OTP sign-in intentionally deferred** — it needs the SMS provider
  system (Phase 8/9) to actually deliver a code; building a stub now would
  mean silently no-op'ing or logging OTPs, both disallowed. Documented in
  `docs/PLAN.md`.
- **Research performed** (per the project's "research current official docs
  first" rule): confirmed the current `google_sign_in` Flutter package major
  version is 7.x (a rewrite from v6 — this is almost certainly what "Google
  Sign-In V2" refers to in the architecture spec) and that
  `google-auth-library`'s `verifyIdToken()` is Google's current official
  Node.js server-side verification method. Sources: pub.dev `google_sign_in`
  package page, `developers.google.com/identity/gsi/web/guides/verify-google-id-token`.
- Not yet done at this point: Flutter-side changes, MinIO/email/SMS/employee-portal/messages/SOS
  API routes (later phases), actual PostgreSQL instance provisioning.

## 2026-09-04 — Phase 5 (profile/trusted contacts) + Flutter half of Phase 4

- **Phase 5 — profile/trusted contacts API**: `profileService.ts`,
  `trustedContactsService.ts`, `GET/PUT /api/v1/profile`,
  `GET/POST/PUT/DELETE /api/v1/profile/trusted-contacts`. Every query is
  scoped to `req.authUser.id` server-side — no route accepts a
  client-supplied target user id (matches docs/AUDIT.md §7's authorization
  requirement structurally, not just by convention). Ownership violations
  (updating/deleting another user's contact) return 404, not 403, to avoid
  confirming another user's resource exists.
- **Backend test suite added**: 38 tests across `sessionService`,
  `googleAuthService`, `authMiddleware`, `authRoutes`, `profileRoutes` —
  all mocked (no live Postgres/Google dependency), covering: missing/malformed/invalid/expired
  token → deny; suspended/deleted account → deny; refresh token
  rotation/invalidation; invalid request bodies → 400; cross-user
  IDOR attempts → 404. All pass; `typecheck`/`lint` clean.
- **Flutter half of Phase 4**: added `lib/core/network/` (`api_config.dart`,
  `api_client.dart`, `api_exception.dart`, `token_storage.dart` — the last
  using `flutter_secure_storage`, added as a new pubspec dependency after
  resolving a `share_plus`/`win32` version conflict by bumping to
  `^11.0.0`). Added two **new, additive** methods to `auth_service.dart`
  (`signInWithGoogleBackend()`, `signOutBackend()`) that call the new
  backend's `/auth/google` and `/auth/logout` using the **same** Google
  `idToken` the existing v6 `google_sign_in` API already retrieves.
  **Deliberately did not touch** the existing `signInWithGoogle()`,
  `signOut()`, phone-OTP methods, `app.dart`'s `_AuthGate`, or
  `login_screen.dart` — those still run entirely on Firebase, unchanged.
  Verified: `flutter analyze` (0 new issues — all 64 pre-existing, none in
  new/touched files), `flutter test` (all 48 existing tests still pass).
- **Two things explicitly deferred, not forgotten**:
  1. Upgrading `google_sign_in` from v6 to v7+ (the likely actual meaning
     of "Google Sign-In V2") is a breaking API change to the working sign-in
     button and is being done as its own isolated, tested step — not bundled
     with the backend-verification change.
  2. Wiring the new backend auth path into the live login UI / `_AuthGate`
     is being held back because there is no deployed backend yet to test
     against (open VPS/domain questions) — implementing untested code into
     the safety-critical auth gate was judged not worth the risk yet.

## 2026-09-04 — Architecture decisions resolved; old backend deleted

- All 6 architecture-scope open questions from the Phase 0 audit answered:
  full replacement (no Firebase/MySQL transition period), old `backend/`
  scaffold deleted, Firebase App Check dropped, phone sign-in kept as an
  independent login method alongside Google Sign-In V2, Employee Portal on
  Flutter Web, JWT access+refresh session model. Recorded in
  `docs/AUDIT.md`'s "Decisions" section.
- `backend/` (the MySQL/Firebase-auth scaffold from the prior plan) deleted
  from disk — verified fully untracked in git first (`git status --short
  backend/` → `?? backend/`), so no history was lost.
- Two items remain open (production domain, GitHub org, VPS port block;
  Orbyatravel's actual VPS footprint) — not blocking for Phases 1-4, needed
  before Phase 18.

## 2026-09-04 — Phase 0: Complete audit (current architecture)

- Read-only repository + infrastructure audit performed against the target
  architecture in `docs/ARCHITECTURE.md`. No app or backend code modified.
- Output: `docs/AUDIT.md` (sections A-X), `docs/ARCHITECTURE.md`,
  `docs/PLAN.md`, this file.
- Key finding requiring a decision before Phase 1: this architecture
  (Google Sign-In V2 / PostgreSQL / MinIO / MapLibre / Employee Portal)
  supersedes an earlier, narrower "Hostinger migration" plan that had
  already produced a partial `backend/` scaffold — see below.
- No tests run (nothing implemented yet under this architecture).

## Prior work (pre-pivot — built under the earlier Firebase-keep/MySQL plan, status unresolved)

This work exists on disk but its fate under the new architecture is an open
question in `docs/AUDIT.md` (keep/retrofit/delete) — listed here for
traceability, not claimed as progress toward the current plan's success
criteria.

- **H0 — Repository inspection** (read-only): full Firebase/Firestore/FCM
  footprint mapped, `sos_dispatch` fully traced, Firestore/Storage rules
  reviewed. Findings folded into `docs/AUDIT.md` §B-F.
- **H1 — Hostinger environment**: confirmed VPS (KVM) with full SSH access,
  sole host operator. Domain, GitHub org, and free port block were never
  confirmed — still open, now tracked in `docs/AUDIT.md`'s open questions.
- **H2 (partial) — Backend foundation**: `backend/` Express + TypeScript
  scaffold built — env config (`zod`-validated), structured logging (`pino`,
  with redaction), Firebase Admin SDK ID-token verification middleware,
  Firebase App Check verification middleware (enforcement-gated), rate
  limiting (general + SOS-specific), central error handling, a MySQL
  connection pool (`mysql2`) + migration runner, a WebSocket server with
  Firebase-token-authenticated upgrades. Verified: `npm run typecheck`,
  `npm run lint`, `npm run build` all pass clean. **Not deployed. No
  Dockerfile/Compose/CI exists.** Not wired to Flutter (no API client in
  `lib/` yet).
- **H3 (partial) — MySQL schema**: `001_init_schema.sql` written —
  `users`, `trusted_contacts`, `groups`/`group_members`, `messages`,
  `sos_events`, `locations`, `official_alerts`, plus an `audit_log` table.
  Typechecked/linted clean. **Never applied to a real database** (no MySQL
  instance provisioned).

Under the new architecture these MySQL/Firebase-Auth-specific pieces are
superseded (see `docs/AUDIT.md` §L's reusability table) pending your decision
on whether to retrofit or rewrite.
