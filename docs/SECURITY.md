# Security

What protects ResQNet today, what does not yet, and how to verify it. Written from the code; every claim names where it lives.

## Accounts and sessions

- **Civilians:** sign in with Google or phone OTP. The backend issues its own short-lived access JWT (15 min) and a rotating refresh token (30 days). The app keeps them in `flutter_secure_storage`.
- **Employees:** a separate login with separate JWT secrets (`EMPLOYEE_JWT_*`), so a civilian token can never reach a portal route.
- **Startup checks:** the backend refuses to start with JWT secrets shorter than 32 characters (`backend/src/config/env.ts`).
- **Phone OTP** (`verificationService.ts`):
  - codes are stored hashed and are single use;
  - wrong attempts are counted, and there is a per-number cooldown;
  - separate rate limits apply per IP and per phone number.
  - Verified against real PostgreSQL in `tests/integration/database.test.ts`.

## Authorisation (portal)

Roles are `super_admin`, `admin` and `employee`. Only `super_admin` bypasses individual grants. Everyone else needs an explicit permission, checked on the server for every request.

| Permission | Allows |
|---|---|
| `OFFICIAL_ALERT_PUBLISH` | publish alerts labelled **official** |
| `PARTNER_ALERT_PUBLISH` | publish **verified partner** alerts |
| `SYSTEM_ALERT_PUBLISH` | publish ResQNet notices |
| `SOS_MONITOR` | view the incident queue, dashboard counts, alerts and disaster-source status, and incident details with the location rounded to about 1 km. The phone number, the civilian's SOS message and responder note text are withheld |
| `SOS_RESPOND` | record responder progress and notes; with `SOS_MONITOR`, see the exact location, phone number, SOS message and note text |
| `RETENTION_HOLD_MANAGE` | place or release a retention hold on an incident (pauses redaction/de-identification; audited without the reason text) |
| `AUDIT_LOG_VIEW` | read the audit log in the operations portal. Metadata keys that look like secrets (token, secret, password, OTP, credential, API key, session) are replaced with `[redacted]` by the reader as defence in depth; IP addresses are not returned |
| `SOS_ASSIGN` | with `SOS_RESPOND`: assign or reassign, stand an incident down, and record progress on behalf of the assignee. Without it, on-scene progress (en route, arrived, assisting, resolved) can only be recorded by the assigned responder |

Denied attempts to publish, assign or change an incident, and rejected state transitions, are written to `audit_logs`. So is every view of an incident's detail, with whether contact details were included. Incident audit entries record the actor's role and the previous and new state; they never include note text, tokens or contact details.

## Mesh (offline) messages

- **SOS origin signatures:** each phone has a P-256 key in the platform keystore. An SOS carries a signed origin envelope.
  - Relays can't change the content without the signature failing.
  - The backend verifies the signature before attributing a relayed SOS to its sender (`sosService.ts`, `utils/originSignature.ts`). A tampered event is rejected.
- **Hop limit and expiry** are inside the signed fields.
- **Official alerts over the mesh:**
  - The server signs every alert it serves when `OFFICIAL_ALERT_SIGNING_KEY` is set. The app pins the public key with `--dart-define=RESQNET_ALERT_PUBLIC_KEY`.
  - A phone that receives an alert over the mesh keeps the "official" label only if the signature verifies. Anything else is shown as an unverified community report.
  - An older signed version never replaces a newer one (replay protection).
  - Canonical format: `backend/src/utils/alertSignature.ts` ↔ `lib/core/security/alert_signature.dart`. Both are tested against the same fixture.
  - `sourceUrl` and `retrievedAt` are **not** signed. They are informational and are not relayed as trusted.
- **Signed content only:** a receiving phone rejects an SOS whose displayed text or location differs from its signed envelope (`matchesSignedContent` in `mesh_service.dart`), so a relay cannot alter what people see, including opted-in medical details. Cancellation notices are checked by their own binding rule.
- **Not encrypted:** mesh payloads are signed but not encrypted. A phone that receives an SOS over the mesh shows the sender's name, the full message and the exact location. The "category and approximate distance only" limit applies to the server's nearby push notifications, not to the mesh. See `PRIVACY_AND_RETENTION.md`.
- **Medical data:** never on ordinary mesh messages. For automatic SOS, only with the user's opt-in, and only inside the signed message. Never in push notifications or the pre-filled SMS. See `PRIVACY_AND_RETENTION.md` ("Medical information").

## Secrets

- **SMS provider credentials:**
  - encrypted at rest with `PROVIDER_CREDENTIALS_ENCRYPTION_KEY`;
  - never returned by any API (tested);
  - leaving a secret blank on update keeps the stored one.
- **Generic HTTP SMS gateway:** stays disabled. An operator-supplied URL would be an SSRF vector (`docs/SMS_PROVIDERS.md`).
- **Adapter URLs:** disaster-source adapters are code, not configuration. No operator can point the server at an arbitrary URL. Stored `source_url` values must be `https://` (enforced by a database CHECK and by validation).
- **Repository scan** (2026-09-27): no private keys, cloud API keys or tokens were found in tracked files. The test fixture contains only a public key and a signature; the matching private key was discarded.

## Dependencies (2026-09-27)

- **Website:** `npm audit --omit=dev` found 0 vulnerabilities.
- **Backend:** `npm audit --omit=dev` found 0 high or critical, and 10 moderate advisories:
  - **Fixed:** `qs` (parses untrusted query strings; express 4.22.3, qs 6.16.0).
  - **Remaining, in `firebase-admin`'s Google Cloud dependencies (`uuid` in `gaxios`/`teeny-request`):**
    - The advisory concerns the v3/v5/v6 functions with a caller-supplied buffer, which ResQNet never calls.
    - The only fix moves `@google-cloud/storage` and firestore up a major version inside firebase-admin. Re-test FCM on a device before taking it.
  - **Remaining, in `minio` → `query-string`/`decode-uri-component`/`stream-json`:**
    - These parse responses from ResQNet's own MinIO server, not user input.
    - The suggested fix downgrades minio to 7.x, so it was not applied.

## Transport and headers

- **API:** helmet sets HSTS, CSP, `X-Content-Type-Options`, frame and referrer policy on every response. CORS is an allow-list (`CORS_ORIGINS`). Set `TRUSTED_PROXY_HOPS` to the real number of proxies (1 behind a single Nginx), or rate limits key on the wrong IP.
- **Android:** release builds block cleartext HTTP. Only the debug manifest allows it, for the local emulator backend.
- **Website:** a static export, so its headers come from the web server, which isn't in this repository. Recommended Nginx configuration for `resqnet.co` (test with `Content-Security-Policy-Report-Only` first):

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-Frame-Options "DENY" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;
# Next.js static export inlines small bootstrap scripts, hence 'unsafe-inline'
# for scripts. Fonts are self-hosted at build time.
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' https://api.resqnet.co; frame-ancestors 'none'; base-uri 'self'; form-action 'self'" always;
```

## Data retention and audit redaction

- **Audit metadata is redacted when written** (`src/utils/auditRedaction.ts`) and again when read. Credential-like keys, location, message/note/body text, phone numbers and medical-looking keys are replaced with `[redacted]`, and long strings are capped. Existing audit fields (ids, states, roles, counts, field names, the email on a failed staff login) are unaffected.
- **Expired personal SOS data is not served** by any endpoint, even before the retention job has run (`models/SosEvent.ts`, `incidentService.ts`).
- **The retention job logs only counts and PostgreSQL error codes,** never error messages or details, which can quote row values.
- **Account deletion** (`DELETE /api/v1/me`):
  - needs a signed-in session, an explicit confirmation string, and the auth rate limit;
  - is refused while an incident is open or held;
  - is audited with counts only.

See `PRIVACY_AND_RETENTION.md`.

## Operations portal

- The portal decides only what to show; every request is authorised again by the backend (tested at both layers).
- An expired or revoked employee session signs the portal out and says why. Employee and civilian sessions never share tokens.
- **Web build:** employee tokens live in browser storage (`flutter_secure_storage` on the web encrypts them with WebCrypto, but a script running on the same origin could still use them).
  - Host the portal on its own origin, allow it in `CORS_ORIGINS`, and serve it with a strict CSP: `default-src 'self'; connect-src 'self' https://api.resqnet.co; img-src 'self' data: https://tile.openstreetmap.org; frame-ancestors 'none'`. Add your tile host if you use a licensed provider.
  - Flutter web may also need `'wasm-unsafe-eval'` in `script-src`. Test the CSP with report-only first.

## Known gaps

- Mesh payloads are not encrypted (see above).
- The seismic webhook is authenticated by a shared secret, not a signature.
- `super_admin` is all-powerful by design. Keep the number of such accounts minimal.
- No external penetration test has been performed.
