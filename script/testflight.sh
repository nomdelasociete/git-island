#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-check}"
PROJECT_NAME="GitIsland.xcodeproj"
SCHEME="GitIsland"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-}"
BUNDLE_ID="com.nomdelasociete.GitIsland"
PROJECT_MARKETING_VERSION="$(
  /usr/bin/awk -F '"' '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml"
)"
MARKETING_VERSION="${MARKETING_VERSION:-$PROJECT_MARKETING_VERSION}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"

BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/GitIsland.xcarchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

validate_upload_auth() {
  if [[ -z "$TEAM_ID" || -z "$ASC_KEY_ID" || -z "$ASC_ISSUER_ID" || ! -f "$ASC_KEY_PATH" ]]; then
    echo "Upload requires explicit TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID, and an existing ASC_KEY_PATH." >&2
    return 2
  fi
}

write_export_options() {
  mkdir -p "$BUILD_DIR"
  rm -f "$EXPORT_OPTIONS_PLIST"
  /usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
  /usr/bin/plutil -insert method -string app-store-connect "$EXPORT_OPTIONS_PLIST"
  /usr/bin/plutil -insert destination -string upload "$EXPORT_OPTIONS_PLIST"
  /usr/bin/plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS_PLIST"
  /usr/bin/plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS_PLIST"
  /usr/bin/plutil -insert uploadSymbols -bool YES "$EXPORT_OPTIONS_PLIST"
}

check_settings() {
  echo "Project: $PROJECT_NAME"
  echo "Scheme: $SCHEME"
  echo "Configuration: $CONFIGURATION"
  echo "Bundle ID: $BUNDLE_ID"
  echo "Team: $TEAM_ID"
  echo "Version: $MARKETING_VERSION ($BUILD_NUMBER)"
  echo "ASC key: $ASC_KEY_PATH"

  xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=arm64" \
    -showBuildSettings \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    | /usr/bin/grep -E "CODE_SIGN_ENTITLEMENTS|CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|ENABLE_APP_SANDBOX|MARKETING_VERSION|CURRENT_PROJECT_VERSION|PRODUCT_BUNDLE_IDENTIFIER"

  if [[ -f "$ASC_KEY_PATH" ]]; then
    echo "App Store Connect API key: installed"
  else
    echo "App Store Connect API key: missing"
  fi
}

build_debug() {
  xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME" \
    -destination "platform=macOS,arch=arm64" \
    -configuration Debug \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build
}

archive_app() {
  if [[ "$CONFIGURATION" != Release || -z "$TEAM_ID" ]]; then
    echo "Archiving requires CONFIGURATION=Release and an explicit TEAM_ID." >&2
    return 2
  fi
  mkdir -p "$BUILD_DIR"
  rm -rf "$ARCHIVE_PATH"
  xcodebuild \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME" \
    -destination "platform=macOS,arch=arm64" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive
}

upload_archive() {
  validate_upload_auth
  local authentication_args=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )

  write_export_options
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates \
    "${authentication_args[@]}"
}

case "$MODE" in
  check)
    check_settings
    ;;
  build)
    build_debug
    ;;
  archive)
    archive_app
    ;;
  upload)
    validate_upload_auth
    build_debug
    archive_app
    upload_archive
    ;;
  upload-existing)
    upload_archive
    ;;
  *)
    echo "usage: $0 [check|build|archive|upload|upload-existing]" >&2
    exit 2
    ;;
esac
