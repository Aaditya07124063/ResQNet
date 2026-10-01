# Privacy and data retention

The single reference for what ResQNet stores, who can see it, how long it is kept, and how it is removed. Written from the code and schema (migrations 001–011); every statement names where it is implemented.

**Status labels:**

- **IMPLEMENTED:** in the code and covered by tests.
- **CONFIGURATION REQUIRED:** implemented, but only active once an operator configures it.
- **OPERATIONAL PROCEDURE:** a person must do it; the code does not.
- **PRODUCT DECISION REQUIRED:** the current behaviour is a placeholder until someone decides.
- **NOT IMPLEMENTED:** does not exist.

Every retention period below is **ResQNet operational policy**: a product choice made to keep the minimum data for the minimum time. None of them is presented as a legal requirement, and this document does not claim compliance with any particular law. Review with legal counsel before launch.

## 1. Data inventory

### Server (PostgreSQL, MinIO)

| Data | Where | Purpose | Who can access it |
|---|---|---|---|
| Civilian account | `users` (name, Google subject, email, phone) | sign-in, identify reporter to contacts | the user; trusted contacts see the name |
| Profile, incl. **medical details** | `user_profiles` (father's name, age, address, blood group, allergies, medications, emergency contact), MinIO image | shown to the user; blood group and allergies are added to an *automatic* SOS only if the user turned on the medical-sharing setting (off by default); medications never | the user (profile API) |
| Trusted contacts | `trusted_contacts` | who is alerted | the owner |
| Groups, membership | `groups`, `group_members`, group `conversations` | family/team coordination | members |
| Chat | `conversations`, `messages` (text, or shared location), `message_recipients`, `message_status` | messaging | participants |
| **SOS incident: operational record** | `sos_events` (category, source, times, civilian status, responder status, assignment) + `sos_incident_updates` (who did what, previous/new state, role, time) | responding; accountability | reporter (own); staff with `SOS_MONITOR` |
| **SOS personal data** | `sos_events.message` (contains blood group and allergies only for an automatic SOS with the medical-sharing setting on), `latitude/longitude/location_accuracy_m`, `origin_envelope_raw` (signed copy of message and location), `origin_signature`; `sos_incident_updates.note` (free text, may describe injuries); `sos_recipients` (contact phone numbers, nearby distances) | reaching the person; verification | reporter (own); staff with `SOS_MONITOR`+`SOS_RESPOND` (exact location, message); `SOS_MONITOR` alone sees ≈1 km and no message, phone or notes; trusted contacts get a push with name, category and location, **not the message**; users notified by the server's nearby push see category and distance band only; **phones that receive the SOS over the offline mesh see the sender's name, the full message and the exact location** (see §6) |
| SOS account link | `sos_events.user_id`, `origin_claimed_user_id`, `origin_device_id`, `origin_key_id` | attributing and following up | as above |
| Nearby-alert location | `nearby_alert_locations` (one row per opted-in user) | matching nearby users | nobody directly |
| Seismic reports | `seismic_reports` (user, location, detector values) | corroborating earthquakes (minutes-long window) | server only |
| Seismic alerts | `seismic_alerts` (location, device count; no user) | aggregate event | server only |
| Emergency alerts | `emergency_alerts` (public content, source, provenance, area) | warning the public | public (active only); staff |
| Sessions | `sessions`, `employee_sessions` (refresh-token hash, IP, user agent) | sign-in | server only |
| OTP attempts | `verification_attempts` (target phone/email, code hash, IP) | phone verification, abuse limits | server only |
| Devices / push tokens | `devices` | push notifications | server only |
| Device signing keys | `device_keys` (public keys) | verifying relayed SOS | server only |
| Employees | `employees`, `employee_permissions` | staff access | admins |
| SMS provider config | `sms_providers` (encrypted credentials) | sending SMS | `SMS_PROVIDER_MANAGE` (credentials never returned) |
| Moderation | `user_reports`, `review_cases`, `moderation_actions` | abuse handling | moderation staff |
| Audit log | `audit_logs` (actor, action, resource id, outcome, redacted metadata, IP) | security investigation, accountability | `AUDIT_LOG_VIEW` (IP not shown) |
| Legacy, unused | `incidents`, `official_alerts`, `locations`, `employee_actions`, `message_review_access_log` | none (placeholders from migration 001) | — |
| Application logs | container stdout (request method, path, status, IP; credentials redacted — `src/utils/logger.ts`) | operations | server operators |
| Backups | whatever the host operator backs up (see §7) | recovery | server operators |

### On the phone

| Data | Store | Purpose |
|---|---|---|
| Own SOS outbox (message, location, delivery state) | SharedPreferences (`EmergencyOutboxStore`) | deliver the SOS; show own history |
| Mesh relay store (other people's SOS) | `MeshRelayStore` | store-and-forward |
| Dedup ledger (event ids only) | `EmergencyOutboxStore` | avoid re-processing |
| Hazards / alerts received | `HazardService` | map and alerts |
| Profile cache incl. medical details | `ProfileService` | offline profile, automatic SOS |
| Medical-sharing opt-in (on/off) | SharedPreferences (`ProfileService`) | whether an automatic SOS may carry blood group and allergies |
| Mesh messages received | memory (`MeshService`), relays in the mesh relay store | showing and relaying nearby emergencies |
| Trusted-contacts cache | `TrustedContactsService` | offline SOS to contacts |
| Unsent chat messages | `CommunicationService` | send when online |
| Sensor recordings (motion + **GPS**) | app documents folder; share copies in cache | opt-in detection logging |
| Map tiles viewed / downloaded | FMTC (ObjectBox) | offline map |
| Notifications shown | the OS notification tray | alerting |
| Session tokens | secure storage | sign-in |

## 2. Retention policy

"After closure" means after a responder resolved or stood the incident down (`sos_events.ops_closed_at`). An incident that has not been closed by a responder is never redacted, de-identified or deleted, however old it is.

| Data | Period (ResQNet operational policy) | What happens | Status |
|---|---|---|---|
| SOS personal data (message, exact location, raw envelope, signature, responder note text, delivery log) | **90 days after closure** (`RETENTION_SOS_SENSITIVE_DAYS`) | redacted (set to NULL); stops being served immediately at expiry, even before the job runs | IMPLEMENTED |
| SOS account link (user, claimed user, device, key id) | **730 days after closure** (`RETENTION_SOS_DEIDENTIFY_DAYS`) | de-identified (set to NULL) | IMPLEMENTED |
| SOS operational record (category, times, states, responder timeline) | kept after de-identification | optional deletion after `RETENTION_SOS_RECORD_DELETE_DAYS` (≥ 365, off by default) | IMPLEMENTED; **PRODUCT DECISION REQUIRED** whether to enable deletion |
| Incident under retention hold | until the hold is released | nothing is redacted or de-identified | IMPLEMENTED |
| Shared-location chat messages | 30 days | deleted | IMPLEMENTED |
| Soft-deleted chat messages | 30 days after deletion | deleted | IMPLEMENTED (no client deletes messages yet) |
| Other chat messages | while the account and conversation exist | removed with the sender's account | **PRODUCT DECISION REQUIRED** (no automatic period) |
| Nearby-alert location | 30 days since last update | ignored for matching at once; deleted by the job | IMPLEMENTED |
| Seismic reports | 30 days | deleted | IMPLEMENTED |
| Seismic alerts (aggregate) | kept | — | **PRODUCT DECISION REQUIRED** |
| OTP attempts | 30 days (codes expire in minutes; cooldown reads 60 s) | deleted | IMPLEMENTED |
| Sessions (civilian and staff) | 30 days after expiry or revocation; valid sessions never | deleted | IMPLEMENTED |
| Sessions of disabled employees | requests rejected at once; stored refresh tokens revoked on the next job run | revoked | IMPLEMENTED |
| Push registrations | 180 days without being seen | deleted | IMPLEMENTED |
| Revoked device keys | 365 days after revocation | deleted | IMPLEMENTED |
| Audit log IP address | 90 days | removed from the entry | IMPLEMENTED |
| Audit log entries | 730 days | deleted | IMPLEMENTED |
| Emergency alerts | 365 days after resolution/cancellation or expiry; current alerts never | deleted | IMPLEMENTED |
| Account, profile (incl. medical), contacts, groups | while the account exists | see §6 | IMPLEMENTED (backend) |
| Employees | kept (accountability: who acted on an emergency) | disabled, never deleted by the code | IMPLEMENTED |
| Moderation records | kept | — | **PRODUCT DECISION REQUIRED** |
| SMS provider config | while configured | deleted with the provider | IMPLEMENTED |
| Application logs | host log rotation | — | **OPERATIONAL PROCEDURE** (not in this repository) |
| Backups | see §7 | — | **OPERATIONAL PROCEDURE** |

Every period can be changed through its `RETENTION_*` variable (`backend/.env.example`). Minimums are enforced, so a typo cannot purge data immediately.

## 3. Why incidents are split into stages

An emergency record serves two different needs that age differently:

1. **Operational record:** what happened, when, who responded and how. This is needed to review responses, resolve complaints and show that an alert was handled. It holds no message, location or contact details, so keeping it for longer carries little personal risk.
2. **Personal data:** the message, which can include medical details, the exact location, the delivery phone numbers and responders' free-text notes. These are only needed while the incident is being handled and for a short review period afterwards.
3. **Account link:** who the reporter was. This is needed for follow-up and disputes for longer than the location, but not indefinitely.

So the job redacts the personal data 90 days after closure and removes the account link after 730 days. The anonymised operational record stays, unless deletion is configured.

Nothing starts until a responder has closed the incident. That is deliberate: a person marking themselves safe does not close an incident (see the responder workflow), and an unhandled incident must never quietly age out. Incidents nobody closes remain in the queue; the dashboard shows the oldest unacknowledged one.

## 4. Automated purge (IMPLEMENTED; scheduling is CONFIGURATION REQUIRED)

`backend/src/services/retention/`:

- **Categories:** `retentionJob.ts` declares one entry per data category above. Each has an eligibility rule, an action that re-checks that rule, and follow-up steps. For example, redacting an incident also redacts its note text and deletes its delivery log.
- **Safety:**
  - One run at a time across every API instance (`pg_try_advisory_lock`).
  - Each batch is its own transaction over at most `RETENTION_BATCH_SIZE` rows, chosen with `FOR UPDATE SKIP LOCKED`, with `lock_timeout 5s` and `statement_timeout 60s`. At most `RETENTION_MAX_BATCHES` batches per category per run; the rest waits for the next run.
  - If a category fails, its batch is rolled back, the report says `ok: false` with only the PostgreSQL error code, and the other categories still run. Every step is idempotent, so the next run is safe.
  - Partial indexes (migration 011) keep each batch to candidate rows only.
- **Observability:**
  - Per category: examined, affected, whether more remain, duration, success, logged as structured JSON.
  - One `retention.run` audit entry with the same counts.
  - Record contents are never logged.
- **Running it (CONFIGURATION REQUIRED — nothing runs until one of these is set up):**
  - `npm run retention:run:prod` inside the api container, from the host scheduler (e.g. daily). Exit code 1 if any category failed.
  - `npm run retention:run -- --dry-run` counts what is eligible without changing anything.
  - Or set `RETENTION_SCHEDULE_MINUTES` for an in-process schedule.

## 5. Exact location (IMPLEMENTED)

Everywhere an exact location is stored, and what limits it:

| Location | Limit |
|---|---|
| SOS | ≈1 km for `SOS_MONITOR`; exact only with `SOS_RESPOND`; nobody after 90 days post-closure. This is enforced when served (`models/SosEvent.ts`, `incidentService.ts`), not only by the purge, so an old endpoint cannot return expired coordinates |
| Raw signed envelope | the same, since it contains the location |
| Shared-location chat messages | deleted after 30 days |
| Nearby-alert location | ignored after 30 days, then deleted |
| Seismic reports | deleted after 30 days |
| Staff map | approximate positions from the queue; exact only in the detail view with `SOS_RESPOND` |
| Offline mesh | the exact location travels with the SOS; every phone that receives it can show it, and relays keep it until the SOS expires (24 h by default). Signed, not encrypted |
| Phone | see §8 |

## 6. Medical information and who sees what

**Where medical information is kept:** in the user's profile (blood group, allergies, medications), entered by the user. It is shown back to the user, and cached on their phone.

**1. Ordinary mesh communication** (messages, location shares and voice notes from the mesh or dashboard screens):
- **Never carries medical information,** whatever the profile contains. The mesh message format has no medical fields.
- Medical fields sent by older app versions are ignored: not shown, not relayed.
- These messages *do* carry the sender's name, text and, if shared, the location, and every ResQNet phone that receives them can read them.

**2. Automatic SOS** (crash or earthquake detection):
- Without the opt-in, it contains the detection text only.
- **Any phone that receives an SOS over the offline mesh shows the sender's name, the full SOS message and the exact location.** That includes phones of people the sender doesn't know. Relays keep a copy until the SOS expires (24 h by default).
- The payload is signed, not encrypted.
- A receiving phone rejects an SOS whose displayed text or location differs from the signed version, so a relay cannot change them, medical details included.

**3. Opt-in medical information:**
- **The setting:** "Include medical information in automatic SOS" is **off by default**, stored on the device, and reset to off when anyone signs out.
- **When on:** blood group and allergies (never medications) are added to the *signed* message of an automatic SOS. If the phone cannot sign, they are left out.
- **Who then sees them:** everyone who receives that SOS over the mesh (point 2), the ResQNet server, and staff with `SOS_RESPOND`.
- **Where they are not sent:** manual SOS messages contain only what the user types. The pre-filled SMS to trusted contacts and hotlines never includes the medical details.

**4. Responder access:**
- Staff with `SOS_MONITOR` alone never receive the SOS message (so never the medical details), the phone number or note text. Their location is approximate (≈1 km).
- Staff with `SOS_MONITOR` and `SOS_RESPOND` see them while retention allows (see §2 and §5).

**5. Trusted-contact notification:**
- The push says "<name> needs emergency assistance — open ResQNet." and carries the name, category and location, **never the SOS message or medical details**.
- How it appears on each phone's lock screen has **not been tested on devices**.
- Trusted contacts currently have no way to read the SOS text in the app. **NOT IMPLEMENTED:** a signed-in view for them.

**Logs and audit:** medical information is never written to logs. Audit metadata drops message, note, medical, phone and location keys, both when written and when read (`src/utils/auditRedaction.ts`).

**Deletion:**
- The SOS message, including opted-in medical details, is redacted 90 days after a responder closes the incident.
- The profile is deleted with the account and removed from the phone on sign-out.
- Copies already received over the mesh live on other phones until the SOS expires there (§8).

**No new medical data collection was added.**

## 7. Backups

- Deleting or redacting a row does **not** remove it from backups taken earlier. A backup keeps whatever it contained until the backup itself is deleted.
- **Backup lifecycle (policy; OPERATIONAL PROCEDURE, not automated here):**
  - daily encrypted `pg_dump`, kept 14 days, plus weekly copies kept 8 weeks;
  - so a purged value can survive in backups for up to about **8 weeks** after the purge;
  - backups are restored only for disaster recovery, never to "undo" retention.
- **After any restore:** run `npm run retention:run:prod` immediately, so data that expired since the backup was taken is purged again.
- **Not implemented here:** backup creation and expiry. See `OPERATIONS.md`.

## 8. Phones and offline copies

A server purge does not delete copies already on phones. **ResQNet cannot delete data from every device that ever received it, and must not claim to.**

| Local data | Lifecycle | Status |
|---|---|---|
| Own SOS outbox | sent or closed entries removed 7 days later at app start; entries still waiting to be delivered or to sync a cancellation are kept | IMPLEMENTED |
| Mesh relay store (others' SOS) | dropped at the SOS's signed expiry (24 h by default); unsigned items after 24 h; bounded in size | IMPLEMENTED |
| Dedup ledger | ids only, 48 h | IMPLEMENTED |
| Hazards | dropped at expiry when saved | IMPLEMENTED |
| Profile (incl. medical), trusted contacts, unsent chat | removed from disk on every sign-out; memory also cleared on explicit sign-out | IMPLEMENTED |
| Medical-sharing opt-in | reset to OFF on every sign-out | IMPLEMENTED |
| SOS and messages received over the mesh | relays: until the SOS expires (24 h by default); shown in the app's received list while it runs | IMPLEMENTED |
| Sensor recordings (contain GPS) | deleted after 30 days at app start (share copies after 1 day); the user can delete sooner | IMPLEMENTED |
| Map tiles | kept until the user deletes the region or the cache | IMPLEMENTED (manual) |
| Notifications in the OS tray | until the user dismisses them | outside ResQNet's control |
| Copies on other people's phones | mesh copies expire as above; chat history and notifications they received stay on their phones | NOT under ResQNet control |
| Uninstalling the app | removes all of the above from that phone | — |

## 9. Account deletion (backend IMPLEMENTED; app screen NOT IMPLEMENTED)

- **Endpoint:** `DELETE /api/v1/me` with body `{"confirm": "DELETE_MY_ACCOUNT"}`. There is **no button in the app yet**; none is faked.
- **Refused (409)** while the person has an SOS that responders have not closed, or one under a retention hold.
- **Removed:**
  - the account, profile (incl. medical), profile image (after commit, best effort);
  - sessions, devices, keys;
  - trusted contacts, memberships;
  - messages they sent;
  - direct conversations, **including the other participant's messages in them** (existing foreign-key behaviour, reviewed);
  - seismic reports, OTP rows, nearby data;
  - reports they filed or that concern them (existing cascade; **PRODUCT DECISION REQUIRED** — moderation evidence is lost).
- **Kept:**
  - Their closed incidents stay as de-identified operational records; the message, location, notes and delivery log are removed immediately.
  - Groups they own pass to an admin, then the longest-standing member; if they were alone, the group is deleted.
  - Audit entries stay with the account link removed.
- **Guard:** migration 011 changed `sos_events.user_id` from `ON DELETE CASCADE`, which erased incidents (even active ones) with the account, to `SET NULL`. A CHECK constraint makes a direct `DELETE FROM users` fail while an incident still identifies the person, so nothing can be orphaned or silently lost.
- **Support-mediated deletion:** OPERATIONAL PROCEDURE; no staff tool exists (NOT IMPLEMENTED). Until one does, a person must sign in and call the endpoint, or an operator must run the same service code deliberately.

## 10. Staff (employee) data

- **Employees are never deleted by the code.** Incident timelines and audit entries reference them with `ON DELETE RESTRICT`, so "who acted on this emergency" always resolves.
- **Disabled employees:** requests are rejected at once (`employeeAuthMiddleware`), and the retention job revokes any refresh token they still hold.
- **Sessions:** ended sessions are deleted after 30 days; valid ones are never touched.
- **Process gap:** there is no endpoint that disables an employee (it is a database change today) — **OPERATIONAL PROCEDURE / NOT IMPLEMENTED**. There is also no process for removing a permission when someone changes role.

## 11. Decisions and procedures still open

- **PRODUCT DECISION REQUIRED:**
  - whether to delete de-identified incident records, and when;
  - a period for ordinary chat messages;
  - moderation-record retention, and whether account deletion should remove reports about the person;
  - seismic-alert retention;
  - how trusted contacts should see the SOS text now that the push is generic (a signed-in view is not implemented);
  - whether the retention periods above are right for the jurisdictions ResQNet operates in (legal review).
- **OPERATIONAL PROCEDURE:**
  - **rewrite the website privacy policy, with legal review:**
    - its "Data retention" section says SOS records are kept rather than deleted after resolution, which no longer matches §2;
    - it does not describe the medical-sharing opt-in or who can see an SOS over the mesh (§6);
    - file: `website/src/app/privacy-policy/page.tsx`, not changed in this phase;
  - follow the first-run and rollback procedures in §13;
  - schedule the retention job;
  - set up backups with the lifecycle in §7;
  - rerun retention after any restore;
  - configure log rotation;
  - handle support-requested deletions;
  - disable departing employees.
- **NOT IMPLEMENTED:**
  - an account deletion screen in the app;
  - a staff tool for deletion requests;
  - data export;
  - mesh payload encryption;
  - remote deletion from other people's phones.

## 12. What must not be claimed publicly

- Not "compliant" with any named law or standard. Retention has not been legally reviewed.
- Not "we delete your data immediately" or "from everywhere". Backups keep copies for up to about 8 weeks, and copies on other phones are outside our control.
- Not "anonymous": SOS records are de-identified after 2 years, not before, and the operational record is kept.
- Not "end-to-end encrypted" for the mesh: payloads are signed, not encrypted.
- Not that users can delete their account in the app. They cannot yet.
- Not that nearby phones only see an approximate distance. That is true only of the server's nearby push notifications; phones receiving an SOS over the mesh see the name, message and exact location.
- Not that medical information is never visible to nearby phones. With the opt-in on, an automatic SOS's blood group and allergies reach every phone that receives it over the mesh.
- Not that the mesh is encrypted. It is signed.

## 13. Rollback and data-loss safety

Migration 011 itself cannot silently lose incident data:
- it runs in one transaction;
- it removes no rows or columns;
- after it, older code fails *loudly* when closing an incident rather than losing anything;
- account deletion no longer cascades to incidents.

The risks are in operator actions:

1. **Prefer fix-forward.** After 011 is applied, fix problems with a new release rather than restoring an old production database backup. Rolling back the API image alone breaks closing incidents (`OPERATIONS.md`).
2. **If a restore is unavoidable,** it discards everything written since the backup: new SOS incidents, responder timelines, messages, accounts. Before restoring:
   - export the incidents (with their timelines) and audit entries created after the backup's timestamp;
   - after restoring, re-import them or keep them as a sealed record;
   - then run retention (§7).
   Never restore over live emergencies without doing this.
3. **The first real retention run is gated,** because it immediately redacts every incident closed more than 90 days ago (their closure time is backfilled by 011), and that can only be reversed from a backup:
   1. run a dry run (`--dry-run`);
   2. review the counts per category;
   3. take a fresh backup **and verify it restores**;
   4. do the real run;
   5. verify afterwards: per-category counts match the dry run, open incidents are untouched, and the portal and civilian endpoints show "removed" only where expected.
4. **Never revert 011's foreign-key change by hand.** `sos_events.user_id` must stay `ON DELETE SET NULL`. Putting `CASCADE` back would again delete a person's incidents, including active ones, when their account is deleted. There is no down-migration, deliberately.
5. **Decision: signed copies redacted before the sender is attributable.**
   - A relayed SOS whose sender's key was never registered stays "unverified" with no account link.
   - If a responder closes it and 90 days pass, redaction removes its signed copy. It can then never be attributed later, even if the key is registered afterwards.
   - This is accepted: the alternative, keeping the exact location and message of unattributed incidents indefinitely in case a key appears, is worse for privacy.
   - The operational record (category, times, responder actions) is kept, as for every incident.
   - To keep a specific one attributable, place a retention hold before the 90 days pass.