# Git Island website prototype

A local, scroll-driven island → MacBook → interactive Git Island study.
The landscape and screen texture are procedural. Sea assets are Quaternius’s
CC0 rigged whale (with its authored swim animation) and Kenney’s CC0 sailboat.
The MacBook uses Jack Baeten’s CC BY 4.0 model; credits and adaptation notes are
in `public/models/ATTRIBUTION.txt`. Draco decoders are self-hosted.
The inbox contains fictional fixtures and makes no GitHub API requests.

## Run

Requires Node.js 22.12+ (validated with Node.js 24).

```sh
cd website
npm ci
npm run dev
```

The dev server binds to localhost. Build with `npm run build`; preview the build
with `npm run preview`. No signing keys, app credentials, backend, or deployment
account is required. This does not launch the native macOS app.

Scroll through the three camera stages, or use “Take a closer look” and
“Skip to demo”. The inbox supports status filters, collapse, outside click and
Escape. Eight PRs cover all four states; fictional status updates run every 5.5
seconds while the inbox is visible. Pause activity or pause the whole scene
with the provided controls. Reduced motion goes directly to the interactive demo. Without WebGL,
the textual introduction and interactive demo remain available.

The browser UI follows `IslandDesignSystem.swift` and `IslandHostView.swift`: native
colors, 68-point rows, five-row viewport, summary counts, notch-adjacent counters,
segmented outline, hover selection and 280 ms pointer-leave collapse. It uses
web equivalents for system symbols and glass buttons, not a native app capture.
Merge/Confirm operates only on fictional in-memory fixtures, never GitHub. The public site is deployed to https://gitis.land on Cloudflare Workers static assets.

## Design

- Sea mist #dce6e7, deep pine #173835, moss #74866a, stone #68716c,
  silver #b4bfbc, and pale paper #edf2ee.
- Manrope for display, DM Sans for text. Currently loaded from Google Fonts;
  self-host before production if third-party font requests are undesirable.
- One cinematic focal point, with a restrained left-aligned introduction and
  a minimal scroll cue. On mobile, the landscape sits below the copy.
- The camera aligns with the tilted display and fills the viewport before a
  shared wallpaper hands off to HTML. The notch then expands into the inbox;
  reverse scrolling resets this reveal.

Three.js and Vite are MIT licensed; their notices are included in the installed
packages. Manrope and DM Sans are distributed under the SIL Open Font License.
Project code retains the repository's GPL-3.0-only license.

## Validation

Production build, desktop/mobile scroll navigation, all status filters,
collapse/Escape, reverse scrolling, reduced-motion behavior, and narrow-viewport
overflow are checked locally. Further production work should include profiling
on physical mobile devices, browser coverage, asset/font hosting, and deployment.

The decorative menu bar and numbered chapter controls are removed. The sailboat uses a shallow, stable draft, gentle roll, tangent-aligned travel
and water-shader wakes. The whale surfaces every 16 seconds with a timed
droplet splash and expanding water ripples; pause and reduced motion apply.

## Deploy

The pinned `cf` CLI deploys to the NOM DE LA SOCIETE account selected explicitly
in `cloudflare.config.ts`. Authenticate with `cf auth login`, then from `website/`
run `npm ci` and `npm run deploy`. The Vite plugin generates Cloudflare Build
Output; only generated static assets are uploaded. The `gitis.land` custom domain
is managed by the deployment. No runtime bindings or application secrets are used.

Use `npx cf deploy --dry-run` to validate first. To publish that exact build, use
`npx cf deploy --prebuilt --mode production`. Generated `.cloudflare/` and
`.wrangler/` directories are ignored. Unknown paths return 404. Deployment is
manual; repository CI builds the site but does not publish it.

Social sharing uses static Open Graph and Twitter card metadata in `index.html`
and the 1200 × 630 `public/social-preview-v1.png` image, rendered from the actual
website scene with navigation controls hidden. The scene model credits in
`public/models/ATTRIBUTION.txt` also apply to this render. Version the image URL
when replacing it so social crawlers can retrieve the new asset.
