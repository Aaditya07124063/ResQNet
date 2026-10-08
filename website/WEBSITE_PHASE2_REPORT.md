# Website Phase 2: report

Date: 2026-10-01. Scope: `website/` only. Nothing was deployed, committed or pushed.

## 1. Baseline

See `WEBSITE_PHASE2_BASELINE.md`. Summary: Next.js 16 static export (15 routes), lint and build green, sound accessibility foundation. Generic, non-mission messaging. Eleven factual mismatches with `docs/FEATURE_STATUS.md`, `docs/PRIVACY_AND_RETENTION.md` and `docs/SECURITY.md` (F1–F11). **No Markdown representations, `public/markdown/`, `llms.txt`, website Nginx config or njs content negotiation exist anywhere in the repository or its git history.**

## 2. Changes made

- **Homepage rebuilt** around "Offline emergency communication". New order: Hero → offline mesh explanation with the interactive demo → for civilians → capabilities → real app screens → Nepal/India globe → safety summary → responders/EOC → release CTA.
- **Interactive demo** (`StoreAndForwardDemo`): relabeled "Interactive Concept Demonstration — not a live emergency network". Added a 7th step (responder acknowledges in the incident queue) and a "Responder portal" node. The false statement "A responder portal is not part of ResQNet yet" became "built but not yet deployed; not integrated with any emergency agency". Single-column layout on mobile; controls wrap.
- **`/organizations/` repurposed** as *For Responders, NGOs & Emergency Operations Centers*: incident queue, enforced state machine, assignment, the rule that only a responder closes an incident, map, alerts, permissions, audit log, and an explicit limitations list. The URL is unchanged, so no existing link breaks.
- **Safety & Privacy page rewritten** from the docs: signed but not encrypted, a who-sees-what table, the medical opt-in, a retention table, account security, and limitations.
- **Privacy Policy corrected**:
  - §4: trusted contacts don't receive the message; added mesh visibility and responder access.
  - New §5 Medical information.
  - §6 Retention now matches policy, including backups and phone copies.
  - §7 notes that account deletion has no button in the app yet.
  - The "not legally reviewed" notice is kept.
- **Features page:** 8 groups (SOS, offline mesh, location, trusted contacts & notifications, disaster awareness, automatic detection, responder operations, privacy & retention), each with a **status badge** taken from FEATURE_STATUS.
- **How It Works:** five offline-first steps, plus updated implemented / "not yet done" lists. Mesh payload encryption and mesh chat are now listed as not done.
- **About, Download** updated: mission, current status, "Android release coming soon", no public APK.
- **Nav/footer:** For Civilians (`/#civilians`) and For Responders added; the logo covers Home. The CTA is "Get ResQNet" instead of "Download App", and the footer links to the source code.

## 3. Files changed

Modified:
- `src/app/{about,download,features,how-it-works,organizations,privacy-policy,safety-privacy}/page.tsx`, `src/app/page.tsx`, `src/app/layout.tsx`, `src/app/globals.css`
- `src/components/layout/{Header,Footer}.tsx`
- `src/components/sections/{CoreConceptsSection,DownloadCTA,Hero,OrganizationsTeaser,SituationalAwarenessSection,StoreAndForwardDemo,TrustSection}.tsx`
- `src/content/{core-concepts,feature-groups,how-it-works,site}.ts`, `src/lib/seo.ts`, `README.md` (one line)

Added: `src/components/sections/{MeshSection,CiviliansSection}.tsx`, `public/llms.txt`, `WEBSITE_PHASE2_BASELINE.md`, `WEBSITE_PHASE2_REPORT.md`.

Deleted (superseded, no remaining imports): `src/components/sections/{ProblemSection,WhenToUseSection,HowItWorksSection}.tsx`. Their useful content was folded into the new sections.

## 4. UX improvements

- The mission is stated in the H1 and the first paragraph. Four hero points cover offline relay, SOS, location and civilians + responders.
- The six-step mesh flow is visible before any feature list. Four plain-language facts explain how the mesh behaves: no Internet between phones, range not fixed, it depends on other people's phones, and Internet/SMS complement it.
- Civilian audiences (disaster victims, trekkers/hikers, tourists, rural communities, forest/field workers, stranded travelers) with six labeled example scenarios.
- Responders have a dedicated dark band on the homepage and their own page.
- CTAs go somewhere real: `#mesh`, release status, contact. The dead "See how it works" span is now a link.

## 5. SEO improvements

- Brand + primary concept: default title "ResQNet — Offline Emergency Communication"; home title matches the H1.
- New, specific titles and descriptions for Home, How It Works, Features, Organizations, Safety & Privacy, Privacy Policy, About and Download.
- **Bug fixed:** subpages had no `og:image`/`twitter:image` because a page-level `openGraph` replaced the root one. `pageMetadata` now references `/opengraph-image`, and each page has exactly one `og:image`.
- JSON-LD `Organization.sameAs` = GitHub repository. No ratings, store URLs, logos or `SearchAction` were added.
- OG image text picks up the new tagline automatically. The canonical URLs, sitemap (10 URLs) and robots file were left as they were.
- Exactly one H1 per page (verified).

## 6. Accessibility improvements

- **No-JS fix:** `.reveal` content was hidden (`opacity: 0`) whenever JS didn't run. The fade now applies only under `(scripting: enabled)`, and the media query survives in the built CSS.
- Mobile menu button enlarged to 44×44px. The menu now closes on same-page hash links, so it no longer stays open with body scroll locked.
- Globe filter chips have a minimum height of 44px.
- New tables and lists use `dl`/`dt`/`dd`, `<table>` with `<caption>` and `scope="col"`, and `aria-label` on lists. Arrows in the flow diagram are `aria-hidden`; the order is carried by an `<ol>`.
- Existing skip link, focus ring, `aria-live` demo caption and reduced-motion handling kept.

## 7. Responsive improvements

- Mesh flow: 6 columns on desktop, a vertical stack with down-arrows on mobile.
- Demo nodes are compact rows on mobile, with the state on the right.
- Hero bullet grid goes from 1 to 2 columns. The responder capability grid goes from 1 to 2 to 3 columns.
- The retention table scrolls inside its own container, so the page never scrolls horizontally.
- Verified with headless Chromium at 375 / 768 / 1440px on all 10 pages: **no horizontal overflow** on any page or width.

## 8. Interactive / demo changes

- Store-and-forward demo: required label, responder acknowledgement step, honest footer, mobile layout. It uses no network calls and no live data.
- The globe (illustrative hazard markers) is kept. Its "Illustrative data, not a live hazard feed" notice now appears in the section description as well.

## 9. Factual limitations now stated on the site

- Mesh is signed, not encrypted. Mesh recipients see name, message and exact location; relays keep copies for up to 24 hours.
- Medical details are opt-in (off by default, reset on sign-out), automatic SOS only, never in SMS or push.
- Trusted-contact push is generic: no message text.
- SMS is a pre-filled text the user sends, and it needs cell signal.
- Retention: 90 days and 730 days after closure. Unclosed incidents are kept. Backups hold data up to about 8 weeks; copies on other phones can't be deleted remotely.
- No deletion button in the app. Policy is not legally reviewed, and no compliance is claimed.
- Mesh tested in simulation only; no range claimed; iOS works in the foreground only; Android background behavior depends on power management.
- Auto-detection needs field testing. The portal is built but not deployed and has no real-time updates for staff. There is no agency integration and no store listing.

## 10. Tests executed

| Check | Result |
|---|---|
| `npm run lint` (baseline and final) | pass, 0 problems |
| `npm run build` (baseline and final) | pass; TypeScript clean; 15/15 static pages |
| Internal link and asset check: every `href`/`src` starting with `/` in `out/**/*.html` resolved to a file | 456 refs, **0 broken** |
| Anchor targets `#mesh`, `#civilians`, `#main-content` | present |
| Headless Chromium on 10 pages + 404 probe at 375/768/1440 | no overflow; 1 H1 per page; no JS errors (only the intentional 404 probe) |
| Visual review of hero, mesh section, homepage bands, footer (screenshots) | layout as intended |
| `og:image` count per page | 1 |
| `git diff -- backend lib docker docs` | empty |

There is no `npm test` script, so no unit tests exist for the website.

## 11. Build result

`next build`: compiled successfully. Routes: `/`, `/about`, `/contact`, `/download`, `/features`, `/how-it-works`, `/organizations`, `/privacy-policy`, `/safety-privacy`, `/terms`, `/_not-found`, `/opengraph-image`, `/robots.txt`, `/sitemap.xml`, all static. `out/llms.txt` and `out/404.html` are present.

## 12. Routes verified

All 10 content routes plus 404, rendered in Chromium at three widths. `sitemap.xml` and `robots.txt` generated unchanged.

## 13. Intentionally NOT changed

- **Markdown representations / njs content negotiation / 406 behavior:** these do not exist in this repository, so there was nothing to preserve and nothing was invented. If they exist on the production server, they live outside the repo and were not touched. Only `public/llms.txt` was added (a static file, served as is).
- No backend, app, Docker, Nginx, `.env`, Firebase or database changes. No SSH, no deploy, no commit, no push.
- Static export, `trailingSlash`, unoptimized images and the contact form (`mailto:` fallback) are all unchanged.
- Terms of Service: only the spelling was normalized. Its existing disclaimers are already accurate.
- The globe was kept despite its weight (the WebGL `cobe` library), because removing existing functionality was out of scope.
- No dark theme was added. The site has always been light-only.
- Pre-existing deletions (`resqnet/`, `storage.rules`) and untracked files at the repo root were left alone.

## 14. Remaining issues

- The privacy policy and safety page still need **legal review**. Section 7 says "contact us to request" deletion, but no staff deletion tool exists (operational procedure only).
- `hello@resqnet.co` is still a placeholder contact address.
- The hero phone image is `loading="lazy"` even though it's above the fold (minor LCP cost; `PhoneFrame` has no eager option).
- The app screenshots are older captures and may not match the current UI.
- `/opengraph-image` is served without a file extension, so production Nginx must send `image/png` for it (this predates Phase 2).
- No automated a11y (axe) or link checking in CI. The Playwright checks in this phase ran from a scratch script and were not added to the project.
- Contrast of `text-ink-faint` (#6b7686) on `bg-subtle` is about 4.6:1, which passes AA for normal text, but there is little margin.

## 15. Recommended manual checks

1. Read every page against `docs/PRIVACY_AND_RETENTION.md` §12 ("What must not be claimed publicly").
2. Keyboard-only pass: skip link, menu, demo controls, globe chips, contact form.
3. Screen-reader pass (VoiceOver/TalkBack) of the demo and the Safety & Privacy tables.
4. Real devices: iPhone SE width, mid-range Android, tablet.
5. Share-preview check (OG/Twitter) for `/` and `/features/` after deploy.
6. Confirm that production Nginx serves `llms.txt` as `text/plain` and `/opengraph-image` as `image/png`.
7. Decide whether the "For Civilians" nav item should become a dedicated page later (it is a homepage section today).
8. Legal review of the Privacy Policy and Terms before launch.

## git status --short (at completion)

```
 D resqnet/.gitignore
 D resqnet/index.js
 D resqnet/package-lock.json
 D resqnet/package.json
 D storage.rules
 M website/README.md
 M website/src/app/about/page.tsx
 M website/src/app/download/page.tsx
 M website/src/app/features/page.tsx
 M website/src/app/globals.css
 M website/src/app/how-it-works/page.tsx
 M website/src/app/layout.tsx
 M website/src/app/organizations/page.tsx
 M website/src/app/page.tsx
 M website/src/app/privacy-policy/page.tsx
 M website/src/app/safety-privacy/page.tsx
 M website/src/components/layout/Footer.tsx
 M website/src/components/layout/Header.tsx
 M website/src/components/sections/CoreConceptsSection.tsx
 M website/src/components/sections/DownloadCTA.tsx
 M website/src/components/sections/Hero.tsx
 D website/src/components/sections/HowItWorksSection.tsx
 M website/src/components/sections/OrganizationsTeaser.tsx
 D website/src/components/sections/ProblemSection.tsx
 M website/src/components/sections/SituationalAwarenessSection.tsx
 M website/src/components/sections/StoreAndForwardDemo.tsx
 M website/src/components/sections/TrustSection.tsx
 D website/src/components/sections/WhenToUseSection.tsx
 M website/src/content/core-concepts.ts
 M website/src/content/feature-groups.ts
 M website/src/content/how-it-works.ts
 M website/src/content/site.ts
 M website/src/lib/seo.ts
?? AGENTS.md
?? ResQNet-GITHUB-CLEANUP/
?? ResQNet-before-metadata-cleanup.bundle
?? website/WEBSITE_PHASE2_BASELINE.md
?? website/WEBSITE_PHASE2_REPORT.md
?? website/public/llms.txt
?? website/src/components/sections/CiviliansSection.tsx
?? website/src/components/sections/MeshSection.tsx
```
