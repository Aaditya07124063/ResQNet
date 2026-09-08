import { Building2, GraduationCap, Landmark } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Button } from "@/components/ui/Button";
import { Reveal } from "@/components/ui/Reveal";

const audiences = [
  { icon: GraduationCap, label: "Universities & campuses" },
  { icon: Building2, label: "Companies & communities" },
  { icon: Landmark, label: "Institutions & future public-sector partners" },
];

export function OrganizationsTeaser() {
  return (
    <section className="bg-white py-20 sm:py-28">
      <Container>
        <div className="grid gap-12 lg:grid-cols-2 lg:items-center">
          <div>
            <SectionHeading
              eyebrow="For organizations"
              title="Built with larger emergency-response ecosystems in mind."
              description="Universities, companies, and institutions can use ResQNet's emergency communication and trusted-contact model as part of their own safety infrastructure."
            />
            <Button href="/organizations/" size="lg" className="mt-8">
              Talk to ResQNet
            </Button>
          </div>

          <Reveal>
            <ul className="space-y-4">
              {audiences.map((audience) => (
                <li
                  key={audience.label}
                  className="flex items-center gap-4 rounded-xl border border-border bg-bg-subtle p-5"
                >
                  <audience.icon size={22} className="shrink-0 text-primary" aria-hidden="true" />
                  <span className="text-sm font-medium text-ink">{audience.label}</span>
                </li>
              ))}
            </ul>
          </Reveal>
        </div>
      </Container>
    </section>
  );
}
