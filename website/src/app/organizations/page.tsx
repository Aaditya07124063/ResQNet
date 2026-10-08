import {
  ListChecks,
  UserCheck,
  Map as MapIcon,
  BellRing,
  ScrollText,
  KeyRound,
  LifeBuoy,
  HeartHandshake,
  Landmark,
  Building2,
} from "lucide-react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Button } from "@/components/ui/Button";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "For Responders, NGOs & Emergency Operations Centers",
  description:
    "ResQNet's responder operations portal: incident queue, enforced response workflow, assignment, incident map, alerts, permissions and audit trail. Built and tested; not yet deployed.",
  path: "/organizations/",
});

const audiences = [
  { icon: LifeBuoy, title: "Rescue teams", description: "See incoming SOS alerts, take ownership and record progress on scene." },
  { icon: HeartHandshake, title: "NGOs and relief groups", description: "Coordinate volunteers responding to people who are cut off." },
  { icon: Landmark, title: "Local authorities", description: "Publish alerts and keep an accountable record of the response." },
  { icon: Building2, title: "Emergency operations centers", description: "One queue, one map and one timeline for every incident." },
];

// From docs/FEATURE_STATUS.md #34–#38 and docs/SECURITY.md — the
// operations portal (lib/main_operations.dart) and /api/v1/employee.
const capabilities = [
  {
    icon: ListChecks,
    title: "Incident queue and workflow",
    description:
      "Every SOS that reaches the server becomes an incident that moves through a fixed sequence: reported, acknowledged, assigned, en route, arrived, assisting, resolved. It can also be stood down with a reason. Resolved and stood-down are final.",
  },
  {
    icon: UserCheck,
    title: "Assignment",
    description:
      "Assign and reassign responders. Only the assigned responder records on-scene progress, unless a coordinator with assignment permission does it for them.",
  },
  {
    icon: ScrollText,
    title: "Nothing silently disappears",
    description:
      "An incident stays in the queue until a responder closes it, even if the person marks themselves safe or cancels. That change is shown on the timeline, and the dashboard shows the oldest unacknowledged incident.",
  },
  {
    icon: MapIcon,
    title: "Map and situational view",
    description:
      "Incidents on a map with approximate positions. Exact location and the SOS message appear only in the detail view, for staff with respond permission.",
  },
  {
    icon: BellRing,
    title: "Alerts and disaster sources",
    description:
      "Publish and update emergency alerts, with per-source publishing permissions. Alerts can be signed so phones can verify an official alert they receive over the mesh.",
  },
  {
    icon: KeyRound,
    title: "Permissions and audit trail",
    description:
      "Separate monitor, respond and assign permissions, enforced on the server. Monitor-only staff never see the message, phone number or notes. Every staff action is written to an audit log.",
  },
];

const limits = [
  "The portal is built and covered by automated tests, but it is not deployed and has not been used in a real response.",
  "Staff get no real-time updates or push notifications yet.",
  "It has not been tested with real screen readers.",
  "No government or official emergency-response system is integrated with ResQNet today, and no agency uses it.",
  "Organization management (multiple agencies, their own staff) is not built yet.",
];

export default function OrganizationsPage() {
  return (
    <>
      <PageHero
        eyebrow="For responders and EOCs"
        title="Turn incoming SOS alerts into owned, tracked incidents."
        description="ResQNet's second half is an operations portal for the people who respond: rescue teams, NGOs, local authorities and emergency operations centers. It runs on the web and on mobile."
      >
        <div className="mt-8 flex flex-wrap gap-4">
          <Button href="/contact/?type=organization" size="lg">
            Talk to ResQNet
          </Button>
          <Button href="/how-it-works/" variant="secondary" size="lg">
            How an SOS reaches you
          </Button>
        </div>
      </PageHero>

      <section className="py-20 sm:py-28">
        <Container>
          <SectionHeading eyebrow="Who it's for" title="Teams who answer emergencies." />
          <div className="mt-12 grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
            {audiences.map((audience) => (
              <div key={audience.title} className="rounded-2xl border border-border p-6">
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
          <SectionHeading
            eyebrow="Operations portal"
            title="What responders get."
            description="Each item below exists in the codebase today and is enforced on the server, not only in the interface."
          />
          <div className="mt-12 grid gap-x-10 gap-y-10 sm:grid-cols-2 lg:grid-cols-3">
            {capabilities.map((item) => (
              <div key={item.title}>
                <item.icon size={22} className="text-primary" aria-hidden="true" />
                <h3 className="mt-4 text-base font-semibold text-ink">{item.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-ink-soft">{item.description}</p>
              </div>
            ))}
          </div>
        </Container>
      </section>

      <section className="py-20 sm:py-28">
        <Container>
          <div className="mx-auto max-w-2xl rounded-2xl border border-dashed border-border p-8 sm:p-10">
            <h2 className="text-2xl font-bold text-ink">Current limitations</h2>
            <ul className="mt-6 list-disc space-y-3 pl-5 text-base leading-relaxed text-ink-soft">
              {limits.map((limit) => (
                <li key={limit}>{limit}</li>
              ))}
            </ul>
            <p className="mt-6 text-base leading-relaxed text-ink-soft">
              If you run emergency response and want to talk about pilots,
              integration or how the workflow fits your procedures, we&apos;d
              like to hear from you.
            </p>
            <div className="mt-8 flex flex-wrap gap-4">
              <Button href="/contact/?type=organization" size="lg">
                Contact us
              </Button>
              <Button href="/contact/?type=government" variant="secondary" size="lg">
                Government / institutional inquiry
              </Button>
            </div>
          </div>
        </Container>
      </section>
    </>
  );
}
