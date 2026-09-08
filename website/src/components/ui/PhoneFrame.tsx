import { cn } from "@/lib/utils";

/**
 * A CSS phone bezel wrapped around a real screenshot of the ResQNet
 * Flutter app (captured from a running build, light theme, cropped to
 * the device content area — see website/public/screenshots/). This
 * intentionally does not render fabricated HTML/CSS UI: the pixels
 * inside the frame are the actual app.
 *
 * `width` is a real prop rather than a className width override —
 * Tailwind utility classes don't reliably "win" by source order (see
 * Button.tsx's identical note), so a conflicting `w-*` passed via
 * `className` could silently lose to this component's own base class.
 * The inner viewport uses `aspect-ratio` (matching the screenshots' real
 * 640×1382 capture size) instead of a fixed pixel height, so it scales
 * correctly at any `width`.
 */
export function PhoneFrame({
  src,
  alt,
  width = 280,
  className,
}: {
  src: string;
  alt: string;
  width?: number;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "relative mx-auto overflow-hidden rounded-[2.5rem] border-[10px] border-surface-dark bg-surface-dark shadow-2xl",
        className,
      )}
      style={{ width: `min(${width}px, 100%)` }}
    >
      <div className="absolute top-0 left-1/2 z-10 h-6 w-32 -translate-x-1/2 rounded-b-2xl bg-surface-dark" />
      <div
        className="overflow-hidden rounded-[2rem] bg-white"
        style={{ aspectRatio: "640 / 1382" }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element -- static
            export with `images.unoptimized: true`; next/image adds no
            benefit here and these assets are already pre-sized for the
            web (see the screenshot-capture note in public/screenshots). */}
        <img
          src={src}
          alt={alt}
          width={640}
          height={1382}
          loading="lazy"
          className="h-full w-full object-cover object-top"
        />
      </div>
    </div>
  );
}
