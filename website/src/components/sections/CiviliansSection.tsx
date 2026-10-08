import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Reveal } from "@/components/ui/Reveal";

const audiences = [
  "People caught in a disaster",
  "Trekkers and hikers",
  "Tourists in unfamiliar places",
  "Rural and remote communities",
  "Forest and field workers",
  "Stranded travelers",
];

// Example scenarios only — not reports of real deployments or incidents.
const scenarios = [
  {
    title: "Earthquake",
    description:
      "Towers are down and the network is jammed. You send an SOS; nearby phones running ResQNet pick it up and carry it towards someone with a working connection. If you're fine, one tap on \"I am safe\" tells the phones around you.",
  },
  {
    title: "Flood or cyclone",
    description:
      "You're cut off with patchy signal. The SOS is saved on your phone first, so it isn't lost if sending fails, and ResQNet keeps trying over the mesh and the Internet as either comes back.",
  },
  {
    title: "Landslide on a mountain road",
    description:
      "A blocked road strands a bus of travelers. Phones in the group form a local mesh, and any traveler who regains signal further down the valley can upload the SOS alerts their phone is carrying.",
  },
  {
    title: "Lost or injured on a trail",
    description:
      "No coverage on the ridge. Your SOS carries your GPS position when the phone has a fix, and passes to other hikers' phones that come within range later, even hours afterwards.",
  },
  {
    title: "Wildfire evacuation",
    description:
      "Everyone is moving at once. Mesh hazard reports, such as a fire or a blocked road, spread between nearby phones as unverified community reports, separate from official alerts.",
  },
  {
    title: "Can't reach your phone",
    description:
      "On-device crash and earthquake detection can start an SOS after a countdown you can cancel. These detectors still need real-world testing and will sometimes miss events or misfire.",
  },
];

export function CiviliansSection() {
  return (
    <section id="civilians" className="scroll-mt-20 bg-white py-20 sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="For civilians"
          title="Built for the places where the network runs out."
          description="ResQNet is for anyone who could be cut off when something goes wrong."
        />

        <ul className="mt-10 flex flex-wrap gap-2" aria-label="Who ResQNet is for">
          {audiences.map((audience) => (
            <li
              key={audience}
              className="rounded-full border border-border bg-bg-subtle px-4 py-2 text-sm font-medium text-ink"
            >
              {audience}
            </li>
          ))}
        </ul>

        <h3 className="mt-14 text-sm font-semibold tracking-wide text-ink-faint uppercase">
          Example scenarios
        </h3>
        <div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {scenarios.map((scenario, index) => (
            <Reveal key={scenario.title} delay={index * 60}>
              <div className="h-full rounded-2xl border border-border p-6">
                <h4 className="text-base font-semibold text-ink">{scenario.title}</h4>
                <p className="mt-2.5 text-sm leading-relaxed text-ink-soft">
                  {scenario.description}
                </p>
              </div>
            </Reveal>
          ))}
        </div>

        <p className="mt-10 max-w-2xl text-sm text-ink-faint">
          These are illustrations of how ResQNet is designed to help, not
          accounts of real deployments. Always contact local emergency services
          when you can. ResQNet also lists local emergency numbers for the
          country you&apos;re in, where they&apos;re included in the app.
        </p>
      </Container>
    </section>
  );
}
