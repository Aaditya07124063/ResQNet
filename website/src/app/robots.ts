import type { MetadataRoute } from "next";
import { siteConfig } from "@/content/site";

// Required for `output: "export"` — this route has no request-time data.
export const dynamic = "force-static";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: "/",
    },
    sitemap: `${siteConfig.url}/sitemap.xml`,
  };
}
