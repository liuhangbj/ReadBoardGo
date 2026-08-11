#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ReadBoard Go"
VERSION="${READBOARD_VERSION:-0.9.4-beta.1}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${READBOARD_BUILD_NUMBER:-1}"
OUTPUT_DIR="${READBOARD_OUTPUT_DIR:-$ROOT_DIR/.artifacts/release}"
ARCHIVE_PATH="${READBOARD_ARCHIVE_PATH:-}"
DERIVED_DATA="${READBOARD_DERIVED_DATA:-$ROOT_DIR/DerivedData/Package}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
INSTALLED_APP="$OUTPUT_DIR/$APP_NAME.app"

"$ROOT_DIR/script/verify_core_ref.sh"

xcodebuild -quiet \
  -project "$ROOT_DIR/ReadBoardGo.xcodeproj" \
  -scheme ReadBoardGoMac \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon \
  CODE_SIGNING_ALLOWED=NO \
  build

[ -d "$BUILT_APP" ] || { echo "Missing built app: $BUILT_APP" >&2; exit 1; }

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/readboard-go-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
ditto "$BUILT_APP" "$STAGED_APP"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$STAGED_APP/Contents/Info.plist"

codesign --deep --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

ARCHITECTURES="$(lipo -archs "$STAGED_APP/Contents/MacOS/$APP_NAME")"
[[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]] || {
  echo "Expected a universal arm64/x86_64 app, got: $ARCHITECTURES" >&2
  exit 1
}

[ -f "$STAGED_APP/Contents/Resources/AppIconLight.icns" ]
[ -f "$STAGED_APP/Contents/Resources/AppIconDark.icns" ]

mkdir -p "$OUTPUT_DIR"
if [ -e "$INSTALLED_APP" ]; then
  mv "$INSTALLED_APP" "$STAGING_ROOT/previous.app"
fi
mv "$STAGED_APP" "$INSTALLED_APP"

echo "ReadBoard Go app: $INSTALLED_APP"
echo "Architectures: $ARCHITECTURES"

if [ -n "$ARCHIVE_PATH" ]; then
  mkdir -p "$(dirname "$ARCHIVE_PATH")"
  TEMP_ARCHIVE="$STAGING_ROOT/$(basename "$ARCHIVE_PATH")"
  ditto -c -k --sequesterRsrc --keepParent "$INSTALLED_APP" "$TEMP_ARCHIVE"
  mv "$TEMP_ARCHIVE" "$ARCHIVE_PATH"
  echo "ReadBoard Go archive: $ARCHIVE_PATH"
fi
