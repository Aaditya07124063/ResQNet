# Release checklist

Tick only with evidence (a test run, a build log, a device report). **Blocker** items must be done before a public release. The others can be accepted as documented limitations.

## Backend

- [ ] **Blocker:** production database backup taken and a restore drill completed (`OPERATIONS.md`).
- [ ] **Blocker:** migrations 005–009 tested against a copy of the production database, then applied.
- [ ] **Blocker:** `OFFICIAL_ALERT_SIGNING_KEY`, `PROVIDER_CREDENTIALS_ENCRYPTION_KEY` and `TRUSTED_PROXY_HOPS` set; secrets stored outside the server.
- [ ] `npm run typecheck && npm run lint && npm test && npm run build` pass on the release commit.
- [ ] `npm run test:integration` passes against a scratch PostgreSQL.
- [ ] At least one SMS provider configured, and a real OTP delivered to a real phone (no SMS delivery claim until then).
- [ ] FCM service account configured and a push received on a real device.
- [ ] Old seismic Cloud Function: keep it until backend seismic corroboration (`POST /seismic/reports`) has been verified in production. Then remove it in a separate change.
- [ ] Retention periods decided and a purge job scheduled (`PRIVACY_AND_RETENTION.md`).

## Android

- [ ] **Blocker:** upload keystore created and kept safe; `android/key.properties` present on the build machine only. Without it, release builds are debug-signed and cannot be published.
- [ ] **Blocker:** `pubspec.yaml` `version` bumped (currently `1.0.0+1`).
- [ ] Release build: `flutter build appbundle --release --dart-define=RESQNET_ALERT_PUBLIC_KEY=<base64 PEM>` (production API is the release default).
- [ ] **Blocker:** physical test plan run on at least 5 phones and results recorded (`PHYSICAL_TEST_PLAN.md`), including signed official alerts relayed over the mesh.
- [ ] Permission prompts reviewed on Android 12, 13 and 14 or later (Nearby devices, location, notifications, foreground service).
- [ ] Play Console data-safety form matches `PRIVACY_AND_RETENTION.md`.

## iOS

- [ ] **Blocker:** bundle identifier is still `com.example.resqnet`. Choose the final id (for example `com.resqnet.app`) in the Apple developer account and update the Xcode project and push configuration together.
- [ ] Xcode build and TestFlight install (not done yet; needs a Mac with Xcode and CocoaPods).
- [ ] MultipeerConnectivity mesh tested on devices: expected to work in the foreground only.

## Website

- [ ] `npm run lint && npm run build` pass.
- [ ] Security headers configured on the web server (`SECURITY.md`). Check with `curl -I https://resqnet.co`.
- [ ] Claims review: no range, delivery, rescue, nationwide-coverage or government-partnership claims. The demo reads "Interactive simulation — not a live emergency network."
- [ ] Privacy policy and terms match the implemented retention and data use.

## Repository hygiene

- [ ] `AGENTS.md` at the repository root is empty and untracked: delete it or add real content before committing.
- [ ] `docs/AUDIT.md`, `docs/DONE.md` and `docs/PLAN.md` are internal development logs. Decide whether they belong in a public repository.
- [ ] No secrets in the diff (`git diff --cached` review before every commit).
