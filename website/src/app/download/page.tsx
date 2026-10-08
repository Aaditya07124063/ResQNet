import { Smartphone, Apple, Bell } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { PageHero } from "@/components/sections/PageHero";
import { Button } from "@/components/ui/Button";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/content/site";

export const metadata = pageMetadata({
  title: "Download",
  description:
    "ResQNet's Android release is coming soon. Current availability for Android and iOS, and how to be notified when the app can be installed.",
  path: "/download/",
});

// No Play Store or App Store listing exists yet — verified via the
// repository audit (the Android applicationId is now "com.resqnet.app",
// but no Play Console submission or store URL exists anywhere in the
// project). This page intentionally shows a real "coming soon" state
// instead of a non-functional download button.
const platforms = [
  {
    icon: Smartphone,
    name: "Android",
    status: "Coming soon",
    detail: "Development builds exist; real-device testing is still to come. No Google Play listing yet.",
  },
  {
    icon: Apple,
    name: "iOS",
    status: "Not yet tested",
    detail: "iOS support has not been tested yet. No App Store date.",
  },
];

export default function DownloadPage() {
  return (
    <>
      <PageHero
        eyebrow="Download"
        title="Android release coming soon."
        description="ResQNet isn't available to install from an app store yet. There is no public APK either; any download that claims to be ResQNet isn't from us. This page will link to the real store listing once it exists."
      />

      <section className="py-20 sm:py-28">
        <Container>
          <div className="mx-auto grid max-w-2xl gap-6 sm:grid-cols-2">
            {platforms.map((platform) => (
              <div
                key={platform.name}
                className="rounded-2xl border border-border bg-bg-subtle p-8 text-center"
              >
                <platform.icon size={28} className="mx-auto text-ink-faint" aria-hidden="true" />
                <h2 className="mt-4 text-lg font-semibold text-ink">{platform.name}</h2>
                <span className="mt-2 inline-block rounded-full bg-white px-3 py-1 text-xs font-semibold text-ink-soft">
                  {platform.status}
                </span>
                <p className="mt-3 text-sm text-ink-faint">{platform.detail}</p>
              </div>
            ))}
          </div>

          <div className="mx-auto mt-14 max-w-xl rounded-2xl border border-border p-8 text-center">
            <Bell size={22} className="mx-auto text-primary" aria-hidden="true" />
            <h2 className="mt-4 text-lg font-semibold text-ink">Want to know when it&apos;s ready?</h2>
            <p className="mt-2 text-sm leading-relaxed text-ink-soft">
              Reach out and we&apos;ll let you know as soon as ResQNet is
              available to install.
            </p>
            <div className="mt-6 flex justify-center">
              <Button href="/contact/?type=general" size="lg">
                Get notified
              </Button>
            </div>
            <p className="mt-4 text-xs text-ink-faint">
              Or reach us directly at{" "}
              <a href={`mailto:${siteConfig.contactEmail}`} className="underline">
                {siteConfig.contactEmail}
              </a>
              .
            </p>
          </div>
        </Container>
      </section>
    </>
  );
}
