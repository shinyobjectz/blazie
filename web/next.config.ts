import type { NextConfig } from "next";

/**
 * Static export, so Cloudflare needs no adapter and no Node compatibility
 * flags. The lander is static and the dashboard is a client-side app talking
 * to a blazie cluster's own HTTP API — there is no server here to render on.
 *
 * If server rendering is ever needed, the route is `@opennextjs/cloudflare`
 * (OpenNext) on Workers rather than the older edge-only `next-on-pages`.
 */
const nextConfig: NextConfig = {
  output: "export",
  // No image optimiser on a static host. The mark is pixel art anyway and
  // must never be resampled.
  images: { unoptimized: true },
  trailingSlash: true,
};

export default nextConfig;
