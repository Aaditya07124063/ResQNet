import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Reveal } from "@/components/ui/Reveal";

const problems = [
  {
    title: "Communication becomes fragmented",
    description:
      "In a fast-moving emergency, calls go unanswered, messages queue up, and no single channel tells the full story.",
  },
  {
    title: "It's unclear who knows",
    description:
      "The person in the emergency often doesn't know whether the people who matter — family, roommates, coworkers — have actually been reached yet.",
  },
  {
    title: "Location gets lost in translation",
    description:
      "Describing where you are, over a call or a text, wastes time that matters when every minute counts.",
  },
  {
    title: "Networks aren't always there",
    description:
      "Mobile networks can be congested, damaged, or simply out of reach — exactly the moments when reliable communication matters most.",
  },
];

export function ProblemSection() {
  return (
    <section className="bg-white py-20 sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="The problem"
          title="Emergencies put communication under strain, right when it matters most."
          description="ResQNet was built around a simple observation: the usual ways people communicate can break down at the worst possible time."
        />

        <div className="mt-14 grid gap-8 sm:grid-cols-2">
          {problems.map((problem, index) => (
            <Reveal key={problem.title} delay={index * 60}>
              <div className="border-l-2 border-border pl-5">
                <h3 className="text-base font-semibold text-ink">{problem.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-soft">
                  {problem.description}
                </p>
              </div>
            </Reveal>
          ))}
        </div>
      </Container>
    </section>
  );
}
