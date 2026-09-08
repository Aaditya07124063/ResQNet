import { CheckCircle2, Compass } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Button } from "@/components/ui/Button";
import { howItWorksSteps, resilientCommunicationStatus } from "@/content/how-it-works";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "How ResQNet Works",
  description:
    "How ResQNet works: setting up trusted contacts, triggering an SOS, and how the app distributes and tracks emergency information.",
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

export default function HowItWorksPage() {
  return (
    <>
      <PageHero
        eyebrow="How it works"
        title="From setup to resolution."
        description="ResQNet is built around a clear, predictable sequence — not automation that leaves you guessing what happened."
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

      <section className="border-t border-border bg-bg-subtle py-20 sm:py-28">
        <Container>
          <SectionHeading
            eyebrow="Resilient communication"
            title="What's implemented today, and what's ahead."
            description="Mesh and offline communication are easy to overstate. Here's exactly what ResQNet does today, and what's planned."
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
                <h3 className="text-base font-semibold text-ink">Planned / future direction</h3>
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
            Device-to-device relay depends on nearby devices also running
            ResQNet with mesh mode active — it extends reach on the ground,
            but it is not a guarantee of connectivity in every situation.
          </p>
        </Container>
      </section>

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
