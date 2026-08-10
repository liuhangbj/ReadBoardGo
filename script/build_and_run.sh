#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ReadBoard Go"
BUNDLE_ID="com.hangbits.ReadBoardGo.mac"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/DerivedData/Run"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
OUTPUT_DIR="${READBOARD_OUTPUT_DIR:-$HOME/Applications}"
INSTALLED_APP="$OUTPUT_DIR/$APP_NAME.app"
APP_BINARY="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
ICON_APPEARANCE="${READBOARD_ICON_APPEARANCE:-auto}"

if [ "$ICON_APPEARANCE" = "auto" ]; then
  if defaults read -g AppleInterfaceStyle 2>/dev/null | grep -q '^Dark$'; then
    ICON_APPEARANCE="dark"
  else
    ICON_APPEARANCE="light"
  fi
fi
case "$ICON_APPEARANCE" in
  light) APP_ICON_NAME="AppIcon" ;;
  dark) APP_ICON_NAME="AppIconDark" ;;
  *) echo "READBOARD_ICON_APPEARANCE must be auto, light, or dark" >&2; exit 2 ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT_ROOT/ReadBoardGo.xcodeproj" \
  -scheme ReadBoardGoMac \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  ASSETCATALOG_COMPILER_APPICON_NAME="$APP_ICON_NAME" \
  CODE_SIGNING_ALLOWED=NO \
  build

install_app() {
  local staging_root
  staging_root="$(mktemp -d "${TMPDIR:-/tmp}/readboard-go-install.XXXXXX")"
  mkdir -p "$OUTPUT_DIR"
  ditto "$APP_BUNDLE" "$staging_root/$APP_NAME.app"
  if [ -e "$INSTALLED_APP" ]; then
    mv "$INSTALLED_APP" "$staging_root/previous.app"
  fi
  mv "$staging_root/$APP_NAME.app" "$INSTALLED_APP"
  rm -rf "$staging_root"
}

install_app

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == '$APP_NAME'"
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == '$BUNDLE_ID'"
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
