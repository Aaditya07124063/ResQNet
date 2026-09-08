import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { LegalNotice } from "@/components/ui/LegalNotice";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/content/site";

export const metadata = pageMetadata({
  title: "Terms of Service",
  description: "The terms governing use of the ResQNet app.",
  path: "/terms/",
});

export default function TermsPage() {
  return (
    <>
      <PageHero
        eyebrow="Legal"
        title="Terms of Service"
        description="Last updated: this is initial product terms content, not a finalized legal document."
      />

      <section className="py-16 sm:py-20">
        <Container>
        {/* Nested wrapper, not a className override on Container — see
            about/page.tsx's identical comment for why. */}
        <div className="mx-auto max-w-2xl">
          <LegalNotice>
            This page describes ResQNet&apos;s terms as implemented today. It
            is informational content prepared alongside the product and has
            not been reviewed by legal counsel. It should be reviewed by a
            qualified lawyer, and by ResQNet&apos;s registered legal entity and
            jurisdiction once those are established, before being relied on
            as a binding agreement.
          </LegalNotice>

          <div className="mt-12 space-y-10 text-base leading-relaxed text-ink-soft">
            <section>
              <h2 className="text-xl font-semibold text-ink">1. Service description</h2>
              <p className="mt-3">
                ResQNet is an emergency communication app that helps you
                signal an SOS, notify trusted contacts, share your location
                when available, and — for nearby devices also running
                ResQNet — relay emergency messages directly between devices.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">2. Emergency-service disclaimer</h2>
              <p className="mt-3">
                <strong className="text-ink">
                  ResQNet is not a replacement for calling your local
                  emergency services.
                </strong>{" "}
                ResQNet is not currently integrated with any official
                emergency-response or government dispatch system, and
                sending an SOS through ResQNet does not notify police, fire,
                medical, or other official emergency services on its own. If
                you are in immediate danger, contact your local emergency
                number first.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">3. Availability disclaimer</h2>
              <p className="mt-3">
                ResQNet depends on your device, your mobile network, push
                notification delivery, and ResQNet&apos;s backend all being
                available and working correctly. We do not guarantee
                uninterrupted availability, and we do not guarantee that any
                specific SOS, notification, or message will be delivered.
                Device-to-device relay only works between nearby devices
                running ResQNet with mesh mode active — it does not provide
                connectivity in every situation or at any distance.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">4. Acceptable use</h2>
              <ul className="mt-3 list-disc space-y-2 pl-5">
                <li>Use ResQNet&apos;s SOS features for genuine situations, not as a test on other people without their knowledge.</li>
                <li>Provide accurate information for your account and trusted contacts.</li>
                <li>Don&apos;t attempt to access another user&apos;s account or data, or interfere with the operation of the service.</li>
                <li>Don&apos;t use ResQNet for any unlawful purpose.</li>
              </ul>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">5. Account responsibilities</h2>
              <p className="mt-3">
                You&apos;re responsible for keeping your account and the device
                it&apos;s signed into secure, and for keeping the information
                you provide — including your trusted-contact list — accurate
                and up to date.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">6. Limitation of liability</h2>
              <p className="mt-3">
                To the fullest extent permitted by law, ResQNet is provided
                on an &ldquo;as is&rdquo; and &ldquo;as available&rdquo; basis, without
                warranties of any kind, and ResQNet is not liable for
                outcomes arising from an emergency, including a failed,
                delayed, or incomplete SOS, notification, or message. Exact
                liability terms will be finalized during legal review.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">7. Changes to these terms</h2>
              <p className="mt-3">
                These terms may be updated as ResQNet&apos;s features evolve.
                Material changes will be reflected here with an updated date
                once ResQNet has a public release to version this against.
              </p>
            </section>

            <section>
              <h2 className="text-xl font-semibold text-ink">8. Contact</h2>
              <p className="mt-3">
                Questions about these terms can be sent to{" "}
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
