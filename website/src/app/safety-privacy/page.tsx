import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Button } from "@/components/ui/Button";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "Safety & Privacy",
  description:
    "Who can see a ResQNet SOS, how mesh messages are signed but not encrypted, the medical-information opt-in, trusted-contact notifications, and how long emergency data is kept.",
  path: "/safety-privacy/",
});

// Every row below is taken from docs/PRIVACY_AND_RETENTION.md (§5, §6) and
// docs/SECURITY.md. Update those first if behaviour changes.
const visibility = [
  {
    who: "Phones that receive your SOS over the mesh",
    sees: "Your name, the full SOS message and your exact location. Relays keep a copy until the SOS expires (24 hours by default).",
  },
  {
    who: "Your trusted contacts (push notification)",
    sees: "Your name, the SOS category and your location, never the message or medical details. The notification text is generic: \"<name> needs emergency assistance — open ResQNet.\"",
  },
  {
    who: "Your trusted contacts and local numbers (SMS)",
    sees: "A pre-filled text you send from your phone: category, your name, any message you typed and a location link. Never medical details.",
  },
  {
    who: "People notified by the server about a nearby emergency",
    sees: "The category and an approximate distance only.",
  },
  {
    who: "Responders with respond permission",
    sees: "The exact location and message, while retention allows.",
  },
  {
    who: "Staff with monitor permission only",
    sees: "Location rounded to about 1 km. No message, phone number or notes.",
  },
];

const retention = [
  ["SOS message, exact location and responder notes", "Stops being served 90 days after a responder closes the incident, then redacted"],
  ["Link between an SOS and your account", "Removed 730 days after closure"],
  ["Incidents that no responder has closed", "Kept; never aged out while unhandled"],
  ["Shared-location chat messages", "30 days"],
  ["Location used for nearby alerts (opt-in)", "Ignored and deleted after 30 days without updates"],
  ["Earthquake sensor reports", "30 days"],
  ["Your own sent SOS entries on your phone", "Removed 7 days after being sent or closed"],
  ["Other people's SOS relayed through your phone", "Dropped at expiry, 24 hours by default"],
  ["Server backups", "Can keep deleted data for up to about 8 weeks"],
];

const limitations = [
  "Mesh messages are signed, not encrypted. Anyone running ResQNet within range can read an SOS that reaches their phone.",
  "Copies that reached other people's phones can't be deleted remotely; they expire on those phones.",
  "Account deletion exists on the server, but there is no button for it in the app yet.",
  "Trusted contacts can't yet read the SOS text inside the app.",
  "These retention periods are ResQNet's own operational policy. They have not been legally reviewed, and ResQNet does not claim compliance with any particular law.",
];

export default function SafetyPrivacyPage() {
  return (
    <>
      <PageHero
        eyebrow="Safety & privacy"
        title="Who sees your SOS, and for how long."
        description="To be useful, an emergency message has to reach strangers' phones. Here is exactly what ResQNet protects, what it can't, and how long it keeps things."
      />

      <section className="py-20 sm:py-28">
        <Container>
          <div className="mx-auto max-w-3xl space-y-14">
            <div>
              <h2 className="text-2xl font-bold text-ink">Signed, not encrypted</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                Each phone holds its own signing key in the platform keystore.
                Every SOS carries a signature over its text, location, hop
                limit and expiry. A relaying phone can&apos;t change any of
                these without the signature failing, so receiving phones reject
                altered copies, and the server checks the signature before
                crediting a relayed SOS to the person who sent it. The content
                itself is <strong className="text-ink">not encrypted</strong>.
              </p>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">Who can see what</h2>
              <dl className="mt-6 divide-y divide-border rounded-2xl border border-border">
                {visibility.map((row) => (
                  <div key={row.who} className="grid gap-1 p-5 sm:grid-cols-[minmax(0,2fr)_minmax(0,3fr)] sm:gap-6">
                    <dt className="text-sm font-semibold text-ink">{row.who}</dt>
                    <dd className="text-sm leading-relaxed text-ink-soft">{row.sees}</dd>
                  </div>
                ))}
              </dl>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">Medical information is opt-in</h2>
              <ul className="mt-4 list-disc space-y-2 pl-5 text-base leading-relaxed text-ink-soft">
                <li>
                  Your profile can hold blood group, allergies and medications.
                  These stay in your profile.
                </li>
                <li>
                  &ldquo;Include medical information in automatic SOS&rdquo; is
                  <strong className="text-ink"> off by default</strong> and
                  resets to off whenever anyone signs out.
                </li>
                <li>
                  When it&apos;s on, blood group and allergies (never
                  medications) are added to the signed message of an{" "}
                  <em>automatic</em> SOS. Every phone that receives that SOS over
                  the mesh can then read them.
                </li>
                <li>
                  A manual SOS contains only what you type. Ordinary mesh
                  messages, push notifications and SMS never carry medical
                  details.
                </li>
              </ul>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">How long data is kept</h2>
              <div className="mt-6 overflow-x-auto rounded-2xl border border-border">
                <table className="w-full text-left text-sm">
                  <caption className="sr-only">ResQNet data retention periods</caption>
                  <thead className="bg-bg-subtle text-ink">
                    <tr>
                      <th scope="col" className="p-4 font-semibold">Data</th>
                      <th scope="col" className="p-4 font-semibold">Retention</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-border text-ink-soft">
                    {retention.map(([data, period]) => (
                      <tr key={data}>
                        <td className="p-4">{data}</td>
                        <td className="p-4">{period}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <p className="mt-4 text-sm text-ink-faint">
                Automated deletion runs once the operator schedules the
                retention job. Expired SOS data stops being served at expiry
                even before the job runs.
              </p>
            </div>

            <div>
              <h2 className="text-2xl font-bold text-ink">Account security</h2>
              <p className="mt-4 text-base leading-relaxed text-ink-soft">
                Every request that reads or writes your account goes through a
                signed-in session with short-lived access tokens and rotating
                refresh tokens. Your data is checked against your account on
                every request. Google Sign-In is verified with Google by the
                server, and ResQNet never handles a Google password. You choose
                who sees your profile photo: private, contacts only or public.
              </p>
            </div>
          </div>
        </Container>
      </section>

      <section className="border-t border-border bg-bg-subtle py-20 sm:py-28">
        <Container>
          <SectionHeading
            eyebrow="Limitations"
            title="What we won't claim."
            description="Security and privacy claims are easy to overstate. These are the current limits."
          />
          <ul className="mt-10 max-w-2xl list-disc space-y-3 pl-5 text-base leading-relaxed text-ink-soft">
            {limitations.map((item) => (
              <li key={item}>{item}</li>
            ))}
          </ul>
        </Container>
      </section>

      <section className="py-16 text-center">
        <Container>
          <p className="text-base text-ink-soft">
            Read the full legal detail in our
          </p>
          <div className="mt-5 flex flex-wrap justify-center gap-4">
            <Button href="/privacy-policy/" variant="secondary">
              Privacy Policy
            </Button>
            <Button href="/terms/" variant="secondary">
              Terms of Service
            </Button>
          </div>
        </Container>
      </section>
    </>
  );
}
