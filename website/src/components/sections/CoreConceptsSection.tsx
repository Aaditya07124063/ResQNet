import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Reveal } from "@/components/ui/Reveal";
import { coreConcepts } from "@/content/core-concepts";

export function CoreConceptsSection() {
  return (
    <section className="border-t border-border bg-bg-subtle py-20 sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="What ResQNet does"
          title="The core capabilities, as they work today."
          description="Each of these is implemented in the app. Where something has only been tested in simulation or still needs real devices, we say so."
        />

        <div className="mt-14 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {coreConcepts.map((concept, index) => (
            <Reveal key={concept.title} delay={index * 60}>
              <div className="h-full rounded-2xl border border-border bg-white p-7">
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
