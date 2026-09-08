"use client";

import { useState, type FormEvent } from "react";
import { useSearchParams } from "next/navigation";
import { Loader2, CheckCircle2, AlertCircle } from "lucide-react";
import { ButtonAsButton } from "@/components/ui/Button";
import { siteConfig } from "@/content/site";

type InquiryType = "general" | "partnership" | "organization" | "government" | "technical";

const inquiryTypes: { value: InquiryType; label: string }[] = [
  { value: "general", label: "General" },
  { value: "partnership", label: "Partnership" },
  { value: "organization", label: "Organization" },
  { value: "government", label: "Government / Institutional" },
  { value: "technical", label: "Technical" },
];

type Status = "idle" | "submitting" | "success" | "error";

// No production contact-submission backend exists in this project today
// (verified during the repository audit — the ResQNet backend has no
// public /contact route). If NEXT_PUBLIC_CONTACT_ENDPOINT is configured
// at build time, the form POSTs there; otherwise it falls back to a
// pre-filled mailto: link, per the task's own allowance for this case.
// See website/README.md "Contact configuration".
const CONTACT_ENDPOINT = process.env.NEXT_PUBLIC_CONTACT_ENDPOINT;

function isValidEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

export function ContactForm() {
  const searchParams = useSearchParams();
  const initialType = (searchParams.get("type") as InquiryType | null) ?? "general";

  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [organization, setOrganization] = useState("");
  const [inquiryType, setInquiryType] = useState<InquiryType>(
    inquiryTypes.some((t) => t.value === initialType) ? initialType : "general",
  );
  const [message, setMessage] = useState("");
  // Honeypot — real users never see or fill this field; a bot filling
  // every input on the page will.
  const [company, setCompany] = useState("");

  const [status, setStatus] = useState<Status>("idle");
  const [errors, setErrors] = useState<Record<string, string>>({});

  function validate(): boolean {
    const nextErrors: Record<string, string> = {};
    if (!name.trim()) nextErrors.name = "Name is required.";
    if (!email.trim()) nextErrors.email = "Email is required.";
    else if (!isValidEmail(email)) nextErrors.email = "Enter a valid email address.";
    if (!message.trim()) nextErrors.message = "Message is required.";
    else if (message.trim().length < 10)
      nextErrors.message = "Message should be at least 10 characters.";
    setErrors(nextErrors);
    return Object.keys(nextErrors).length === 0;
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (company) return; // honeypot tripped — silently drop.
    if (!validate()) return;

    setStatus("submitting");

    const payload = { name, email, organization, inquiryType, message };

    if (!CONTACT_ENDPOINT) {
      // Fallback: open the visitor's own email client with the message
      // pre-filled, rather than pretending a submission happened.
      const subject = encodeURIComponent(`ResQNet inquiry — ${inquiryType}`);
      const body = encodeURIComponent(
        `Name: ${name}\nEmail: ${email}\nOrganization: ${organization || "—"}\nType: ${inquiryType}\n\n${message}`,
      );
      window.location.href = `mailto:${siteConfig.contactEmail}?subject=${subject}&body=${body}`;
      setStatus("success");
      return;
    }

    try {
      const response = await fetch(CONTACT_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      if (!response.ok) throw new Error(`Request failed with status ${response.status}`);
      setStatus("success");
    } catch {
      setStatus("error");
    }
  }

  if (status === "success") {
    return (
      <div className="flex flex-col items-center rounded-2xl border border-border bg-bg-subtle p-10 text-center">
        <CheckCircle2 size={32} className="text-[var(--color-success)]" aria-hidden="true" />
        <h2 className="mt-4 text-lg font-semibold text-ink">
          {CONTACT_ENDPOINT ? "Message sent" : "Your email app should have opened"}
        </h2>
        <p className="mt-2 max-w-sm text-sm text-ink-soft">
          {CONTACT_ENDPOINT
            ? "Thanks for reaching out — we'll get back to you soon."
            : `If it didn't, email us directly at ${siteConfig.contactEmail}.`}
        </p>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} noValidate className="space-y-5">
      <input
        type="text"
        name="company"
        value={company}
        onChange={(e) => setCompany(e.target.value)}
        tabIndex={-1}
        autoComplete="off"
        aria-hidden="true"
        className="hidden"
      />

      <div>
        <label htmlFor="name" className="block text-sm font-medium text-ink">
          Name
        </label>
        <input
          id="name"
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          aria-invalid={Boolean(errors.name)}
          aria-describedby={errors.name ? "name-error" : undefined}
          className="mt-1.5 w-full rounded-lg border border-border px-3.5 py-2.5 text-sm text-ink outline-none focus:border-primary"
        />
        {errors.name && (
          <p id="name-error" className="mt-1.5 text-sm text-[var(--color-alert)]">
            {errors.name}
          </p>
        )}
      </div>

      <div>
        <label htmlFor="email" className="block text-sm font-medium text-ink">
          Email
        </label>
        <input
          id="email"
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          aria-invalid={Boolean(errors.email)}
          aria-describedby={errors.email ? "email-error" : undefined}
          className="mt-1.5 w-full rounded-lg border border-border px-3.5 py-2.5 text-sm text-ink outline-none focus:border-primary"
        />
        {errors.email && (
          <p id="email-error" className="mt-1.5 text-sm text-[var(--color-alert)]">
            {errors.email}
          </p>
        )}
      </div>

      <div>
        <label htmlFor="organization" className="block text-sm font-medium text-ink">
          Organization <span className="font-normal text-ink-faint">(optional)</span>
        </label>
        <input
          id="organization"
          type="text"
          value={organization}
          onChange={(e) => setOrganization(e.target.value)}
          className="mt-1.5 w-full rounded-lg border border-border px-3.5 py-2.5 text-sm text-ink outline-none focus:border-primary"
        />
      </div>

      <div>
        <label htmlFor="inquiryType" className="block text-sm font-medium text-ink">
          Inquiry type
        </label>
        <select
          id="inquiryType"
          value={inquiryType}
          onChange={(e) => setInquiryType(e.target.value as InquiryType)}
          className="mt-1.5 w-full rounded-lg border border-border bg-white px-3.5 py-2.5 text-sm text-ink outline-none focus:border-primary"
        >
          {inquiryTypes.map((type) => (
            <option key={type.value} value={type.value}>
              {type.label}
            </option>
          ))}
        </select>
      </div>

      <div>
        <label htmlFor="message" className="block text-sm font-medium text-ink">
          Message
        </label>
        <textarea
          id="message"
          rows={5}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          aria-invalid={Boolean(errors.message)}
          aria-describedby={errors.message ? "message-error" : undefined}
          className="mt-1.5 w-full rounded-lg border border-border px-3.5 py-2.5 text-sm text-ink outline-none focus:border-primary"
        />
        {errors.message && (
          <p id="message-error" className="mt-1.5 text-sm text-[var(--color-alert)]">
            {errors.message}
          </p>
        )}
      </div>

      {status === "error" && (
        <p className="flex items-center gap-2 text-sm text-[var(--color-alert)]">
          <AlertCircle size={16} aria-hidden="true" />
          Something went wrong sending your message. Please try again, or
          email {siteConfig.contactEmail} directly.
        </p>
      )}

      <ButtonAsButton type="submit" size="lg" className="w-full sm:w-auto" disabled={status === "submitting"}>
        {status === "submitting" && <Loader2 size={16} className="animate-spin" aria-hidden="true" />}
        {status === "submitting" ? "Sending…" : "Send message"}
      </ButtonAsButton>
    </form>
  );
}
