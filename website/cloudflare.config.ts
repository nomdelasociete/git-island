import { defineConfig } from "cf/config";

export default defineConfig({
  accountId: "0a0c8c3111c01831f0604c9ad662706b",
  worker: {
    name: "git-island-website",
    compatibilityDate: "2026-10-19",
    domains: ["gitis.land"],
    // Only the og:video file runs the Worker first, so it can answer Range
    // requests; everything else stays a free static asset.
    entrypoint: "./worker/index.js",
    env: { ASSETS: { type: "assets" } },
    assets: {
      notFoundHandling: "none",
      runWorkerFirst: ["/social-video-v1.mp4"],
    },
    observability: { enabled: false },
  },
});
