# Git Island implementation status

## What has been built

- Debug builds use Git Island Dev (com.nomdelasociete.GitIsland.dev), with
  separate preferences and Keychain identity. Release keeps the TestFlight
  identity. The local build script only accepts Debug and defaults to ad-hoc
  signing. TestFlight 0.12 (202610100026) was verified running from Applications
  with Apple's TestFlight signature on 2026-10-18.

- The island window passes mouse events through while compact and outside its
  visible expanded surface. Independent pointer tracking preserves hover, and
  routing changes never resize the expanded host. AppKit regression tests cover
  compact input, leaving/re-entering the expanded surface, and collapse.
  The user verified adjacent menu-bar clicks in both compact and expanded
  states on their Mac on 2026-10-18.

- Guided onboarding uses the current logo, explains GitHub permissions, verifies
  an actual inbox read, and reports the live relay connection separately. Live
  enrollment is optional; periodic refresh remains available. Initial outline,
  animation, sound, and launch-at-login settings apply to the real app. Completed
  onboarding is remembered; GitHub 401 responses reopen connection recovery
  without resetting preferences. Temporary network errors do not reopen it.
  Compile and unit validation completed; visual validation on notched hardware
  remains pending. Existing line settings are retained; choosing Halo is explicit.

- Native macOS app with an AppKit borderless panel anchored to the real MacBook
  notch area.
- The panel is only shown on displays that expose macOS auxiliary notch screen
  areas, so external displays without a notch are ignored.
- Compact island is the notch only, with a single status outline around it
  (keeps the menu bar free for macOS 27 status items). Each status owns a
  share of the outline proportional to its PR count:
  - amber `waiting`
  - blue `testing`
  - red `blocked`
  - green `ready`
- Hover opens the island Dynamic Island–style (widen then drop; rise then
  narrow on close). Status counters appear in the wings only while opened, and
  the outline stays visible and morphs with the surface.
- Status changes animate on the outline: boundaries spring to the new
  proportions and a sheen runs from the old status segment to the new one.
  Crazy mode adds waves of the status color radiating from the outline.
- Opened state shows minimal actionable PR rows and clicking a row opens the PR
  on GitHub.
- GitHub data is real, using the authenticated local account through
  Git Island OAuth, `GITHUB_TOKEN`, or `GH_TOKEN`.
- The inbox is fetched with one batch GraphQL request (aliased searches with the
  same scope as the REST queries). It falls back to the per-PR REST path when
  GraphQL errors, a search or a PR's check contexts exceed one page, or the
  repository filter needs more than 8 searches. The query costs about 4
  rate-limit points (rollup contexts instead of nested check suites).
- GitHub PR inbox buckets are approximated by two broad candidate search queries
  followed by classification from PR details, GitHub GraphQL merge/review
  readiness, reviews, check runs, and commit statuses:
  - `blocked`: authored open drafts, merge conflicts, requested changes, failing checks, or GitHub-blocked PRs
  - `waiting`: authored open PRs where GitHub reports `REVIEW_REQUIRED`, plus directly review-requested PRs that only need your review
  - `testing`: authored open PRs with pending checks
  - `ready`: authored open PRs or directly review-requested PRs that GitHub reports as green, including repos where review is not required; a branch that is only behind the base branch stays ready and shows an update action
- Relay v2 client supports browser device enrollment, a computer identity distinct
  from its linked GitHub installations, automatic access-token rotation, and
  revocation. Access and refresh tokens share one device-only Keychain item;
  a persisted request ID resumes a rotation after a lost response or restart.
  Pending revocations also survive restart and retry without renewing access. SSE expiration/401 renews access without directly
  refreshing GitHub. Legacy v1 credentials remain untouched in their separate Keychain item and are
  no longer used after successful v2 enrollment; 404/503 setup responses preserve the existing connection. The authority and browser origins are fixed deployment trust anchors, separate
  from the configurable relay origin; mutable preferences cannot redirect enrollment or refresh credentials. Public
  enrollment still requires the relay authorization service to be available.
- Optional relay SSE wakes use a per-computer token stored separately in Keychain.
  A validated event stream refreshes GitHub on connection and wake, coalesces
  in-flight demand, and respects GitHub rate-limit deadlines. Connected streams
  suspend polling; disconnected configured streams poll every 60 seconds.
  Refresh settings configure the relay origin and browser authorization, and create or revoke a wake hook. The legacy token remains in its separate Keychain item, unused after v2 enrollment.
  OAuth sign-out preserves the computer token. Relay never receives OAuth tokens.
- Without relay configuration, the app uses adaptive local-only refresh: prompt event-driven refreshes, capped
  by a short minimum spacing, on app focus, island interaction, system wake,
  network return, and merge actions; temporary 20-30s bursts while activity is
  fresh or checks are running; then fallback to the saved idle interval. Manual
  refresh restarts an in-flight GitHub fetch so a slow request does not make the
  control feel dead.
- **2026-07-03**: Work on Epic #43 completed on jb/refresh-freshness-epic (slices 1-4 + diagnostics + GraphQL query expansion + richer tracking).
  ETags + caching (304s for stable), parallel + paginated searches, 15s cadence for testing, expanded GraphQL per-PR for future reviews data, richer diagnostics with candidates/304/breakdown.
  Builds clean. See docs/refresh-improvement-epic.md and GitHub #43.
  Current description below reflects pre-epic for context.
- Settings expose refresh diagnostics: in-flight state, reason, last
  start/finish, duration, next scheduled refresh, last message, and copyable
  debug text.
- Settings scopes the inbox to every authored and review-requested pull
  request, or to a typed list of `owner/repository` names. Selected mode adds
  `repo:` qualifiers to GitHub search. All mode keeps that search unscoped.
  Right-click a pull request to hide it until its group, head SHA, or reason
  changes, or to mute its repository. Muted repositories are dropped after
  fetch. Settings lists the typed allowlist, muted repositories, and hidden
  pull requests.
- Settings is a sidebar window (General, Appearance, Sounds, Refresh,
  Repositories). Appearance and onboarding share Lines (the existing default), Halo, and Minimal. Halo
  has persisted strength and transparency sliders; Lines retains width, spacing,
  and lane-limit controls. The live preview includes one of each status, single
  colors, unequal counts, and an empty inbox. Halo and Minimal show proportions,
  while Lines also encodes volume. Native notched-hardware validation of the halo
  remains pending.
- General settings offer opt-in launch at login using macOS login item
  registration, with system approval guidance and registration error feedback.
- Per-event sounds (new PR, ready, blocked, waiting, checks running, merged):
  none, a macOS system sound, or an imported file copied into Application
  Support. One refresh plays only its most important event.
- The expanded PR list follows the outline's color order (ready, blocked,
  waiting, testing), oldest first within each status.
- A project-local `script/build_and_run.sh` builds, stages, and launches the app
  as a `.app` bundle.
- A project-local `script/testflight.sh` can archive and upload to App Store
  Connect using automatic signing.
- A generated `GitIsland.xcodeproj` provides a native Xcode macOS app target for
  development builds and local signing.
- First-run onboarding with welcome, permissions, and GitHub device flow sign-in.
- Keychain token storage with sign-out from Settings.
- Expanded island shows PR titles, up to five scrollable rows, and inline
  loading/error states.
- SwiftPM regression tests cover the known GitHub PR classification states.

## What is intentionally not done yet
- No membership repository browser. The app does not list every repository
  the account can access. Exclusion is mute-by-repository and hide-by-pull-request.
- No exact private GitHub PR Inbox API integration. GitHub does not expose this
  new inbox surface as a stable public API, so the current behavior mirrors it
  through documented search qualifiers.
- Repository allowlist, muted repositories, and hidden pull-request signatures
  are persisted in UserDefaults. Visible-group selection is transient. Sign-out
  clears the allowlist, mutes, and hidden pull requests.
- Idle auto-refresh interval preference is saved in UserDefaults.
- Updates are manual for direct downloads; TestFlight is a separate distribution
  channel. No Sparkle updater is included.
- Second design pass: true notch gap, wing tabs, list-style rows, calmer motion.
- Further shape tuning may still be needed against specific MacBook notch sizes.

## Known product/design gaps

- The four status buckets are intentionally compressed. GitHub's full PR page
  also has separate buckets such as review requests and drafts.
- GitHub search is used only to find candidate PRs. Displayed bucket labels are
  based on verified PR details, GitHub `reviewDecision` / `mergeStateStatus`,
  reviews, check runs, and commit statuses.
- A PR with no required review and no active check/status contexts is shown as
  ready when GitHub reports it mergeable; otherwise it stays waiting.
- Long PR titles truncate to one line; full title is available on hover tooltip.

### Live access account binding (pending release)

Relay pairing, restored credentials and renewed access require the authority’s authenticated computer subject to match the native token’s `/user` ID. Account switches and late identity responses cannot re-enable a previous session. Legacy unbound stream tokens fail closed; periodic GitHub reads remain available. Requires the authority `/computers/identity` endpoint before client rollout. Verified with session regression tests and compile-only Xcode builds; real two-account GitHub testing is still pending.

### Open-source repository preparation

The repository starts with a clean source snapshot. Original development credit
is recorded in AUTHORS.md; GPL-3.0-only and third-party notices are preserved.
Private development history, discussions, review links and audit evidence are
not included.

The snapshot includes credential-free CI, synthetic test identities, issue/PR
templates, security reporting, privacy disclosures, and a bundled UserDefaults
privacy manifest. The source revision passed 113 ordinary SwiftPM tests and
unsigned Debug and Release builds. Its Xcode 26.2 hosted CI passed; this new
repository runs its own independent CI.

Credential read retries preserve valid credentials. Explicit sign-out persists
before deletion, exposes cleanup failures, and suppresses environment tokens.
Environment credentials are Debug-only. Relay credentials are restricted to the
official origin, and cleanup is retried after revocation or rejected refresh.
Authenticated GitHub traffic rejects redirects and unexpected destinations;
copied diagnostics omit free-form private text.

Remaining release work includes hosted-service security/retention verification,
authorized live acceptance, artwork provenance, Apple distribution review,
signed release validation, and real notched-hardware checks. Repository
visibility and branch-protection enforcement are separate publication decisions.

### Website transition prototype

`website/` contains an isolated Vite/Three.js prototype for gitis.land: a
scroll-driven procedural island with credited CC0 boat models and a rigged whale,
a credited CC BY MacBook Pro model, and an HTML Git Island inbox with eight
fictional PRs and pausable status updates. The browser island now follows native
source layout, colors, row metrics, outline and hover behavior. The page uses the official app logo. It includes scroll navigation, mobile layouts,
reduced-motion handling, and a WebGL fallback. The production web build and
local browser interaction checks pass. This prototype is now deployed as the public website described below. It does
not modify or launch the native app. See website/README.md for local use.

### Direct-download onboarding design (local preview)

The native first-launch flow uses the website’s sea and pine palette, official
logo, and credited island artwork. Welcome, permission disclosure, GitHub device
sign-in, inbox verification, and appearance setup share a wider native shell.
Authorization behavior is preserved, and transitions respect Reduce Motion.

`packaging/` and `script/package_dmg.sh` provide matching Retina installer artwork
and a Finder drag-to-Applications layout. The release path verifies signing,
Gatekeeper assessment, and the app’s stapled ticket; packaging does not sign or
notarize the resulting DMG. A separately labeled unsigned Debug preview was built
locally. Compile-only Xcode validation and all 113 ordinary SwiftPM tests pass.
The shared welcome components were rendered for design inspection; full native
runtime, Finder layout, and quarantined signed-download validation remain pending.
This was an unpublished local preview; version 0.13 distribution is recorded below.

Onboarding dismissal now uses a normal window with an always-enabled Set up later
action, Escape and Command-W. Closing cancels pending view sign-in work and
suppresses automatic authorization-recovery reopening for the current session;
manual setup from the menu remains available. The app, website, favicon, onboarding
and installer share a new sea-and-pine island icon; the menu bar uses a simplified
monochrome island silhouette. The new raster icon was generated with the built-in
image tool (miniature low-poly island, three pines, pale sea, moss land; edited to remove the invented black pill and colored dots,
with no lettering, interface elements or computer). Native close-control interaction
validation remains pending because the UI automation service timed out.

### Public website deployment

The merged website is deployed at https://gitis.land using Cloudflare Workers
static assets in NOM DE LA SOCIETE. Versioned cf CLI/Vite tooling, explicit account
and custom-domain configuration, and repeatable deployment instructions are in
`website/`. HTTPS and static asset delivery are verified. The download button links to the signed GitHub release installer; source-build
instructions remain available.

### Version 0.13 distribution

Version 0.13 (202610230001) packages the new branding/onboarding and PR hiding /
repository muting changes. The direct-download app and DMG are signed by NOM DE
LA SOCIETE, notarized by Apple, stapled, and accepted by Gatekeeper. The website
links to the versioned GitHub release asset. Direct-download updates are manual.
The same archive is exported separately for TestFlight, with build-specific
What to Test notes for the existing internal group.

All 116 ordinary SwiftPM tests, the Release archive, both signed exports, and
the website production build pass. The download link is checked in desktop and
mobile browser layouts. Native onboarding/hover checks on notched hardware and
two-account relay acceptance remain pending; distribution is not evidence of
those runtime checks. No production app was launched or replaced during release.

### Installation guide and Homebrew

The site navigation links directly to the installation section, with DMG
drag-to-Applications instructions and the official `nomdelasociete/tap/git-island`
Homebrew cask. Homebrew updates require `brew update` and `brew upgrade`; no
background updater is included. The cask uses the immutable release DMG URL and
verified SHA-256. Future releases must bump its version and checksum in the tap.

The cask passes Homebrew style and online audit, and installs successfully into
an isolated application directory. The installed app passes Gatekeeper; it was
not launched, and the temporary installation was removed after verification.

### Version 0.14 distribution

Halo and Minimal are additional notch styles; Lines remains the default and
preserves existing lane preferences. Settings and onboarding share appearance
controls, including continuous Halo strength and transparency sliders and inbox
preview scenarios.

All 116 ordinary SwiftPM tests, Debug build, Release archive, both signed exports,
and website production build pass. Native onboarding welcome, permissions, sign-in
entry, appearance choices, slider extremes, and completion were checked on the
notched Mac. The OAuth authorization flow was not repeated. Exhaustive hover
transitions with unequal group sizes remain unverified. The direct app and DMG
are notarized, stapled, and accepted by Gatekeeper.

TestFlight 0.14 (202610260001) is valid and in internal beta testing, with
build-specific What to Test notes read back and verified. The signed DMG is
published at the v0.14 GitHub release; its downloaded SHA-256 matches the release
artifact and Gatekeeper accepts it. Website and Homebrew updates remain in their
reviewed PR workflows. App Store export uses the existing Frontline API profile,
as for 0.13; RonssinCI lacks the required cloud-signing permissions.


## Prepared server inbox synchronization

The optional server inbox path reads Relay snapshots after a separate browser
OAuth grant. Merge and branch-update writes remain native. Local repository
filters apply to the received inbox, not to server reads. Old clients and users
who have not opted in keep their previous local-read behavior. Relay handles
per-user coalescing, targeted webhook invalidations, reconciliation for uncovered
repositories, and persistent provider backoff. Native GraphQL rate-limit errors
no longer trigger REST fallback.

Relay PR #25 (`c8aa67a`) was deployed to all five production Workers on
26 October 2026, preserving existing keys and domains. The separate Git Island
Inbox Sync OAuth App is configured. Public health and authentication checks pass.
A real browser authorization and temporary device session verified matching
numeric identity, snapshot delivery, four concurrent reads sharing one cached
revision, the inbox SSE handshake, and explicit refresh. Cleanup deleted the
server inbox grant/cache and revoked the temporary device; subsequent requests
returned 428 and 401 respectively. Deleting the server grant does not revoke the
OAuth authorization at GitHub.

The native client remains in PR #15 and is not distributed. Its 120 ordinary
Swift tests and compile-only macOS build pass on the updated branch. Full native
UI acceptance, webhook-to-display latency, multiple real Macs/accounts, SSO and
naturally elapsed OAuth renewal remain unverified. The concurrent-read check
establishes shared snapshot responses, not a measured GitHub API call count.
No app launch or distribution is part of this work.
