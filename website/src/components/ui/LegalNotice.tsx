import { AlertTriangle } from "lucide-react";

export function LegalNotice({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex gap-3 rounded-xl border border-[var(--color-warn)]/30 bg-[var(--color-warn-soft)] p-5 text-sm leading-relaxed text-[var(--color-warn)]">
      <AlertTriangle size={18} className="mt-0.5 shrink-0" aria-hidden="true" />
      <p>{children}</p>
    </div>
  );
}
