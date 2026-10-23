# Git Island website prototype

A local, scroll-driven island → MacBook → interactive Git Island study.
The landscape and screen texture are procedural. Sea assets are Quaternius’s
CC0 rigged whale (with its authored swim animation) and Kenney’s CC0 sailboat.
The MacBook uses Jack Baeten’s CC BY 4.0 model; credits and adaptation notes are
in `public/models/ATTRIBUTION.txt`. Draco decoders are self-hosted.
The inbox contains fictional fixtures and makes no GitHub API requests.

## Run

Requires Node.js 22.18+ (validated with Node.js 24).

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

The only production publication path is a PR merged into `main`, followed by
successful CI and the `deploy-website` job. Follow the publication authority rules
in [AGENTS.md](../AGENTS.md#publication-authority-mandatory). Agents leave PRs open
unless the user explicitly requests their merge. Direct Cloudflare deployment
and rollback from local tools, APIs, or the dashboard are prohibited.

For local validation, use `npm ci`, `npm run build`, and `npm run preview`.
The `deploy` package script is reserved for the CI production job. The scoped
`CLOUDFLARE_API_TOKEN` is exposed only to that job, never to pull-request builds.
CI selects the NOM DE LA SOCIETE account configured in `cloudflare.config.ts`.

The Vite plugin generates Cloudflare Build Output: static assets and
`worker/index.js`, which handles og:video Range requests. The Worker's only
binding is `ASSETS`; no application secrets are used. The compatibility date
must stay within the locally installed workerd's supported range. Generated
`.cloudflare/` and `.wrangler/` directories are ignored; unknown paths return 404.

The production environment accepts only `main`. Runs compare against the last
successful `website-production` deployment, preserving changes across failed or
queued runs. App-only changes skip website publishing. A website deployment
does not publish a DMG, TestFlight build, or Homebrew cask.

Social sharing uses static Open Graph and Twitter card metadata in `index.html`
and the 1200 × 630 `public/social-preview-v2.png` image, rendered from the actual
website scene with navigation controls hidden. The scene model credits in
`public/models/ATTRIBUTION.txt` also apply to this render. Version the image URL
when replacing it so social crawlers can retrieve the new asset.

`og:video` points to `public/social-video-v1.mp4`, a 6-second silent loop
(1200 × 630, H.264) for previews that play video inline, such as Discord;
everywhere else the image stays the card. The card is the Mac's screen: the
island scene, without the MacBook, is the wallpaper and Git Island opens, turns
a pull request green, and closes at its real size. `npm run capture:video`
renders it: `?capture` stops the page clock and the script steps every frame,
CSS transitions included, then dissolves the tail into the opening with ffmpeg.
It needs Google Chrome and ffmpeg with libx264. Write a new `-vN` file and
update both `og:video` URLs and `runWorkerFirst` in `cloudflare.config.ts` when
the scene changes. Static assets answer Range requests with the whole file,
which Apple's video stack (iMessage previews, Safari) refuses, so that path runs
the Worker first and gets `206 Partial Content` responses. Every other request
is a free static asset; requests that match no asset reach the Worker, which
returns the same 404.
