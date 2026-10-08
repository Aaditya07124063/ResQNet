import { CheckCircle2, Compass } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { StoreAndForwardDemo } from "@/components/sections/StoreAndForwardDemo";
import { CiviliansSection } from "@/components/sections/CiviliansSection";
import { Button } from "@/components/ui/Button";
import { howItWorksSteps, resilientCommunicationStatus } from "@/content/how-it-works";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "How ResQNet Works Offline",
  description:
    "How an SOS travels through ResQNet's offline mesh: phone-to-phone over Bluetooth and Wi-Fi Direct, store-and-forward relay, Internet gateway upload, and responder workflow.",
  path: "/how-it-works/",
});

// A small, concrete picture of "two nearby phones relaying a message
// directly" — the one real capability behind "resilient communication"
// that otherwise only appears as prose everywhere it's mentioned.
function MeshRelayIllustration() {
  return (
    <svg viewBox="0 0 220 96" className="h-20 w-auto" aria-hidden="true">
      {/* Two devices, each a recognizable phone silhouette */}
      <rect x="8" y="18" width="40" height="66" rx="9" fill="none" stroke="var(--color-ink)" strokeWidth="2.5" />
      <rect x="17" y="27" width="22" height="38" rx="2" fill="var(--color-primary-soft)" />
      <rect x="172" y="18" width="40" height="66" rx="9" fill="none" stroke="var(--color-ink)" strokeWidth="2.5" />
      <rect x="181" y="27" width="22" height="38" rx="2" fill="var(--color-primary-soft)" />
      {/* A message relayed directly between them — not through a tower.
          The staggered pulse (motion-safe only) reads as the message
          traveling from one device to the other; the static faded-dot
          trail already conveys the same thing with reduced motion. */}
      <g fill="var(--color-primary)">
        <circle cx="88" cy="51" r="4" opacity="0.9" className="motion-safe:animate-pulse" />
        <circle
          cx="110"
          cy="51"
          r="4"
          opacity="0.6"
          className="motion-safe:animate-pulse [animation-delay:200ms]"
        />
        <circle
          cx="132"
          cy="51"
          r="4"
          opacity="0.35"
          className="motion-safe:animate-pulse [animation-delay:400ms]"
        />
      </g>
    </svg>
  );
}

// Moved from the homepage when it became photo-led.
const meshFacts = [
  {
    title: "No Internet needed between phones",
    body: "Nearby phones running ResQNet talk directly over Bluetooth and Wi-Fi Direct. No cell tower, router or server sits in the middle.",
  },
  {
    title: "Range is not fixed",
    body: "How far one phone reaches another depends on the hardware, walls, terrain and interference. ResQNet will publish measured field-test results, not a promised distance.",
  },
  {
    title: "Other people's phones carry it",
    body: "The mesh only exists where other people are running ResQNet with mesh mode on. On Android, whether it keeps working in the background depends on the phone's power management; on iOS, expect it to work only while the app is open.",
  },
  {
    title: "Internet and SMS still help",
    body: "Any phone that has Internet uploads the SOS. Your phone can also open a pre-filled text to your trusted contacts, which needs ordinary cell signal. The server adds to the mesh; it doesn't replace it.",
  },
];

export default function HowItWorksPage() {
  return (
    <>
      <PageHero
        eyebrow="How it works"
        title="From SOS to response, with or without a network."
        description="An SOS is saved on the phone, sent every way that's available, and passed hand to hand by nearby phones until one of them reaches the Internet and a responder takes ownership."
      />

      <section className="py-20 sm:py-28">
        <Container>
          <ol className="relative mx-auto max-w-2xl space-y-14">
            {/* Threads the steps into one visible path rather than a
                plain numbered list — painted behind the step circles,
                see the circle's own `relative` class below. */}
            <div
              aria-hidden="true"
              className="absolute top-6 bottom-6 left-6 w-px bg-border"
            />
            {howItWorksSteps.map((step) => (
              <li key={step.number} className="flex gap-6">
                <span className="relative flex h-12 w-12 shrink-0 items-center justify-center rounded-full bg-primary-soft text-lg font-bold text-[var(--color-primary-strong)]">
                  {step.number}
                </span>
                <div>
                  <h2 className="text-xl font-semibold text-ink">{step.title}</h2>
                  <p className="mt-2 text-base leading-relaxed text-ink-soft">
                    {step.description}
                  </p>
                </div>
              </li>
            ))}
          </ol>
        </Container>
      </section>

      <section className="border-t border-border py-20 sm:py-28">
        <Container>
          <SectionHeading
            eyebrow="When networks fail"
            title="How an SOS travels with no signal."
            description="Step through it below. This is a concept demonstration of the protocol, not a live network."
          />
          <div className="mt-10">
            <StoreAndForwardDemo />
          </div>
        </Container>
      </section>

      <section className="border-t border-border bg-bg-subtle py-20 sm:py-28">
        <Container>
          <SectionHeading
            eyebrow="Resilient communication"
            title="What's implemented today, and what's ahead."
            description="Mesh and offline communication are easy to overstate. Here's exactly what ResQNet does today, and what it doesn't yet."
          />

          <div className="mt-12 grid gap-8 lg:grid-cols-2">
            <div className="rounded-2xl border border-border bg-white p-8">
              <MeshRelayIllustration />
              <div className="mt-4 flex items-center gap-2.5">
                <CheckCircle2 size={20} className="text-[var(--color-success)]" aria-hidden="true" />
                <h3 className="text-base font-semibold text-ink">Implemented today</h3>
              </div>
              <ul className="mt-5 space-y-4">
                {resilientCommunicationStatus.implemented.map((item) => (
                  <li key={item} className="text-sm leading-relaxed text-ink-soft">
                    {item}
                  </li>
                ))}
              </ul>
            </div>

            <div className="rounded-2xl border border-dashed border-border bg-white p-8">
              <div className="flex items-center gap-2.5">
                <Compass size={20} className="text-ink-faint" aria-hidden="true" />
                <h3 className="text-base font-semibold text-ink">Not yet done</h3>
              </div>
              <ul className="mt-5 space-y-4">
                {resilientCommunicationStatus.planned.map((item) => (
                  <li key={item} className="text-sm leading-relaxed text-ink-soft">
                    {item}
                  </li>
                ))}
              </ul>
            </div>
          </div>

          <p className="mt-8 max-w-2xl text-sm text-ink-faint">
            Relay depends on other people nearby running ResQNet with mesh mode
            on. Range depends on the phones, terrain, buildings and
            interference; no range is claimed until it has been measured. On
            iOS the mesh works only while the app is open. ResQNet extends
            reach on the ground; it does not guarantee that a message gets
            through.
          </p>
        </Container>
      </section>

      <section className="border-t border-border py-20 sm:py-28">
        <Container>
          <SectionHeading
            eyebrow="How the offline mesh works"
            title="Four things to know about the mesh."
          />
          <div className="mt-10 grid gap-8 sm:grid-cols-2">
            {meshFacts.map((fact) => (
              <div key={fact.title} className="border-l-2 border-ink/20 pl-5">
                <h3 className="text-base font-semibold text-ink">{fact.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-soft">{fact.body}</p>
              </div>
            ))}
          </div>
        </Container>
      </section>

      <div className="border-t border-border">
        <CiviliansSection />
      </div>

      <section className="py-16 text-center">
        <Container>
          <h2 className="text-2xl font-bold text-ink">See every capability in detail</h2>
          <div className="mt-6 flex justify-center">
            <Button href="/features/" size="lg">
              Explore Features
            </Button>
          </div>
        </Container>
      </section>
    </>
  );
}
