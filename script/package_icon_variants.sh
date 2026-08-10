#!/usr/bin/env bash
# Xcode 只会输出当前选中的 AppIcon；这里把浅、深两套完整 icns 都装入应用包。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="${1:?usage: package_icon_variants.sh <app-resources-directory>}"
CATALOG_DIR="$PROJECT_DIR/App/Assets.xcassets"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/readboard-go-icons.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_icns() {
    local source="$1"
    local output="$2"
    local iconset="$TMP_ROOT/$(basename "$output" .icns).iconset"
    mkdir -p "$iconset"
    for name in \
        icon_16x16.png icon_16x16@2x.png \
        icon_32x32.png icon_32x32@2x.png \
        icon_128x128.png icon_128x128@2x.png \
        icon_256x256.png icon_256x256@2x.png \
        icon_512x512.png icon_512x512@2x.png; do
        [ -f "$source/$name" ] || { echo "Missing icon resource: $source/$name" >&2; exit 1; }
        cp -p "$source/$name" "$iconset/$name"
    done
    iconutil -c icns "$iconset" -o "$output"
}

mkdir -p "$RESOURCES_DIR"
make_icns "$CATALOG_DIR/AppIcon.appiconset" "$RESOURCES_DIR/AppIconLight.icns"
make_icns "$CATALOG_DIR/AppIconDark.appiconset" "$RESOURCES_DIR/AppIconDark.icns"
