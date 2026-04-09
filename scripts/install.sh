#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-install}"
TARGET_REPO="${2:-$PWD}"
FORCE="${FORCE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_LOOP="$SRC_ROOT/vibe-loop"
DEST_LOOP="$TARGET_REPO/.codex/vibe-loop"

usage() {
  cat <<USAGE
Usage:
  ./scripts/install.sh install [target_repo]
  ./scripts/install.sh update [target_repo]
  ./scripts/install.sh uninstall [target_repo]

Environment:
  FORCE=1   Overwrite target CODEX.md and prd.json during install/update.
USAGE
}

copy_if_needed() {
  local src="$1"
  local dest="$2"
  if [[ "$FORCE" == "1" || ! -f "$dest" ]]; then
    cp "$src" "$dest"
  fi
}

install_or_update() {
  mkdir -p "$DEST_LOOP" "$DEST_LOOP/logs" "$DEST_LOOP/reports"

  cp "$SRC_LOOP/runner.sh" "$DEST_LOOP/runner.sh"
  cp "$SRC_LOOP/taskctl.py" "$DEST_LOOP/taskctl.py"
  cp "$SRC_LOOP/.gitignore" "$DEST_LOOP/.gitignore"

  copy_if_needed "$SRC_LOOP/CODEX.md" "$DEST_LOOP/CODEX.md"
  copy_if_needed "$SRC_LOOP/prd.json" "$DEST_LOOP/prd.json"

  chmod +x "$DEST_LOOP/runner.sh" "$DEST_LOOP/taskctl.py"

  echo "[vibe-runner] $ACTION complete"
  echo "target: $DEST_LOOP"
  if [[ "$FORCE" != "1" ]]; then
    echo "note: existing CODEX.md/prd.json were preserved (set FORCE=1 to overwrite)"
  fi
}

uninstall_loop() {
  if [[ -d "$DEST_LOOP" ]]; then
    rm -rf "$DEST_LOOP"
    echo "[vibe-runner] uninstall complete"
    echo "removed: $DEST_LOOP"
  else
    echo "[vibe-runner] nothing to uninstall at $DEST_LOOP"
  fi
}

case "$ACTION" in
  install)
    install_or_update
    ;;
  update)
    install_or_update
    ;;
  uninstall)
    uninstall_loop
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    usage
    exit 2
    ;;
esac
