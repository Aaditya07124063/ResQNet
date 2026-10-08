import Link from "next/link";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/content/site";

export const metadata = pageMetadata({
  title: "About",
  description:
    "Why ResQNet exists: emergency communication for people cut off by disasters or remote terrain, built offline-first, and where the project stands today.",
  path: "/about/",
});

export default function AboutPage() {
  return (
    <>
      <PageHero
        eyebrow="About"
        title="Why ResQNet exists."
        description="The networks people rely on to call for help are often the first thing a disaster takes down. ResQNet is built for that moment."
      />

      <section className="py-20 sm:py-28">
        <Container>
          {/* Nested wrapper rather than a className override on Container:
              both would target max-width, and Tailwind's stylesheet order
              (not className order) decides which wins. */}
          <div className="mx-auto max-w-2xl space-y-14">
            <div>
              <h2 className="text-2xl font-bold text-ink">The problem</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                Earthquakes, floods, landslides and cyclones damage towers and
                cut power. Networks that do survive are overloaded. Trekkers,
                forest workers and rural communities are often outside coverage
                to begin with. In those moments a phone can still do a great
                deal: it has a radio, GPS and a battery. What it lacks is a way
                to reach anyone.
              </p>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">What ResQNet is</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                ResQNet is offline-first emergency communication. Phones running
                it connect directly over Bluetooth and Wi-Fi Direct, carry each
                other&apos;s SOS alerts, and hand them on until one reaches the
                Internet. From there an operations portal lets rescue teams,
                NGOs, local authorities and emergency operations centers take
                ownership of each incident. When the network is available,
                ResQNet uses it too. The server adds to the mesh rather than
                replacing it.
              </p>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                It is emergency infrastructure, not a social or chat app.
                Everything in it is shaped by one question: does this help a
                person who is cut off reach someone who can help?
              </p>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">Where it stands today</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                ResQNet is in active development, starting with Nepal and
                India. The core SOS, mesh relay, store-and-forward and responder
                workflow are implemented and covered by automated tests,
                including simulated multi-hop delivery. They have not yet been
                tested across many real phones in the field, and range, battery
                and background behaviour still have to be measured. The app is
                not yet in public app stores, and ResQNet is not integrated with
                any government or emergency agency.
              </p>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                See{" "}
                <Link href="/features/" className="font-medium text-primary hover:underline">
                  Features
                </Link>{" "}
                for the status of each capability,{" "}
                <Link href="/safety-privacy/" className="font-medium text-primary hover:underline">
                  Safety &amp; Privacy
                </Link>{" "}
                for its limits, or read the{" "}
                <a href={siteConfig.githubUrl} className="font-medium text-primary hover:underline">
                  source code
                </a>
                .
              </p>
            </div>
          </div>
        </Container>
      </section>
    </>
  );
}
