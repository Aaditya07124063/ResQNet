import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Reveal } from "@/components/ui/Reveal";
import { coreConcepts } from "@/content/core-concepts";

export function CoreConceptsSection() {
  return (
    <section className="bg-white py-20 sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="How ResQNet helps"
          title="Six ideas, built into one app."
          description="Emergency SOS, trusted contacts, location, notifications, resilient communication, and coordination — six concepts that work together during an emergency."
        />

        <div className="mt-14 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {coreConcepts.map((concept, index) => (
            <Reveal key={concept.title} delay={index * 60}>
              <div className="h-full rounded-2xl bg-bg-subtle p-7">
                <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-primary-soft">
                  <concept.icon
                    size={22}
                    className="text-[var(--color-primary-strong)]"
                    aria-hidden="true"
                  />
                </div>
                <h3 className="mt-5 text-lg font-semibold text-ink">
                  {concept.title}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-soft">
                  {concept.description}
                </p>
              </div>
            </Reveal>
          ))}
        </div>
      </Container>
    </section>
  );
}
