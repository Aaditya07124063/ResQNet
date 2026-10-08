import type { Metadata } from "next";
import { siteConfig } from "@/content/site";

/**
 * Builds per-page metadata on top of shared site defaults (root layout
 * already sets metadataBase, so paths here can stay relative) — keeps
 * every page's SEO tags consistent without repeating boilerplate.
 */
export function pageMetadata(options: {
  title: string;
  description: string;
  path: string;
}): Metadata {
  const { title, description, path } = options;
  const url = path === "/" ? siteConfig.url : `${siteConfig.url}${path}`;
  // A page-level `openGraph` object replaces the parent's, dropping the
  // root opengraph-image — so reference it explicitly.
  const image = { url: "/opengraph-image", width: 1200, height: 630, alt: `${siteConfig.name} — ${siteConfig.tagline}` };

  return {
    title,
    description,
    alternates: {
      canonical: path,
    },
    openGraph: {
      title,
      description,
      url,
      siteName: siteConfig.name,
      locale: "en_US",
      type: "website",
      images: [image],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [image.url],
    },
  };
}
