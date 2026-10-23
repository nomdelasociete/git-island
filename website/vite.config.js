import { defineConfig } from "vite";
import { cloudflare } from "@cloudflare/vite-plugin";

export default defineConfig({
  // Read cloudflare.config.ts (as `cf build` does) so dev, preview, and the
  // CI build run the same Worker as production.
  plugins: [cloudflare({ experimental: { newConfig: true } })],
});
