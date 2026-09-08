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
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
    },
  };
}
