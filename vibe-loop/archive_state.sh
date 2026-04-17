#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$SCRIPT_DIR"
ARCHIVE_ROOT="$LOOP_ROOT/archive"

ARCHIVE_NAME=""
DRY_RUN=0

usage() {
  cat <<USAGE
Usage:
  ./archive_state.sh [options]

Options:
  --name <label>   Optional archive label suffix (example: plan-1)
  --dry-run        Print what would be archived without writing files
  -h, --help       Show this help

Behavior:
  Archives current loop state into:
    ./.codex/vibe-loop/archive/<timestamp>[-label]/

  Included when present:
    - prd.json
    - reports/
    - logs/
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        ARCHIVE_NAME="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
}

sanitize_name() {
  local raw="$1"
  local safe
  safe="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  echo "$safe"
}

main() {
  parse_args "$@"

  if [[ ! -f "$LOOP_ROOT/prd.json" && ! -d "$LOOP_ROOT/reports" && ! -d "$LOOP_ROOT/logs" ]]; then
    echo "No loop state found to archive."
    exit 0
  fi

  local ts suffix archive_dir
  ts="$(date -u +"%Y%m%d-%H%M%S")"
  suffix=""
  if [[ -n "$ARCHIVE_NAME" ]]; then
    suffix="-$(sanitize_name "$ARCHIVE_NAME")"
  fi

  archive_dir="$ARCHIVE_ROOT/$ts$suffix"
  if [[ -e "$archive_dir" ]]; then
    archive_dir="${archive_dir}-$$"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry run archive path: $archive_dir"
    [[ -f "$LOOP_ROOT/prd.json" ]] && echo "Would copy: $LOOP_ROOT/prd.json"
    [[ -d "$LOOP_ROOT/reports" ]] && echo "Would copy: $LOOP_ROOT/reports/"
    [[ -d "$LOOP_ROOT/logs" ]] && echo "Would copy: $LOOP_ROOT/logs/"
    exit 0
  fi

  mkdir -p "$archive_dir"

  if [[ -f "$LOOP_ROOT/prd.json" ]]; then
    cp "$LOOP_ROOT/prd.json" "$archive_dir/prd.json"
  fi
  if [[ -d "$LOOP_ROOT/reports" ]]; then
    cp -a "$LOOP_ROOT/reports" "$archive_dir/reports"
  fi
  if [[ -d "$LOOP_ROOT/logs" ]]; then
    cp -a "$LOOP_ROOT/logs" "$archive_dir/logs"
  fi

  echo "Archived loop state: $archive_dir"
}

main "$@"
