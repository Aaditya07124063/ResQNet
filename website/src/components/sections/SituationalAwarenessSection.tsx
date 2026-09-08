"use client";

import { useMemo, useState } from "react";
import { Info, Radio, ArrowRight } from "lucide-react";
import { Container } from "@/components/layout/Container";
import { SectionHeading } from "@/components/ui/SectionHeading";
import { Globe, type GlobeMarker } from "@/components/ui/Globe";
import {
  demoHazards,
  hazardTypeMeta,
  regionMeta,
  type HazardType,
  type HazardRegion,
} from "@/content/hazard-data";
import { cn } from "@/lib/utils";

const allTypes = Object.keys(hazardTypeMeta) as HazardType[];
const allRegions = Object.keys(regionMeta) as HazardRegion[];

function Chip({
  active,
  onClick,
  color,
  children,
}: {
  active: boolean;
  onClick: () => void;
  color?: string;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={cn(
        "inline-flex items-center gap-2 rounded-full border px-3.5 py-1.5 text-sm font-medium transition-colors",
        active
          ? "border-white/30 bg-white/10 text-white"
          : "border-white/10 bg-transparent text-white/50 hover:border-white/20 hover:text-white/75",
      )}
    >
      {color && (
        <span
          className="h-2 w-2 rounded-full"
          style={{ background: color }}
          aria-hidden="true"
        />
      )}
      {children}
    </button>
  );
}

export function SituationalAwarenessSection() {
  const [activeTypes, setActiveTypes] = useState<Set<HazardType>>(
    new Set(allTypes),
  );
  const [activeRegions, setActiveRegions] = useState<Set<HazardRegion>>(
    new Set(allRegions),
  );

  function toggleType(type: HazardType) {
    setActiveTypes((prev) => {
      const next = new Set(prev);
      if (next.has(type) && next.size > 1) next.delete(type);
      else next.add(type);
      return next;
    });
  }

  function toggleRegion(region: HazardRegion) {
    setActiveRegions((prev) => {
      const next = new Set(prev);
      if (next.has(region) && next.size > 1) next.delete(region);
      else next.add(region);
      return next;
    });
  }

  const visibleHazards = useMemo(
    () =>
      demoHazards.filter(
        (h) => activeTypes.has(h.type) && activeRegions.has(h.region),
      ),
    [activeTypes, activeRegions],
  );

  const markers: GlobeMarker[] = useMemo(() => {
    const regionMarkers: GlobeMarker[] = allRegions
      .filter((r) => activeRegions.has(r))
      .map((r) => ({
        location: regionMeta[r].center,
        size: 0.09,
        color: [0.86, 0.2, 0.13],
      }));
    const hazardMarkers: GlobeMarker[] = visibleHazards.map((h) => ({
      location: h.coordinates,
      size: h.severity === "high" ? 0.05 : h.severity === "moderate" ? 0.04 : 0.03,
    }));
    return [...regionMarkers, ...hazardMarkers];
  }, [visibleHazards, activeRegions]);

  // Recreates the globe only when the filter selection actually changes —
  // cheap for a marker set this small, and avoids needing a live marker-
  // update API the underlying renderer doesn't expose.
  const globeKey = `${[...activeTypes].sort().join(",")}|${[...activeRegions].sort().join(",")}`;

  return (
    <section className="bg-surface-dark py-20 text-white sm:py-28">
      <Container>
        <SectionHeading
          eyebrow="Situational awareness"
          title="Emergencies are local. Understanding where matters as much as knowing that."
          light
          description="ResQNet's product today is a global idea starting in one specific place — Nepal and India — because emergency communication has to work for a specific place before it can work anywhere."
        />

        <div className="mt-14 grid gap-12 lg:grid-cols-[minmax(0,1fr)_380px] lg:items-center">
          <div className="flex flex-col items-center">
            <Globe key={globeKey} markers={markers} />
            <p className="mt-4 max-w-sm text-center text-xs text-white/40">
              World → South Asia → Nepal and India. Drag to rotate.
            </p>
          </div>

          <div>
            <h3 className="text-sm font-semibold tracking-wide text-white/70 uppercase">
              Hazard layer
            </h3>
            <div className="mt-4 flex flex-wrap gap-2">
              {allTypes.map((type) => (
                <Chip
                  key={type}
                  active={activeTypes.has(type)}
                  onClick={() => toggleType(type)}
                  color={hazardTypeMeta[type].color}
                >
                  {hazardTypeMeta[type].label}
                </Chip>
              ))}
            </div>

            <h3 className="mt-6 text-sm font-semibold tracking-wide text-white/70 uppercase">
              Region
            </h3>
            <div className="mt-4 flex flex-wrap gap-2">
              {allRegions.map((region) => (
                <Chip
                  key={region}
                  active={activeRegions.has(region)}
                  onClick={() => toggleRegion(region)}
                >
                  {regionMeta[region].label}
                </Chip>
              ))}
            </div>

            <div className="mt-8 flex items-start gap-3 rounded-xl border border-white/10 bg-white/5 p-4">
              <Info size={18} className="mt-0.5 shrink-0 text-white/50" aria-hidden="true" />
              <p className="text-sm leading-relaxed text-white/60">
                <strong className="font-semibold text-white/80">Illustrative data.</strong>{" "}
                The markers above are example locations, not a live hazard
                feed — no authority disaster-alert source is connected yet.
                See below for what&apos;s real today.
              </p>
            </div>
          </div>
        </div>

        <div className="mt-20 grid gap-8 border-t border-white/10 pt-14 lg:grid-cols-3">
          <div>
            <div className="flex items-center gap-2.5">
              <Radio size={18} className="text-[var(--color-success)]" aria-hidden="true" />
              <h3 className="text-base font-semibold text-white">Real today</h3>
            </div>
            <p className="mt-3 text-sm leading-relaxed text-white/60">
              ResQNet cross-checks its on-device earthquake detection
              against USGS&apos;s and EMSC&apos;s real public earthquake
              feeds — never as the trigger itself, only to confirm a local
              reading after the fact. Peer-reported hazards (flood, fire,
              landslide, and more) relay directly between nearby devices
              over the mesh, with no server involved.
            </p>
          </div>
          <div>
            <div className="flex items-center gap-2.5">
              <span className="flex h-[18px] w-[18px] items-center justify-center rounded-full border border-dashed border-white/40 text-[10px] text-white/40">
                ~
              </span>
              <h3 className="text-base font-semibold text-white">Architecture, not yet connected</h3>
            </div>
            <p className="mt-3 text-sm leading-relaxed text-white/60">
              The app already has a single integration point built for a
              real government or authority disaster-alert feed — today
              it&apos;s an empty placeholder. Once a real feed exists, it
              flows through the same hazard and map system peer reports
              already use, with no rebuild required.
            </p>
          </div>
          <div>
            <div className="flex items-center gap-2.5">
              <span className="flex h-[18px] w-[18px] items-center justify-center rounded-full border border-dashed border-white/40 text-[10px] text-white/40">
                ~
              </span>
              <h3 className="text-base font-semibold text-white">Concept: a risk-interpretation layer</h3>
            </div>
            <p className="mt-3 text-sm leading-relaxed text-white/60">
              Rainfall, terrain, seismic readings, and historical
              data could feed a layer that interprets conditions into a
              simple low/moderate/high read for a given area. That layer
              doesn&apos;t exist yet — it&apos;s a direction, not a
              feature.
            </p>
          </div>
        </div>

        <div className="mt-14 flex flex-col items-start gap-3 border-t border-white/10 pt-10 sm:flex-row sm:items-center sm:justify-between">
          <p className="max-w-xl text-sm leading-relaxed text-white/60">
            Understanding a situation only matters if it reaches the people
            who need to know. That&apos;s where the app itself takes over —
            trigger an SOS, and ResQNet gets it to your trusted contacts,
            nearby devices, and local responders.
          </p>
          <span className="inline-flex shrink-0 items-center gap-1.5 text-sm font-semibold text-white/80">
            See how it works
            <ArrowRight size={16} aria-hidden="true" />
          </span>
        </div>
      </Container>
    </section>
  );
}
