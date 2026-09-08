import { Hero } from "@/components/sections/Hero";
import { ProblemSection } from "@/components/sections/ProblemSection";
import { WhenToUseSection } from "@/components/sections/WhenToUseSection";
import { CoreConceptsSection } from "@/components/sections/CoreConceptsSection";
import { SituationalAwarenessSection } from "@/components/sections/SituationalAwarenessSection";
import { HowItWorksSection } from "@/components/sections/HowItWorksSection";
import { ProductExperienceSection } from "@/components/sections/ProductExperienceSection";
import { TrustSection } from "@/components/sections/TrustSection";
import { OrganizationsTeaser } from "@/components/sections/OrganizationsTeaser";
import { DownloadCTA } from "@/components/sections/DownloadCTA";
import { pageMetadata } from "@/lib/seo";
import { siteConfig } from "@/content/site";

export const metadata = pageMetadata({
  // Brand-first (helps "ResQNet" / "ResQNet app" searches surface this as
  // the official site) followed by the exact non-brand phrase this page
  // most directly matches — the on-page H1/tagline is unchanged, this is
  // the <title> tag only.
  title: `${siteConfig.name} — Emergency Communication App`,
  description: siteConfig.description,
  path: "/",
});

export default function HomePage() {
  return (
    <>
      <Hero />
      <ProblemSection />
      <WhenToUseSection />
      <CoreConceptsSection />
      <SituationalAwarenessSection />
      <HowItWorksSection />
      <ProductExperienceSection />
      <TrustSection />
      <OrganizationsTeaser />
      <DownloadCTA />
    </>
  );
}
