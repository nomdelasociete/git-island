# Git Island

A quiet, native macOS menu-bar app for your GitHub pull requests, right beside
your MacBook’s notch.

Git Island groups your authored PRs and direct review requests into **blocked**,
**waiting**, **testing**, and **ready**. Hover to expand, open a PR on GitHub,
or explicitly confirm a merge. GitHub remains the authority on merge permissions.

Requires **macOS 26 or later**. The island needs a MacBook with a notch;
other displays do not show it. The menu-bar controls remain available.

## Install

Download the signed, Apple-notarized [Git Island 0.16 installer](https://github.com/nomdelasociete/git-island/releases/download/v0.16/Git-Island-0.16.dmg),
open it and drag Git Island to Applications. This edition checks for and downloads
signed updates automatically, installs them when the app quits, and offers a restart
if it stays open. Configure updates in General settings or use **Check for Updates…**
in the menu.

Or install with Homebrew:

```sh
brew install --cask nomdelasociete/tap/git-island
```

Update with `brew update && brew upgrade --cask --greedy nomdelasociete/tap/git-island`.
Homebrew does not install updates in the background by default.

Existing 0.15 and older installations need one manual upgrade to 0.16 to receive
automatic updates through Sparkle. TestFlight continues to manage its own updates.

## Build from source

Install Xcode 26 or later (Swift 6.2+) and
[XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0).
Select the full Xcode installation as your developer directory.

Compile and test without an Apple team, signing credentials, GitHub token,
or relay account:

```sh
xcodegen generate --spec project.yml
xcodebuild -project GitIsland.xcodeproj -scheme GitIsland \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
swift test --skip RelayLiveAcceptanceTests
```

The Xcode scheme currently builds the app; SwiftPM runs the unit tests.
CI selects Xcode 26.2 on macOS 26. Local validation has also used Xcode 27.1.

For a local ad-hoc signed Debug bundle, use `./script/build_and_run.sh build`.
To launch intentionally, use `./script/build_and_run.sh run`, or configure your
own team in Xcode and run the Debug scheme. Debug is **Git Island Dev**, with
separate preferences and Keychain identity from the release app. Do not change
it to the production bundle ID. UI checks require real notched hardware.

## Connect GitHub

Sign in using GitHub’s device flow. The OAuth client ID is public; no client
secret belongs in the app. The grant requests `read:user repo`: **broad repository
access, including private repositories and write capabilities**. The app uses
writes for actions you explicitly choose, such as merging or updating a branch.
A typed allowlist in Settings limits search queries. Muting a repository or hiding a pull request only filters the inbox on this Mac. Neither changes the token’s permissions.

For development, `GITHUB_TOKEN`, `GH_TOKEN`, and `GITHUB_OAUTH_CLIENT_ID` are
Debug-only settings. Tokens are fallbacks when no stored credential exists. Use your own test account and credentials; never put them
in source, fixtures, issues, or PRs. Sign-out suppresses environment credentials across restarts; it cannot erase them from the parent process.
Fork publishers should register their own OAuth app with device flow enabled.

## Updates and privacy

Periodic refresh works without a hosted-service account. Optional live updates
use a separate hosted authority, browser authorization service, and relay to
trigger fresh GitHub reads. Live access is an additional authorization; signing
out of GitHub does not revoke it. The hosted implementation is not included here.

See [PRIVACY.md](PRIVACY.md) for current data flows, storage, and removal limits.
Hosted-service readiness is still in progress. The direct-download app works
with periodic GitHub refreshes; this repository does not promise a public relay service.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md). Substantial changes begin with an
issue; small fixes can go straight to a PR. Use synthetic data in tests and
screenshots. Read the [product principles](docs/MANIFESTO.md) and relevant
[engineering guidance](AGENTS.md).

Report vulnerabilities privately using [SECURITY.md](SECURITY.md).
Participants follow the [code of conduct](CODE_OF_CONDUCT.md).

## License

Git Island’s original code and documentation are licensed under **GPL-3.0-only**
(the GNU General Public License, version 3). See [LICENSE](LICENSE) and [AUTHORS.md](AUTHORS.md) for attribution.
Third-party assets retain their own licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The license does not grant rights to imply that a fork is an official release.
Use distinct app, signing, OAuth, and service identities when publishing a fork.
Official Apple distribution remains subject to a separate license/terms review;
adding this license does not clear that release gate.
