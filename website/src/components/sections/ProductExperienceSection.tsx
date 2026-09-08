import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { PhoneFrame } from "@/components/ui/PhoneFrame";
import { Reveal } from "@/components/ui/Reveal";

// Real screens, captured from a running build of the actual Flutter app
// (light theme) — not reconstructed HTML. See
// website/public/screenshots/ and PhoneFrame.tsx's own doc comment.
const screens = [
  {
    src: "/screenshots/login.png",
    alt: "ResQNet's sign-in screen, with phone number entry, a country code selector, a CAPTCHA check, and a Continue with Google option",
    caption: "Sign in",
    description: "Phone or Google — verified before anything else happens.",
  },
  {
    src: "/screenshots/home.png",
    alt: "ResQNet's home screen, showing the SOS button, an I am safe broadcast option, and status for mesh, GPS, and nearby devices",
    caption: "Home",
    description: "One button for SOS, live status for what's actually connected.",
  },
  {
    src: "/screenshots/sos.png",
    alt: "ResQNet's Send SOS screen, showing emergency type selection and a disclosure of exactly who gets alerted",
    caption: "Send an SOS",
    description: "Pick a category, and see exactly who this reaches before you send it.",
  },
  {
    src: "/screenshots/emergency-contacts.png",
    alt: "ResQNet's Emergency Contacts screen, showing a trusted contacts list and location-aware local emergency hotlines",
    caption: "Emergency Contacts",
    description: "Trusted contacts you've added, plus local hotlines for where you are.",
  },
];

export function ProductExperienceSection() {
  return (
    <section className="bg-white py-20 sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="The real app"
          title="This is what actually ships."
          description="Four screens from a running build of ResQNet — not mockups reconstructed for this page."
        />

        <div className="mt-16 grid grid-cols-2 gap-x-6 gap-y-14 lg:grid-cols-4">
          {screens.map((screen, index) => (
            <Reveal key={screen.src} delay={index * 90} className="flex flex-col items-center">
              <PhoneFrame src={screen.src} alt={screen.alt} width={200} />
              <p className="mt-5 text-center text-sm font-semibold text-ink">
                {screen.caption}
              </p>
              <p className="mt-1 max-w-[200px] text-center text-xs leading-relaxed text-ink-faint">
                {screen.description}
              </p>
            </Reveal>
          ))}
        </div>
      </Container>
    </section>
  );
}
