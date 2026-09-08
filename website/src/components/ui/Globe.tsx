"use client";

import { useEffect, useRef, useState } from "react";
import createGlobe from "cobe";

export type GlobeMarker = {
  location: [number, number];
  size: number;
  color?: [number, number, number];
};

/**
 * A real rotating globe (WebGL canvas via `cobe`, ~19kB, zero
 * dependencies of its own) — not a decorative spinning-Earth GIF, and not
 * a full mapping/3D-globe library like three.js or react-globe.gl, which
 * would be far more than this one visual needs.
 *
 * `cobe` v2 has no built-in animation callback — it exposes
 * `globe.update(state)` for imperative frame-by-frame updates, so the
 * rotation loop here is a plain `requestAnimationFrame` loop that this
 * component owns and cancels on unmount.
 *
 * Rotation is slow (~50s per revolution), pauses while the pointer is
 * dragging it, and is disabled entirely (a still frame, still showing the
 * markers) under `prefers-reduced-motion: reduce` — checked once via
 * `matchMedia` rather than reactively, since a user's OS-level motion
 * preference doesn't change while this page is open.
 */
export function Globe({
  markers,
  className,
}: {
  markers: GlobeMarker[];
  className?: string;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const phiRef = useRef(4.9);
  const pointerInteracting = useRef<number | null>(null);
  const pointerInteractionMovement = useRef(0);
  // Lazy initializer (not an effect + setState) so this reads once at
  // mount and never triggers an extra render — guarded for the static-
  // export server render, where `window` doesn't exist.
  const [reduceMotion] = useState(() =>
    typeof window === "undefined"
      ? false
      : window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  );

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const width = canvas.offsetWidth;
    const globe = createGlobe(canvas, {
      devicePixelRatio: 2,
      width: width * 2,
      height: width * 2,
      phi: phiRef.current,
      theta: 0.3,
      dark: 1,
      diffuse: 1.1,
      mapSamples: 14000,
      mapBrightness: 3.5,
      baseColor: [0.25, 0.32, 0.34],
      markerColor: [0.86, 0.2, 0.13],
      glowColor: [0.16, 0.33, 0.32],
      markers,
    });

    let raf = 0;
    const step = () => {
      if (pointerInteracting.current === null) {
        if (!reduceMotion) {
          // ~50 seconds per revolution at 60fps.
          phiRef.current += (2 * Math.PI) / (50 * 60);
        }
      } else {
        phiRef.current += pointerInteractionMovement.current;
        pointerInteractionMovement.current = 0;
      }
      globe.update({ phi: phiRef.current });
      raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);

    return () => {
      cancelAnimationFrame(raf);
      globe.destroy();
    };
  }, [markers, reduceMotion]);

  return (
    <div className={className} style={{ width: "100%", maxWidth: 560, aspectRatio: 1, margin: "0 auto" }}>
      <canvas
        ref={canvasRef}
        role="img"
        aria-label="Rotating globe highlighting Nepal and India, with illustrative hazard markers"
        onPointerDown={(e) => {
          pointerInteracting.current = e.clientX;
          if (canvasRef.current) canvasRef.current.style.cursor = "grabbing";
        }}
        onPointerUp={() => {
          pointerInteracting.current = null;
          if (canvasRef.current) canvasRef.current.style.cursor = "grab";
        }}
        onPointerOut={() => {
          pointerInteracting.current = null;
          if (canvasRef.current) canvasRef.current.style.cursor = "grab";
        }}
        onPointerMove={(e) => {
          if (pointerInteracting.current !== null) {
            const delta = e.clientX - pointerInteracting.current;
            pointerInteracting.current = e.clientX;
            pointerInteractionMovement.current = delta / 150;
          }
        }}
        style={{ width: "100%", height: "100%", cursor: "grab", contain: "layout paint size" }}
      />
    </div>
  );
}
