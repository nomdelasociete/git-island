# Contributing to Git Island

Bug reports, ideas, documentation, and focused fixes are welcome.

## Agree on substantial changes first

Open an issue describing the problem and proposed behavior before building a
feature or changing the architecture. Typos and obvious small fixes can go
directly to a PR. Keep each PR focused on one change.

Read the [product principles](docs/MANIFESTO.md) and the relevant parts of
[AGENTS.md](AGENTS.md), especially the notch geometry and interaction invariants.

## Build and validate

Fork and branch from current `main`. Follow the credential-free build and test
commands in [README.md](README.md). No Apple team, production token, or relay
access is needed to compile or run ordinary tests. Never use a production
account to supply test fixtures.

Run `swift test --skip RelayLiveAcceptanceTests` and the unsigned Xcode build.
Regenerate the project with XcodeGen 2.46.0 when changing `project.yml` or file
layout; commit the generated project too. Do not treat an Xcode build as a test
run: tests currently live in SwiftPM.

For UI changes, validate on a notched Mac: expand/collapse, blocked ↔ testing
with unequal list heights, top anchoring, and click-through below the compact
island. Check Reduce Motion. State clearly when hardware validation is pending.
Do not launch another app copy inadvertently.

For auth or relay changes, cover account isolation, cancellation, credential
destinations, and failure/restart behavior. The live acceptance test is opt-in,
and never belongs in public PR CI with credentials. It requires both
`RELAY_LIVE_VALIDATION_DIR` (a private output directory) and
`RELAY_LIVE_GITHUB_TOKEN` (a dedicated, authorized test-account token). The test
writes a browser approval URL in a private per-run directory. It uses an isolated
Keychain account and attempts revocation after failures. If cleanup cannot finish,
it retains the retry credential in Keychain and writes a non-secret
`recovery-account` pointer; an operator must finish revocation before removing it.
Do not treat an ordinary unit-test pass as live-service acceptance.

Release uploads require explicit `TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
and `ASC_KEY_PATH`. Archiving requires Release and an explicit team. Never commit
the signing key or supply release credentials to pull-request jobs.

Match surrounding Swift style. Add tests for changed behavior where useful;
avoid unrelated refactors. Keep README and behavior documentation accurate.

## Official publications

This policy governs the project's official website, GitHub releases, Homebrew
tap, and TestFlight distribution. It does not restrict independent builds or
fork distributions permitted by the project's license.

Contributions are submitted as pull requests. Maintainers decide when to merge
after the required reviews and CI checks pass; direct pushes to `main` and
bypassing those checks are not part of the publication workflow.

The website deploys exclusively through CI after a PR merges into `main`.
Direct Cloudflare deployments, uploads, and rollbacks are prohibited. Website
rollbacks follow the same reviewed PR and CI path. Local builds and previews
are available for development without production access.

Official Homebrew, DMG, and TestFlight releases are separate maintainer decisions.
Each release and distribution channel requires explicit maintainer authorization,
including binary uploads, draft releases, asset replacements, and tester
distribution. A website merge does not authorize an app release. Homebrew cask
changes require a PR in the [official tap](https://github.com/nomdelasociete/homebrew-tap).
Access to signing credentials or deployment tools does not grant release authority.

Before publication, reconcile the intended revision with the current production
revision and pending deployments to avoid replacing newer or unmerged work.
Verify the deployed assets or distributed artifact before announcing availability.

## Preparing direct-distribution updates

Use the **GitIslandDirect** scheme for Developer ID archives/DMGs. Use the
existing **GitIsland** scheme for TestFlight; it deliberately does not link
Sparkle or include its sandbox exceptions. Archive each scheme separately, even
when version and build numbers match. Keep `CFBundleVersion` increasing; Settings
reads both version fields from the built Info.plist.

The direct Release configuration enables Sparkle's installer service, automatic
checks/downloads and archive signature verification. Its public key is committed
in project.yml. The matching private key lives only in the release operator's
login Keychain under Sparkle account `com.nomdelasociete.GitIsland`. Preserve a
secure backup through the normal signing-key process; never commit or log it.
Use the pinned Sparkle 2.10.1 tools from the resolved package artifacts.

After exporting, notarizing and stapling the Developer ID app and DMG, prepare
the feed locally:

```sh
SPARKLE_BIN=/path/to/Sparkle/bin ./script/prepare_appcast.sh /path/to/Git-Island-VERSION.dmg VERSION
```

The helper validates the artifact and signature, generates a candidate feed in
`build/appcast-VERSION/`, and publishes nothing. Inspect the generated version,
minimum OS, signature and download URL. After explicit release/channel approval,
publish the exact DMG to the GitHub release and verify its downloaded checksum.
Copy the candidate appcast to `website/public/appcast.xml` in a PR only after
that asset is available. Merge/deploy the feed through the existing website CI
policy. Never advertise an unpublished artifact or reuse a published build number.
The initial empty feed is intentional until the first authorized Sparkle release.

Before shipping the updater, test a real signed/notarized old-to-new installation
on a Mac, including automatic download, restart, preserved credentials/settings,
no-update/offline behavior and rejected tampered archives. An unsigned build or
unit-test run does not establish end-to-end update acceptance. For Homebrew's
first updater-enabled release, set the cask's `auto_updates true` in its version
PR so Homebrew knows the app manages its own updates.

## Privacy and security

Use invented people, repositories, titles, addresses, and keys in fixtures and
screenshots. Never paste raw credentials or private inbox data into an issue,
PR, diagnostic dump, or Actions log. New data flows must be documented and
explained to the user; do not introduce telemetry without an explicit product
and privacy decision.

Vulnerabilities go through [SECURITY.md](SECURITY.md), not public issues.

## Submit

Explain the problem, resulting behavior, related issue, and validation performed.
Mention remaining runtime checks. Reviewers may request a narrower change to
preserve the app’s small scope and calm interaction model.

## Contribution license

By submitting a contribution, you agree to license your original contribution
under GPL-3.0-only and confirm you have the right to do so. Identify third-party
material and preserve its notices; do not submit incompatible material. No
copyright assignment or separate CLA is required by this project.

Everyone participating follows [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
