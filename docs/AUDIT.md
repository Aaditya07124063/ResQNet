# ResQNet — Phase 0 Complete Audit

Status: **read-only audit, no implementation performed**. Date: 2026-09-04.

## ⚠️ Architecture pivot notice

This audit is written against the **new target architecture** (Google Sign-In V2,
PostgreSQL, MinIO, MapLibre, configurable email/SMS providers, Employee Portal,
Orbyatravel isolation) as specified in the latest instructions. This **supersedes**
an earlier, narrower "Hostinger migration" plan that this project was mid-way
through executing, which explicitly said to *keep* Firebase Authentication and use
*MySQL*. That earlier plan had already produced:

- `backend/` — a working Express + TypeScript scaffold: env config, structured
  logging, Firebase Admin SDK token verification middleware, App Check
  verification middleware, rate limiting, error handling, a MySQL connection
  pool (`mysql2`), a MySQL schema (`users`, `trusted_contacts`, `groups`,
  `group_members`, `messages`, `sos_events`, `locations`, `official_alerts`,
  `audit_log`), and a WebSocket server with Firebase-token-authenticated
  upgrades. It builds, typechecks, and lints clean, but **has not been deployed
  and has no Docker/CI setup**.
- No Flutter code was changed under that plan.

Under the new architecture, the **auth-verification and MySQL-specific pieces of
`backend/` are obsolete** (Google Sign-In V2 replaces Firebase Auth verification;
PostgreSQL replaces MySQL) but the **general Express/WebSocket/rate-limiting/
logging scaffolding pattern is reusable** as a starting shape once redirected.
**No `backend/` files have been touched during this audit** — this is noted for
your decision, not acted on. See "Migration risks" (§X) for what that means
concretely.

**This document does not reconcile that conflict — it flags it for you to
confirm before Phase 1 implementation begins**, per "DO NOT make assumptions
where the requirement is unclear."

---

## A. Current architecture

```
Flutter app (lib/)
  |
  +-- Firebase Authentication (phone OTP + Google Sign-In wrapped through
  |   FirebaseAuth.signInWithCredential)
  +-- Cloud Firestore (7 collections, see §D)
  +-- Firebase Cloud Messaging (push tokens + foreground/background handling)
  +-- Firebase Storage (profile pictures only)
  +-- Cloud Functions (functions/index.js — 3 triggers, Admin SDK)
  +-- On-device crash/earthquake detection (sensors_plus, own scoring pipeline)
  +-- Sensor recording/replay (test/debug infrastructure)
  +-- Mesh (nearby_connections on Android, native Swift plugin on iOS) — SOS
  |   relay over Bluetooth/Wi-Fi, writes history to Firestore when back online
  +-- flutter_map + OpenStreetMap tiles + flutter_map_tile_caching (offline
      tile cache) — NOT MapLibre, NOT Google Maps
```

A separate, partially-built `backend/` (Express/TypeScript/MySQL) exists from
the prior migration plan — see the pivot notice above. It is not wired to the
Flutter app in any way yet (no API client exists in `lib/`).

## B. Current Firebase dependencies

From `pubspec.yaml` (resolved versions in `pubspec.lock`):

| Package | Resolved | Purpose in this app |
|---|---|---|
| `firebase_core` | 3.15.2 | App bootstrap |
| `firebase_auth` | 5.7.0 | Phone OTP + Google Sign-In wrapper |
| `cloud_firestore` | 5.6.12 | All app data (see §D) |
| `firebase_messaging` | 15.2.10 | Push notifications |
| `firebase_storage` | 12.4.10 | Profile pictures only |

**Not present at all**: `firebase_app_check`, `firebase_analytics`,
`firebase_crashlytics`, `firebase_remote_config`.

15 files in `lib/` reference Firebase; full per-file breakdown is in the
earlier H0 inspection (still valid, reproduced in relevant sections below).

## C. Current authentication flow

`lib/features/auth/auth_service.dart` (115 lines) wraps `FirebaseAuth`:

- **Phone OTP**: `FirebaseAuth.verifyPhoneNumber` → `PhoneAuthProvider.credential`
  → `_auth.signInWithCredential`. Firebase (not ResQNet) owns OTP delivery,
  rate limiting, and verification.
- **Google Sign-In**: uses `google_sign_in: ^6.2.1` (resolved 6.3.0) to get a
  `GoogleSignInAccount`, then wraps its `idToken`/`accessToken` into a
  `GoogleAuthProvider.credential` and calls `_auth.signInWithCredential` —
  i.e. **Google Sign-In is already integrated, but only as a credential
  federated into Firebase Auth, not as ResQNet's own verified identity.**
  Moving to "Google Sign-In V2" as its own backend-verified system means:
  removing the `signInWithCredential` step, sending the Google ID token
  directly to the ResQNet backend, and having the backend verify it against
  Google's tokeninfo/certs endpoint (or the current recommended
  `google-auth-library` server-side flow) — **the exact current API surface
  needs verification against Google's live documentation before
  implementation** (per your Final Rule); "Google Sign-In V2" most likely
  refers to Google's newer Sign-In for Web/Credential Manager-based flow
  (`google_sign_in` package v7+ uses Credential Manager on Android / redesigned
  iOS flow) rather than a versioned server API — **do not assume which one is
  meant; confirm before Phase 4.**
- `lib/app.dart` — `_AuthGate` widget listens to `FirebaseAuth.instance.authStateChanges()`; **bypasses login entirely when `kDebugMode` is true** (pre-existing, flagged again here as directly relevant to the auth migration).
- No password-based auth exists anywhere (expected/correct — never stored).

## D. Current Firestore collections

| Collection | Path shape | Purpose |
|---|---|---|
| `user_profiles` (+`trusted_contacts` subcoll.) | `user_profiles/{uid}` | Profile fields (name, blood group, address, country/state/city, allergies, medications, emergencyContact, photoUrl) + nested trusted contacts |
| `sos_history` (+`messages` subcoll.) | `sos_history/{uid}/messages/{id}` | Mesh SOS message log, written on every mesh broadcast/relay |
| `sos_broadcasts` | `sos_broadcasts/{alertId}` | Nearby-user SOS alerts, create-only, Cloud Function fan-out |
| `sos_dispatch` | `sos_dispatch/{alertId}` | SOS → trusted-contact/hotline dispatch record, create-only, Cloud Function fan-out. **Single write site**: `lib/core/services/sos_dispatch_service.dart:135`; **3 callers**: `sos_screen.dart:91`, `crash_countdown_dialog.dart:75`, `earthquake_alert_dialog.dart:78`; **no client ever reads it** |
| `user_tokens` | `user_tokens/{uid}` | FCM push tokens |
| `seismic_events` | `seismic_events/{eventId}` | Earthquake candidate reports, create-only, Cloud Function clustering |

`firestore.rules` (62 lines, **untracked in git** — unverified whether it
matches what's actually deployed) is owner-scoped/create-only throughout; no
overly permissive rules found. Full text is in the prior H0 report.

## E. Current Firebase Storage usage

Single use site: `lib/features/profile/profile_screen.dart:124-129`
(`_pickAndUploadPhoto`) — uploads to
`FirebaseStorage.instance.ref('profile_pictures/$uid.jpg')`, then stores the
resulting download URL as `photoUrl` on the Firestore profile document via
`ProfileService.saveProfile`. `storage.rules` (20 lines, also untracked)
allows any signed-in user to **read** any profile picture (no privacy control
at all today — directly relevant to §10's requirement); write is restricted
to the owner's own filename, size <5MB, `image/*` only.

**No other Storage usage** — no attachments, no incident media.

## F. Current FCM/notification implementation

`lib/core/services/notification_service.dart`:
- Registers/persists FCM token to Firestore `user_tokens/{uid}` on init and
  `onTokenRefresh`.
- Handles foreground and background messages.
- Writes `sos_broadcasts/{alertId}` (§D) which a Cloud Function fans out via
  `admin.messaging().sendEachForMulticast`.
- No APNs-specific code found beyond what `firebase_messaging` handles
  internally; no OneSignal or other push provider present.
- `functions/index.js` — 3 Firestore-triggered Cloud Functions
  (`sendSosNotification`, `notifyTrustedContacts`, `correlateSeismicEvent`),
  all Admin SDK, all bypass Firestore rules by design.
- **Known latent bug** (carried over from prior audit): `notifyTrustedContacts`
  matches trusted-contact phone numbers against a `phone` field on
  `user_profiles` that the client (`ProfileService`) never actually writes —
  this push path is silently broken today.

## G. Current map implementation

**Not MapLibre, not Google Maps.** Uses `flutter_map: ^7.0.2` +
`latlong2: ^0.9.0` + `flutter_map_tile_caching: ^9.1.0`, tiles from OpenStreetMap
(`lib/core/services/map_cache_service.dart`, `lib/features/map/map_screen.dart`).
`flutter_map_tile_caching` already provides offline tile download/caching —
this is functioning prior art for the "offline map packages" requirement in
§8, just on a different rendering engine. No abstraction layer exists (no
`MapService`/`MapProvider` interface) — the screen talks to `flutter_map`
directly.

## H. Current user/profile implementation

`lib/core/services/profile_service.dart` — cache-first (SharedPreferences key
`profile_cache`) with background Firestore sync to `user_profiles/{uid}`.
Fields: name, fatherName, age, address, bloodGroup, allergies, medications,
emergencyContact, photoUrl, country, state, city. **No `phone`, no email
verification status, no account status, no last_login_at** — none of the
fields required by §3's target user record exist today.

`lib/core/services/trusted_contacts_service.dart` — separate cache-first
service, Firestore sync to `user_profiles/{uid}/trusted_contacts/{id}`.
Distinct from `emergency_contacts_service.dart`, which is static hardcoded
national hotline data (no network calls) — not user data, don't confuse the
two when planning the PostgreSQL schema.

## I. Current message implementation

Two independent message-shaped things exist today, not one:
1. **Mesh relay history** (`mesh_service.dart` writes `sos_history/{uid}/messages/{id}`
   on every Bluetooth/Wi-Fi mesh broadcast/relay) — read by
   `sos_history_screen.dart` via `.snapshots()`.
2. **`sos_dispatch`** (§D) — not really a "message," a one-shot dispatch record.

**There is no group-chat/"Communicate" feature implemented anywhere today** —
§13's groups/group_members/messages/conversations system is entirely new
build, not a migration of existing functionality (confirmed: no `groups`
collection, no group screen, no conversation model anywhere in `lib/`).

## J. Current reporting/moderation implementation

**None exists.** No `user_reports`, no moderation actions, no report UI, no
threshold logic anywhere in the repository. §15-21 (user reporting, admin
threshold, employee review workflow, last-100-messages review) is a
ground-up new build, not a migration.

## K. Current admin implementation

**None exists.** No admin panel, no admin API, no admin settings storage, no
role/permission model anywhere in the repository (Flutter or `functions/`).
§13-14, §22 (Employee Portal, granular permissions, admin settings) is a
ground-up new build.

## L. Current backend architecture

The `backend/` directory from the prior Hostinger/MySQL plan (see pivot
notice). Concretely, what exists and what's reusable vs. obsolete under the
new architecture:

| File | Reusable as-is? |
|---|---|
| `src/app.ts`, `src/server.ts` (Express bootstrap, helmet, CORS, JSON limits) | Yes — provider-agnostic |
| `src/utils/{logger,httpError,asyncHandler}.ts` | Yes |
| `src/middleware/{errorHandler,rateLimiter}.ts` | Yes |
| `src/middleware/authMiddleware.ts` (verifies **Firebase** ID tokens) | **No** — replace with Google Sign-In V2 verification |
| `src/middleware/appCheckMiddleware.ts` | Keep only if Firebase App Check stays in scope; the new prompt doesn't mention App Check at all — **open question, see Open Questions** |
| `src/config/firebaseAdmin.ts` | Only the parts needed if FCM/App Check remain; auth verification part is obsolete |
| `src/database/pool.ts`, `migrate.ts`, `migrations/001_init_schema.sql` (**MySQL**, via `mysql2`) | **No** — replace with PostgreSQL (`pg`) equivalents |
| `src/models/User.ts`, `src/services/userService.ts` | Shape is reusable, implementation (MySQL queries, Firebase UID) is not |
| `src/websocket/{wsServer,wsAuth}.ts` | Structure reusable; `wsAuth.ts` needs the same auth-provider swap |
| `src/routes/index.ts` (single `/me` route) | Trivial, reusable |

No Dockerfile, no docker-compose, no `.github/workflows/` exist yet under
`backend/` — §28's Docker/Compose deployment model was never implemented,
only documented as a plan.

## M. Current Docker architecture

**None exists anywhere in the repository** (`find . -iname "Dockerfile*" -o
-iname "docker-compose*"` returns nothing, excluding `node_modules`). The
`resqnet-api`/`resqnet-db`/`resqnet-minio` container topology in §1/§28 is
entirely new build.

## N. Current Hostinger deployment

**Nothing is deployed.** No `.env.prod`, no live VPS configuration touched by
this repository. Per your prior confirmation: Hostinger VPS (KVM), full SSH
access available to you as the sole host operator. No domain, GitHub org, or
free port block has been confirmed yet (still open from the prior H1 attempt)
— **these are still required inputs regardless of which architecture we
build**, see Open Questions.

**No `orbya`/`Orbyatravel` reference exists anywhere on this machine**
(`grep -rli orbya ~/Desktop/dev/` returned nothing) — I have no visibility
into that other application or its VPS footprint at all. The isolation rules
in §2 can be followed procedurally (distinct network/container/volume names,
no shared credentials) but **I cannot verify no collision will occur without
you telling me what already exists on the VPS under the Orbyatravel name** —
this is a hard blocker for §2/§28 the same way the Hostinger plan/domain was
a blocker in the earlier H1 exchange.

## O. Security implications

- **Biggest net-new attack surface**: the Employee Portal + last-100-messages
  review capability (§19-21). This is the most sensitive thing in the entire
  spec — a privileged interface that can read private message content. It
  needs its own threat model (separate session/auth from the regular user
  app, mandatory audit trail, no ability for the Flutter/employee-web
  frontend to be trusted for the authorization decision — matches your §20
  requirement) before any code is written.
- **Credential-storage surface doubles**: today only Firebase issues secrets
  (service account key). The new architecture adds Google OAuth
  client secret, N email-provider API keys, N SMS-provider API keys/auth
  keys/secrets, MinIO access/secret keys, PostgreSQL credentials — all
  needing encryption-at-rest for the provider-config tables (§5's
  `encrypted_credentials` requirement) and a masking convention for admin UI
  display (§32's `••••••••1234`).
  the SMS providers.
- **Google Sign-In V2 verification detail matters a lot for security** — using
  the wrong/deprecated verification method here is a full auth bypass risk;
  this is the one place in the whole plan I most want to research the exact
  current API before writing a single line (per your Final Rule).
- **Profile-picture privacy (§10)** is a real, currently-open gap: today's
  `storage.rules` lets *any* signed-in user read *any* profile picture. The
  new architecture's server-enforced visibility is a genuine security fix,
  not just a nice-to-have.
- **Report-threshold abuse (§16-17)**: the spec already anticipates this
  correctly (review trigger, not auto-punish) — the audit finds no existing
  counter-abuse logic to build on, so the dedup/window/counting logic is
  fully new design work.

## P. Exact files that must change (once Phase 1+ begins — not now)

Flutter side (all currently Firebase-coupled):
- `lib/features/auth/auth_service.dart` — full rewrite (remove FirebaseAuth, add ResQNet session/token handling)
- `lib/app.dart` — swap `authStateChanges()` gate for ResQNet session state
- `lib/main.dart`, `lib/firebase_options.dart` — reduce/remove `Firebase.initializeApp` once Firestore/Storage/Messaging dependencies are actually migrated (not before)
- `lib/core/services/profile_service.dart`, `trusted_contacts_service.dart`, `mesh_service.dart`, `sos_dispatch_service.dart`, `notification_service.dart`, `earthquake_correlation_service.dart` — each currently talks to Firestore directly; each needs to move to the new ResQNet API client
- `lib/features/profile/profile_screen.dart` — Firebase Storage → MinIO-backed upload endpoint
- `lib/features/map/map_screen.dart`, `lib/core/services/map_cache_service.dart` — flutter_map's tile source swapped behind a new `MapService` abstraction (exact MapLibre package TBD — you said the use case comes later; don't touch yet)
- `functions/index.js` — logic ports to the new backend (Node/TS), then the Cloud Functions themselves get retired once parity is confirmed

Backend side: effectively all of `backend/` per §L's reusability table, plus everything net-new in §Q.

## Q. New files/services required (net-new, no existing equivalent)

- `backend/src/services/googleAuthService.ts` (or similar) — Google ID token verification
- `backend/src/database/` — PostgreSQL pool/client (`pg` or `postgres`), migrations rewritten for Postgres syntax (`SERIAL`/`UUID` types, `TIMESTAMPTZ`, etc. — not a straight copy-paste from the MySQL migration)
- `backend/src/services/{email,sms}/` — provider interfaces + adapters (`EmailProvider`, `SmsProvider`) + admin-facing provider-config CRUD + secret encryption
- `backend/src/services/storageService.ts` — MinIO client wrapper (`minio` npm package), signed-URL generation for private profile pictures
- `backend/src/routes/employee/*`, `backend/src/middleware/rbac.ts` — Employee Portal API + permission-check middleware
- `backend/src/services/moderationService.ts` — report counting/threshold/review-case state machine
- A **separate Employee Portal frontend** (web — not specified whether Flutter-web, a separate framework, or something else; **open question**, don't assume)
- `docs/ARCHITECTURE.md`, `docs/PLAN.md`, `docs/DONE.md` — created alongside this audit, per your request

## R. Database migration plan (high level — detailed schema is a Phase 1 deliverable, not here)

Firestore/current-state → PostgreSQL, table-by-table:
- `user_profiles` + subcoll. `trusted_contacts` → `users` + `user_profiles` + `trusted_contacts` (split identity from profile fields, matching §3/§11's separation)
- `sos_history/{uid}/messages` + `sos_dispatch` + `sos_broadcasts` → unified `sos_events` + `sos_recipients`
- `seismic_events` → folds into `sos_events` with a source/type discriminator, or stays a related table — **design decision for Phase 1**, not resolved here
- `user_tokens` → `devices` (push-token-per-device, matching §11's `devices` table)
- New, no Firestore precedent: `groups`, `group_members`, `messages`, `message_recipients`, `message_status`, `conversations`, `incidents`, `official_alerts`, `reports`/`user_reports`, `moderation_actions`, `employee_actions`, `admin_settings`, `email_providers`, `sms_providers`, `verification_attempts`, `sessions`, `audit_logs`

Do not run any migration until this is a reviewed, standalone Phase 1
document — this audit only maps the *sources*, not the target DDL.

## S. Authentication migration plan (high level)

1. Research current official Google Sign-In verification flow for a
   Node/TS backend (server-side ID token verification — likely
   `google-auth-library`'s `OAuth2Client.verifyIdToken`, but confirm against
   current docs, not memory).
2. Add `backend` Google verification + ResQNet session/access-token issuance
   (JWT or opaque session token — needs its own decision, not assumed here).
3. Add Flutter-side Google Sign-In V2 integration (package version TBD by the
   same research step), send ID token to backend instead of
   `FirebaseAuth.signInWithCredential`.
4. Run both systems in parallel behind a feature flag long enough to verify,
   then remove `firebase_auth` from `auth_service.dart`.
5. Decide the phone-OTP replacement path explicitly — §3's target flow is
   Google-only; the current app also supports **phone-number OTP sign-in**
   via Firebase, which the new spec doesn't mention as a *login* method (only
   as a *verification* step in §5-6). **Open question**: does phone sign-in
   as an independent login method go away entirely, or does it become
   "verify a phone number already associated with a Google-authenticated
   account"? This changes `login_screen.dart`/`otp_screen.dart` substantially
   either way — needs your decision before Phase 4.

## T. Storage migration plan (high level)

1. Stand up `resqnet-minio` (own container/volume/credentials/network, per §23).
2. Create buckets (`resqnet-profile-images` at minimum for parity with today).
3. Backend endpoint: validate MIME + extension + file signature (magic bytes,
   not just extension) + size limit + re-encode/resize server-side (today's
   client-side `imageQuality: 75`/512×512 resize in `profile_screen.dart` is
   client-controlled only — the new server-side validation in §9 is a real
   hardening, not redundant).
4. Store `profile_image_object_key` in PostgreSQL, not a public download URL.
5. Signed/controlled URL generation respecting `profile_picture_visibility`
   (§10) — authorization check happens before a URL/signed-access is ever
   handed out, matching your explicit "must not simply hide the image in
   Flutter" requirement.
6. Only after backend parity is verified: remove `firebase_storage` and its
   one call site.

## U. Email provider architecture (design note, not implementation)

Matches §4/§35 exactly as specified: `EmailService` → `EmailProvider`
interface → `ZeptoMailProvider`/`BrevoProvider`/future, admin-configured
priority + fallback chain, secrets never returned by normal admin API
responses (masked), used for verification/recovery/security notifications.
No existing code to migrate from — Firebase never provided email verification
in this app (no evidence of Firebase Email Link/Password auth anywhere).
**Before implementation**: pull ZeptoMail's and Brevo's *current* transactional-email API docs (auth method, request shape, rate limits, sender-domain verification requirements) — do not implement from memory/assumption.

## V. SMS provider architecture (design note, not implementation)

Matches §5/§35. Today's phone verification is 100% delegated to Firebase
(`verifyPhoneNumber`), so this is also a ground-up build, not a migration —
Firebase currently owns OTP generation, delivery, rate limiting, and
verification-code checking; all of that logic needs to be reimplemented
server-side (OTP generation, expiry, attempt/resend limits, rate limiting,
audit events per §6) since none of it exists in this codebase today outside
Firebase's black box. **Before implementation**: pull current official docs
for Sparrow SMS, MSG91/SMS91, 2Factor, and SMSCountry specifically — do not
reuse old/unofficial examples, per your Final Rule.

## W. Employee portal architecture (design note, not implementation)

No existing admin/employee concept to build on (§K). Needs, at minimum: a
separate authenticated surface (own login, not the consumer Google Sign-In
flow — likely email+password or SSO for staff, **undecided, not assumed
here**), `SUPER_ADMIN`/`ADMIN`/`EMPLOYEE` roles backed by a granular
permission table (not a hardcoded enum switch, per §14/§35's "modular"
principle applied consistently), and the review-case/last-100-messages
workflow in §19-21 with its own audit trail distinct from general
`audit_logs`.

## X. Migration risks

1. **Scope**: this is a full-stack replacement of auth, database, storage,
   and realtime, plus two entirely new subsystems (provider abstraction,
   employee/moderation portal) that have zero existing implementation to
   build from. This is materially larger than the "keep Firebase, add a
   Hostinger API layer" plan this project was previously executing partway
   through — flagged once at the top of this document, not repeated
   per-section, but it affects every phase's risk profile.
2. **Two prior instruction sets actively conflict** (keep-Firebase-Auth +
   MySQL vs. remove-Firebase-Auth + PostgreSQL). If both are meant to coexist
   somehow (e.g. a longer transitional period), that needs to be stated
   explicitly — this audit assumes the newer prompt is the current target and
   says so, but does not guess at a transition timeline that wasn't specified.
3. **sos_dispatch / crash / earthquake dispatch paths must not regress**
   during the auth+DB swap — these are the app's actual safety-critical
   paths. §26 correctly keeps detection on-device, but the *dispatch* side
   (writing an SOS, notifying trusted contacts) is exactly what's being
   rebuilt, so this needs explicit before/after parity testing, not just unit
   tests of the new system in isolation.
4. **Orbyatravel isolation cannot be independently verified by me** — I have
   no visibility into whatever already runs on the VPS under that name (§N).
5. **Google Sign-In V2 is a named-but-unverified technology** for this audit
   — treat every mention of it in this document as "to be confirmed against
   Google's current docs," not as settled.
6. **The prior `backend/` MySQL work becomes partially wasted effort** if this
   pivot is confirmed — worth deciding explicitly whether to delete it,
   archive it, or attempt a Postgres/Google-auth retrofit of the reusable
   parts (see §L's table) rather than a from-scratch rewrite.

---

## Decisions (resolved 2026-09-04)

1. **Architecture scope**: new architecture **fully replaces** the earlier
   Hostinger/Firebase-keep/MySQL plan. No parallel-transition period.
2. **Old `backend/` MySQL scaffold**: **deleted**. Removed from disk
   (it was fully untracked in git, so nothing was lost). Phase 1-3 build a
   fresh `backend/` against PostgreSQL + Google Sign-In V2.
3. **Firebase App Check**: **dropped**, along with Firebase Auth. No
   device-attestation layer for now — can revisit with a non-Firebase
   alternative later if abuse patterns justify it.
4. **Phone sign-in**: **kept as an independent login method**, alongside
   Google Sign-In V2 — not demoted to verification-only. Both are first-class
   login paths; phone OTP delivery/verification moves to the new
   provider-agnostic SMS system (§5/§V) instead of Firebase.
5. **Employee Portal frontend**: **Flutter Web**.
6. **Session/token model**: **JWT access token + refresh token**, refresh
   events tracked server-side (a `sessions` table) for revocation.

## Additional decision (2026-09-04)

9. **Domain deferred until app store / Play Store submission.** For VPS
   testing before then, the Flutter app talks directly to the VPS's
   IP:port over plain HTTP (`ResQNetEnvironment.vps` in
   `lib/core/network/api_config.dart`, set via `--dart-define`). The
   `production` environment still requires a real HTTPS domain before it
   will resolve — that guard is intentionally NOT relaxed to match, since
   shipping a real user-facing build over plain-IP HTTP would be a genuine
   downgrade, not just a convenience. Testing-over-IP and
   production-needs-a-domain are two different bars.

## Still open — needed before Phase 18 (deployment), not before Phase 1-4

7. GitHub org (for GHCR) and currently-free VPS port block — still
   unconfirmed from the earlier H1 exchange. The VPS's actual IP address is
   also still needed (for the `vps` testing environment above, not just for
   final deployment).
8. What already exists on the VPS under the Orbyatravel name, so isolation
   can be verified rather than assumed.
