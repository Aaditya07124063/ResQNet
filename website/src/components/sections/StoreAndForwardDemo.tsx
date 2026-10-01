"use client";

import { useEffect, useState } from "react";
import { Pause, Play, RotateCcw, StepForward } from "lucide-react";
import { cn } from "@/lib/utils";

// A controlled SIMULATION of how an SOS moves through ResQNet when there is
// no network: phone to phone (store-and-forward) until one phone has
// Internet. It illustrates the protocol only — it does not measure or prove
// radio range, which depends on devices and conditions.

type NodeState = "idle" | "created" | "carrying" | "gateway" | "received" | "notified";

interface Step {
  caption: string;
  states: Record<string, NodeState>;
  /** Which link is active in this step, e.g. "A-B". */
  link?: string;
}

const NODES = [
  { id: "A", label: "Phone A", note: "Needs help · no signal" },
  { id: "B", label: "Phone B", note: "Offline" },
  { id: "C", label: "Phone C", note: "Offline" },
  { id: "D", label: "Phone D", note: "Offline" },
  { id: "E", label: "Phone E", note: "Has Internet" },
];

const STEPS: Step[] = [
  {
    caption: "No mobile network or Internet. Phone A sends an SOS. It is saved on the phone first, with location if GPS has a fix.",
    states: { A: "created" },
  },
  {
    caption: "Phone B comes within range of A. B receives the SOS, checks its signature, and keeps a copy.",
    states: { A: "created", B: "carrying" },
    link: "A-B",
  },
  {
    caption: "A and B are no longer in range of each other. Later, B meets Phone C and hands over its stored copy.",
    states: { A: "created", B: "carrying", C: "carrying" },
    link: "B-C",
  },
  {
    caption: "C meets Phone D. Each hop is counted; the SOS stops after its hop limit or when it expires.",
    states: { A: "created", B: "carrying", C: "carrying", D: "carrying" },
    link: "C-D",
  },
  {
    caption: "D meets Phone E, which has Internet. E acts as a gateway and uploads the SOS to the ResQNet server.",
    states: { A: "created", B: "carrying", C: "carrying", D: "carrying", E: "gateway" },
    link: "D-E",
  },
  {
    caption:
      "The server verifies the SOS came from Phone A (not from E) and alerts A's trusted contacts who use ResQNet. Other gateways uploading the same SOS do not create a duplicate.",
    states: { A: "created", B: "carrying", C: "carrying", D: "carrying", E: "gateway", server: "received", family: "notified" },
  },
];

const stateStyle: Record<NodeState, string> = {
  idle: "border-border bg-white text-ink-faint",
  created: "border-[var(--color-alert)] bg-[var(--color-alert-soft)] text-[var(--color-alert)]",
  carrying: "border-[var(--color-warn)] bg-[var(--color-warn-soft)] text-[var(--color-warn)]",
  gateway: "border-primary bg-primary-soft text-[var(--color-primary-strong)]",
  received: "border-[var(--color-success)] bg-[var(--color-success-soft)] text-[var(--color-success)]",
  notified: "border-[var(--color-success)] bg-[var(--color-success-soft)] text-[var(--color-success)]",
};

const stateText: Record<NodeState, string> = {
  idle: "Waiting",
  created: "SOS created",
  carrying: "Stored & relaying",
  gateway: "Gateway: uploading",
  received: "Received",
  notified: "Notified",
};

export function StoreAndForwardDemo() {
  const [step, setStep] = useState(0);
  const [playing, setPlaying] = useState(false);
  const last = STEPS.length - 1;
  const current = STEPS[step]!;

  // Playback stops by itself at the last step.
  const isPlaying = playing && step < last;

  useEffect(() => {
    if (!isPlaying) return;
    const timer = setTimeout(() => setStep((s) => Math.min(s + 1, last)), 2600);
    return () => clearTimeout(timer);
  }, [isPlaying, step, last]);

  const stateOf = (id: string): NodeState => current.states[id] ?? "idle";

  return (
    <div className="rounded-2xl border border-border bg-white p-6 sm:p-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <span className="rounded-full bg-[var(--color-warn-soft)] px-3 py-1 text-xs font-bold tracking-wide text-[var(--color-warn)] uppercase">
          Interactive simulation — not a live emergency network.
        </span>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => setPlaying(!isPlaying)}
            disabled={step >= last}
            className="inline-flex min-h-11 items-center gap-2 rounded-lg border border-border px-3 text-sm font-semibold text-ink disabled:opacity-40"
          >
            {isPlaying ? <Pause size={16} aria-hidden="true" /> : <Play size={16} aria-hidden="true" />}
            {isPlaying ? "Pause" : "Play"}
          </button>
          <button
            type="button"
            onClick={() => {
              setPlaying(false);
              setStep((s) => Math.min(s + 1, last));
            }}
            disabled={step >= last}
            className="inline-flex min-h-11 items-center gap-2 rounded-lg border border-border px-3 text-sm font-semibold text-ink disabled:opacity-40"
          >
            <StepForward size={16} aria-hidden="true" />
            Next step
          </button>
          <button
            type="button"
            onClick={() => {
              setPlaying(false);
              setStep(0);
            }}
            className="inline-flex min-h-11 items-center gap-2 rounded-lg border border-border px-3 text-sm font-semibold text-ink"
          >
            <RotateCcw size={16} aria-hidden="true" />
            Reset
          </button>
        </div>
      </div>

      <ol className="mt-8 grid grid-cols-2 gap-3 sm:grid-cols-5" aria-label="Phones in the simulation">
        {NODES.map((node, index) => {
          const state = stateOf(node.id);
          const linkActive = current.link === `${node.id}-${NODES[index + 1]?.id}`;
          return (
            <li key={node.id} className="relative">
              <div
                className={cn(
                  "rounded-xl border-2 p-3 text-center transition-colors motion-reduce:transition-none",
                  stateStyle[state],
                )}
              >
                <p className="text-sm font-bold text-ink">{node.label}</p>
                <p className="text-xs text-ink-faint">{node.note}</p>
                <p className="mt-2 text-xs font-semibold">{stateText[state]}</p>
              </div>
              {linkActive && (
                <span className="absolute top-1/2 -right-3 z-10 hidden h-1 w-6 -translate-y-1/2 rounded bg-primary motion-safe:animate-pulse sm:block" aria-hidden="true" />
              )}
            </li>
          );
        })}
      </ol>

      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        {[
          { id: "server", label: "ResQNet server", note: "Verifies origin, stores once" },
          { id: "family", label: "Trusted contacts", note: "Push notification" },
        ].map((node) => {
          const state = stateOf(node.id);
          return (
            <div key={node.id} className={cn("rounded-xl border-2 p-3 text-center", stateStyle[state])}>
              <p className="text-sm font-bold text-ink">{node.label}</p>
              <p className="text-xs text-ink-faint">{node.note}</p>
              <p className="mt-2 text-xs font-semibold">{stateText[state]}</p>
            </div>
          );
        })}
      </div>

      <p className="mt-6 text-base leading-relaxed text-ink" aria-live="polite">
        <span className="font-semibold">
          Step {step + 1} of {STEPS.length}:
        </span>{" "}
        {current.caption}
      </p>

      <p className="mt-4 text-sm text-ink-faint">
        This animation shows the order of events only. How far one phone reaches another depends on the phones,
        radio conditions, terrain and buildings; ResQNet will publish measured results from field tests rather than
        a promised range. A responder portal is not part of ResQNet yet.
      </p>
    </div>
  );
}
