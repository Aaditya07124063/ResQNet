# ResQNet Website

The official public marketing website for ResQNet — a separate codebase
from the Flutter mobile app (`../lib`) and the backend API (`../backend`).
It ships as a fully static site and has no runtime dependency on the
ResQNet backend.

## Stack

- **Next.js 16** (App Router, static export via `output: "export"`)
- **React 19** + **TypeScript** (strict)
- **Tailwind CSS v4** (CSS-first `@theme`, see `src/app/globals.css`)
- **lucide-react** for icons, **clsx** for conditional class names

No large UI/animation library is used. Scroll-reveal animation is a small
custom `IntersectionObserver` hook (`src/hooks/useInView.ts`) driving a
plain CSS transition, and respects `prefers-reduced-motion` (see
`globals.css`).

Why static export: the site has no server-side data dependency (no
authenticated content, no database calls), so it can be served as plain
HTML/CSS/JS from any static host or from Nginx directly — see
"Deployment" below.

## Project structure

```
src/
  app/            Routes (App Router) — one folder per page, plus
                  layout.tsx, globals.css, sitemap.ts, robots.ts,
                  opengraph-image.tsx, not-found.tsx
  components/
    layout/       Header, Footer, Container, SkipLink
    sections/     Page-level sections (Hero, ProblemSection, etc.)
      mockups/    The CSS-built phone-screen mockups (no real
                  screenshots exist in the project — see below)
    ui/           Reusable primitives (Button, SectionHeading, Logo,
                  PhoneFrame, Reveal, LegalNotice)
    forms/        ContactForm (client component)
  content/        Copy/data as typed modules (site.ts, feature-groups.ts,
                  core-concepts.ts, how-it-works.ts) — single source of
                  truth so copy isn't duplicated across pages
  hooks/          useInView
  lib/            utils.ts (cn helper), seo.ts (per-page metadata builder)
```

## Local development

```bash
npm install
npm run dev       # http://localhost:3000
```

## Build & production preview

```bash
npm run build      # outputs static files to ./out
npx serve out       # serve the static export locally, e.g. on :3000
```

`npm run lint` and `npm run build` (which runs the TypeScript check) are
the two commands to run before shipping a change.

## Environment variables

All environment variables are optional; the site works with none set.

| Variable | Purpose | Default |
|---|---|---|
| `NEXT_PUBLIC_CONTACT_EMAIL` | Contact address shown in the footer/download/contact pages, and used as the `mailto:` fallback target | `hello@resqnet.co` (placeholder — update once a real inbox exists) |
| `NEXT_PUBLIC_CONTACT_ENDPOINT` | If set, the contact form `POST`s JSON (`{ name, email, organization, inquiryType, message }`) here instead of falling back to a `mailto:` link | unset (form uses `mailto:` fallback) |

No other integration exists. The site does **not** call the ResQNet API
(`api.resqnet.co`) — see "Known limitations" for why, and section 20 of
the original build brief for the reasoning (a public marketing site
should not be coupled to an authenticated backend).

## Content that needs a real value before public launch

- **`NEXT_PUBLIC_CONTACT_EMAIL`** — currently a placeholder
  (`hello@resqnet.co`). No real contact mailbox is documented anywhere in
  the project; set this before launch.
- **Play Store / App Store links** (`src/app/download/page.tsx`) — the
  Download page intentionally shows a "coming soon"-style status instead
  of a link. The Android `applicationId` is still Flutter's own default
  (`com.example.resqnet`), confirming no store listing exists yet. Once a
  real listing exists, replace the status cards with real store buttons
  (and QR codes, if desired).
- **Privacy Policy / Terms of Service** — both pages carry an explicit
  "not legally reviewed" notice (`LegalNotice` component) and describe
  only what the product actually does today. Have these reviewed by
  counsel, and fill in the legal entity/jurisdiction once established,
  before treating them as binding.
- **Social links** (`src/content/site.ts`, `siteConfig.social`) —
  deliberately empty. No verified ResQNet social accounts exist; add
  entries there once real ones do.

## Design system

Tokens live in `src/app/globals.css` under `:root`/`@theme inline`:
`--color-ink`, `--color-bg`, `--color-primary` (a restrained teal — the
brand color is deliberately *not* red, to avoid the emergency-app cliché
of an all-red UI), and `--color-alert` (reserved for literal SOS/status
indicators only, never used as a theme color). No official ResQNet logo
exists in the project's assets (verified during the initial audit — the
app currently ships Flutter's own default icon); `src/components/ui/Logo.tsx`
is a simple wordmark + geometric mark built for the website, not an
invented "official" brand identity.

## Product mockups

`src/components/sections/mockups/` are hand-built HTML/CSS phone screens,
not screenshots — no product screenshots exist in the repository. Their
content (SOS categories, trusted-contact fields, SOS status values) is
taken directly from the actual Flutter/backend implementation
(`lib/core/services/ai_service.dart`'s `EmergencyType` enum,
`trusted_contacts_service.dart`'s model, and the backend's
`sos_events.status` values) rather than invented, per the build brief's
instruction not to invent UI that contradicts the real app.

## Known limitations

- No Play Store/App Store listing exists — the Download page reflects
  that honestly (see above) rather than linking anywhere.
- The contact form has no real backend endpoint by default (uses the
  `mailto:` fallback described above) — no `/contact` route exists on the
  ResQNet backend.
- `opengraph-image.tsx` generates the social-share image at build time
  from JSX (via `next/og`) rather than a designed asset, since no
  marketing artwork exists yet.
- No automated accessibility audit tool (e.g. axe) is wired into CI —
  accessibility was checked manually (semantic headings, focus states,
  `aria-hidden` on decorative icons, labeled form fields, skip link,
  `prefers-reduced-motion`) and via a one-off Playwright smoke test
  during development (not part of the committed project — see the git
  history/PR description of this change for what was run).

## Future work

- Real Play Store / App Store links + QR codes once available.
- Wire `NEXT_PUBLIC_CONTACT_ENDPOINT` to a real submission service once
  one exists (a serverless function, a form-backend SaaS, or a future
  backend `/contact` route) — no code change needed beyond setting the
  env var, as long as the target accepts the same JSON shape.
- Replace the generated OG image with designed marketing artwork.
- Add real screenshots to the Product Experience section once the app
  has a stable, presentable UI to capture.

## Deployment

This is a static site with **no server runtime** — `npm run build`
produces `./out`, which can be served by any static file host or by
Nginx directly. It is designed to be deployed independently from the
backend:

```
https://resqnet.co        → this website (static files)
https://api.resqnet.co    → ResQNet backend API (separate deploy, already live)
```

Deploying this website does not require, and must not involve, any
change to the backend's Docker/Nginx/DNS configuration, or to
Orbyatravel (a separate, unrelated project on the same infrastructure).
No such change was made or is needed to build this site — actual
production deployment (DNS, Nginx vhost, TLS) is a host-operator action
outside this repository's scope, same as the backend's own deployment
workflow (see `../docs/PLAN.md` Phase 18).
