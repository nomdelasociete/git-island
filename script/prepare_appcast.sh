#!/usr/bin/env bash
# Prepare only. Publication still requires release/channel authorization and a PR.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:?Usage: prepare_appcast.sh /path/to/Git-Island-VERSION.dmg VERSION}"
VERSION="${2:?Missing version}"
SPARKLE_BIN="${SPARKLE_BIN:?Set SPARKLE_BIN to the pinned Sparkle bin directory}"
ACCOUNT=com.nomdelasociete.GitIsland
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Invalid version' >&2; exit 2; }
[[ "$(basename "$DMG")" == "Git-Island-$VERSION.dmg" && -f "$DMG" ]] || { echo 'Unexpected DMG filename' >&2; exit 2; }
[[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/sign_update" && -x "$SPARKLE_BIN/generate_keys" ]] || exit 2
# Require a valid notarized distribution artifact before it can be advertised.
spctl --assess --type open --context context:primary-signature "$DMG"
xcrun stapler validate "$DMG"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/git-island-update.XXXXXX")"
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
APP="$MOUNT/Git Island.app"
python3 "$ROOT_DIR/script/verify_update_bundle.py" "$APP" direct
python3 - "$APP/Contents/Info.plist" "$VERSION" <<'PYINFO'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleShortVersionString'] == sys.argv[2], 'DMG version mismatch'
assert info['CFBundleIdentifier'] == 'com.nomdelasociete.GitIsland', 'Wrong app identity'
PYINFO
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP"
# sign_update verifies against the selected Keychain account, not the app key.
# Bind that account to the verified bundle before generating any feed candidate.
SIGNING_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)"
python3 "$ROOT_DIR/script/verify_update_bundle.py" "$APP" direct "$SIGNING_PUBLIC_KEY"
hdiutil detach -quiet "$MOUNT"
rmdir "$MOUNT"
trap - EXIT
OUTPUT="$ROOT_DIR/build/appcast-$VERSION"
[[ ! -e "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 2; }
mkdir -p "$OUTPUT"
cp "$DMG" "$OUTPUT/"
cp "$ROOT_DIR/website/public/appcast.xml" "$OUTPUT/appcast.xml"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/nomdelasociete/git-island/releases/download/v$VERSION/" \
  --link https://gitis.land "$OUTPUT"
python3 "$ROOT_DIR/script/validate_appcast.py" "$OUTPUT/appcast.xml" "$VERSION" "$OUTPUT/$(basename "$DMG")"
SIGNATURE="$(python3 - "$OUTPUT/appcast.xml" "$VERSION" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
for item in ET.parse(sys.argv[1]).findall('./channel/item'):
    if item.findtext('s:shortVersionString', namespaces=ns) == sys.argv[2]:
        print(item.find('enclosure').get('{'+ns['s']+'}edSignature'))
        break
PY
)"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$OUTPUT/$(basename "$DMG")" "$SIGNATURE"
echo "Prepared $OUTPUT/appcast.xml. Nothing has been uploaded or published."
