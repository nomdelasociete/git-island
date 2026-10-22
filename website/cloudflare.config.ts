import { defineConfig } from "cf/config";

export default defineConfig({
  accountId: "0a0c8c3111c01831f0604c9ad662706b",
  worker: {
    name: "git-island-website",
    compatibilityDate: "2026-10-22",
    domains: ["gitis.land"],
    assets: { notFoundHandling: "none" },
    observability: { enabled: false },
  },
});
