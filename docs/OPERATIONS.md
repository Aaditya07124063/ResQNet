# Operations

How to deploy, migrate, back up and recover the ResQNet backend. The production host layout (`/opt/resqnet/…`) is owned by the host operator. The scripts in `docker/` are reference copies.

## Deploying a new version

1. **Back up the database first** (see below). `docker/deploy.sh` runs migrations but does **not** take a backup.
2. Set any new environment variables in the production `.env` (see the table below).
3. Run `deploy.sh`. It records the running image, pulls the new one, runs `node dist/src/database/migrate.js` inside the api container, and waits for `/health`.
4. Smoke test:
   - `GET /health`;
   - `GET /api/v1/alerts`: each alert has `signature` and `signingKeyId` when signing is configured;
   - sign in with an employee who has `SOS_MONITOR` and open `GET /api/v1/employee/incidents`.

**Rollback caveat:** `rollback.sh` rolls back the container image only; the schema is **not** rolled back.
- Up to migration 010, older code ignores the new columns, so an image rollback is safe.
- **From migration 011 on it is not:** an image older than 011 closes incidents without setting `ops_closed_at`, which the new CHECK rejects, so responders could not resolve or stand down incidents.
- After 011, **fix forward** with a new release. Restoring the pre-deploy database backup discards every incident, timeline entry, message and account written since the backup. Do it only if unavoidable, and only after exporting what was written since (`PRIVACY_AND_RETENTION.md` §13).
- **Never revert 011's `sos_events.user_id` foreign key to `CASCADE` by hand.**

## Migrations

- Files in `backend/src/database/migrations/` are applied in order, once each, and tracked in `schema_migrations`.
- Each file and its tracking row commit in one transaction: a failing migration leaves nothing behind and can be fixed and rerun.

| File | Adds |
|---|---|
| 005_seismic_reports.sql | backend seismic corroboration |
| 006_group_kind.sql | group kinds |
| 007_emergency_alerts.sql | alerts with provenance |
| 008_incident_response.sql | responder workflow (`ops_status`, `assigned_employee_id`, `sos_incident_updates`) |
| 009_alert_provenance.sql | `international_public` source type, `source_url`, `retrieved_at` |
| 011_data_lifecycle.sql | data lifecycle: incident closure time (backfilled), redaction/de-identification markers, retention hold, note redaction; `sos_events.user_id` becomes `ON DELETE SET NULL` (was CASCADE, which deleted incidents with the account) guarded by a CHECK; partial indexes for the retention job |
| 010_incident_state_integrity.sql | responder state machine support (`stood_down`, `civilian_state` timeline entries, previous/new state and actor role per entry); CHECKs that every active assignment and every `assigned` entry has an assignee; employee references become `ON DELETE RESTRICT` |

**Verified 2026-09-27** on PostgreSQL 16:
- a clean database through 001–011;
- an idempotent rerun;
- an upgrade from 004 with existing data;
- a forced failure that rolled back cleanly.

The real-database suite passes on each. **Not yet run against a copy of the production database.** Do that before deploying.

`incidents` and `official_alerts` in `001_init_schema.sql` are unused placeholders: the incident workflow is on `sos_events`, and alerts are in `emergency_alerts`. Leave them until a migration deliberately removes them.

## Environment added by recent work

| Variable | Where | Purpose |
|---|---|---|
| `OFFICIAL_ALERT_SIGNING_KEY` | backend | base64 of a P-256 private key PEM. Without it alerts are served unsigned, and phones will not treat mesh-relayed copies as official |
| `RESQNET_ALERT_PUBLIC_KEY` | app build (`--dart-define`) | base64 of the matching public key PEM |
| `PROVIDER_CREDENTIALS_ENCRYPTION_KEY` | backend | encrypts SMS provider credentials |
| `TRUSTED_PROXY_HOPS` | backend | `1` behind a single Nginx |

Generating the alert key pair (on a trusted machine; never commit the private key):

```sh
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out alert_signing.pem
openssl ec -in alert_signing.pem -pubout -out alert_public.pem
base64 < alert_signing.pem | tr -d '\n'   # → OFFICIAL_ALERT_SIGNING_KEY
base64 < alert_public.pem  | tr -d '\n'   # → RESQNET_ALERT_PUBLIC_KEY
```

**Key rotation:** the app pins one public key, so rotating needs an app release that carries the new key before the server switches. Until then, phones on the old build see relayed alerts as unverified; alerts fetched directly from the server are unaffected. Support for several pinned keys (by `signingKeyId`) is not implemented.

## Backups

**Not configured in this repository.** The host operator must set up:

- **PostgreSQL:** nightly `pg_dump -Fc` of the ResQNet database, kept off the server (another region or provider), with at least 14 daily and 8 weekly copies. Encrypt the dumps: they contain personal data and exact SOS locations.
- **MinIO:** profile images; a bucket mirror (`mc mirror`) to separate storage.
- **Secrets:** the production `.env` (JWT secrets, `PROVIDER_CREDENTIALS_ENCRYPTION_KEY`, `OFFICIAL_ALERT_SIGNING_KEY`), kept in a password manager or vault, **not** next to the database dumps.
  - Losing `PROVIDER_CREDENTIALS_ENCRYPTION_KEY` makes the stored SMS credentials unreadable. They would have to be re-entered.

### Backups and retention

Redacting or deleting a row does not change backups taken earlier. With 14 daily and 8 weekly copies, a purged value can survive for up to about 8 weeks. Expire backups on that schedule and never keep dumps longer "just in case". **After any restore, run the retention job at once** (below), because the restored data includes records that have expired since the backup was taken. See `PRIVACY_AND_RETENTION.md` §7.

## Retention job

Redacts, de-identifies and deletes data past its retention period (`PRIVACY_AND_RETENTION.md`). **Nothing runs until it is scheduled.**

- **Recommended:** a host cron entry or systemd timer, daily at a quiet hour:

  ```sh
  docker compose -f <compose file> exec -T api node dist/src/scripts/runRetention.js
  ```

  - Exit code 0 means every category succeeded; 1 means at least one failed. The output is JSON with counts only.
  - Alert on a non-zero exit. A failed category changed nothing in its failing batch, and the next run retries it.
- **Alternative:** set `RETENTION_SCHEDULE_MINUTES` (e.g. `1440`) for an in-process schedule. With several API instances, the advisory lock lets only one run at a time.
- **First run in production (gated).** The first real run immediately redacts every incident closed more than 90 days ago, and only a backup can undo it:
  1. dry run:

     ```sh
     docker compose -f <compose file> exec -T api node dist/src/scripts/runRetention.js --dry-run
     ```

  2. review the per-category counts; stop if any is unexpected;
  3. take a fresh backup and **verify it restores** (recovery drill below);
  4. real run: the same command without `--dry-run`;
  5. verify: counts match the dry run, the exit code is 0, open incidents are untouched, and the portal shows "Removed under the retention policy" only on old closed incidents.

  Only then schedule it. See `PRIVACY_AND_RETENTION.md` §13.

- Periods are configured with the `RETENTION_*` variables in `backend/.env.example`.
- **Retention hold:** staff with `RETENTION_HOLD_MANAGE` can pause removal for one incident from the portal. Holds are operational flags, not legal determinations. Review and release them.

## Recovery drill

Do this at least once before launch, and record the date and duration:

1. Create an empty PostgreSQL database and `pg_restore` the latest dump into it.
2. Point a staging backend at it with the production secrets and run `npm run migrate:prod`. It should report every migration as already applied.
3. Check `GET /health`, sign in as a test user, and confirm a known SOS event and alert are present.
4. Record the time from start to working service. This is the real recovery time.
5. Run the retention job against the restored database before it serves traffic.

## Real-database test suite

For a **throwaway** database only; it truncates every table. Export the `PG_*` variables for that database, plus the other required variables from `.env.example` with dummy values (the migrator loads the full config), then:

```sh
cd backend
npm run migrate
npm run test:integration
```

## Operations (EOC) portal

The staff portal is part of the Flutter code base. It uses the same employee sign-in, session and API client everywhere (`lib/core/employee/`, `lib/features/operations/`):

- **In the mobile app:** Profile → staff portal (phones and tablets).
- **In a browser (desktop, laptop, tablet):** a separate web build that contains only the portal:

  ```sh
  flutter build web -t lib/main_operations.dart --dart-define=API_ENV=production
  ```

  Host the `build/web` output on its **own origin** (e.g. `ops.resqnet.co`), not on the public website. Then add that origin to the backend's `CORS_ORIGINS`, or the browser will block every API call. On the web, the employee tokens are kept in browser storage by `flutter_secure_storage`, so serve the portal with a strict CSP and nothing else on that origin (see `SECURITY.md`).
- **Not built or tested here:** a native desktop build (macOS/Windows), because this environment has no Xcode.

### Sections and permissions

The backend enforces every permission. The portal hides what the employee can't use.

| Section | Needs | Uses |
|---|---|---|
| Dashboard | `SOS_MONITOR` | `GET /employee/incidents/summary`, `GET /employee/alerts` |
| Incidents (queue, detail) | `SOS_MONITOR` (+ `SOS_RESPOND` for exact location, phone, SOS message, note text and actions) | `GET /employee/incidents`, `GET /employee/incidents/:id`, `POST /employee/incidents/:id/updates` |
| Map | `SOS_MONITOR` | the queue (approximate positions); the detail endpoint for an exact pin, `SOS_RESPOND` only |
| Alerts | `SOS_MONITOR` or an alert publish permission to view; the matching publish permission to create, resolve or cancel | `GET/POST/PATCH /employee/alerts` |
| Disaster sources | same as viewing alerts | `GET /employee/alerts/sources` |
| Responders | `SOS_ASSIGN` | `GET /employee/incidents/responders` (name, role, open assignments only) |
| SMS providers | `SMS_PROVIDER_MANAGE` | existing `/employee/sms-providers` screens |
| Audit log | `AUDIT_LOG_VIEW` (new) | `GET /employee/audit-logs` |
| Account | signed in | `GET /employee/me` |

There is no staff "Groups" section: civilian groups are private to their members, and no staff API exposes them.

### Incident workflow in the portal

- Buttons only offer the transitions the backend state machine allows for the current state, the employee's permissions, and whether they are the assignee. A unit test fails if the portal's transition table drifts from `backend/src/services/incidentStateMachine.ts`. The backend remains the authority; a rejected action (409) is explained and the incident reloaded.
- Every state change and assignment asks for confirmation. Stand-down requires a reason. Reassignment never offers the current assignee.
- When the reporter marks themselves safe or cancels, the incident shows a banner and **stays open** until a responder resolves or stands it down. The timeline separates reporter entries from responder entries.

### Refresh behaviour

Nothing in the portal is realtime.
- **Manual refresh:** every page shows when its data was last fetched, and warns when that is more than 2 minutes old.
- **Optional polling:** the queue can poll every 30 s and the map every 60 s. Both are off by default and labelled as polling.
- **No push:** responders are not notified when the reporter's state changes. They see it on the next refresh.

### Limitations

- No realtime updates or push notifications to staff.
- The map shows at most the 200 most recent open incidents. It uses the app's configured tile provider (OpenStreetMap by default, viewed tiles only).
- Queue sorting is newest-first only (the cursor order).
- No automatic escalation of unacknowledged incidents; the dashboard shows the oldest unacknowledged time.
- The web build has been compiled, but not run against a deployed backend or tested with screen readers on real devices.
