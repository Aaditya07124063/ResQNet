"use client";

import type { ReactNode } from "react";
import { useInView } from "@/hooks/useInView";
import { cn } from "@/lib/utils";

/**
 * Fades + slides content in once it scrolls into view. Reduced-motion
 * users get the plain, final state immediately via CSS
 * (`prefers-reduced-motion` in globals.css turns the transition off), so
 * this component doesn't need to branch on that itself.
 */
export function Reveal({
  children,
  delay = 0,
  className,
}: {
  children: ReactNode;
  delay?: number;
  className?: string;
}) {
  const { ref, inView } = useInView<HTMLDivElement>();

  return (
    <div
      ref={ref}
      className={cn(
        "reveal",
        inView && "reveal-visible",
        className,
      )}
      style={{ transitionDelay: inView ? `${delay}ms` : "0ms" }}
    >
      {children}
    </div>
  );
}
