# Disaster and alert sources

## Architecture (implemented)

```
external source → adapter (backend/src/services/disasterSources.ts)
  → validation → emergency_alerts (PostgreSQL, migration 007)
  → GET /api/v1/alerts → app map (GovernmentAlertFeedService) → mesh relay
```

- Every alert has a `source_type`: `official`, `verified_partner`, `international_public`, `resqnet_system`, `community`, or `device_sensor`.
  - An adapter stamps its own source on everything it ingests, so a feed cannot claim to be someone else.
  - `international_public` is for public international feeds used without an agreement. They are never shown as official (the app labels them "PUBLIC INTERNATIONAL SOURCE").
  - Provenance per item: `source_url` (https only, enforced in validation and by a database CHECK) and `retrieved_at` (set on every ingestion; null for portal-issued alerts).
- Staff issue alerts in the portal API (`/api/v1/employee/alerts`). Each source label needs its own permission, and every create, update, resolve, and denied attempt is audit-logged:
  - `OFFICIAL_ALERT_PUBLISH`
  - `PARTNER_ALERT_PUBLISH`
  - `SYSTEM_ALERT_PUBLISH`
- The app labels an alert OFFICIAL when it fetched it from the ResQNet server itself, or when a copy relayed over the mesh carries a valid server signature (pinned P-256 key; see `SECURITY.md`). Anything else relayed over the mesh is shown as a community report ("claims official, unverified" when it says otherwise).

## Sources — none connected yet

No adapter is registered (`registeredAdapters` is empty). A source is added only after checking all of the following:

- the API exists and is stable (format, update frequency, availability);
- the terms of use allow redistribution to app users, including offline and cached copies;
- who issues the data, which decides whether it is `official` or `verified_partner`;
- that it covers Nepal.

| Candidate | Type | Status |
|---|---|---|
| Nepal Disaster Risk Reduction portal (BIPAD, Government of Nepal) | official | Not verified — API, terms, and data ownership to confirm with the authority |
| Department of Hydrology and Meteorology (flood / weather warnings) | official | Not verified |
| National Earthquake Monitoring and Research Center (earthquakes) | official | Not verified |
| GDACS (Global Disaster Alert and Coordination System) | international_public | Not verified — check feed format and terms before use |
| USGS / EMSC earthquake feeds | already used in the app only as a cross-check for on-device detection, not as alerts | — |

Do not register a source, or label anything as official, based on this table alone.
