# Git Island data handling

This describes the native client. It is not a claim that the optional hosted
service has completed a production privacy review.

## GitHub

The app sends authenticated requests to GitHub to read your profile, pull requests,
reviews, and checks, including the repository metadata on those pull requests.
It does not download the account's repository membership list. Explicit merge
and branch-update actions send writes to GitHub. The OAuth scope is `read:user repo`,
including broad private-repository and write access. A typed repository allowlist
limits search queries. Muting a repository or hiding a pull request filters the
inbox on this Mac and does not narrow the token's permissions. Profile images
are requested from GitHub when shown in Settings.

Tokens are stored in macOS Keychain with device-only accessibility on new writes.
Debug builds can use environment tokens only when no stored credential exists;
Release ignores these overrides. An explicit sign-out suppresses environment
credentials, including after restart. Legacy plaintext migration must both save
to Keychain and delete the source file before authentication proceeds. Failures
are reported in Settings. Debug uses its own legacy directory and does not
read or delete the Release application's legacy file. PR data and account caches are held in
memory. UserDefaults stores preferences, the typed repository allowlist, muted
repository names, and hidden pull-request records (id, group, head SHA, reason,
repository name, and number). Hidden records do not include titles or review text.

## Optional live updates

Without device enrollment, periodic GitHub reads remain available. Enrollment
uses `access.relay.nomdelasociete.com` and a browser at
`auth.relay.nomdelasociete.com`; the default stream is
`relay.nomdelasociete.com`. The native GitHub token is sent to GitHub, not the
relay. The authority verifies the linked GitHub identity using a separate device
access token. Device access/refresh credentials and installation IDs are stored
in a separate Keychain item.

The service can observe connection metadata such as IP addresses and device
identity. Server logging, retention, subprocessors, and deletion guarantees still
require operator verification; no “zero data collection” claim is made here.
The client accepts only the official relay origin for device credentials.
Custom relay hosting is not supported by this build. Authenticated GitHub and
relay sessions reject redirects; GitHub requests use ephemeral, uncached sessions.

Wake hooks are optional. Their URL is saved in preferences; their secret is
shown on creation. Forgetting the URL locally does not revoke the remote hook.

## Local data and support

Appearance/sound settings persist locally. Imported sound files are copied into
Application Support. Debug and Release use distinct app identities. There is no
automatic analytics upload in the client. Copied refresh diagnostics omit free-form error messages and request breakdowns.
Inspect any support material before sharing. Use
invented PRs in screenshots and bug reports.

## Sign-out, revocation, and removal

Sign-out clears the displayed inbox, the repository allowlist, muted repositories,
hidden pull requests, and attempts to
remove the GitHub token. It cannot erase a token from the process environment, but stops using it.
The sign-out decision is saved before deletion; retained tokens cannot silently
restore authentication. Failed cleanup is shown in Settings with a retry action
and is retried during credential restoration.
For remote GitHub revocation, remove the authorization in GitHub’s application
settings; local sign-out does not revoke the OAuth grant remotely.

Live device authorization is retained on GitHub sign-out. Revoke it separately
in Settings; offline revocation may remain pending until reconnection. After confirmed revocation (or an already-invalid credential response), the
client removes legacy relay credentials and replaces its saved pair with a
non-secret enrollment-required record. Failed cleanup retains retry material
in Keychain and blocks streaming until cleanup succeeds.
Revoke wake hooks separately. Preferences and imported sounds survive sign-out.
Uninstalling the app is not a guarantee that Keychain items or server records
are removed. Contact **contact@nomdelasociete.com** about hosted-service data
removal or privacy questions.

A complete local reset flow and a verified server retention/deletion policy
remain release-preparation tasks. The bundled PrivacyInfo.xcprivacy declares
UserDefaults access for the app's own preferences (CA92.1). It does not assert
that the hosted service collects no data, replace App Store privacy disclosures,
or establish distribution compliance.
