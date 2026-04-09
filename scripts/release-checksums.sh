#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: ./scripts/release-checksums.sh <archive> [archive...]" >&2
  exit 2
fi

for archive in "$@"; do
  if [[ ! -f "$archive" ]]; then
    echo "File not found: $archive" >&2
    exit 1
  fi

  sha256sum "$archive"
done
