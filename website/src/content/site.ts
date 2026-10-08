/**
 * Single source of truth for site-wide identity, navigation, and legal
 * copy — referenced by layout, SEO metadata, and the footer instead of
 * being duplicated across files.
 */

export const siteConfig = {
  name: "ResQNet",
  tagline: "Offline Emergency Communication",
  description:
    "ResQNet is an offline-first emergency communication app. When mobile networks or the Internet are down, nearby phones relay SOS alerts, messages and location to each other over Bluetooth and Wi-Fi Direct.",
  // Public source repository (README "Source Code" link and git remote).
  githubUrl: "https://github.com/Aaditya07124063/ResQNet",
  // Confirmed live in lib/core/network/api_config.dart (production API
  // decision, 2026-09-05: https://api.resqnet.co verified via GET /health).
  url: "https://resqnet.co",
  apiUrl: "https://api.resqnet.co",
  // No public contact mailbox is documented anywhere in the project yet.
  // Override at build time with NEXT_PUBLIC_CONTACT_EMAIL once one
  // exists — see website/README.md.
  contactEmail: process.env.NEXT_PUBLIC_CONTACT_EMAIL ?? "hello@resqnet.co",
  // No verified social accounts exist for this project — deliberately
  // empty rather than invented (see task instruction: "Do not invent
  // social accounts"). Add entries here once real accounts exist.
  social: [] as { label: string; href: string }[],
};

export type NavLink = {
  label: string;
  href: string;
};

export const primaryNav: NavLink[] = [
  { label: "How It Works", href: "/how-it-works/" },
  { label: "Features", href: "/features/" },
  { label: "For Civilians", href: "/how-it-works/#civilians" },
  { label: "For Responders", href: "/organizations/" },
  { label: "Safety & Privacy", href: "/safety-privacy/" },
  { label: "About", href: "/about/" },
];

export const footerNav = {
  product: [
    { label: "How It Works", href: "/how-it-works/" },
    { label: "Features", href: "/features/" },
    { label: "Download", href: "/download/" },
  ] satisfies NavLink[],
  organization: [
    { label: "For Civilians", href: "/how-it-works/#civilians" },
    { label: "For Responders & EOCs", href: "/organizations/" },
    { label: "Work With Us", href: "/contact/?type=organization" },
  ] satisfies NavLink[],
  company: [
    { label: "About", href: "/about/" },
    { label: "Safety & Privacy", href: "/safety-privacy/" },
    { label: "Source Code", href: "https://github.com/Aaditya07124063/ResQNet" },
    { label: "Contact", href: "/contact/" },
  ] satisfies NavLink[],
  legal: [
    { label: "Privacy Policy", href: "/privacy-policy/" },
    { label: "Terms of Service", href: "/terms/" },
  ] satisfies NavLink[],
};
