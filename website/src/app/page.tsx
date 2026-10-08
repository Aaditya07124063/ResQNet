import type { ReactNode } from "react";
import Link from "next/link";
import { preload } from "react-dom";
import { ArrowRight } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { Button } from "@/components/ui/Button";
import { PhoneFrame } from "@/components/ui/PhoneFrame";
import { Photo, PhotoCredit } from "@/components/ui/Photo";
import { Reveal } from "@/components/ui/Reveal";
import { photos, type PhotoId } from "@/content/photos";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/content/site";
import { cn } from "@/lib/utils";

export const metadata = pageMetadata({
  // Brand first, then the primary concept — matches the on-page H1.
  title: `${siteConfig.name} — Offline Emergency Communication`,
  description: siteConfig.description,
  path: "/",
});

// Documentary direction: real photographs carry the story, text only
// guides it. Every detail removed from this page lives on a dedicated
// page (How It Works, Features, Responders, Safety & Privacy, Download).

const display = "font-display font-semibold uppercase leading-[0.95] tracking-[0.01em]";

/** A full-bleed photograph with a dark scrim and text anchored low. */
function PhotoSection({
  id,
  photo,
  position,
  priority,
  textTop = false,
  className,
  children,
  ...rest
}: {
  id?: string;
  photo: PhotoId;
  position?: string;
  priority?: boolean;
  /** Put the type at the top when the photo's subject sits low in the frame. */
  textTop?: boolean;
  className?: string;
  children: ReactNode;
  "aria-labelledby"?: string;
}) {
  return (
    <section
      id={id}
      className={cn(
        "relative isolate flex min-h-[100svh] scroll-mt-18 overflow-hidden bg-surface-dark text-white",
        textTop ? "items-start" : "items-end",
        className,
      )}
      {...rest}
    >
      <Photo id={photo} position={position} priority={priority} parallax={!priority} className="-z-10" />
      {/* Scrim: dark at the bottom where the type sits, clear above so the
          photograph keeps its weight. */}
      <div
        aria-hidden="true"
        className={cn(
          "absolute inset-0 -z-10 from-black/90 via-black/45 to-black/10",
          textTop ? "bg-gradient-to-b" : "bg-gradient-to-t",
        )}
      />
      <Container className={textTop ? "pt-16 pb-40 sm:pt-24" : "pt-40 pb-10 sm:pb-14"}>
        {children}
        <PhotoCredit id={photo} className="mt-12 max-w-md" />
      </Container>
    </section>
  );
}

function Hero() {
  const id = "nepal-earthquake-rescue-2015";
  preload(`/photos/${id}-1600.webp`, {
    as: "image",
    fetchPriority: "high",
    imageSrcSet: photos[id].widths.map((w) => `/photos/${id}-${w}.webp ${w}w`).join(", "),
    imageSizes: `max(100vw, ${Math.round((photos[id].width / photos[id].height) * 100)}vh)`,
  });

  return (
    <PhotoSection
      photo={id}
      position="46% 70%"
      priority
      className="min-h-[calc(100svh-4.5rem)]"
      aria-labelledby="hero-title"
    >
      <h1 id="hero-title" className={cn(display, "max-w-4xl text-6xl sm:text-7xl lg:text-8xl")}>
        When the network goes down.
      </h1>
      <p className="mt-5 max-w-md text-lg text-white/85 sm:text-xl">
        Emergency communication that keeps working nearby.
      </p>
      <div className="mt-9 flex flex-wrap gap-3">
        <Button href="#story" variant="light" size="lg">
          Explore ResQNet
        </Button>
        <Button href="/how-it-works/" variant="outlineOnDark" size="lg">
          See how it works
        </Button>
      </div>
    </PhotoSection>
  );
}

/** A quiet mesh drawn over a still photograph. Decorative — the ordered
 * list beside it carries the meaning for screen readers. */
function MeshLines() {
  const nodes = [
    [12, 70], [30, 52], [26, 82], [48, 38], [52, 66], [70, 50], [86, 30], [80, 74],
  ] as const;
  const links = [[0, 1], [0, 2], [1, 3], [1, 4], [2, 4], [3, 5], [4, 5], [5, 6], [5, 7]] as const;
  return (
    <svg
      viewBox="0 0 100 100"
      preserveAspectRatio="none"
      aria-hidden="true"
      className="absolute inset-0 -z-10 h-full w-full opacity-60"
    >
      {links.map(([a, b]) => (
        <line
          key={`${a}-${b}`}
          x1={nodes[a][0]}
          y1={nodes[a][1]}
          x2={nodes[b][0]}
          y2={nodes[b][1]}
          stroke="white"
          strokeWidth="1"
          strokeDasharray="4 6"
          vectorEffect="non-scaling-stroke"
        />
      ))}
      {nodes.map(([x, y], i) => (
        <circle key={i} cx={x} cy={y} r="0.6" fill={i === 0 ? "var(--color-alert)" : "white"} />
      ))}
    </svg>
  );
}

const meshSteps = ["Your phone", "Nearby devices", "Emergency message"];

const screens = [
  {
    src: "/screenshots/sos.png",
    alt: "ResQNet's Send SOS screen, showing emergency type selection and a disclosure of exactly who gets alerted",
    caption: "Send SOS",
  },
  {
    src: "/screenshots/home.png",
    alt: "ResQNet's home screen, showing the SOS button, an I am safe broadcast option, and status for mesh, GPS, and nearby devices",
    caption: "Find nearby help",
  },
  {
    src: "/screenshots/emergency-contacts.png",
    alt: "ResQNet's Emergency Contacts screen, showing a trusted contacts list and location-aware local emergency hotlines",
    caption: "Reach your people",
  },
];

const regions = [
  { label: "Nepal", photo: "nepal-broken-trail-2015", position: "40% 45%" },
  { label: "India", photo: "ernakulam-flood-2018", position: "50% 35%" },
] as const;

const linkCta =
  "mt-8 inline-flex min-h-11 items-center gap-2 text-sm font-semibold tracking-[0.12em] uppercase hover:underline";

export default function HomePage() {
  return (
    <>
      <Hero />

      <PhotoSection photo="chennai-flood-rooftop-2015" position="88% 85%" textTop aria-labelledby="problem-title">
        <Reveal>
          <h2 id="problem-title" className={cn(display, "max-w-3xl text-5xl sm:text-6xl lg:text-7xl")}>
            When infrastructure fails, communication matters most.
          </h2>
          <p className="mt-5 text-lg text-white/85">Floods. Earthquakes. Landslides. Remote terrain.</p>
        </Reveal>
      </PhotoSection>

      <PhotoSection id="story" photo="bihar-kosi-flood-boat-2008" position="62% 40%" aria-labelledby="story-title">
        <Reveal>
          <h2 id="story-title" className={cn(display, "text-5xl sm:text-6xl lg:text-7xl")}>
            People help people.
          </h2>
          <p className="mt-5 max-w-md text-lg text-white/85">
            ResQNet helps nearby phones communicate when ordinary networks cannot.
          </p>
        </Reveal>
      </PhotoSection>

      {/* How it works — the one place the technology is drawn. */}
      <section
        aria-labelledby="mesh-title"
        className="relative isolate overflow-hidden bg-surface-dark py-28 text-white sm:py-40"
      >
        <Photo id="nepal-earthquake-rubble-2015" parallax className="-z-20 opacity-35 grayscale" />
        <div aria-hidden="true" className="absolute inset-0 -z-10 bg-surface-dark/60" />
        <MeshLines />
        <Container>
          <Reveal>
            <ol className="flex flex-col items-start gap-4 sm:flex-row sm:items-center sm:gap-6">
              {meshSteps.map((step, i) => (
                <li key={step} className="flex flex-col items-start gap-4 sm:flex-row sm:items-center sm:gap-6">
                  <span className="flex items-center gap-3 text-sm font-semibold tracking-[0.18em] uppercase">
                    <span
                      aria-hidden="true"
                      className={cn("h-2.5 w-2.5 rounded-full", i === 0 ? "bg-[var(--color-alert)]" : "bg-white")}
                    />
                    {step}
                  </span>
                  {i < meshSteps.length - 1 && (
                    <ArrowRight size={16} aria-hidden="true" className="ml-0.5 rotate-90 text-white/50 sm:ml-0 sm:rotate-0" />
                  )}
                </li>
              ))}
            </ol>
            <h2 id="mesh-title" className={cn(display, "mt-14 max-w-3xl text-6xl sm:text-7xl lg:text-8xl")}>
              No cell tower required.
            </h2>
            <p className="mt-5 max-w-md text-lg text-white/80">
              Phones pass the message along until one of them can reach help.
            </p>
            <Link href="/how-it-works/" className={linkCta}>
              How it works <ArrowRight size={16} aria-hidden="true" />
            </Link>
          </Reveal>
          <PhotoCredit id="nepal-earthquake-rubble-2015" className="mt-16" />
        </Container>
      </section>

      <section aria-labelledby="app-title" className="bg-bg-subtle py-24 sm:py-32">
        <Container>
          <h2 id="app-title" className={cn(display, "text-5xl text-ink sm:text-6xl")}>
            The real app.
          </h2>
          <p className="mt-3 text-sm text-ink-soft">Screens from a running build, not mockups.</p>
        </Container>
        {/* Swipeable on phones, a row on desktop. Focusable so keyboard
            users can scroll it too. */}
        <div
          tabIndex={0}
          role="region"
          aria-label="App screenshots"
          className="mt-12 flex snap-x snap-mandatory gap-8 overflow-x-auto px-6 pb-6 sm:px-8 lg:mx-auto lg:max-w-6xl lg:justify-between lg:overflow-visible"
        >
          {screens.map((screen) => (
            <figure key={screen.src} className="w-[72vw] max-w-[300px] shrink-0 snap-center lg:w-[300px]">
              <PhoneFrame src={screen.src} alt={screen.alt} width={300} />
              <figcaption className="mt-6 text-center text-xs font-semibold tracking-[0.18em] text-ink uppercase">
                {screen.caption}
              </figcaption>
            </figure>
          ))}
        </div>
        <Container>
          <Link href="/features/" className={cn(linkCta, "text-ink")}>
            Every feature and its status <ArrowRight size={16} aria-hidden="true" />
          </Link>
        </Container>
      </section>

      <PhotoSection photo="ndrf-nepal-search-rescue-2015" position="45% 45%" aria-labelledby="responders-title">
        <Reveal>
          <h2 id="responders-title" className={cn(display, "max-w-3xl text-5xl sm:text-6xl lg:text-7xl")}>
            From signal to response.
          </h2>
          <p className="mt-5 max-w-md text-lg text-white/85">
            ResQNet gives authorized responders a clearer picture of active incidents.
          </p>
          <p className="mt-2 text-sm text-white/75">Built and tested. Not yet deployed.</p>
          <Link href="/organizations/" className={linkCta}>
            Responder operations <ArrowRight size={16} aria-hidden="true" />
          </Link>
        </Reveal>
      </PhotoSection>

      <section aria-labelledby="region-title" className="bg-surface-dark text-white">
        <Container className="py-24 sm:py-32">
          <Reveal>
            <h2 id="region-title" className={cn(display, "max-w-4xl text-5xl sm:text-6xl lg:text-7xl")}>
              Built for places where connectivity cannot be taken for granted.
            </h2>
          </Reveal>
        </Container>
        <div className="grid md:grid-cols-2">
          {regions.map((region) => (
            <div key={region.label} className="relative isolate flex min-h-[85svh] items-end overflow-hidden">
              <Photo
                id={region.photo}
                position={region.position}
                sizes="(min-width: 768px) 50vw, 100vw"
                className="-z-10"
              />
              <div
                aria-hidden="true"
                className="absolute inset-0 -z-10 bg-gradient-to-t from-black/85 via-black/20 to-transparent"
              />
              <div className="p-6 sm:p-10">
                <h3 className={cn(display, "text-6xl sm:text-7xl")}>{region.label}</h3>
                <PhotoCredit id={region.photo} className="mt-4 max-w-sm" />
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Critical limitations stay on the homepage, in brief. */}
      <section aria-labelledby="limits-title" className="border-t border-white/10 bg-surface-dark py-14 text-white">
        <Container className="grid gap-6 md:grid-cols-[12rem_1fr] md:gap-16">
          <h2 id="limits-title" className="font-sans text-sm font-semibold tracking-[0.18em] text-white/90 uppercase">
            Please know
          </h2>
          <div className="max-w-2xl space-y-3 text-sm leading-relaxed text-white/75">
            <p>
              ResQNet is in active development and has not yet been field-tested across many phones. It does not
              replace official emergency services and cannot guarantee that a message gets through. SOS messages on
              the mesh are signed but not encrypted.{" "}
              <Link href="/safety-privacy/" className="text-white underline underline-offset-2">
                Safety &amp; privacy
              </Link>
            </p>
            <p>
              The photographs show real disasters and responses in Nepal and India. The people pictured are not
              ResQNet users, and ResQNet was not involved in these events.
            </p>
          </div>
        </Container>
      </section>

      <PhotoSection photo="machhapuchhre-ghandruk" position="62% 40%" aria-labelledby="closing-title">
        <Reveal>
          <h2 id="closing-title" className={cn(display, "max-w-3xl text-5xl sm:text-6xl lg:text-7xl")}>
            When everything else goes quiet, keep people connected.
          </h2>
          <div className="mt-9 flex flex-wrap gap-3">
            <Button href="/features/" variant="light" size="lg">
              Explore ResQNet
            </Button>
            <Button href="/how-it-works/" variant="outlineOnDark" size="lg">
              View the technology
            </Button>
          </div>
          <p className="mt-6 text-sm text-white/75">
            Android release coming soon. Not yet on Google Play or the App Store.{" "}
            <Link href="/download/" className="text-white underline underline-offset-2">
              Release status
            </Link>
          </p>
        </Reveal>
      </PhotoSection>
    </>
  );
}
