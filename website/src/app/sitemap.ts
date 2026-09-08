import type { MetadataRoute } from "next";
import { siteConfig } from "@/content/site";

// Required for `output: "export"` — this route has no request-time data.
export const dynamic = "force-static";

// Priority is relative within this site only (per the sitemap protocol,
// not a ranking promise) — the homepage and the two pages the task's
// non-brand keywords map to most directly are weighted highest; legal
// pages lowest, since they're neither frequently updated nor a target
// for search.
const routes: { path: string; priority: number; changeFrequency: MetadataRoute.Sitemap[number]["changeFrequency"] }[] = [
  { path: "", priority: 1.0, changeFrequency: "weekly" },
  { path: "how-it-works", priority: 0.9, changeFrequency: "monthly" },
  { path: "features", priority: 0.9, changeFrequency: "monthly" },
  { path: "organizations", priority: 0.7, changeFrequency: "monthly" },
  { path: "safety-privacy", priority: 0.7, changeFrequency: "monthly" },
  { path: "about", priority: 0.6, changeFrequency: "monthly" },
  { path: "download", priority: 0.8, changeFrequency: "weekly" },
  { path: "contact", priority: 0.5, changeFrequency: "yearly" },
  { path: "privacy-policy", priority: 0.2, changeFrequency: "yearly" },
  { path: "terms", priority: 0.2, changeFrequency: "yearly" },
];

export default function sitemap(): MetadataRoute.Sitemap {
  return routes.map(({ path, priority, changeFrequency }) => ({
    url: `${siteConfig.url}/${path}`.replace(/\/$/, "") + "/",
    lastModified: new Date(),
    changeFrequency,
    priority,
  }));
}
