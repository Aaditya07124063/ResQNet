import { photos, type PhotoEntry, type PhotoId } from "@/content/photos";
import { cn } from "@/lib/utils";

/**
 * A responsive documentary photograph filling its (positioned) parent.
 * Static export has no image optimizer, so the WebP widths are generated
 * ahead of time (public/photos) and picked by the browser via srcset.
 * Only the hero passes `priority`; everything else lazy-loads.
 */
export function Photo({
  id,
  sizes,
  priority = false,
  position = "50% 50%",
  parallax = false,
  className,
}: {
  id: PhotoId;
  /** Defaults to a full-bleed cover: on a portrait screen a landscape photo
   * is drawn wider than the viewport, so ask for width × aspect too. */
  sizes?: string;
  priority?: boolean;
  /** CSS object-position, so the subject survives portrait/landscape crops. */
  position?: string;
  parallax?: boolean;
  className?: string;
}) {
  const photo: PhotoEntry = photos[id];
  const src = (w: number) => `/photos/${id}-${w}.webp`;
  const largest = photo.widths[photo.widths.length - 1];

  return (
    // eslint-disable-next-line @next/next/no-img-element -- static export, pre-sized srcset (see above)
    <img
      src={src(Math.min(1600, largest))}
      srcSet={photo.widths.map((w) => `${src(w)} ${w}w`).join(", ")}
      sizes={sizes ?? `max(100vw, ${Math.round((photo.width / photo.height) * 100)}vh)`}
      alt={photo.alt}
      width={photo.width}
      height={photo.height}
      loading={priority ? "eager" : "lazy"}
      fetchPriority={priority ? "high" : undefined}
      decoding="async"
      style={{ objectPosition: position }}
      className={cn(
        "absolute inset-0 h-full w-full object-cover",
        parallax && "photo-parallax",
        priority && "photo-fade-in",
        className,
      )}
    />
  );
}

/** Place, date and credit for a photo — small, but always present. */
export function PhotoCredit({ id, className }: { id: PhotoId; className?: string }) {
  const photo: PhotoEntry = photos[id];
  return (
    <p className={cn("text-[11px] leading-snug text-white/70", className)}>
      {photo.place}. Photo:{" "}
      <a href={photo.sourceUrl} className="underline-offset-2 hover:underline">
        {photo.credit}
      </a>
      ,{" "}
      {photo.licenseUrl ? (
        <a href={photo.licenseUrl} className="underline-offset-2 hover:underline">
          {photo.license}
        </a>
      ) : (
        photo.license.toLowerCase()
      )}
      .
    </p>
  );
}
