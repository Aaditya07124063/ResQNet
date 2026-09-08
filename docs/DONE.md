# ResQNet — Completion Log

Dated record of what has actually been built and verified, most recent
first. Only entries backed by a real test/build/lint result go here — this is
evidence, not intent (intent lives in `docs/PLAN.md`).

---

## 2026-09-06 — Phase 21 closure (seismic push path fixed)

Fixed the one gap Phase 21 found but deliberately did not fix (out of
scope for a testing-only phase): `functions/index.js`'s
`correlateSeismicEvent` still read the obsolete Firestore `user_tokens`
collection to notify nearby users, dead since Phase 20 moved device-token
registration to the backend's `POST /api/v1/devices` (Postgres `devices`).

**Inspected first** (per the task's own instruction, before changing
anything): `earthquake_correlation_service.dart` (confirmed it only
*writes* Firestore `seismic_events` — a Firebase Auth uid, not a backend
user id; nothing reads corroboration back into Flutter); all callers of
`correlateSeismicEvent` (none — it's a Firestore-triggered Cloud Function,
called by nothing in this repo); `deviceService.ts`/`Device.ts` (Postgres
`devices`, ownership-scoped CRUD, `getPushTokensForUsers`); `fcm.ts`
(`sendMulticast` — safe no-op when `FIREBASE_SERVICE_ACCOUNT_JSON` is
absent, never throws, never logs a token); `pushNotificationService.ts`
(`notifyUsersDevices`/`notifyAllOtherActiveUsers` — the exact Phase 17
machinery this fix needed to reuse, not duplicate); existing seismic
tests (`earthquake_detection_test.dart` — local STA/LTA detection only,
unrelated to server-side correlation/notification, confirmed untouched
by this fix).

**Key finding that shaped the design**: `functions/index.js` runs on
Firebase's infrastructure with no access to the backend's Postgres — the
only way to "use the existing PostgreSQL device-token + FCM architecture"
from there is a network call to the backend, which already has that
architecture built. This is not new notification behavior (the broadcast
itself — alert nearby active users' devices, unscoped — already existed
and already ran, just via a now-dead code path) — only the trigger
mechanism (an HTTP call) is new plumbing.

**A second key finding**: the intended exclusion of "whoever already felt
it" from the broadcast is not resolvable as originally written.
`seismic_events.userId` is a Firebase Auth uid; the backend's `users`
table has no Firebase-uid column at all (`google_subject` is the Google
OAuth `sub` claim from direct backend verification — a different
namespace than Firebase's own per-project uid; phone sign-in records no
linkage either). There is no reliable way to map the reporting/
corroborating users to backend `users.id` rows to exclude them. Rather
than invent a new cross-identity mapping (explicitly out of scope —
"do not invent new notification behavior"), the fix broadcasts to all
active users with no exclusion, disclosed here rather than silently
changed. This is a minor simplification, not a functional regression:
the reporting device(s) already received their own on-device alert from
the local STA/LTA detector before server-side correlation ever runs
(`earthquake_correlation_service.dart`'s own doc comment) — this
broadcast only ever adds a confirmatory push for them, never their first
notice of the event.

**Files changed**:
- `backend/src/services/pushNotificationService.ts` — `notifyAllOtherActiveUsers`'s `excludeUserId` parameter now accepts `string | null` (`null` = no exclusion filter at all); the one existing caller (`sosService.ts`) is unaffected (still passes a real id). Added `notifySeismicCorroboration(input)` — composes the exact same alert title/body/data `correlateSeismicEvent` used to build itself, then calls `notifyAllOtherActiveUsers(null, ...)`. No new push-sending logic — `notifyUsersDevices`/`sendMulticast`/`fcm.ts`/`deviceService.ts` are 100% reused, untouched.
- `backend/src/routes/internalRoutes.ts` (new) — `POST /api/v1/internal/seismic-alerts`, service-to-service only (no Flutter/user/employee caller), gated by `seismicWebhookAuth.ts` instead of `requireAuth`/`requireEmployeeAuth`, body-validated by `seismicSchemas.ts`, delegates to `notifySeismicCorroboration`. Mounted in `routes/index.ts` as `/internal`.
- `backend/src/middleware/seismicWebhookAuth.ts` (new) — constant-time (`crypto.timingSafeEqual`) shared-secret check against `env.SEISMIC_WEBHOOK_SECRET`; 503 if unconfigured (never a silent bypass), 401 on a missing/wrong header, never logs the header or the configured secret on any path.
- `backend/src/validation/seismicSchemas.ts` (new) — `{ latitude, longitude, deviceCount }`, exactly what the Cloud Function already has in hand.
- `backend/src/config/env.ts` — added `SEISMIC_WEBHOOK_SECRET: z.string().optional()` (same "absent in local dev, safe-degrade" pattern as `FIREBASE_SERVICE_ACCOUNT_JSON`).
- `backend/src/utils/logger.ts` — added the new header to the base logger's own `redact.paths` (defense-in-depth; see the real bug found below for why this alone was not sufficient).
- `backend/src/app.ts` — **real bug found and fixed during live verification**: `pinoHttp({ logger, redact: [...] })`'s own `redact` option is a SEPARATE list from the `logger` instance's own redact config — they are not merged. The webhook secret header was appearing in cleartext in the HTTP access log (`"x-seismic-webhook-secret":"local-dev-seismic-secret-value"`) on every request to the new route despite `logger.ts`'s redact list already containing it. Reproduced live (booted the real server, sent a real request, grepped the log file), fixed by adding the same path to `app.ts`'s `pinoHttp` redact array too, reverified live (0 occurrences of the raw secret afterward; `"x-seismic-webhook-secret":"[Redacted]"` appears instead).
- `functions/index.js` — removed the entire Firestore `user_tokens` read / `reportingUserIds` exclusion / `admin.messaging().sendEachForMulticast` block; replaced with a `fetch()` call to `POST {RESQNET_BACKEND_URL}/api/v1/internal/seismic-alerts` with the `X-Seismic-Webhook-Secret` header, reading both from `process.env` (configured via the Cloud Function's own environment/Secret Manager — deployment configuration itself is out of scope, no Firebase project access in this sandbox). Missing config → logged, skipped, never thrown (a corroborated event was already recorded by the point this runs). Network/HTTP failure → caught, logs only `e.message` (never the full error object, which could carry request details) and the response status, never a token or the secret. Detection/correlation code (lines above this block) is byte-for-byte unchanged.
- `backend/tests/pushNotificationService.test.ts` — 3 new tests: `excludeUserId=null` queries with no exclusion filter; `notifySeismicCorroboration` broadcasts correctly; it never throws with zero active users or with every device send failing (delegates to Phase 17's existing, already-tested failure handling).
- `backend/tests/seismicWebhookAuth.test.ts` (new) — 5 tests: unconfigured → 503 (never a silent 401-that-looks-like-it-tried), missing header → 401, wrong secret → 401, length-mismatch branch → 401, correct secret → passes through.
- `backend/tests/internalRoutes.test.ts` (new) — 5 tests: no header → 401, wrong header → 401, invalid body → 400, valid request → 202 + delegates correctly, and a thrown internal error never leaks the secret or a stack trace in the response body.

**Old path removed**: Firestore `user_tokens` collection read, `admin.messaging().sendEachForMulticast()` call, and the `reportingUserIds` exclusion-by-Firestore-doc-id logic — all gone from `functions/index.js`.

**New path**: `correlateSeismicEvent` (detection/correlation unchanged) → `fetch(POST /api/v1/internal/seismic-alerts)` → `seismicWebhookAuth` → `seismicCorroborationAlertSchema` → `notifySeismicCorroboration` → `notifyAllOtherActiveUsers(null, ...)` → `notifyUsersDevices` → `getPushTokensForUsers` (Postgres `devices`) + `sendMulticast` (`fcm.ts`, unchanged Phase 17 FCM client) → `removeDevicesByToken` for any token FCM reports invalid.

**Tests/results**: Backend **328/328** passing (314 Phase-21 baseline + 13 new + 1 test that already existed gained no changes), `typecheck`/`lint`/`build` all clean. `functions/index.js`: `node -c` syntax-clean; `eslint` shows the same 2 pre-existing issues as before this change (1 missing-jsdoc on `haversineKm`, 1 pre-existing long line — both untouched by this edit), zero new. Live-verified against the real running backend + real local Postgres: no-secret request → 401; wrong secret → 401; correct secret + valid body → 202 (and a genuine no-registered-device scenario resolves safely, matching `notifyUsersDevices`'s existing `'no_device'` handling — nothing throws); invalid body → 400; the webhook secret never appears in the request/access log after the `app.ts` fix (0 occurrences across multiple live requests, confirmed by grepping the actual log file both before and after the fix).

**Remaining limitations** (disclosed, not silently worked around):
- No exclusion of the reporting/corroborating users from the broadcast — see the "second key finding" above. Fixing this for real would require a new Firebase-uid-to-backend-user-id linkage that doesn't exist and isn't specified anywhere.
- `RESQNET_BACKEND_URL`/`SEISMIC_WEBHOOK_SECRET` must be configured in the actual deployed Cloud Function's environment for this to work in production — not done here (no Firebase project/deploy access in this sandbox); until configured, the function logs a warning and skips the alert (never throws, never blocks the correlation write).
- End-to-end delivery through a REAL deployed Cloud Function calling a REAL deployed backend was not (and could not be) tested here — the backend side was live-verified directly; the Cloud Function side was verified by syntax/lint/code-review only, consistent with every prior phase's disclosed boundary for `functions/index.js`.
- `functions/` still has no automated test harness (pre-existing condition; `firebase-functions-test` is an installed but unused devDependency) — building one was judged disproportionate to a single-gap fix and was not attempted.

Not deployed; no VPS/Docker-production/Orbyatravel file touched; no
Flutter file touched (none needed — the fix is entirely
backend + Cloud Function); nothing committed.

## 2026-09-06 — Phase 21 (Final comprehensive testing)

Fresh, from-scratch inspection of the actual repository, `docs/PLAN.md`,
and `docs/DONE.md` (not a review of prior phase claims), followed by
comprehensive validation — unit suites plus, where a real local Postgres
instance and a real running backend server made it possible, genuine live
integration testing rather than only mocks.

**Real bug found and fixed**: `backend/src/middleware/errorHandler.ts` had
a case for `express.json()`'s oversized-payload error (`entity.too.large`
→ 413) but none for its malformed-JSON-body error (`entity.parse.failed`)
— that fell through to the generic branch, returning a raw **500** with
the JSON parser's own error message, instead of a **400**. Live-reproduced
first (`curl` a malformed body against the running server), then fixed by
adding a matching `entity.parse.failed` → 400 `INVALID_JSON` case, then
reverified live and via 4 new regression tests
(`tests/errorHandler.test.ts`) covering all four branches (malformed JSON,
oversized payload, a thrown `HttpError`, and a genuinely unexpected
error). Full suite: 314/314 (310 pre-existing + 4 new), zero regressions.

**Subsystem-by-subsystem results**:

| # | Subsystem | Result | Evidence |
|---|---|---|---|
| 1 | Flutter app | PASS | `flutter analyze` 62 issues (same pre-existing baseline, zero new), `flutter test` 85/85, `flutter build apk --debug` succeeds |
| 2 | Google auth + session restore | PARTIAL | Backend `POST /auth/google` code + unit tests reviewed; Flutter `google_login_cutover_test.dart`/`backend_session_controller_test.dart` pass (in the 85/85). Real-device ID-token audience check: **NOT VERIFIED** (no Android device/emulator in this sandbox — same blocker every phase since 4C) |
| 3 | Backend JWT/refresh/logout | PASS | Live: employee login (wrong password → 401, correct → 200), consumer-JWT-on-employee-route and employee-JWT-on-consumer-route both correctly 401 (separate secret/identity spaces) verified against the real running server; `sessionService`/`employeeAuthService` unit tests (algorithm pinning, Phase 19) pass |
| 4 | Profile | PASS | Live `GET`/`PUT /api/v1/profile` against real Postgres — new user gets `null`, write round-trips correctly |
| 5 | Trusted contacts | PASS | Live CRUD + IDOR: non-owner `PUT`/`DELETE` → 404, owner succeeds |
| 6 | Profile images/MinIO | PARTIAL | `imageSignature`/`profileImageAccessService`/`profileImageRoutes` unit tests pass; no local MinIO instance running in this sandbox, so an actual upload/signed-URL round trip is **NOT VERIFIED**; MinIO production-viability gap (archived upstream repo, image pinned to last-ever release, Phase 18) re-confirmed unchanged |
| 7 | SOS creation/history/status | PASS | Live: create (201), duplicate `eventId` retry returns the identical event id (idempotency), list scoped to owner (not leaked to another user), `PATCH` status by non-owner → 404 / by owner → 200, invalid body → 400 |
| 8 | SOS recipient handling | PARTIAL | `sosServicePush.test.ts` (trusted-contact fan-out → `sos_recipients` rows) passes; real FCM delivery to a real recipient device is **NOT VERIFIED** (see #9) |
| 9 | Push/device tokens/FCM | PARTIAL | Device `POST`/`GET`/`DELETE` live-tested (ownership-scoped, raw `pushToken` never returned in list responses); actual FCM send still degrades to a safe no-op without a real `FIREBASE_SERVICE_ACCOUNT_JSON` (Phase 17's disclosed, unchanged limitation) — real delivery **NOT VERIFIED** |
| 10 | WebSocket SOS events | PASS | Live: a real WS client authenticated via `?access_token=`, a real `POST /api/v1/sos` on the same user, `sos_created` received over the socket within 2s |
| 11 | Reports | PASS | Live: report creation (201), self-report rejected (400+), threshold-triggered `review_cases` auto-open confirmed against real Postgres (with `admin_settings.report_threshold` configured for the test, then removed) |
| 12 | Employee auth/RBAC | PASS | Live: wrong password 401, correct password 200, permission-gated action 403s without `USER_SUSPEND` and 201s once granted — both directions of the RBAC check exercised, not just the positive case |
| 13 | Moderation/review cases | PASS | Live, full pipeline: report → auto-opened review case → employee views it → `suspend_temporary` action → `users.account_status` flips to `suspended` → review case closes — all against real Postgres |
| 14 | DB migrations/data integrity | PASS | Both `001_init_schema.sql`/`002_employee_sessions.sql` already applied to the live dev database (31 tables); `npm run migrate` re-run confirms idempotency (`"Migration already applied, skipping"` for both, no errors) |
| 15 | API authorization/IDOR | PASS | Live cross-user 404s on trusted-contacts/devices/SOS (this phase) layered on Phase 19's full from-scratch source audit (unchanged — no backend route file touched since) |
| 16 | Rate limiting | PASS | Live: SOS-specific limiter (5/60s) — attempts 1-5 succeed (201), 6th and 7th return 429; default limiter's `RateLimit-*` headers observed on a real response. Employee-auth-specific limiter remains unit-tested only (not re-exercised live, to avoid needing many disposable employee accounts) |
| 17 | Input validation/security | PASS (1 bug fixed) | Malformed-JSON 500→400 bug found and fixed (above); garbage bearer token → clean 401 (not 500); zod rejects invalid SOS `eventId` (400) — all live-verified |
| 18 | Docker/CI/CD configuration | PARTIAL | `.github/workflows/backend-ci.yml`, `deploy.yml`, `docker/docker-compose.reference.yml` all parse as valid YAML; `docker/deploy.sh`/`rollback.sh` pass `bash -n`; secrets scan of all CI/compose/example-env files found only clearly-labeled CI dummy values and empty/placeholder production secrets (`GOOGLE_OAUTH_CLIENT_ID` is a public OAuth client id, not a secret, by design). Actual `docker build`/`docker compose up`/deploy execution **NOT VERIFIED** — no Docker daemon or VPS access in this sandbox (unchanged since Phase 18) |
| 19 | Firebase-removal migration | PASS | Re-confirmed Phase 20's end state unchanged: repo-wide grep shows the same accounted-for Firebase imports, `flutter_storage` still absent, no backend file needed for any of it |
| 20 | Seismic/earthquake functionality | PARTIAL | `crash_detection_test.dart`/`earthquake_detection_test.dart` pass (in the 85/85); `correlateSeismicEvent`'s dependence on now-unpopulated Firestore `user_tokens` (Phase 20's documented gap) reconfirmed still present and still not fixed — see correction below. Actual live Firestore-trigger execution was never testable in any phase (requires a deployed Firebase project) — **NOT VERIFIED** |
| 21 | Production configuration/readiness | PARTIAL | `.env.example`/`docker/.env.prod.example` contain only placeholders; `backend/.env`/`docker/.env.prod` correctly gitignored and untracked; MinIO end-of-life packaging gap (Phase 18) and the 13 moderate `npm audit` advisories (Phase 19) both reconfirmed unchanged. Real production deployment **NOT VERIFIED** — no VPS/domain/GHCR access in this sandbox |

**Correction to the Phase 20 report**: this phase's prompt asked to verify
that the seismic nearby-user push path "no longer depends on obsolete
Firestore `user_tokens`" — re-reading `functions/index.js` confirms it
still does (this was Phase 20's own disclosed, deliberately-not-fixed
gap, not something that changed since). Reported accurately rather than
claimed fixed: fixing it for real would mean building new, unspecified
infrastructure (a backend-exposed device-token read for Cloud Functions,
or moving seismic correlation off Firestore entirely), which is out of
scope for a testing/validation phase.

**Live-integration testing method**: since no real Google ID token or
Firebase-issued FCM credentials exist in this sandbox, live backend tests
used directly-inserted test users/employees plus hand-signed JWTs (via
the server's own `JWT_ACCESS_SECRET`/`EMPLOYEE_JWT_ACCESS_SECRET`) against
the actual running server and actual local Postgres — the same precedent
Phase 19 used ("temporary script, deleted after use"). All test data
(2 test users, 1 test employee, temporary `admin_settings` rows) was
deleted in every case, verified by a zero-row count query afterward; the
temporary scripts themselves were deleted (`git status` on their paths
confirms nothing left behind).

**Self-correction during this phase**: while trying to independently
reconfirm Phase 19's "`npm audit fix` makes zero changes" claim, an
`npm audit fix` run was accidentally executed against a `git stash`-reset
copy of `package-lock.json` rather than the real one, producing a large,
wrong diff. Caught immediately, reverted via `git checkout` +
`git stash pop`, then verified the restored lockfile is correct — `npm
ci` installs cleanly from it, and the full backend suite
(typecheck/build/314 tests) passes unchanged afterward. No lasting effect;
noted here for transparency. Phase 19's underlying claim was not
re-verified live after this (repeating the same risky command against the
real lockfile wasn't worth the risk) — `npm audit` itself was re-run
cleanly and confirms the same 13 moderate findings, unchanged.

Not deployed; no VPS/Docker-production/Nginx/DNS/PostgreSQL-production/
Orbyatravel file touched; no Flutter file touched (none needed); nothing
committed by this session (unrelated commits from the user's own workflow
landed on `main` between Phase 20 and this phase — confirmed via `git
log`, not something this session did).

## 2026-09-06 — Phase 20 (Firebase removal — migrated what has a backend equivalent; documented what doesn't)

Inspected the actual current repository from scratch (not prior phase
reports) for every remaining Firebase usage category: Auth, Firestore,
Cloud Functions, Messaging/FCM, Core/config, Flutter services, Android/iOS
config, packages, and docs/env references.

**Migrated to the existing backend (Phases 4-19), no new backend built:**
- `lib/core/services/profile_service.dart` — rewritten off Firestore
  `user_profiles/{uid}` onto `GET/PUT /api/v1/profile` (Phase 5). Added
  `_applyBackendData()` (merges only the fields the backend's
  `user_profiles` table actually has) and `refreshPhotoUrl()` (MinIO
  signed URLs expire after 10 minutes — Phase 6 — unlike Firebase
  Storage's permanent URLs, so a fresh one is fetched rather than trusted
  from cache). **Documented gap**: `name`/`phone`/`email`/`photoUrl` have
  no column on the backend's `user_profiles` table (identity fields live
  on `users`, populated from sign-in, with no update endpoint exposed) —
  these stay local-cache-only, not synced, for every user regardless of
  sign-in state now (previously only for users who'd never touched
  Firestore). A real fix needs a `users` display-name update endpoint,
  which does not exist and was not invented here.
- `lib/core/services/trusted_contacts_service.dart` — rewritten off the
  Firestore subcollection onto `GET/POST/PUT/DELETE
  /api/v1/profile/trusted-contacts` (Phase 5). Added
  `TrustedContact.fromBackendJson()` to map the backend's
  `phoneNumber`/`relationship` field names onto the local
  `phone`/`relation` model. `addContact()` now reconciles the optimistic
  local id with the backend-assigned id on success.
- `lib/features/profile/profile_screen.dart` — `_pickAndUploadPhoto()`
  rewritten off `firebase_storage` onto `ApiClient.putBytes('/profile/image',
  ...)` (Phase 6), gated on `auth.isBackendSignedIn()` (this call requires
  a backend session specifically, not a Firebase one — the one identity
  check in this phase that was a hard blocker to fix, unlike the
  `mesh_screen.dart`/`dashboard_screen.dart` instances below).
- `lib/core/services/sos_service.dart` — added an `eventSource` parameter
  (`'manual'`/`'crash_detection'`/`'earthquake_detection'`) and
  `_reportToBackend()`, calling `POST /api/v1/sos` (Phase 11), which
  already handles trusted-contact push fan-out and cross-user broadcast
  server-side (Phase 17) — removed this phase's dependency on
  `firebase_service.dart`/`notification_service.dart` for that.
  `eventSource` threaded from the 3 real call sites: `sos_screen.dart`
  (default `'manual'`), `crash_countdown_dialog.dart`
  (`'crash_detection'`), `earthquake_alert_dialog.dart`
  (`'earthquake_detection'`), through `sos_dispatch_service.dart`'s
  `dispatch()`.
- `lib/core/services/sos_dispatch_service.dart` — removed
  `_writeDispatchRecord()` (the Firestore `sos_dispatch` write) entirely,
  fully superseded by the backend recording the same event via
  `sos_service.dart` above.
- `lib/features/sos_history/sos_history_screen.dart` — rewritten from a
  `StatelessWidget`+Firestore `StreamBuilder` to a
  `StatefulWidget`+`FutureBuilder` over `GET /api/v1/sos` (Phase 11);
  `EmergencyMessage` type/priority now re-derived at display time via
  `AiService` from the backend's raw `category`/`message` (previously
  computed once at Firestore-write time). **Documented gap**: delete/clear-
  all functionality removed — no backend DELETE endpoint exists for SOS
  events, by Phase 11's own deliberate audit-trail design; inventing one
  was out of scope.
- `lib/core/services/mesh_service.dart` — removed `_saveToHistory()` (the
  Firestore `sos_history` write), now redundant since the backend records
  the same SOS event via `sos_service.dart`.
- `lib/core/services/notification_service.dart` — `_saveToken()` rewritten
  from Firestore `user_tokens/{uid}` onto `POST /api/v1/devices`
  (Phase 17's device-CRUD, now actually wired from Flutter for the first
  time). Removed `broadcastSosNotification()` entirely — fully superseded
  by the backend's own SOS-triggered push sends (Phase 17).
  `firebase_messaging`'s actual FCM receive/foreground/background handling
  is unchanged — still required, see below.
- `lib/features/auth/auth_service.dart` — removed the dead
  `signInWithGoogle()` method (the pre-Phase-4C Firebase-credential Google
  path) — confirmed unused via grep, since `login_screen.dart`'s Google
  button has called `signInWithGoogleBackend()` since Phase 4C.

**Removed as obsolete, confirmed unused first:**
- `firebase_storage: ^12.3.2` — removed from `pubspec.yaml` after
  confirming (grep) it was unused anywhere once `profile_screen.dart` was
  migrated. `flutter pub get` removed exactly `firebase_storage`,
  `firebase_storage_platform_interface`, `firebase_storage_web` — nothing
  else changed ("Changed 3 dependencies!").
- `lib/core/services/firebase_service.dart` — deleted; confirmed a pure
  stub, fully unused after `sos_service.dart`'s migration above.
- `functions/index.js`'s `sendSosNotification` (Firestore
  `sos_broadcasts/{alertId}` trigger) and `notifyTrustedContacts`
  (Firestore `sos_dispatch/{alertId}` trigger) — both confirmed permanently
  orphaned via repository-wide grep: nothing writes to `sos_broadcasts` or
  `sos_dispatch` any more after the migrations above. Also removed
  `normalizePhone()`, which only `notifyTrustedContacts` called.
  `correlateSeismicEvent` (Firestore `seismic_events` trigger) **kept** —
  see gaps below.

**Central finding — Firebase is NOT fully removed, and cannot be under the
architecture actually built so far** (this is Phase 20's honest conclusion,
per its own instruction to document rather than invent a replacement for a
feature with no backend/spec equivalent):
1. **Phone-OTP login** (`AuthService.sendOtp`/`verifyOtp`, using
   `FirebaseAuth.verifyPhoneNumber`) has zero backend replacement — Phase
   8/9 (SMS provider system) was never built. Removing `firebase_auth`
   would delete phone login outright.
2. **FCM client-side** (`firebase_messaging`) is structurally required to
   receive pushes and obtain device tokens, independent of who triggers
   sends server-side. Phase 17 already decided to keep FCM as the delivery
   provider — this dependency was never going to be removable under that
   decision.
3. **Seismic correlation** (`earthquake_correlation_service.dart`'s
   Firestore `seismic_events` collection) has no Postgres/backend
   equivalent — confirmed via Phase 17's own prior audit, never speced.
4. **`firebase_core`** bootstraps all three of the above and so cannot be
   removed either.

**New gap surfaced by this phase's own migration** (not present before
Phase 20, disclosed rather than silently left broken): `functions/index.js`'s
kept `correlateSeismicEvent` reads Firestore `user_tokens` to push-notify
nearby users once an earthquake is corroborated by enough devices. Since
device push tokens now live in backend Postgres
(`POST /api/v1/devices`, wired from Flutter for the first time in this very
phase, per the migration above), nothing writes to Firestore `user_tokens`
any more — that read will find nothing, and the notify-fanout step silently
no-ops. The correlation math itself (`corroboratingDeviceCount`/
`corroborated`, written back onto the Firestore seismic event for the app
to read) is unaffected. Documented in `functions/index.js` and here, not
fixed — a real fix needs either a backend-exposed device-token read for
Cloud Functions, or moving seismic correlation off Firestore onto the
backend, neither of which is specified or was invented here.

**Deliberately not touched, out of this phase's scope**:
`mesh_screen.dart`/`dashboard_screen.dart` still read
`FirebaseAuth.instance.currentUser?.uid ?? 'anonymous'` for mesh message
`senderId` — silently degrades to `'anonymous'` for backend-Google-
authenticated users (whose `FirebaseAuth.instance.currentUser` is null).
Pre-existing, same shape as the still-unapproved Phase 4C/4D identity-
unification work; fixing it was not required to satisfy this phase's own
migration goals and risked scope creep into that separate, larger, still-
blocked effort.
Android/iOS Firebase config (`google-services.json`,
`GoogleService-Info.plist`, `firebase.json`, `.firebaserc`) intentionally
left untouched — still required by `firebase_core`/`firebase_auth`/
`firebase_messaging`/`cloud_firestore` above.

**Testing**:
- `flutter analyze`: 62 issues (down from the prior ~64-issue baseline;
  zero new issues introduced — every remaining item is a pre-existing
  `deprecated_member_use`/`prefer_const_constructors` info or one of two
  pre-existing warnings in `mesh_service.dart`/`mesh_service_android.dart`
  already present before this phase).
- `flutter test`: **85/85 passing**, zero regressions (includes the
  pre-existing flaky `api_client_test.dart` single-flight-refresh test,
  which passed on this run — reproduced its flakiness in isolation earlier
  in this phase across repeated runs; a hardcoded 5ms timing race unrelated
  to any change made here).
- `flutter build apk --debug`: succeeds.
- Backend: `npm test` **310/310 passing**, `typecheck`/`lint`/`build` all
  clean — unchanged from Phase 19's baseline (no backend file touched this
  phase).
- `functions/index.js`: `node -c` syntax-checks clean; `eslint` shows 5
  pre-existing issues (confirmed by diffing against both the git `HEAD`
  version and the exact pre-this-phase working-tree content — baseline was
  6 issues, tied to the two removed functions plus lines untouched by this
  edit; removing the dead functions reduced the count, introduced zero new
  ones).
- Repository-wide grep for `package:firebase`/`package:cloud_firestore`/
  `package:cloud_functions` confirms every remaining Flutter import sits in
  one of: `main.dart`/`app.dart`/`firebase_options.dart` (bootstrap/hybrid
  auth gate), `earthquake_correlation_service.dart` (gap #3),
  `notification_service.dart` (gap #2), `auth_service.dart` (gap #1),
  `mesh_screen.dart`/`dashboard_screen.dart` (documented, out-of-scope
  identity gap above) — no orphaned or forgotten Firebase import found.

Not deployed; no VPS/Docker-production/Nginx/DNS/PostgreSQL-production/
Orbyatravel file touched; no backend file touched (none needed — all
target APIs already existed from Phases 5, 6, 11, 17); nothing committed.

## 2026-09-05 — Phase 19 (Security audit)

Fresh, from-scratch code inspection (not a review of prior phase reports)
across all 58 backend source files, spanning the 12 required categories.
No CRITICAL or HIGH findings. Full findings table:

| Sev | Component/file | Issue | Fix |
|---|---|---|---|
| MEDIUM | `sessionService.ts`/`employeeAuthService.ts` (`jwt.sign`/`jwt.verify`) | `algorithms`/`algorithm` never pinned explicitly — relied on jsonwebtoken's own type-based inference rather than an explicit allowlist | Pinned `algorithm: 'HS256'` on sign, `algorithms: ['HS256']` on verify, both token types. 4 new tests (alg:none, wrong-HMAC-variant) prove the pin does something, not just that the library's default happened to be safe |
| MEDIUM | `moderationService.ts` `takeModerationAction` | The `account_status` UPDATE had no floor guard — a later, less-severe `suspend_*` action (on a NEW review case opened after an earlier case already soft-deleted the same target) could downgrade `'deleted'` back to `'suspended'` | Added `AND account_status != 'deleted'` (mirrors the existing guard pattern in `reportService.ts`'s `maybeOpenReviewCase`). 1 new test + verified live against real Postgres |
| MEDIUM | `websocket/wsServer.ts` | `WebSocketServer` had no `maxPayload` — `ws` defaults to 100MiB; an authenticated client could send huge frames repeatedly (memory/CPU DoS via `JSON.parse`) for a connection that has no legitimate inbound protocol at all today | Set `maxPayload: 16 * 1024`. 1 new test (oversized message closes the connection) |
| MEDIUM | `websocket/wsServer.ts` | The raw `http.Server` `'upgrade'` event is completely outside Express — none of `app.ts`'s rate limiters (which key off `req.authUser`, set by Express-only middleware) ever see this path, so WS upgrade attempts (each costing a JWT verify + DB lookup) were entirely unbounded | Added a minimal in-memory sliding-window limiter (30/60s, keyed by `req.socket.remoteAddress`) rejecting with a raw `429` before authentication runs. 1 new test |
| LOW | `middleware/rateLimiter.ts` `defaultRateLimiter` | Doc comment claimed "keyed by authenticated user when available" — false in practice: it's mounted in `app.ts` before any route's `requireAuth` runs, so `req.authUser` is always `undefined` here; it's always IP-keyed | Comment corrected to describe actual behavior; no behavior change (not a vulnerability, just an inaccurate comment) |
| LOW | Dependencies (`npm audit`) | 13 moderate advisories: `qs`/`body-parser` (via `express`) — DoS/array-limit bypass, no fix available even via non-force `npm audit fix` (ran it — zero changes); `decode-uri-component`/`stream-json` (via `minio`) and `uuid` (via `firebase-admin`'s `@google-cloud/storage` chain) — fixes exist only via `--force`, which would downgrade `minio` to 7.1.3 or `firebase-admin` to 10.3.0 (a major, breaking regression undoing Phase 17's modular-API integration) | **Not fixed** — no safe/non-breaking path exists today; documented here for tracking until upstream (`express`, `minio`, `firebase-admin`) ships a real fix. Re-run `npm audit` before Phase 21 |
| LOW | `employeeManagementRoutes.ts` `POST /` (create employee), `POST/:id/permissions` | No dedicated rate limiter (unlike login) — contained risk since both already require `requireEmployeeAuth` + `EMPLOYEE_MANAGE` (an already-privileged actor) | Not fixed — low value for the added surface; `defaultRateLimiter`'s blanket 100/min IP-keyed limit still applies |
| LOW | `employeeManagementRoutes.ts` `POST /:id/permissions` | Granting a permission to a nonexistent employee id hits the `employee_permissions.employee_id` FK violation (23503), uncaught → generic 500 instead of 404 | Not fixed — cosmetic/robustness only, no data or auth exposure |
| INFO | `employee_permissions` design | `EMPLOYEE_MANAGE` lets its holder grant ANY permission, including `EMPLOYEE_MANAGE`/`SETTINGS_MANAGE` itself, to any employee (including themselves) | Not a bug — inherent to the schema's own "granular permission table" design (confirmed via its own doc comment); a finer-grained "permission to grant permission X but not Y" model would be a real redesign, out of scope |
| INFO | `admin_settings` | Free-form `key`/JSONB `value`, no allow-list of known setting names | By design (matches the column's own JSONB/no-fixed-schema shape); already gated behind `SETTINGS_MANAGE` |
| INFO | Auth/RBAC/IDOR/SQL injection (broad) | Every route re-verified: consumer routes (`profile`, `trusted-contacts`, `sos`, `devices`, `reports`) are 100% ownership-scoped via `WHERE ... = req.authUser.id`, 404-not-403 on a foreign resource; employee routes are 100% `requireEmployeeAuth` + `requirePermission`; every query is parameterized (`$1`/`$2`/...), zero string-concatenated SQL found anywhere; MinIO object keys and image types are derived server-side from verified identity/magic-bytes, never client-declared | No issues found |
| INFO | Secrets/logging | `logger.ts`'s redact list covers password/token/refresh/idToken/otp/private_key/push_token/service-account fields; `errorHandler.ts` only echoes raw error messages when `!isProduction`; FCM/employee JWT/PROVIDER_CREDENTIALS_ENCRYPTION_KEY secrets are all optional-with-safe-no-op or required-with-boot-time-validation, never logged | No issues found |
| INFO | CORS/Docker/CI | `credentials: false` + explicit origin allow-list (empty-origin-allowed only outside production); Dockerfile now on `node:22-alpine` (Phase 18); CI workflow never echoes secrets, uses scoped `GITHUB_TOKEN` | No issues found (already addressed in Phase 18 where applicable) |

Also ran (not force-applied) `npm audit fix` in safe mode — made zero
changes, confirming no non-breaking upgrade path currently exists for the
`qs`/`body-parser` chain.

**7 new regression tests** across `sessionService.test.ts` (2),
`employeeAuthService.test.ts` (2), `moderationService.test.ts` (1),
`wsServer.test.ts` (2, plus a new `resetUpgradeRateLimiterForTests()`
test-only export needed to isolate the new upgrade-rate-limit test from
every other test in that file sharing the same loopback address).
Verified live against real Postgres + real JWT signing (temporary script,
deleted after use): a wrong-algorithm-but-correct-secret token is really
rejected; a real `delete` action followed by a real later
`suspend_temporary` action on a new case really leaves the account
`deleted`, not downgraded. Full suite: **310/310 passing** (303
pre-existing + 7 new, zero regressions). `typecheck`/`lint`/`build` all
clean.

Not deployed; no VPS/Docker-production/Nginx/DNS/PostgreSQL-production/
Orbyatravel file touched; no Firebase file touched (audit found nothing
requiring a Firebase-side change); no Flutter file touched; nothing
committed.

## 2026-09-05 — Phase 18 (CI/CD authored; production deployment NOT performed)

- Inspected first: `docs/PLAN.md`'s Phase 18 line and "Still open" list
  (GHCR namespace/org, VPS IP, free port block, Orbyatravel's footprint —
  all still unresolved), `docs/AUDIT.md` §N ("Nothing is deployed... full
  SSH access available to **you** [the host operator]... I have no
  visibility into [Orbyatravel] at all"), `backend/package.json`'s
  scripts (`typecheck`/`lint`/`test`/`build`/`migrate`/`migrate:prod`),
  `backend/Dockerfile`, `docker/docker-compose.reference.yml`,
  `docker/.env.prod.example`. Confirmed: no `.github/` workflows existed,
  no SSH keys/config exist in this environment (`~/.ssh` empty), no
  Docker daemon available here either — none of this is new to Phase 18,
  it's the same "local dev sandbox, not the VPS" boundary every prior
  phase has operated inside.
- **CI** (`.github/workflows/backend-ci.yml`): triggers on push/PR to
  `main` touching `backend/**` (plus manual `workflow_dispatch`).
  `test` job: typecheck, lint, `npm test` (dummy env values only — every
  test already mocks its own dependencies, matching
  `tests/setupEnv.ts`'s existing local pattern), build, then verifies
  `dist/src/server.js` actually exists (catches a silently-no-op build).
  `migration-check` job (needs: test): spins up an ephemeral
  `postgres:16-alpine` service container, runs `npm run migrate` against
  it TWICE — the second run must be a no-op (validates every migration's
  own `IF NOT EXISTS`/`schema_migrations`-tracking idempotency, not just
  that it works once). `docker-build` job (needs: test): always builds
  the image (validates the Dockerfile on every push/PR); pushes to
  `ghcr.io/<repo>/resqnet-api` ONLY on an actual push to `main`, tagged
  **exclusively by commit SHA — no `:latest`** (requirement #7), using
  the automatically-scoped `GITHUB_TOKEN` (least-privilege — no separate
  PAT needed for GHCR under the same repo).
- **Deploy** (`.github/workflows/deploy.yml`): deliberately
  **`workflow_dispatch`-only**, never automatic — this project has
  treated every production action as a human decision the whole way
  through (every phase before this said "do not deploy"), and there's no
  reason for CI/CD to change that posture by itself. Takes an
  `image_tag` input (a commit SHA `backend-ci.yml` already built and
  pushed), SSHs in using `HOSTINGER_SSH_HOST`/`_USER`/`_KEY`/`_PORT`
  secrets (inline script, not a third-party marketplace action — keeps
  anything touching production credentials directly reviewable), runs
  `deploy.sh` remotely, then runs an HTTPS smoke test
  (`https://api.resqnet.co/health`) from the runner itself. Fails
  immediately with a clear error if the SSH secrets aren't configured,
  rather than a confusing timeout.
- **`docker/deploy.sh`** / **`docker/rollback.sh`** (new, host-operator-
  owned reference copies, same pattern as `docker-compose.reference.yml`
  itself): `deploy.sh` records the currently-running image (for
  rollback), pulls the target image, recreates **only** the `api`
  service (`--no-deps` — `db`/`minio` and their volumes are never
  touched, satisfying "do not recreate/delete the PostgreSQL data
  volume"), runs `dist/src/database/migrate.js` against the live
  database, then polls the container's own `/health` for up to 60s.
  Refuses to run if `RESQNET_API_IMAGE` resolves to `:latest`.
  `rollback.sh` redeploys the recorded (or explicitly given) prior image
  by calling `deploy.sh` again — no separate rollback logic to keep in
  sync.
- **`docker-compose.reference.yml`**: `api` service now deploys
  `image: ${RESQNET_API_IMAGE}` instead of `build: context: ../backend`
  — the actual point of Phase 18 (CI builds and tests the artifact once;
  production runs that exact artifact, never a host-side rebuild from
  source). Isolation from Orbyatravel is unchanged (same resqnet-prefixed
  names, same private network, same single loopback-bound port) — this
  edit touches only which image the `api` service resolves to.
- **Two real production-readiness gaps found and fixed while inspecting**
  (both directly required by requirement #7, not scope creep):
  - `backend/Dockerfile` used `node:20-alpine` in both build stages —
    verified via current official Node.js release-schedule sources that
    Node 20 reached end-of-life **2026-04-30** (today is 2026-09-05: it
    has been unpatched for over four months). Bumped to `node:22-alpine`
    (current Active LTS, EOL 2027-04-30). CI's `actions/setup-node`
    version bumped to match (22).
  - `docker/docker-compose.reference.yml`'s `minio` service used
    `minio/minio:latest`, left deliberately unpinned in Phase 6 pending
    verification. Verified via MinIO's own GitHub releases page and an
    independent industry writeup: **github.com/minio/minio was archived
    by its owner on 2026-04-25** (read-only, no further releases ever),
    and MinIO stopped publishing free pre-built Docker Hub images in
    October 2025 — its own final release notes say "clone the source and
    build the latest container" instead. Pinned to
    `RELEASE.2025-10-15T17-29-55Z` — the last tag that exists and the one
    that fixes MinIO's final critical CVE (service-account/STS privilege
    escalation) before archival. **This is disclosed as a real
    architectural gap, not resolved**: this pin will never receive
    another security update because the upstream project is gone. A
    deliberate decision (self-build from the archived source, a
    maintained fork, or replacing MinIO with another S3-compatible
    provider) is needed before real user data lands in MinIO — explicitly
    out of Phase 18's scope ("do not invent infrastructure").
  - Also bumped stale third-party Action version pins discovered while
    authoring the workflow (`actions/checkout` v4→v6, `actions/setup-node`
    v4→v6, `docker/setup-buildx-action` v3→v4, `docker/login-action`
    v3→v4, `docker/build-push-action` v6→v7) — verified against current
    GitHub Marketplace listings rather than left at whatever version was
    first guessed.
- **Also documented, additively**: `docker/.env.prod.example` gained
  `RESQNET_API_IMAGE` (with an explicit placeholder for the still-unknown
  GHCR org/repo — not guessed).
- **Verification performed**: full backend suite (303/303), typecheck,
  lint, build all re-run clean after the Dockerfile/compose/CI changes
  (zero backend TypeScript source touched this phase, so this reconfirms
  no regression rather than testing new logic). Both workflow YAML files
  parsed successfully (`Ruby`'s `YAML.load_file`, since no YAML tooling
  was otherwise available in this environment). Action version pins
  cross-checked against current Marketplace listings via web search, not
  assumed. `bash -n` validated both shell scripts' syntax.
- **Verification NOT performed, and why**: no Docker daemon exists in
  this sandbox, so `docker build`/the CI `docker-build` job's actual
  execution was never run locally — only manually reviewed. No SSH
  access, VPS IP, GHCR org, domain, or `.env.prod` exist here, so
  `deploy.yml`/`deploy.sh` were authored and reviewed but never executed
  — production is **exactly as undeployed as `docs/AUDIT.md` §N already
  described**, nothing has changed there. This mirrors the Phase 4C
  real-device and Phase 17 real-Firebase-credential blockers exactly:
  code/config is complete and reviewed; the external environment to
  actually run it against does not exist in this session.
- Not deployed; no VPS/Docker-production/Nginx/DNS/UFW/PostgreSQL-
  production/Orbyatravel file touched or SSH session opened; no Firebase
  file touched; no Flutter file touched; nothing committed.

## 2026-09-05 — Phase 17 (Push notifications — backend infrastructure + SOS integration; Flutter/real-device delivery deferred) — backend only

- Inspected first: `docs/AUDIT.md` §F (current FCM/notification implementation — `notification_service.dart`'s Firestore token registration, `functions/index.js`'s three Cloud Functions), the `devices` table (already existed from Phase 1, with a doc comment explicitly deferring the provider choice to "a Phase 17 decision"), Phase 11's SOS/`sos_recipients` model, Phase 5's trusted contacts, PLAN.md's Firebase-removal-order note tying FCM removal to this phase's own decision.
- **Provider decision**: keep FCM (already the app's only provider — AUDIT.md §F confirms no OneSignal/other provider exists) — the architecture change is WHO triggers it (this backend, via `firebase-admin`, instead of Firebase Cloud Functions), not WHAT sends it. `functions/index.js` is completely untouched.
- **`devices` table CRUD** (`deviceService.ts`, `routes/deviceRoutes.ts`, mounted at `/api/v1/devices`): `POST /` (register/upsert on `(user_id, push_token)` conflict — idempotent for an unchanged token, a genuinely refreshed token creates a new row), `GET /` (list own devices — response shape deliberately excludes `push_token` entirely, even from the owner, per "never expose unnecessary token information"), `DELETE /:id` (ownership-scoped, 404 whether missing or not yours). New `deviceRateLimiter` (30/window, generous — explicitly sized not to break legitimate multi-device use).
- **`fcm.ts`**: thin wrapper around `firebase-admin`'s modular `firebase-admin/app`/`firebase-admin/messaging` API (the current v14 API — the older namespaced `admin.app`/`admin.credential` style isn't exported by the installed version, caught and fixed via `tsc` during implementation). Lazy init from `FIREBASE_SERVICE_ACCOUNT_JSON` (new, OPTIONAL env var — real per-environment credential material this project has no way to fabricate); never throws, degrades to a safe no-op when unconfigured or malformed. Chunks to FCM's real 500-token limit. Maps FCM's per-token response to a `shouldRemoveToken` flag (only for `registration-token-not-registered`/`invalid-registration-token` — never for a transient failure).
- **`pushNotificationService.ts`**: DB-aware layer — `notifyUsersDevices` (per-user `sent`/`failed`/`no_device` outcome, batched into as few FCM calls as possible, cleans up FCM-confirmed-dead tokens) and `notifyAllOtherActiveUsers` (mirrors `sendSosNotification`'s unscoped broadcast exactly, including its lack of geographic scoping — the schema stores no device location, so this is today's real limitation, not something invented here).
- **SOS integration** (`sosService.ts`): after the existing (unchanged) SMS-channel trusted-contact fan-out, a contact who is ALSO a ResQNet user now additionally gets a separate `channel='push'` `sos_recipients` row — this does not alter the SMS row/semantics at all. `createSosEvent` then (best-effort, outside the DB transaction — an external network call must never hold one open): broadcasts to all other active users (mirrors `sendSosNotification`), and pushes the targeted trusted-contact-users (mirrors `notifyTrustedContacts`'s intent, but correctly — using `recipient_user_id`, unlike Firestore's known-broken phone-number matching per AUDIT.md §F), updating each push-channel row's status (`sent`/`failed`; left `pending` when the contact has no registered device — never conflating "not attempted" with "failed"). Self-delivery (reporter's own devices) is deliberately NOT duplicated through push — that's already Phase 12's WebSocket job.
- **Real bug caught by live-Postgres verification, not by any mocked unit test**: the `sos_recipients` status-update query reused one placeholder (`$1`) both as a value assigned to `status` (varchar) and compared against a string literal in a `CASE`, which Postgres's parser rejects ("inconsistent types deduced for parameter $1") — a mocked `pool.query` never parses SQL, so this only surfaced against the real database. Fixed by passing the value through two separate placeholders instead of reusing one.
- **New dependency**: `firebase-admin` (the official, current Google Node.js FCM integration — not a new provider, just the correct server-side library for the one already in use).
- **49 new tests** across 6 files (`fcm`, `pushNotificationService`, `deviceService`, `deviceRoutes`, `sosServicePush`.test.ts, plus fixes to `sosService.test.ts` for the new push-row insert): no-config/malformed-credential safe degradation, 500-token chunking, per-token FCM-error-code-based token removal (never removes a token for a transient failure), per-user sent/failed/no_device attribution, device ownership (IDOR: another user can't delete/read your device), identity-spoof resistance, duplicate/multi-device registration, rate limiting, SOS broadcast content (reporter name, category, message, coordinates — never a token/secret, tested explicitly), targeted-push status transitions, idempotent-retry produces no spurious notification, provider/step failures never fail the underlying SOS write. Also ran a live end-to-end script against real Postgres (temporary, deleted after use; found and fixed the bug above): real multi-device registration, ownership enforcement, a real SOS event producing both a real SMS row and a real PUSH row, the push row correctly staying `pending` (contact has no device) vs `failed` (contact has a device but FCM is unconfigured) — never fabricating `sent`. Full suite: **303/303 passing** (254 pre-existing + 49 new, zero regressions). `typecheck`/`lint`/`build` all clean.
- No new migration — `devices` already existed from Phase 1.
- **Deferred, not built**: Flutter-side device-token registration/wiring (no Flutter file touched — same backend-first pattern as every other phase; the app still only writes FCM tokens to Firestore today), any employee/moderation notification (report created, moderation action taken, review case opened) — not specified anywhere, explicitly not invented per this phase's own instruction. Real device/provider delivery is unverified — no `FIREBASE_SERVICE_ACCOUNT_JSON` exists in this environment; this is a genuine external-credential blocker, not a code gap (mirrors Phase 4C's real-Android-device blocker).
- Not deployed; no VPS/Docker/Nginx/DNS/PostgreSQL-production/Orbyatravel/Firebase-removal file touched; no Flutter file touched; nothing committed.

## 2026-09-05 — Phase 16 (Moderation/review workflow — review-case + moderation-action; last-100-messages deferred) — backend only

- Inspected first: PLAN.md's Phase 16 one-liner ("review queue, last-100-
  messages access, full audit trail"), `review_cases`/`moderation_actions`/
  `employee_actions`/`message_review_access_log` DDL, Phase 14's
  `maybeOpenReviewCase` (already live, dormant until a threshold is
  configured), Phase 15's RBAC/employee-auth (reused unchanged). Confirmed
  zero existing moderation code anywhere (backend or Flutter).
- **Key schema finding**: `user_reports` has NO `review_case_id` column —
  a case connects to its reports only via `target_user_id` =
  `reported_user_id`, and `review_cases.report_count_at_open` is a
  snapshot count, not a captured list of report ids. "The reports for a
  case" is therefore necessarily every report ever filed against that
  target, including ones filed after the case opened — not an assumption,
  the only relationship the schema actually supports.
- **Key design finding**: nothing in this codebase has ever SET
  `users.account_status` to `'suspended'` or `'deleted'` before this
  phase, even though `requireAuth`/`wsAuth` have checked for and blocked
  both since Phase 4 — dead code until now. `moderation_actions.action_type`
  already enumerates `suspend_temporary`/`suspend_permanent`/`delete`,
  identically named to the two account_status values nothing else
  produces. Implementing that mapping is the literal, only sensible
  reading of the schema's own naming, not an invented business rule.
- **`moderationService.ts`** (named exactly as `docs/AUDIT.md` §Q
  anticipated): `listReviewCases(status?)`, `getReviewCaseWithReports(id)`,
  `takeModerationAction(reviewCaseId, employeeId, {actionType, reason})`.
  The action function: locks the case row (`SELECT ... FOR UPDATE`) inside
  one transaction, 404s if missing, 409s if already closed (this is also
  what safely rejects a duplicate/replayed action). For every
  `actionType` except `escalate`: records the `moderation_actions` row,
  closes the case (`closed_at`/`closed_by_employee_id`), resolves every
  currently-open `user_reports` row against the target
  (`status='dismissed'` for `dismiss`, else `'actioned'`, with
  `resolution`/`resolved_by_employee_id`/`resolved_at` filled in — without
  this, `uq_user_reports_open_pair` would block new reports against an
  already-actioned user forever), and — only for the two suspend variants
  and `delete` — updates `users.account_status`. `escalate` records the
  action and changes nothing else: no reassignment, routing, or
  notification exists anywhere in the spec, so none was built.
- **Deliberately NOT built**: last-100-messages access — `MESSAGE_REVIEW`
  permission name reserved for it, `message_review_access_log` table
  still unused — blocked on Phase 10 (chat/messages), which has no
  Flutter feature or data behind it at all; building a "last 100
  messages" endpoint against a table with zero rows would be a hollow
  feature, not a real one. A general `GET /employee/reports` independent
  of any review case — PLAN.md says "review queue", which maps to
  `review_cases`, and Phase 14's own report explicitly deferred that
  decision rather than assuming it. Any UI — no employee UI of any kind
  exists yet (Phase 15's note).
- **Endpoints** (`routes/employee/moderationRoutes.ts`, mounted at
  `/api/v1/employee/review-cases`): `GET /` (list, optional
  `?status=open|closed`), `GET /:id` (case + every report against its
  target), `POST /:id/actions` (take an action). Permission names reuse
  the employee_permissions table's OWN example vocabulary (`USER_VIEW`,
  `USER_SUSPEND`) rather than inventing new ones — `USER_SUSPEND` gates
  every action type here, not just literal suspension, matching the
  schema's per-capability (not per-action-type) permission granularity.
- **Audit**: `moderation_actions` itself IS the audit trail for
  moderation (each row: who, what, against whom, why, when) — nothing
  also written to `employee_actions`, which its own doc comment says is
  for portal-administration actions specifically, distinct from
  moderation. `performedByEmployeeId` always comes from
  `req.authEmployee.id`; never a client-supplied field (tested).
- **36 new tests** (`moderationService.test.ts` 15,
  `moderationRoutes.test.ts` 21): every action type's exact side effects
  (dismiss/warn/suspend×2/delete/escalate), FOR UPDATE locking, 404/409
  state-transition guards, SQL-injection-shaped input passed as a bound
  parameter never concatenated, identity-spoof resistance, a normal
  consumer-user session explicitly proven unable to reach these routes
  (wired to `requireEmployeeAuth`, not `requireAuth`), permission
  allow/deny/super-admin-bypass, malformed input, reporter identity
  correctly exposed only in the employee-facing report view (never the
  consumer-facing one). Also ran a live end-to-end script against real
  Postgres (temporary, deleted after use) chaining all three phases:
  configured a real `report_threshold` via Phase 15 → submitted real
  reports via Phase 14's `reportService` → confirmed the case
  auto-opened and `account_status` flipped to `review_required` →
  employee viewed the real case + reports → took a real
  `suspend_temporary` action → confirmed the case closed, both reports
  resolved to `actioned`, `account_status` flipped to `suspended`, and a
  second action against the now-closed case was rejected with 409. Full
  suite: **254/254 passing** (218 pre-existing + 36 new, zero
  regressions — Phase 14/15 behavior unchanged). `typecheck`/`lint`/
  `build` all clean.
- No new migration needed — every table Phase 16 uses already existed
  from Phase 1.
- Not deployed; no VPS/Docker/Nginx/DNS/PostgreSQL-production/Orbyatravel/
  Firebase file touched; no Flutter file touched; nothing committed.

## 2026-09-05 — Phase 15 (Employee Portal — backend infrastructure only) — backend only

- Inspected first: `docs/AUDIT.md` §K/§W/§Q and the Decisions section, plus
  the `employees`/`employee_permissions`/`review_cases`/
  `moderation_actions`/`employee_actions`/`message_review_access_log`/
  `admin_settings` DDL already in `001_init_schema.sql`. Confirmed zero
  existing employee/admin/RBAC code anywhere (backend or Flutter) — a
  ground-up build, matching §K's own "None exists" note.
- **Scope decision**: PLAN.md's Phase 15 one-liner ("separate privileged
  surface, roles, granular permission table") and AUDIT.md §Q's named
  files (`routes/employee/*`, `middleware/rbac.ts`) describe
  *infrastructure* — identity, auth, RBAC — not the review queue itself,
  which AUDIT.md §Q separately names `moderationService.ts` for and
  PLAN.md assigns to Phase 16. Built infrastructure only; the moderation
  workflow is explicitly Phase 16's job, not touched here.
  - Also built, as a **necessary bootstrap**, not scope creep: employee
    account management (create/list employees, grant/revoke permissions)
    — without it there is no way to ever populate `employee_permissions`
    at all — and `admin_settings` CRUD, which Phase 14's own report
    flagged as missing ("no Phase 15 admin API exists yet to set
    [report_threshold]").
  - **Flutter Web employee UI NOT built**: `docs/AUDIT.md`'s Decision 5
    names Flutter Web as the eventual technology, but no employee UI of
    any kind exists yet, and Phase 15's own spec text doesn't call for it
    this round — consistent with every other phase's backend-first
    pattern (4/5/6/11). Flagged as a specification gap for whoever starts
    the UI: no login-flow/navigation/screen spec exists yet either.
  - **No SOS integration**: nothing in PLAN.md or AUDIT.md specifies
    employee access to SOS events — none was built (would have required
    inventing dispatch/escalation/review semantics with no spec).
- **Employee auth** (`employeeAuthService.ts`, `employeeAuthMiddleware.ts`,
  `routes/employee/authRoutes.ts`): email+password login (bcrypt, cost 12)
  against `employees.password_hash`, issuing a JWT access+refresh pair
  signed with **entirely separate secrets**
  (`EMPLOYEE_JWT_ACCESS_SECRET`/`EMPLOYEE_JWT_REFRESH_SECRET`) from the
  consumer `JWT_ACCESS_SECRET`/`JWT_REFRESH_SECRET` pair — verified live
  that an employee token cannot be used as a consumer token or vice versa.
  Refresh-token rotation tracked in a new `employee_sessions` table
  (mirrors `sessions` exactly; kept separate because `sessions.user_id` is
  FK'd to `users`, and employees are a documented separate identity
  space). Invalid email / wrong password / disabled account are all
  indistinguishable 401s. `GET /employee/me` mirrors `GET /api/v1/me`.
- **RBAC** (`employeePermissionService.ts`, `middleware/rbac.ts`):
  `SUPER_ADMIN` implicitly has every permission (no DB row needed, per
  the schema's own doc comment); `ADMIN`/`EMPLOYEE` need an explicit
  `employee_permissions` row for the exact permission string — never
  inferred from role name. Permission strings are free text (VARCHAR(60),
  no CHECK constraint) — not a hardcoded enum, matching the table's own
  "not a hardcoded enum switch" design note.
- **Employee management** (`employeeService.ts`,
  `routes/employee/employeeManagementRoutes.ts`): create/list employees,
  grant/revoke permissions — all gated behind an `EMPLOYEE_MANAGE`
  permission (super_admin has it implicitly). Password hashing happens
  server-side; the hash is never accepted from a client and never
  returned in any response.
- **`admin_settings` CRUD** (`adminSettingsService.ts`,
  `routes/employee/settingsRoutes.ts`): generic key/value/description,
  gated behind a `SETTINGS_MANAGE` permission — verified live that
  writing `report_threshold` here is now readable by
  `reportService.ts`'s dormant threshold check, unblocking it for the
  first time.
- **New dependency**: `bcryptjs` (pure-JS, no native bindings — avoids
  node-gyp/Docker cross-compile concerns for a value genuinely required
  by the pre-existing `password_hash` column; no hashing library existed
  in this project before).
- **New, additive migration**: `002_employee_sessions.sql` — one new
  table only, no existing table/column altered. Applied cleanly to the
  real local Postgres instance.
- **68 new tests** across 7 files (`employeeAuthService`,
  `employeePermissionService`, `employeeAuthMiddleware`, `rbac`,
  `employeeAuthRoutes`, `employeeManagementRoutes`,
  `employeeSettingsRoutes`.test.ts): login success/failure/disabled-
  account, cross-identity-space token rejection, RBAC allow/deny/
  super_admin-bypass, unauthenticated/insufficient-permission/malformed-
  input rejection on every route, identity-spoof resistance (grantedBy/
  updatedBy always from the session, never the request body),
  `password_hash` never exposed anywhere, rate limiting. Also ran a live
  end-to-end script against real Postgres (temporary, deleted after use):
  created real employees, a real bcrypt-backed login, confirmed the real
  JWT cross-verification boundary, a real permission grant taking effect,
  and a real `admin_settings` round trip. Full suite: **218/218 passing**
  (150 pre-existing + 68 new, zero regressions). `typecheck`/`lint`/
  `build` all clean.
- Not deployed; no VPS/Docker/Nginx/DNS/PostgreSQL-production/Orbyatravel/
  Firebase file touched (the `docker/.env.prod.example` edit is a
  template/documentation file, not a live deployment); no Flutter file
  touched; nothing committed.

## 2026-09-05 — Phase 12 (WebSocket realtime — SOS self-delivery only) — backend only

- Inspected first: `src/websocket/wsServer.ts`/`wsAuth.ts` already existed,
  carried over from the pre-pivot scaffold and already updated (2026-09-04)
  to verify the current ResQNet JWT access token instead of Firebase —
  connection registry (userId -> sockets), `broadcastToUser()`, upgrade
  auth (Bearer header or `access_token` query fallback), disconnect
  cleanup. It had never been wired to an actual domain event, and had zero
  test coverage. Flutter has no WebSocket client code anywhere — nothing
  to inspect/change there.
- **Scope decision**: the only realtime behavior justified by what
  actually exists today is SOS create/status-update delivery back to the
  *same* reporting user's other connected devices (`docs/PLAN.md` names
  "SOS-status delivery" explicitly, and self-delivery needs no new
  authorization model — `broadcastToUser` only ever reaches sockets
  already authenticated as that exact user). Explicitly NOT built:
  pushing to `sos_recipients.recipient_user_id` (other users) — doing so
  would require inventing undefined semantics (is this a "sent" delivery
  for a row whose `channel` is hardcoded `'sms'` from Phase 11? what data
  shape reaches a third party?); chat/message realtime (Phase 10 doesn't
  exist); presence/typing/read-receipts (never specified anywhere).
- **`sosService.ts`**: `createSosEvent`/`updateSosEventStatus` now call
  `broadcastToUser(reporterUserId, {type, event})` after a successful
  write (never on the idempotent-retry path — nothing changed, no
  spurious event). Best-effort: a broadcast failure never fails the
  underlying write, same isolation pattern as Phase 11's trusted-contact
  fan-out and Phase 14's review-case step.
- **`wsServer.ts`**: added an inbound `message` handler purely for safety
  — no inbound command protocol is specified anywhere, so it JSON-parses
  defensively and always ignores the result (logs receipt, never the raw
  payload); a non-JSON or unrecognized message can no longer be a code
  path that was simply never exercised. Hardened `broadcastToUser` so one
  socket's `.send()` throwing can't stop delivery to a user's other
  devices.
- **26 new tests**: `wsAuth.test.ts` (10, mirrors `authMiddleware.test.ts`'s
  exact case list — valid/missing/malformed/expired token, suspended/
  deleted/review_required account, header-vs-query precedence);
  `wsServer.test.ts` (12, real `http.Server` + real `ws` client against
  mocked session/user services — accept/reject on real upgrade handshakes,
  wrong-path socket destruction, cross-user broadcast isolation ("never
  leaked to the other user"), multi-device delivery, disconnect cleanup,
  malformed/unrecognized inbound messages not crashing the connection);
  4 more added to `sosService.test.ts` for the new broadcast calls
  (fired on create/update, never on retry or a failed update, isolated
  from broadcast failures). Also ran a full live end-to-end script
  (temporary, deleted after use): real JWT issued by `sessionService` →
  real authenticated WS client → real `createSosEvent()` against real
  local Postgres → confirmed the live client actually received the
  `sos_created` broadcast. Full suite: **150/150 passing** (124
  pre-existing + 26 new, zero regressions). `typecheck`/`lint`/`build` all
  clean.
- No new port exposed — same HTTP server/port the Express app already
  listens on, upgraded in-process; no Nginx/DNS/Docker/VPS change.
- Not deployed; no VPS/Docker/Nginx/DNS/PostgreSQL-production/Orbyatravel/
  Firebase file touched; no Flutter file touched; nothing committed.

## 2026-09-05 — Phase 11 (SOS migration only — groups deferred) — backend only

- Inspected first: the Flutter app has no group-chat/group-SOS feature at
  all (`groups`/`group_members` are schema-only, never referenced outside
  the DDL) — implementing "groups" now would mean inventing product
  behavior with no spec, so this phase's scope was narrowed to SOS only
  (user-approved) rather than guessed.
- Also inspected the concrete existing SOS flow being migrated:
  `sos_service.dart.triggerSos()` (creates an alert; its Firestore "upload"
  is actually a `debugPrint` stub, not a real write),
  `sos_dispatch_service.dart` (writes a Firestore `sos_dispatch/{alertId}`
  doc consumed by the `notifyTrustedContacts` Cloud Function, then opens a
  pre-filled SMS to trusted contacts + country hotline numbers), and
  `sos_history_screen.dart` (reads `sos_history/{uid}/messages`).
- **`POST/GET /api/v1/sos`, `PATCH /api/v1/sos/:id`** (`sosRoutes.ts`,
  `sosService.ts`, `sosSchemas.ts`, `models/SosEvent.ts`). `event_id` is
  the client-generated idempotency key the schema comment describes for
  offline-retried sends: a unique-violation on retry looks up and returns
  the existing event instead of erroring, *except* when the same event_id
  belongs to a different user, which is refused (409) rather than leaking
  that user's event back. `PATCH` accepts `acknowledged`/`resolved`/
  `false_alarm` only — `open` is server-assigned, never a client-chosen
  transition — and sets `resolved_at` only on the two terminal statuses.
- **Trusted-contact fan-out**: on first creation (never on an idempotent
  retry), one `sos_recipients` row per the reporter's own trusted contact
  (Phase 5) is created as `channel='sms', status='pending'`, populating
  `recipient_user_id` when that contact is also a ResQNet user. Actual
  delivery is Phase 8's SMS-provider system, not implemented yet — rows
  are deliberately left `pending`, schema-faithful rather than invented
  (same reasoning as Phase 14's dormant review-case logic). Explicitly
  excluded from this phase: police/disaster hotline numbers (no per-user
  DB record backs those — static country lookup, Phase 8/9 concern) and
  "all nearby ResQNet users" fan-out (push infrastructure, Phase 17).
  Fan-out failing is best-effort and never fails the SOS event write
  itself — mirrors `reportService.ts`'s `maybeOpenReviewCase` isolation.
- Caught and fixed during implementation, before it shipped: an initial
  draft ran the insert-then-idempotent-lookup inside one `withTransaction`
  client — a caught unique-violation leaves that Postgres transaction
  aborted, so the follow-up SELECT on the same client would itself have
  failed. Fixed by doing the idempotent-retry lookup on a fresh
  `pool.query` connection instead.
- Reused the existing `sosRateLimiter` (5/60s, keyed by authenticated
  user) — already present in `rateLimiter.ts` from an earlier phase,
  pre-commented for this exact use.
- **26 new tests** (`sosService.test.ts`, `sosRoutes.test.ts`): idempotent
  retry (same user / different-user rejection), fan-out population and
  its failure-isolation, numeric-string-to-number parsing, ownership
  scoping, status-transition `resolved_at` behavior, auth/validation
  rejection, identity-spoof resistance, rate limiting. Also ran a live
  sanity check against the real local Postgres instance (temporary
  script, deleted after): created a user + trusted contact, created an
  event, retried with the same `event_id`, confirmed exactly one
  recipient row (not two), listed, resolved, then cleaned up — all
  matched expected behavior. Full suite: **124/124 passing** (98
  pre-existing + 26 new, zero regressions). `typecheck`/`lint`/`build` all
  clean.
- Not deployed; no VPS/Docker/Nginx/DNS/PostgreSQL-production/Orbyatravel/
  Firebase file touched; no Flutter file touched; nothing committed.

## 2026-09-05 — Phase 14 (Reporting) — backend only

- **`POST /api/v1/reports`** (`reportRoutes.ts`, `reportService.ts`,
  `reportSchemas.ts`, `models/UserReport.ts`). Schema inspected first:
  `user_reports` supports exactly one target type (another `users` row via
  `reported_user_id` — no polymorphic target-type column), so no other
  report-target kind was invented. Dedup relies entirely on the existing
  partial unique index (`uq_user_reports_open_pair`, open reports only) —
  the Postgres unique-violation is caught and mapped to a safe 409, not a
  raw DB error; FK-violation (nonexistent target) → 400; check-violation
  (self-report) → 400, with an app-level self-report check ahead of the
  DB round-trip too.
- **Review-case linkage**: after a report is recorded, a best-effort step
  checks `admin_settings` for `report_threshold`/`report_window_days`. If
  configured and crossed, opens a `review_cases` row
  (`trigger_reason='report_threshold'`) and promotes the target's
  `users.account_status` from `active` to `review_required` (a value the
  schema already defined but nothing had used yet). **`admin_settings` has
  zero rows today** — no seed, no Phase 15 admin API exists to set these
  — so this logic is schema-correct but dormant until real values are
  configured; no fallback default was hard-coded (explicitly disallowed
  by the original spec). A failure in this side-effect step never rolls
  back or fails the reporter's already-successful report submission.
- **No GET endpoint added** — reading back one's own reports, or anything
  about `review_cases`, wasn't part of this phase's explicit scope and
  risks exposing moderation-internal state to the reported-on user;
  deferred as a deliberate decision, not an oversight.
- New `reportRateLimiter` (10/60s, keyed by authenticated user), following
  the exact pattern already used for `sosRateLimiter`/`authRateLimiter`.
- **23 new tests** (`reportService.test.ts`, `reportRoutes.test.ts`)
  covering: self-report rejection, successful creation, all three mapped
  Postgres error codes, review-case threshold crossed/not-crossed/already-open,
  side-effect-failure isolation, auth/validation rejection, identity-spoof
  resistance, rate limiting. Full suite: **98/98 passing** (75 pre-existing
  + 23 new, zero regressions). `typecheck`/`lint`/`build` all clean;
  verified the compiled `dist/` actually contains the new files.
- Not deployed; no VPS/Docker/Nginx/DNS/PostgreSQL-production/Orbyatravel/
  Firebase file touched; no Flutter file touched; nothing committed.

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
