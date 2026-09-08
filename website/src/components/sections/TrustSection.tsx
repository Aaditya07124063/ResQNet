import Link from "next/link";
import { Lock, UserCheck, ServerCog } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Reveal } from "@/components/ui/Reveal";

const points = [
  {
    icon: Lock,
    title: "Authenticated by design",
    description:
      "Every request to ResQNet's backend runs through an authenticated session — there's no unauthenticated path to read or change your data.",
  },
  {
    icon: UserCheck,
    title: "Scoped to your account",
    description:
      "Your profile, trusted contacts, and SOS history are scoped to your account. The backend is built so one user's request can't reach another user's records.",
  },
  {
    icon: ServerCog,
    title: "Infrastructure ResQNet controls",
    description:
      "ResQNet runs its own API and database rather than depending entirely on a single third-party backend, so the emergency path isn't built on a foundation ResQNet doesn't control.",
  },
];

export function TrustSection() {
  return (
    <section className="bg-bg-subtle py-20 sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="Safety & privacy"
          title="Emergency information deserves careful handling."
          description="ResQNet is built with the understanding that the data it handles is sensitive by nature."
        />

        <div className="mt-14 grid gap-8 sm:grid-cols-3">
          {points.map((point, index) => (
            <Reveal key={point.title} delay={index * 80}>
              <div>
                <point.icon size={22} className="text-primary" aria-hidden="true" />
                <h3 className="mt-4 text-base font-semibold text-ink">{point.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-soft">
                  {point.description}
                </p>
              </div>
            </Reveal>
          ))}
        </div>

        <Link
          href="/safety-privacy/"
          className="mt-10 inline-block text-sm font-semibold text-primary hover:underline"
        >
          Read the full Safety &amp; Privacy page →
        </Link>
      </Container>
    </section>
  );
}
