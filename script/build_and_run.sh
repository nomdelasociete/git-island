#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_NAME="GitIsland.xcodeproj"
SCHEME="GitIsland"
CONFIGURATION="${CONFIGURATION:-Debug}"
if [[ "$CONFIGURATION" != "Debug" ]]; then
  echo "Local builds must use Debug. Use an Xcode archive for TestFlight releases." >&2
  exit 2
fi
DISPLAY_NAME="Git Island Dev"
BUNDLE_ID="com.nomdelasociete.GitIsland.dev"
SIGNING_MODE="${SIGNING_MODE:-local}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$DISPLAY_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$DISPLAY_NAME"

stop_running_app() {
  pkill -x "$DISPLAY_NAME" >/dev/null 2>&1 || true
}

build_app() {
  local build_command=(
    xcodebuild
    -quiet
    -project "$ROOT_DIR/$PROJECT_NAME"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$DERIVED_DATA_DIR"
    build
  )

  if [[ "$SIGNING_MODE" == "local" ]]; then
    build_command+=(
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY=-
      CODE_SIGN_ENTITLEMENTS=GitIslandLocal.entitlements
      DEVELOPMENT_TEAM=
      PROVISIONING_PROFILE_SPECIFIER=
    )
  fi

  "${build_command[@]}"
}

open_app() {
  if pgrep -x "$DISPLAY_NAME" >/dev/null; then
    echo "Git Island is already running; leaving the existing instance alone."
    return 0
  fi

  /usr/bin/open "$APP_BUNDLE"
}

verify_app() {
  sleep 1
  if pgrep -x "$DISPLAY_NAME" >/dev/null; then
    echo "Git Island is running."
    return 0
  fi

  echo "Git Island failed to start: $APP_BUNDLE" >&2
  return 1
}

build_app

case "$MODE" in
  run)
    open_app
    verify_app
    ;;
  build)
    echo "Built: $APP_BUNDLE"
    ;;
  restart)
    stop_running_app
    open_app
    verify_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$DISPLAY_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_app
    ;;
  *)
    echo "usage: $0 [run|build|restart|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
