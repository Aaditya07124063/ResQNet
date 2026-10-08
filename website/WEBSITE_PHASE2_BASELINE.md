# Website Phase 2: baseline audit

Recorded 2026-10-01, before any Phase 2 change. Scope: `website/` only.

## Git state at start

```
 D resqnet/.gitignore          (pre-existing, unrelated nested project; untouched)
 D resqnet/index.js
 D resqnet/package-lock.json
 D resqnet/package.json
 D storage.rules               (pre-existing, unrelated; untouched)
?? AGENTS.md                   (pre-existing, empty; untouched)
?? ResQNet-GITHUB-CLEANUP/     (pre-existing; untouched)
?? ResQNet-before-metadata-cleanup.bundle
```

`website/` itself had no uncommitted changes.

## Architecture

- Next.js 16.3.4 App Router, React 19.2, TypeScript (strict), Tailwind CSS v4.
- `output: "export"`, `trailingSlash: true`, `images.unoptimized: true` (`next.config.ts`).
- Dependencies: `clsx`, `lucide-react`, `cobe` (WebGL globe). No test framework.
- Content as typed modules in `src/content/` (`site.ts`, `core-concepts.ts`, `feature-groups.ts`, `how-it-works.ts`, `hazard-data.ts`).
- Per-page metadata via `src/lib/seo.ts` (`pageMetadata`: title, description, canonical, OG, Twitter).

## Routes (15 generated)

`/`, `/about/`, `/contact/`, `/download/`, `/features/`, `/how-it-works/`, `/organizations/`, `/privacy-policy/`, `/safety-privacy/`, `/terms/`, `/_not-found` (+ `404.html`), `/opengraph-image`, `/robots.txt`, `/sitemap.xml`.

## Components

- Layout: `Header` (sticky, mobile menu below `xl`), `Footer`, `Container`, `SkipLink`.
- UI: `Button`/`ButtonAsButton`, `SectionHeading`, `Logo`, `PhoneFrame` (real app screenshots), `Reveal` (scroll fade), `Globe` (cobe WebGL), `LegalNotice`.
- Sections: `Hero`, `ProblemSection`, `WhenToUseSection`, `CoreConceptsSection`, `SituationalAwarenessSection` (globe with illustrative hazard markers, filter chips), `HowItWorksSection`, `ProductExperienceSection` (4 real screenshots), `TrustSection`, `OrganizationsTeaser`, `DownloadCTA`, `PageHero`, `StoreAndForwardDemo` (interactive A→E store-and-forward simulation, on `/how-it-works/` only).
- Forms: `ContactForm` (validation, honeypot, `mailto:` fallback or `NEXT_PUBLIC_CONTACT_ENDPOINT`).

## Design system

Tokens in `globals.css` `:root` + `@theme inline`: ink/bg/surface-dark, teal `--color-primary`, `--color-alert` reserved for SOS states. Inter font. Light theme only. Global `:focus-visible` ring, skip link, `prefers-reduced-motion` handling.

## Assets

`public/favicon.png`, `favicon.svg`, `site.webmanifest`, `screenshots/{home,login,sos,emergency-contacts}.png` (real app captures).

## SEO / machine readability

- Root metadata: title template, description, `metadataBase`, robots index/follow, OG/Twitter defaults, manifest, icon.
- Per-page canonical + OG + Twitter via `pageMetadata`.
- JSON-LD: `Organization` + `WebSite` (no `sameAs`, no logo).
- `sitemap.ts` (10 URLs, trailing slash), `robots.ts` (allow all + sitemap).
- Generated OG image (`opengraph-image.tsx`).
- **Not present anywhere in the repository:** `public/markdown/`, Markdown page representations, `llms.txt`, website Nginx config, njs content negotiation, 406 handling. Searched `website/`, `docker/`, `docs/`, `ResQNet-GITHUB-CLEANUP/` and git history (all branches). There is nothing to preserve; see "Proposed changes".

## Tests / checks

- No test script. `npm run lint` (eslint): **pass, 0 problems**.
- `npm run build`: **pass**, TypeScript clean, 15/15 static pages.

## Accessibility state

Good foundation: skip link, landmarks, `aria-current`, `aria-expanded`/`aria-controls` on the menu toggle, `aria-hidden` icons, labelled form fields, `aria-live` demo caption, reduced-motion handling.

Problems found:
1. `.reveal` sets `opacity: 0` for all motion-tolerant users until JS runs, so with JS disabled or failing, most homepage content is invisible. The CSS comment claims the opposite.
2. Mobile menu toggle is ~40px (p-2 + 24px icon), under the 44px target.
3. Globe chips are ~34px tall.
4. In `SituationalAwarenessSection`, "See how it works →" is styled as a link but is a `<span>` (dead CTA).
5. Demo nodes on mobile (2-column grid) lose the link indicator, so relay direction isn't visible.

## Responsive state

Layouts use mobile-first grids; header collapses below `xl`. The demo's 5-node row becomes a 2-column grid on mobile without direction cues. No visual check tooling is in the repo (Playwright browsers are cached locally but not a project dependency).

## Factual problems (website vs. `docs/FEATURE_STATUS.md`, `docs/PRIVACY_AND_RETENTION.md`, `docs/SECURITY.md`, code)

| # | Location | Current claim | Reality |
|---|---|---|---|
| F1 | Privacy Policy §5 | SOS records kept as history rather than deleted | SOS personal data redacted 90 d after closure, account link de-identified at 730 d (PRIVACY §2; the doc itself flags this page as stale) |
| F2 | Privacy Policy §4 | Trusted contacts receive category, **message**, and location | Trusted-contact push is generic: name, category, location, **never the message** (PRIVACY §6.5) |
| F3 | Privacy Policy | No mention of mesh visibility, medical opt-in, backups, account deletion | Mesh recipients see name, full message, exact location (signed, not encrypted); medical opt-in off by default; backups up to ~8 weeks; deletion API exists but no app screen |
| F4 | Features → Location | "only ever collected as part of an emergency event — not tracked continuously" | Also: opt-in nearby-alert location, shared-location chat, opt-in sensor recordings with GPS |
| F5 | WhenToUse | "trusted contacts get an SMS immediately, whether you're online or not" | App opens a **pre-filled SMS** to trusted contacts + hotline; needs cellular signal and the user to send it |
| F6 | StoreAndForwardDemo footer | "A responder portal is not part of ResQNet yet." | Operations portal built (queue, workflow, assignment, map, audit), **not deployed** (FEATURE_STATUS #34) |
| F7 | Features → Notifications | status changes reflected "in real time" | Push and WebSocket are PRODUCTION-UNVERIFIED |
| F8 | Home how-it-works step 3 | SOS "recorded by ResQNet's backend, which then notifies…" | Offline-first: saved on phone, sent over mesh + SMS, backend only once a phone has Internet |
| F9 | Safety & Privacy page | No mention of mesh not being encrypted, medical opt-in, generic contact push, retention | All documented limitations missing |
| F10 | Organizations page | Targets universities/companies | Mission's secondary audience is rescue teams, NGOs, authorities, EOC; portal capabilities not described |
| F11 | Auto-detection copy | "can start an SOS on their own" | Implemented, PHYSICAL-TEST-REQUIRED; detector score not validated |

Hero/home messaging is generic ("Communication when it matters most") and never states "offline", "mesh", or the civilian audiences (trekkers, rural communities, etc.).

## Proposed changes

1. Homepage rebuilt around "Offline Emergency Communication": new hero, mesh flow explanation with the existing interactive demo (relabelled "Interactive Concept Demonstration", responder acknowledgement step added), civilian audiences and example scenarios, real capabilities, responder teaser, factual safety summary.
2. `/organizations/` repurposed to **For Responders & Organizations** (incident queue, state machine, assignment, map, alerts, audit, permissions), clearly marked "built, not yet deployed". Same URL, so no broken links.
3. Correct F1–F11 in content files and pages; rewrite the Safety & Privacy page and the Privacy Policy data/retention sections from the docs.
4. SEO: brand + "Offline Emergency Communication" titles/descriptions, `sameAs` GitHub, `SoftwareApplication` JSON-LD without unverifiable fields, consistent per-page metadata.
5. Add a short factual `public/llms.txt`. Do **not** invent a Markdown/njs negotiation layer that the repo never had; document it as not present.
6. Accessibility fixes 1–5 above.
7. Keep the static export, all routes, the contact form, the globe and the screenshots.
