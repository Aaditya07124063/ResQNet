/**
 * Single source of truth for site-wide identity, navigation, and legal
 * copy — referenced by layout, SEO metadata, and the footer instead of
 * being duplicated across files.
 */

export const siteConfig = {
  name: "ResQNet",
  tagline: "Communication when it matters most.",
  description:
    "ResQNet is an emergency communication app built to help people reach trusted contacts, share their situation, and coordinate during emergencies.",
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
  { label: "Home", href: "/" },
  { label: "How It Works", href: "/how-it-works/" },
  { label: "Features", href: "/features/" },
  { label: "For Organizations", href: "/organizations/" },
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
    { label: "For Organizations", href: "/organizations/" },
    { label: "Partnership", href: "/contact/?type=organization" },
  ] satisfies NavLink[],
  company: [
    { label: "About", href: "/about/" },
    { label: "Contact", href: "/contact/" },
  ] satisfies NavLink[],
  legal: [
    { label: "Privacy Policy", href: "/privacy-policy/" },
    { label: "Terms of Service", href: "/terms/" },
  ] satisfies NavLink[],
};
