import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "About",
  description:
    "Why ResQNet exists, the problem behind it, and the direction the project is headed.",
  path: "/about/",
});

export default function AboutPage() {
  return (
    <>
      <PageHero
        eyebrow="About"
        title="Why ResQNet exists."
        description="ResQNet started from a straightforward observation: the tools people reach for during an emergency are the same ones that can let them down at the worst time."
      />

      <section className="py-20 sm:py-28">
        <Container>
          {/* A nested wrapper, not a className override on Container
              itself — Container's own max-w-6xl and this max-w-2xl would
              otherwise both target the same element, and Tailwind's
              generated stylesheet order (not className order) decides
              which one wins. Narrower than the site's default content
              width on purpose: this is continuous prose, not cards/grids,
              and reads better at a tighter, more editorial measure. */}
          <div className="mx-auto max-w-2xl space-y-14">
            <div>
              <h2 className="text-2xl font-bold text-ink">The problem behind the project</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                Phone calls go unanswered. Text messages queue up behind a
                congested network. The person closest to an emergency often
                doesn&apos;t know whether the people who matter to them have
                actually been reached. And describing a location over a call,
                in the middle of a stressful moment, wastes time that matters.
                None of this is a hypothetical — it&apos;s the ordinary
                experience of trying to communicate under pressure.
              </p>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">What ResQNet is built to do</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                ResQNet is an emergency communication app built around a small
                number of ideas that work together: a fast way to signal an
                SOS, a trusted-contact list that&apos;s ready before it&apos;s
                needed, location information attached automatically when it&apos;s
                available, and a status that everyone involved can follow. It
                also includes a device-to-device relay capability, so nearby
                devices can stay in contact even when a mobile network isn&apos;t
                cooperating.
              </p>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                ResQNet runs its own backend and database rather than building
                its emergency path entirely on top of a single third-party
                service — the goal is for the parts that matter most during an
                emergency to be under ResQNet&apos;s own control.
              </p>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">Where this is headed</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                ResQNet today is a mobile app for individuals. The longer-term
                direction is for that same foundation — SOS, trusted contacts,
                resilient communication — to support organizations,
                institutions, and eventually collaboration with existing
                emergency-response infrastructure. That&apos;s a direction we&apos;re
                building toward, not a claim about what exists today. See{" "}
                <a href="/organizations/" className="font-medium text-primary hover:underline">
                  For Organizations
                </a>{" "}
                for more on that.
              </p>
            </div>
          </div>
        </Container>
      </section>
    </>
  );
}
