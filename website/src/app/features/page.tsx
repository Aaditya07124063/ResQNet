import { Check } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { Button } from "@/components/ui/Button";
import { featureGroups } from "@/content/feature-groups";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "Emergency SOS, Trusted Contacts & More",
  description:
    "ResQNet's actual product capabilities: Emergency SOS, Trusted Contacts, Location, Notifications, Resilient Communication, and Security.",
  path: "/features/",
});

export default function FeaturesPage() {
  return (
    <>
      <PageHero
        eyebrow="Features"
        title="What ResQNet actually does."
        description="Every capability below reflects what's built into the app today — not a roadmap."
      />

      <section className="py-20 sm:py-28">
        <Container>
          <div className="space-y-16">
            {featureGroups.map((group) => (
              <div
                key={group.title}
                className="grid gap-8 border-b border-border pb-16 last:border-b-0 last:pb-0 lg:grid-cols-3"
              >
                <div>
                  <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-primary-soft">
                    <group.icon size={22} className="text-[var(--color-primary-strong)]" aria-hidden="true" />
                  </div>
                  <h2 className="mt-5 text-xl font-semibold text-ink">{group.title}</h2>
                  <p className="mt-2 text-sm leading-relaxed text-ink-soft">
                    {group.summary}
                  </p>
                </div>

                <ul className="space-y-4 lg:col-span-2">
                  {group.points.map((point) => (
                    <li key={point} className="flex gap-3">
                      <Check
                        size={18}
                        className="mt-0.5 shrink-0 text-[var(--color-primary-strong)]"
                        aria-hidden="true"
                      />
                      <span className="text-sm leading-relaxed text-ink-soft">{point}</span>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </Container>
      </section>

      <section className="border-t border-border py-16 text-center">
        <Container>
          <h2 className="text-2xl font-bold text-ink">
            See how these capabilities work together
          </h2>
          <p className="mx-auto mt-3 max-w-xl text-base text-ink-soft">
            Read the step-by-step walkthrough, or check how ResQNet handles
            the data behind these features.
          </p>
          <div className="mt-6 flex flex-wrap justify-center gap-4">
            <Button href="/how-it-works/" size="lg">
              How It Works
            </Button>
            <Button href="/safety-privacy/" variant="secondary" size="lg">
              Safety &amp; Privacy
            </Button>
          </div>
        </Container>
      </section>
    </>
  );
}
