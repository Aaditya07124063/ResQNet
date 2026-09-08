import { ImageResponse } from "next/og";
import { siteConfig } from "@/content/site";

// Required for `output: "export"` — this image has no request-time data.
export const dynamic = "force-static";
export const alt = `${siteConfig.name} — ${siteConfig.tagline}`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// Generated at build time (static export compatible) — no external image
// asset exists to use instead (see Logo.tsx's doc comment).
export default function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "80px",
          background: "#0b1220",
          color: "white",
          fontFamily: "sans-serif",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
          <div
            style={{
              width: 64,
              height: 64,
              borderRadius: 18,
              background: "#0f6e66",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: 34,
              fontWeight: 700,
            }}
          >
            R
          </div>
          <div style={{ fontSize: 44, fontWeight: 700 }}>{siteConfig.name}</div>
        </div>
        <div style={{ marginTop: 48, fontSize: 56, fontWeight: 700, maxWidth: 900 }}>
          {siteConfig.tagline}
        </div>
        <div style={{ marginTop: 24, fontSize: 26, color: "rgba(255,255,255,0.7)", maxWidth: 820 }}>
          {siteConfig.description}
        </div>
      </div>
    ),
    { ...size },
  );
}
