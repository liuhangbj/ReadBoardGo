#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source CoreVersion.env

[[ "$READBOARD_CORE_REF" =~ ^[0-9a-f]{40}$ ]] || {
  echo "CoreVersion.env must contain a full 40-character commit SHA" >&2
  exit 1
}

grep -Fq "?? \"$READBOARD_CORE_REF\"" Package.swift
grep -Fq "revision: $READBOARD_CORE_REF" project.yml
grep -Fq "revision = $READBOARD_CORE_REF;" ReadBoardGo.xcodeproj/project.pbxproj

echo "ReadBoard Core dependency is pinned consistently: $READBOARD_CORE_REF"
