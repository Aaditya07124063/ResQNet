import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { LegalNotice } from "@/components/ui/LegalNotice";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/content/site";

export const metadata = pageMetadata({
  title: "Privacy Policy",
  description: "What information the ResQNet app collects, who can see an SOS (including over the offline mesh), the medical-information opt-in, and how long data is kept.",
  path: "/privacy-policy/",
});

export default function PrivacyPolicyPage() {
  return (
    <>
      <PageHero
        eyebrow="Legal"
        title="Privacy Policy"
        description="Last updated: this is initial product policy content, not a finalized legal document."
      />

      <section className="py-16 sm:py-20">
        <Container>
        {/* Nested wrapper, not a className override on Container — see
            about/page.tsx's identical comment for why. */}
        <div className="mx-auto max-w-2xl">
          <LegalNotice>
            This page describes ResQNet&apos;s product-level privacy practices
            as implemented today. It is informational content prepared
            alongside the product and has not been reviewed by legal
            counsel. It should be reviewed by a qualified lawyer, and by
            ResQNet&apos;s registered legal entity and jurisdiction once those
            are established, before being relied on as a binding policy.
          </LegalNotice>

          <div className="mt-12 space-y-10 text-base leading-relaxed text-ink-soft">
            <section>
              <h2 className="text-xl font-semibold text-ink">1. What this policy covers</h2>
              <p className="mt-3">
                This policy describes the information ResQNet&apos;s mobile app
                and backend collect and how that information is used. It
                applies to the ResQNet app and its backend API, not to this
                website (see below for website-specific data).
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">2. Information we collect</h2>
              <ul className="mt-3 list-disc space-y-2 pl-5">
                <li>
                  <strong className="text-ink">Account information</strong> —
                  when you sign in with Google, we receive your email address
                  and display name from Google to create your account. If you
                  sign in with a phone number, we receive that phone number.
                </li>
                <li>
                  <strong className="text-ink">Profile information</strong> —
                  optional fields you choose to provide, such as blood group,
                  allergies, medications, emergency contact, and address
                  details. Blood group and allergies are added to an
                  automatic SOS only if you turn on the medical-sharing
                  setting, which is off by default (see section 5).
                </li>
                <li>
                  <strong className="text-ink">Trusted contacts</strong> — the
                  names, phone numbers, and relationships you add for people
                  you want notified during an emergency.
                </li>
                <li>
                  <strong className="text-ink">Emergency (SOS) information</strong>{" "}
                  — when you trigger an SOS, we record its category, any
                  message you include, and your location and location
                  accuracy if your device provides them, plus a signature
                  from your device that lets us verify an SOS relayed by
                  other phones.
                </li>
                <li>
                  <strong className="text-ink">Optional location features</strong>{" "}
                  — if you turn on nearby-emergency alerts, your last known
                  location so we can tell you about emergencies near you; and
                  any location you choose to share in a chat message.
                </li>
                <li>
                  <strong className="text-ink">Device information</strong> — a
                  push-notification token and platform (Android/iOS) so we
                  can deliver notifications to your device.
                </li>
                <li>
                  <strong className="text-ink">Profile photo</strong> — if you
                  upload one, stored in ResQNet&apos;s object storage, with a
                  visibility setting you control.
                </li>
              </ul>
              <p className="mt-3">
                We do not collect this information through this marketing
                website — only through the ResQNet app itself.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">3. How we use information</h2>
              <p className="mt-3">
                Information is used to operate ResQNet&apos;s core functions:
                creating and authenticating your account, recording and
                distributing SOS events, notifying your trusted contacts,
                delivering push notifications, and letting you manage your
                own profile and contacts. We do not use your emergency
                information for advertising.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">4. Who we share information with</h2>
              <ul className="mt-3 list-disc space-y-2 pl-5">
                <li>
                  <strong className="text-ink">Your trusted contacts</strong> —
                  contacts who use ResQNet receive a push notification with
                  your name, the SOS category and your location, but not your
                  message or medical details. If you send the pre-filled SMS
                  the app opens, they (and any local emergency numbers it
                  includes) receive what that text contains.
                </li>
                <li>
                  <strong className="text-ink">People near you, over the offline mesh</strong>{" "}
                  — an SOS sent over the mesh is readable by every ResQNet phone
                  that receives or relays it, including people you don&apos;t
                  know. They can see your name, the SOS message and your exact
                  location. Mesh messages are signed, not encrypted, and relays
                  keep a copy until the SOS expires (24 hours by default).
                </li>
                <li>
                  <strong className="text-ink">Authorized responders</strong> —
                  staff with permission to respond see the SOS message and
                  exact location while retention allows; staff with monitoring
                  permission only see an approximate location.
                </li>
                <li>
                  <strong className="text-ink">Service providers</strong> —
                  Google (Sign-In verification and, where used, Firebase
                  Cloud Messaging for push notifications) and ResQNet&apos;s own
                  object storage for profile images. These providers process
                  data on ResQNet&apos;s behalf; they do not receive it for
                  their own independent use.
                </li>
              </ul>
              <p className="mt-3">
                We do not sell personal information, and we do not share
                emergency information with advertisers.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">5. Medical information</h2>
              <p className="mt-3">
                The setting &ldquo;Include medical information in automatic
                SOS&rdquo; is off by default and resets to off on sign-out.
                When on, your blood group and allergies (never medications)
                are added to the signed message of an automatic SOS, and are
                then visible to everyone who receives that SOS over the mesh,
                to ResQNet&apos;s server, and to authorized responders. They are
                never included in push notifications or the pre-filled SMS.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">6. Data retention</h2>
              <ul className="mt-3 list-disc space-y-2 pl-5">
                <li>
                  Account, profile, and trusted-contact information is kept
                  while your account exists.
                </li>
                <li>
                  An SOS that no responder has closed is kept. Once a responder
                  closes it, its personal data (message, exact location,
                  responder notes, delivery log) stops being served after 90
                  days and is then redacted. The link to your account is
                  removed after 730 days. An anonymous operational record
                  (category, times, response steps) is kept.
                </li>
                <li>
                  Other periods include: shared-location chat messages 30
                  days; nearby-alert location 30 days without updates;
                  earthquake sensor reports 30 days; sessions 30 days after
                  they end.
                </li>
                <li>
                  Backups can contain deleted data for up to about 8 weeks.
                  Copies on other people&apos;s phones expire there and
                  can&apos;t be deleted remotely.
                </li>
              </ul>
              <p className="mt-3">
                These periods are ResQNet&apos;s operational policy, not a
                statement of legal compliance.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">7. Your choices</h2>
              <p className="mt-3">
                You can edit or remove your profile information and trusted
                contacts directly in the app at any time, turn the medical
                sharing and nearby-alert settings on or off, and choose who
                can see your profile photo (private, contacts only, or
                public). Signing out removes your profile, contacts and
                unsent messages from the phone. Account deletion is supported
                by ResQNet&apos;s server but does not yet have a button in the
                app; contact us to request it. Deletion is refused while you
                have an SOS that responders have not closed.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">8. Children&apos;s privacy</h2>
              <p className="mt-3">
                ResQNet is not directed at children, and we do not knowingly
                collect information from children. This section will be
                expanded with a specific age policy as part of legal review.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">9. Changes to this policy</h2>
              <p className="mt-3">
                As ResQNet&apos;s features and infrastructure evolve, this
                policy will be updated to reflect them. Material changes will
                be reflected here with an updated date once ResQNet has a
                public release to version this against.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">10. Contact</h2>
              <p className="mt-3">
                Questions about this policy can be sent to{" "}
                <a href={`mailto:${siteConfig.contactEmail}`} className="font-medium text-primary hover:underline">
                  {siteConfig.contactEmail}
                </a>
                .
              </p>
            </section>
          </div>
        </div>
        </Container>
      </section>
    </>
  );
}
