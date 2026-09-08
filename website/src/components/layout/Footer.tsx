import Link from "next/link";
import { ArrowUpRight } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { Logo } from "@/components/ui/Logo";
import { siteConfig, footerNav } from "@/content/site";

function FooterColumn({
  title,
  links,
}: {
  title: string;
  links: { label: string; href: string }[];
}) {
  return (
    <div>
      <h3 className="text-sm font-semibold text-white">{title}</h3>
      <ul className="mt-4 space-y-3">
        {links.map((link) => (
          <li key={link.href}>
            <Link
              href={link.href}
              className="group inline-flex items-center gap-1 text-sm text-white/70 transition-colors hover:text-white"
            >
              {link.label}
              <ArrowUpRight
                size={12}
                aria-hidden="true"
                className="text-white/40 motion-safe:transition-transform motion-safe:duration-200 motion-safe:ease-out motion-safe:group-hover:-translate-y-0.5 motion-safe:group-hover:translate-x-0.5 motion-safe:group-focus-visible:-translate-y-0.5 motion-safe:group-focus-visible:translate-x-0.5"
              />
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

export function Footer() {
  return (
    <footer className="border-t border-border-dark bg-surface-dark text-white">
      <Container className="grid grid-cols-2 gap-10 py-16 sm:grid-cols-3 lg:grid-cols-6">
        <div className="col-span-2 lg:col-span-2">
          <Logo variant="light" />
          <p className="mt-4 max-w-xs text-sm leading-relaxed text-white/70">
            {siteConfig.description}
          </p>
        </div>

        <FooterColumn title="Product" links={footerNav.product} />
        <FooterColumn title="Organization" links={footerNav.organization} />
        <FooterColumn title="Company" links={footerNav.company} />
        <FooterColumn title="Legal" links={footerNav.legal} />
      </Container>

      <div className="border-t border-border-dark">
        <Container className="flex flex-col items-center justify-between gap-3 py-6 text-xs text-white/50 sm:flex-row">
          <p>&copy; {new Date().getFullYear()} ResQNet. All rights reserved.</p>
          <p>Built for resilient emergency communication.</p>
        </Container>
      </div>
    </footer>
  );
}
