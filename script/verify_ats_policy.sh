#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
  set -- "$ROOT_DIR/App/Info-macOS.plist" "$ROOT_DIR/App/Info-iOS.plist"
fi

for PLIST in "$@"; do
  [ -f "$PLIST" ] || { echo "Missing Info.plist: $PLIST" >&2; exit 1; }

  for KEY in NSAllowsArbitraryLoads NSAllowsArbitraryLoadsInWebContent; do
    if /usr/libexec/PlistBuddy \
        -c "Print :NSAppTransportSecurity:$KEY" "$PLIST" >/dev/null 2>&1; then
      echo "ReadBoard Go must keep ATS strict; found $KEY in $PLIST" >&2
      exit 1
    fi
  done

  echo "ReadBoard Go scoped ATS policy verified: $PLIST"
done
