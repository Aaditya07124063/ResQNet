import { Lock, UserCheck, ServerCog, Eye, KeyRound } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Button } from "@/components/ui/Button";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  title: "Safety & Privacy",
  description:
    "How ResQNet handles emergency information: authenticated access, account-scoped data, secure communication with the backend, and responsible data handling.",
  path: "/safety-privacy/",
});

const principles = [
  {
    icon: Lock,
    title: "Authenticated access, every time",
    description:
      "ResQNet's backend requires a verified, signed-in session for every action that reads or writes your data. There is no anonymous write path into your account.",
  },
  {
    icon: UserCheck,
    title: "Your data is scoped to your account",
    description:
      "Profile details, trusted contacts, devices, and SOS history are all tied to your account and checked against it on every request — one user's session cannot reach another user's records.",
  },
  {
    icon: Eye,
    title: "You control what's visible",
    description:
      "Your profile photo's visibility (private, contacts only, or public) is a setting you control, not a default you have to work around.",
  },
  {
    icon: ServerCog,
    title: "Secure communication with the backend",
    description:
      "The app communicates with ResQNet's backend over an authenticated session using signed access tokens, not long-lived shared secrets embedded in the app.",
  },
  {
    icon: KeyRound,
    title: "Sign-in without a new password to manage",
    description:
      "Google Sign-In is verified directly against Google by ResQNet's backend, so your credentials are never handled or stored by ResQNet itself.",
  },
];

export default function SafetyPrivacyPage() {
  return (
    <>
      <PageHero
        eyebrow="Safety & privacy"
        title="Emergency information deserves careful handling."
        description="ResQNet deals with sensitive information by nature — who you are, where you are, and who you trust. Here's how that's handled."
      />

      <section className="py-20 sm:py-28">
        <Container>
          <div className="mx-auto max-w-2xl space-y-12">
            {principles.map((principle) => (
              <div key={principle.title} className="flex gap-5">
                <principle.icon size={24} className="mt-1 shrink-0 text-primary" aria-hidden="true" />
                <div>
                  <h2 className="text-lg font-semibold text-ink">{principle.title}</h2>
                  <p className="mt-2 text-base leading-relaxed text-ink-soft">
                    {principle.description}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </Container>
      </section>

      <section className="border-t border-border bg-bg-subtle py-20 sm:py-28">
        <Container>
          <SectionHeading
            eyebrow="What we won't claim"
            title="Careful language, on purpose."
            description="Security claims are easy to overstate. We'd rather describe what's actually true."
          />
          <div className="mt-10 max-w-2xl space-y-4 text-base leading-relaxed text-ink-soft">
            <p>
              We don&apos;t describe ResQNet as unhackable, guaranteed private,
              or &ldquo;military grade.&rdquo; No system can honestly claim
              that, and we won&apos;t either.
            </p>
            <p>
              What we can say is that ResQNet is built around authentication,
              account-scoped access, and infrastructure ResQNet controls
              rather than depends on entirely — and that we treat emergency
              data as sensitive by default, not as an afterthought.
            </p>
          </div>
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
