"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Menu, X } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { Logo } from "@/components/ui/Logo";
import { Button } from "@/components/ui/Button";
import { primaryNav } from "@/content/site";
import { cn } from "@/lib/utils";

export function Header() {
  const [open, setOpen] = useState(false);
  const pathname = usePathname();

  // Close the mobile menu on route change. Adjusting state during render
  // (React's documented pattern for "reset on prop change") rather than
  // in an effect avoids an extra commit + cascading re-render.
  const [lastPathname, setLastPathname] = useState(pathname);
  if (pathname !== lastPathname) {
    setLastPathname(pathname);
    setOpen(false);
  }

  useEffect(() => {
    document.body.style.overflow = open ? "hidden" : "";
    return () => {
      document.body.style.overflow = "";
    };
  }, [open]);

  return (
    <header className="sticky top-0 z-50 border-b border-border bg-white/90 backdrop-blur-sm">
      <Container className="flex h-18 items-center justify-between py-4">
        <Link href="/" aria-label="ResQNet home" onClick={() => setOpen(false)}>
          <Logo />
        </Link>

        <nav
          aria-label="Primary"
          className="hidden items-center gap-8 xl:flex"
        >
          {primaryNav.map((item) => {
            const isActive =
              item.href === "/" ? pathname === "/" : pathname.startsWith(item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                aria-current={isActive ? "page" : undefined}
                className={cn(
                  "text-sm font-medium text-ink-soft transition-colors hover:text-ink",
                  isActive && "text-ink",
                )}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>

        <div className="hidden items-center gap-3 xl:flex">
          <Button href="/contact/" variant="ghost" size="md">
            Contact
          </Button>
          <Button href="/download/" variant="primary" size="md">
            Download App
          </Button>
        </div>

        <button
          type="button"
          className="inline-flex items-center justify-center rounded-lg p-2 text-ink xl:hidden"
          aria-label={open ? "Close menu" : "Open menu"}
          aria-expanded={open}
          aria-controls="mobile-nav"
          onClick={() => setOpen((v) => !v)}
        >
          {open ? (
            <X size={24} aria-hidden="true" />
          ) : (
            <Menu size={24} aria-hidden="true" />
          )}
        </button>
      </Container>

      {open && (
        <div
          id="mobile-nav"
          className="border-t border-border bg-white xl:hidden"
        >
          <Container className="flex flex-col gap-1 py-4">
            {primaryNav.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className="rounded-lg px-3 py-3 text-base font-medium text-ink hover:bg-bg-subtle"
              >
                {item.label}
              </Link>
            ))}
            <Link
              href="/contact/"
              className="rounded-lg px-3 py-3 text-base font-medium text-ink hover:bg-bg-subtle"
            >
              Contact / Partner With Us
            </Link>
            <Button href="/download/" variant="primary" size="lg" className="mt-3 w-full">
              Download App
            </Button>
          </Container>
        </div>
      )}
    </header>
  );
}
