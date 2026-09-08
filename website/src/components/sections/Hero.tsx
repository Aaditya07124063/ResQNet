import { Container } from "@/components/layout/Container";
import { Button } from "@/components/ui/Button";
import { PhoneFrame } from "@/components/ui/PhoneFrame";
import { ShieldCheck } from "lucide-react";

export function Hero() {
  return (
    <section className="relative overflow-hidden bg-white py-20 sm:py-28">
      {/* A quiet signal/network motif, not a gradient glow — echoes the
          concentric-pulse mark in Logo.tsx, kept faint enough to sit
          behind light-background content rather than compete with it. */}
      <svg
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 h-full w-full"
      >
        <defs>
          <pattern id="hero-grid" width="36" height="36" patternUnits="userSpaceOnUse">
            <circle cx="1.5" cy="1.5" r="1.5" fill="rgba(11,18,32,0.05)" />
          </pattern>
        </defs>
        <rect width="100%" height="100%" fill="url(#hero-grid)" />
        <g fill="none" stroke="var(--color-primary)" strokeWidth="1">
          <circle cx="84%" cy="38%" r="120" opacity="0.14" />
          <circle cx="84%" cy="38%" r="210" opacity="0.09" />
          <circle cx="84%" cy="38%" r="300" opacity="0.05" />
        </g>
      </svg>
      <Container className="relative grid items-center gap-16 lg:grid-cols-2">
        <div>
          <span className="inline-flex items-center gap-2 rounded-full border border-border bg-bg-subtle px-3 py-1 text-xs font-medium text-ink-soft">
            <ShieldCheck size={14} aria-hidden="true" />
            Built for resilient emergency communication
          </span>

          <h1 className="mt-6 text-4xl font-bold tracking-tight text-ink sm:text-5xl lg:text-6xl">
            Communication when it matters most.
          </h1>

          <p className="mt-6 max-w-xl text-lg leading-relaxed text-ink-soft">
            Communication can become difficult exactly when people need it
            most. ResQNet is an emergency communication app designed to help
            you reach trusted contacts, share your situation, and coordinate
            during an emergency — with or without a reliable network nearby.
          </p>

          <div className="mt-9 flex flex-wrap gap-4">
            <Button href="/download/" size="lg">
              Download App
            </Button>
            <Button href="/contact/" variant="secondary" size="lg">
              Contact / Partner With Us
            </Button>
          </div>
        </div>

        <div className="flex justify-center lg:justify-end">
          <PhoneFrame
            src="/screenshots/home.png"
            alt="ResQNet's home screen, showing the SOS button, an I am safe broadcast option, mesh and GPS status, and quick access to the emergency map, mesh network, dashboard, and emergency contacts"
          />
        </div>
      </Container>
    </section>
  );
}
