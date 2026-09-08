import { cn } from "@/lib/utils";

/**
 * Wordmark + a small signal-pulse mark. No official ResQNet logo exists
 * in the project's assets today (verified during the repository audit —
 * the app currently ships Flutter's own default icon, not a product
 * logo), so this is a deliberately simple, typographic identity for the
 * website rather than an invented "official" brand mark.
 */
export function Logo({
  className,
  variant = "dark",
}: {
  className?: string;
  variant?: "dark" | "light";
}) {
  const textColor = variant === "dark" ? "text-ink" : "text-white";

  return (
    <span className={cn("inline-flex items-center gap-2.5 font-semibold", className)}>
      <svg
        width="28"
        height="28"
        viewBox="0 0 28 28"
        fill="none"
        aria-hidden="true"
        className="shrink-0"
      >
        <rect width="28" height="28" rx="8" fill="var(--color-primary)" />
        <circle cx="14" cy="14" r="3" fill="white" />
        <path
          d="M9 14a5 5 0 0 1 5-5"
          stroke="white"
          strokeWidth="1.8"
          strokeLinecap="round"
          opacity="0.85"
        />
        <path
          d="M19 14a5 5 0 0 1-5 5"
          stroke="white"
          strokeWidth="1.8"
          strokeLinecap="round"
          opacity="0.85"
        />
        <path
          d="M6.5 14a7.5 7.5 0 0 1 7.5-7.5"
          stroke="white"
          strokeWidth="1.4"
          strokeLinecap="round"
          opacity="0.5"
        />
        <path
          d="M21.5 14a7.5 7.5 0 0 1-7.5 7.5"
          stroke="white"
          strokeWidth="1.4"
          strokeLinecap="round"
          opacity="0.5"
        />
      </svg>
      <span className={cn("text-lg tracking-tight", textColor)}>ResQNet</span>
    </span>
  );
}
