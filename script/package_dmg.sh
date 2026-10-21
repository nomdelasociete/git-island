#!/bin/bash
# Package an existing app; never builds, signs, uploads, or launches it.
set -euo pipefail
preview=false
if [[ "${1:-}" == "--preview" ]]; then preview=true; shift; fi
if [[ $# -ne 2 ]]; then
  echo "Usage: DMG_PYTHON=/path/to/python $0 [--preview] /path/to/App.app /path/to/output.dmg" >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
python="${DMG_PYTHON:-python3}"
[[ -d "$app/Contents" && "$app" == *.app ]] || { echo "Expected an app bundle" >&2; exit 2; }
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 2; }
"$python" -c 'import ds_store, mac_alias'
volume_name="Git Island"
if $preview; then
  [[ "$output" == *[Pp]review* ]] || { echo "Preview filename must contain preview" >&2; exit 2; }
  volume_name="Git Island — Installer Preview"
else
  codesign --verify --deep --strict "$app"
  spctl --assess --type execute "$app"
  xcrun stapler validate "$app"
fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/git-island-dmg.XXXXXX")"
mount="$stage/mounted"
attached=false
cleanup() {
  if $attached; then
    hdiutil detach "$mount" -quiet || { echo "Could not detach $mount; preserving temporary files" >&2; return; }
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
mkdir -p "$stage/contents/.background" "$mount"
ditto "$app" "$stage/contents/$(basename "$app")"
ln -s /Applications "$stage/contents/Applications"
cp "$root/packaging/dmg-background.png" "$stage/contents/.background/installer.png"
cp "$root/LICENSE" "$stage/contents/.background/LICENSE"
cp "$root/THIRD_PARTY_NOTICES.md" "$stage/contents/.background/THIRD_PARTY_NOTICES.md"
hdiutil create -quiet -volname "$volume_name" -srcfolder "$stage/contents" -format UDRW "$stage/layout.dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$mount" "$stage/layout.dmg"
attached=true
"$python" "$root/script/dmg_layout.py" "$mount" "$(basename "$app")"
hdiutil detach -quiet "$mount"
attached=false
hdiutil convert -quiet "$stage/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$output"
echo "Created $output"
if $preview; then echo "LOCAL DESIGN PREVIEW ONLY — unsigned development app; not for distribution."; fi
