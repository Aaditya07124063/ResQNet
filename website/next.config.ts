import type { NextConfig } from "next";

// Static export: the website ships as plain HTML/CSS/JS with no Node.js
// server, so it can be deployed independently of the ResQNet API (behind
// its own Nginx/static host at resqnet.co) without any server runtime.
// See website/README.md "Deployment" for the intended split with
// api.resqnet.co.
const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  images: {
    // No remote images and no image optimization server exists in a
    // static export — every image in this project is a local SVG/inline
    // asset, so this only disables the (unavailable) optimization step.
    unoptimized: true,
  },
};

export default nextConfig;
