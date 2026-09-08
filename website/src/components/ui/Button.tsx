import type { ButtonHTMLAttributes, ReactNode } from "react";
import Link from "next/link";
import { cn } from "@/lib/utils";

type Variant = "primary" | "secondary" | "ghost" | "outlineOnDark";
type Size = "md" | "lg";

// Each variant is a complete, self-contained style — never combined with
// className overrides for background/text/border, since Tailwind utility
// classes don't reliably "win" by source order the way plain CSS would
// (this project doesn't pull in tailwind-merge, so conflicting utilities
// passed via className can silently lose to a variant's own classes).
const variantStyles: Record<Variant, string> = {
  primary:
    "bg-primary text-white hover:bg-[var(--color-primary-strong)] shadow-sm",
  secondary:
    "bg-white text-ink border border-border hover:border-ink/30 hover:bg-bg-subtle",
  // Matches the resting/hover color pair primaryNav links use (Header.tsx)
  // — the only current caller sits inline with them, and differing weight
  // there read as an accidental active-state rather than a deliberate CTA.
  ghost: "text-ink-soft hover:text-ink hover:bg-black/5",
  // For use on dark section backgrounds (e.g. the Hero) where "secondary"
  // (white fill) would fight the dark backdrop instead of sitting on it.
  outlineOnDark:
    "bg-transparent text-white border border-white/25 hover:bg-white/10 hover:border-white/40",
};

const sizeStyles: Record<Size, string> = {
  md: "px-5 py-2.5 text-sm",
  lg: "px-6 py-3.5 text-base",
};

const baseStyles =
  "inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-colors duration-150 disabled:opacity-50 disabled:pointer-events-none";

type CommonProps = {
  variant?: Variant;
  size?: Size;
  className?: string;
  children: ReactNode;
};

export function Button({
  variant = "primary",
  size = "md",
  className,
  children,
  href,
  ...rest
}: CommonProps &
  ({ href: string } & Omit<
    React.AnchorHTMLAttributes<HTMLAnchorElement>,
    "className"
  >)) {
  const classes = cn(baseStyles, variantStyles[variant], sizeStyles[size], className);

  const isExternal = href.startsWith("http") || href.startsWith("mailto:");

  if (isExternal) {
    return (
      <a href={href} className={classes} {...rest}>
        {children}
      </a>
    );
  }

  return (
    <Link href={href} className={classes} {...rest}>
      {children}
    </Link>
  );
}

export function ButtonAsButton({
  variant = "primary",
  size = "md",
  className,
  children,
  ...rest
}: CommonProps & ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      className={cn(baseStyles, variantStyles[variant], sizeStyles[size], className)}
      {...rest}
    >
      {children}
    </button>
  );
}
