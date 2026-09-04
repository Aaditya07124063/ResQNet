# ResQNet — Target Architecture

Status: **target/design document**. Describes where the project is headed,
not necessarily what exists today — see `docs/AUDIT.md` for current state and
`docs/DONE.md` for what has actually been built so far.

## Aim / motto

ResQNet is an emergency communication and safety application. Its core promise
is that **emergency communication keeps working when nothing else does** —
when there's no internet, when a vendor has an outage, when a device is
damaged mid-crash. Every architectural choice here is weighed against that:
does it make the SOS path more reliable, or does it just make the platform
more feature-rich? When those conflict, reliability of the emergency path
wins.

ResQNet is its own system: not a thin wrapper over any single vendor's
backend-as-a-service. Firebase, Google, email/SMS vendors, and map tile
providers are all **replaceable dependencies**, not foundations — the
foundation is ResQNet's own API, database, and object storage, running on
infrastructure ResQNet controls (Hostinger VPS).

## High-level architecture

```
Flutter Mobile App
        |
        +-------- Google Sign-In V2 (server-verified)
        |
        +-------- ResQNet API
        |             |
        |             +-- PostgreSQL     (all core application data)
        |             +-- MinIO          (object storage: profile pictures, attachments)
        |             +-- WebSocket      (realtime: messages, presence, SOS updates)
        |             +-- Email Provider (configurable, multi-provider, fallback chain)
        |             +-- SMS Provider   (configurable, multi-provider, fallback chain)
        |
        +-------- MapLibre-based maps (tile source replaceable, online + offline)
        |
        +-------- Offline Bluetooth / Wi-Fi Direct mesh (works with zero backend dependency)
```

```
Internet
   |
   v
Cloudflare        (DNS, TLS, DDoS/WAF, edge rate limiting, analytics)
   |
   v
Hostinger VPS
   |
   v
Nginx             (host-owned reverse proxy; only entry point to the VPS)
   |
   v
ResQNet Backend   (127.0.0.1:<port> -> resqnet-api:3000, loopback-only)
   |
   v
Private resqnet_network (Docker)
   |
   +-- resqnet-api
   +-- resqnet-db      (PostgreSQL, no public port)
   +-- resqnet-minio   (no public port)

   optional later:
   +-- resqnet-redis
   +-- resqnet-worker
```

Detection stays on-device (see "What never moves to the backend" below); the
backend's job in the emergency path is synchronization, notification, and
authorized access — not deciding whether an emergency is happening.

## Design principles

1. **Vendor replaceability.** Every external dependency (email, SMS, map
   tiles, push) sits behind an interface (`EmailProvider`, `SmsProvider`,
   `MapProvider`, ...). Business logic never branches on a specific vendor
   name (`if provider == "brevo"`) — it calls the interface, and admin
   configuration decides which concrete provider handles the call.
2. **Server derives identity, never trusts the client for it.** Every
   protected request's `userId`/`ownerId`/`role`/`groupId` comes from a
   verified token or a server-side lookup, never from a client-supplied
   field, for every resource in the system.
3. **Offline-first for emergencies.** SOS creation, mesh relay, and local
   message queuing must not require Firebase, Google auth, Cloudflare, or
   Hostinger to be reachable at the moment of the emergency. Sync happens
   when connectivity returns; nothing in the online stack is a precondition
   for the offline emergency path.
4. **Isolation from Orbyatravel.** ResQNet shares nothing with the other
   application on this VPS — no code, database, Docker network/volume,
   credentials, ports, nginx config, domain, Cloudflare config, or GitHub
   Actions. Every ResQNet resource is name-prefixed (`resqnet-*`,
   `resqnet_network`). See the isolation checklist in `docs/PLAN.md`.
5. **Minimize what's collected, protect what's sensitive.** Location data,
   message contents, and SOS details are never sent to analytics. Employee
   moderation access to private messages is capability-gated (permission +
   active review case), audited, and capped (last 100 messages, not full
   history).
6. **Research before implementing unfamiliar vendor/provider APIs.** For
   Google Sign-In, email providers, and SMS providers specifically: current
   official documentation is the source of truth, not memory or old
   tutorials — several of these APIs (Google Sign-In's Credential
   Manager-based flow in particular) have changed meaningfully in ways that
   matter for correctness and security.

## What never moves to the backend

Crash detection, earthquake detection, sensor recording/replay, and the
feature-extraction/ML work planned for Phase 4/5 all stay **on-device**. This
migration touches identity, data storage, realtime communication, and
moderation — not detection:

```
Sensors -> Motion processing -> Feature extraction -> Classifier -> Candidate
    -> User confirmation -> SOS -> Backend synchronization
```

The backend's role starts at "SOS": storage, notification fan-out,
synchronization, authorized-user access, group communication, rescue
workflow support.

## Services (Docker, on the VPS)

| Container | Purpose | Public port? |
|---|---|---|
| `resqnet-api` | Node.js/TypeScript, Express + WebSocket | No — nginx proxies from loopback only |
| `resqnet-db` | PostgreSQL | Never |
| `resqnet-minio` | Object storage | Never |
| `resqnet-redis` (future, only if needed) | Caching/pubsub for WebSocket scale-out | Never |
| `resqnet-worker` (future, only if needed) | Background jobs (e.g. email/SMS retry queues) | Never |

## Domains (create only what's actually needed, when needed)

- `resqnet.com` — marketing/consumer surface (if applicable)
- `api.resqnet.com` — backend API
- `admin.resqnet.com` — admin portal (if kept distinct from employee portal)
- `employee.resqnet.com` — Employee Portal (privileged moderation/admin surface, distinct from the consumer app)

Exact domain(s) to be confirmed by the project owner before any Cloudflare/DNS
work happens — see the open questions in `docs/AUDIT.md`.

## Isolation from Orbyatravel — hard rules

ResQNet must never share, with Orbyatravel: code, repositories, databases
(Postgres/MySQL/Redis), MinIO, Docker containers/networks/volumes,
environment variables, secrets, ports, nginx configuration, domains,
Cloudflare configuration, GitHub Actions, or deployment directories. ResQNet
containers attach only to `resqnet_network`, never to `orbya_default` or any
other Orbyatravel-owned resource. No nginx/UFW/Cloudflare/SSH/other-project
change is ever made automatically by ResQNet's CI/CD — those remain
host-operator-owned actions, executed manually.
