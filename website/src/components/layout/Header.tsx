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
    <header className="sticky top-0 z-50 border-b border-white/10 bg-surface-dark text-white">
      <Container className="flex h-18 items-center justify-between py-4">
        <Link href="/" aria-label="ResQNet home" onClick={() => setOpen(false)}>
          <Logo variant="light" />
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
                  "text-sm font-medium text-white/75 transition-colors hover:text-white",
                  isActive && "text-white",
                )}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>

        <div className="hidden items-center gap-3 xl:flex">
          <Link href="/contact/" className="px-3 py-2.5 text-sm font-medium text-white/75 hover:text-white">
            Contact
          </Link>
          <Button href="/download/" variant="light" size="md">
            Get ResQNet
          </Button>
        </div>

        <button
          type="button"
          className="inline-flex h-11 w-11 items-center justify-center rounded-lg text-white xl:hidden"
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
          className="h-[calc(100svh-4.5rem)] overflow-y-auto border-t border-white/10 bg-surface-dark xl:hidden"
        >
          <Container className="flex flex-col gap-1 py-6">
            {primaryNav.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                // Hash links (/how-it-works/#civilians) may not change the
                // pathname, so close explicitly.
                onClick={() => setOpen(false)}
                className="rounded-lg px-3 py-3 font-display text-2xl font-semibold tracking-wide text-white uppercase hover:bg-white/5"
              >
                {item.label}
              </Link>
            ))}
            <Link
              href="/contact/"
              className="rounded-lg px-3 py-3 font-display text-2xl font-semibold tracking-wide text-white uppercase hover:bg-white/5"
            >
              Contact
            </Link>
            <Button href="/download/" variant="light" size="lg" className="mt-4 w-full">
              Get ResQNet
            </Button>
          </Container>
        </div>
      )}
    </header>
  );
}
