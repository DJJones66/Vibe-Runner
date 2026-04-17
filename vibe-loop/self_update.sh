#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

BOOTSTRAP_URL="${VIBE_RUNNER_BOOTSTRAP_URL:-https://raw.githubusercontent.com/DJJones66/Vibe-Runner/main/scripts/bootstrap.sh}"

usage() {
  cat <<USAGE
Usage:
  ./self_update.sh [bootstrap options]

Purpose:
  Updates Vibe Runner in the current project using the remote bootstrap script.

Examples:
  ./self_update.sh --allow-unsigned
  ./self_update.sh --version v1.2.3 --sha256 <sha256>
  ./self_update.sh --repo-url https://github.com/<your-org>/Vibe-Runner --allow-unsigned

Environment:
  VIBE_RUNNER_BOOTSTRAP_URL   Override bootstrap script URL
USAGE
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        usage
        exit 0
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required" >&2
    exit 1
  fi

  echo "[vibe-runner] updating target: $TARGET_REPO"
  echo "[vibe-runner] bootstrap URL: $BOOTSTRAP_URL"

  # Forward all user-provided bootstrap flags and force update into this repo root.
  curl -fsSL "$BOOTSTRAP_URL" \
    | bash -s -- --action update --target "$TARGET_REPO" "$@"
}

main "$@"
