#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_REF="${1:-}"

[[ "$CORE_REF" =~ ^[0-9a-f]{40}$ ]] || {
  echo "usage: $0 <40-character-core-commit>" >&2
  exit 2
}

cd "$ROOT_DIR"
sed -i '' -E \
  "s/^READBOARD_CORE_REF=.*/READBOARD_CORE_REF=$CORE_REF/" CoreVersion.env
sed -i '' -E \
  "s/revision: [0-9a-f]{40}/revision: $CORE_REF/" project.yml
sed -i '' -E \
  "s/\?\? \"[0-9a-f]{40}\"/?? \"$CORE_REF\"/" Package.swift
xcodegen generate

echo "ReadBoard Core 已锁定到 $CORE_REF"
