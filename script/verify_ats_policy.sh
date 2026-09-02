#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
  set -- "$ROOT_DIR/App/Info-macOS.plist" "$ROOT_DIR/App/Info-iOS.plist"
fi

for PLIST in "$@"; do
  [ -f "$PLIST" ] || { echo "Missing Info.plist: $PLIST" >&2; exit 1; }

  ARBITRARY_LOADS="$(/usr/libexec/PlistBuddy \
    -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$PLIST" 2>/dev/null || true)"
  [ "$ARBITRARY_LOADS" = "true" ] || {
    echo "ReadBoard Go self-hosted TLS requires NSAllowsArbitraryLoads=true: $PLIST" >&2
    exit 1
  }

  for KEY in NSAllowsArbitraryLoadsInMedia NSAllowsArbitraryLoadsInWebContent NSAllowsLocalNetworking; do
    if /usr/libexec/PlistBuddy \
        -c "Print :NSAppTransportSecurity:$KEY" "$PLIST" >/dev/null 2>&1; then
      echo "$KEY makes the general self-hosted TLS exception ineffective: $PLIST" >&2
      exit 1
    fi
  done

  echo "ReadBoard Go ATS policy verified: $PLIST"
done
