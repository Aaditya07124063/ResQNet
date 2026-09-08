import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Reveal } from "@/components/ui/Reveal";

const scenarios = [
  {
    title: "Something happens and you need help fast",
    description:
      "A medical emergency, an accident, a fire — you tap Broadcast SOS, confirm during a five-second countdown, and ResQNet takes it from there.",
  },
  {
    title: "You want your people to know, without making the call yourself",
    description:
      "An earthquake, a flood, an evacuation — the moment matters more than a phone call to each person individually. Your trusted contacts get an SMS immediately, whether you're online or not.",
  },
  {
    title: "The mobile network is the problem",
    description:
      "Congested towers, patchy signal, a disaster that's damaged infrastructure nearby — ResQNet's mesh mode relays your alert directly to other nearby phones over Bluetooth and Wi-Fi Direct, no cell signal required.",
  },
  {
    title: "You're not sure who to call",
    description:
      "ResQNet detects your location and surfaces the right local emergency numbers — police, fire, ambulance, disaster management — instead of you searching for them under pressure.",
  },
  {
    title: "You just want to say you're okay",
    description:
      "After a scare that affected people nearby, one tap on \"I am safe\" broadcasts that to every ResQNet device around you — you don't have to reassure each person one at a time.",
  },
  {
    title: "You can't reach your phone, but your phone can still act",
    description:
      "ResQNet's on-device crash and earthquake detection can start an SOS on their own when the signal is strong enough — for the moments you're not able to open the app yourself.",
  },
];

export function WhenToUseSection() {
  return (
    <section className="bg-bg-subtle py-20 sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="When ResQNet helps"
          title="You'd reach for this the moment something goes wrong."
          description="Not a general-purpose safety app you check occasionally — a specific tool for a specific kind of moment."
        />

        <div className="mt-14 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {scenarios.map((scenario, index) => (
            <Reveal key={scenario.title} delay={index * 60}>
              <div className="h-full rounded-2xl bg-white p-6">
                <h3 className="text-base font-semibold text-ink">{scenario.title}</h3>
                <p className="mt-2.5 text-sm leading-relaxed text-ink-soft">
                  {scenario.description}
                </p>
              </div>
            </Reveal>
          ))}
        </div>

        <p className="mx-auto mt-10 max-w-2xl text-center text-sm text-ink-faint">
          ResQNet doesn&apos;t replace emergency services, and it can&apos;t
          guarantee a rescue — it&apos;s a faster, clearer way to reach the
          people and numbers that matter, in the moment you need them.
        </p>
      </Container>
    </section>
  );
}
