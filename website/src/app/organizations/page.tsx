import {
  GraduationCap,
  Building2,
  Landmark,
  Siren,
  Users,
  Radio,
  ShieldCheck,
} from "lucide-react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Button } from "@/components/ui/Button";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "For Organizations & Institutions",
  description:
    "How universities, companies, communities, and institutions can work with ResQNet on emergency communication and coordination.",
  path: "/organizations/",
});

const audiences = [
  {
    icon: GraduationCap,
    title: "Universities & campuses",
    description:
      "Give students and staff a direct way to alert trusted contacts and campus safety contacts during an incident.",
  },
  {
    icon: Building2,
    title: "Companies & communities",
    description:
      "Support employees or residents with a shared emergency communication tool that doesn't depend on any one person's phone habits.",
  },
  {
    icon: Landmark,
    title: "Institutions & future public-sector partners",
    description:
      "Explore how ResQNet's emergency communication model could fit alongside existing institutional or emergency-response processes.",
  },
];

const value = [
  {
    icon: Siren,
    title: "Emergency communication",
    description: "A consistent way for people in your organization to signal an emergency.",
  },
  {
    icon: Users,
    title: "Trusted-contact workflows",
    description: "Individuals maintain their own trusted contacts, notified automatically on SOS.",
  },
  {
    icon: Radio,
    title: "Resilient communication",
    description: "Device-to-device relay for nearby devices, useful in dense campuses or facilities.",
  },
  {
    icon: ShieldCheck,
    title: "Safety infrastructure",
    description: "Built on an authenticated, ownership-scoped backend — not a spreadsheet or group chat.",
  },
];

export default function OrganizationsPage() {
  return (
    <>
      <PageHero
        eyebrow="For organizations"
        title="Built with larger emergency-response ecosystems in mind."
        description="ResQNet is designed so universities, companies, communities, and institutions can build on the same emergency communication and trusted-contact model individuals already use."
      >
        <div className="mt-8">
          <Button href="/contact/?type=organization" size="lg">
            Talk to ResQNet
          </Button>
        </div>
      </PageHero>

      <section className="py-20 sm:py-28">
        <Container>
          <SectionHeading eyebrow="Who this is for" title="Organizations we can support." />
          <div className="mt-12 grid gap-8 sm:grid-cols-3">
            {audiences.map((audience) => (
              <div key={audience.title} className="rounded-2xl border border-border p-7">
                <audience.icon size={22} className="text-primary" aria-hidden="true" />
                <h3 className="mt-4 text-base font-semibold text-ink">{audience.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-soft">{audience.description}</p>
              </div>
            ))}
          </div>
        </Container>
      </section>

      <section className="border-t border-border bg-bg-subtle py-20 sm:py-28">
        <Container>
          <SectionHeading eyebrow="Possible value" title="What ResQNet can bring to an organization." />
          <div className="mt-12 grid gap-8 sm:grid-cols-2">
            {value.map((item) => (
              <div key={item.title} className="flex gap-4">
                <item.icon size={22} className="mt-1 shrink-0 text-primary" aria-hidden="true" />
                <div>
                  <h3 className="text-base font-semibold text-ink">{item.title}</h3>
                  <p className="mt-1 text-sm leading-relaxed text-ink-soft">{item.description}</p>
                </div>
              </div>
            ))}
          </div>
        </Container>
      </section>

      <section className="py-20 sm:py-28">
        <Container>
          <div className="rounded-2xl border border-border bg-bg-subtle p-10 text-center sm:p-14">
            <h2 className="text-2xl font-bold text-ink sm:text-3xl">
              Government & emergency-response collaboration
            </h2>
            <p className="mx-auto mt-4 max-w-2xl text-base leading-relaxed text-ink-soft">
              ResQNet is not currently integrated with any government or
              official emergency-response system. We see pilot programs,
              institutional deployment, and closer coordination with existing
              emergency infrastructure as a future opportunity worth
              exploring together — not a claim about where things stand
              today.
            </p>
            <div className="mt-8 flex justify-center">
              <Button href="/contact/?type=government" size="lg">
                Talk to ResQNet
              </Button>
            </div>
          </div>
        </Container>
      </section>
    </>
  );
}
