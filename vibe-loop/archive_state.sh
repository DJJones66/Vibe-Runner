#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$SCRIPT_DIR"
ARCHIVE_ROOT="$LOOP_ROOT/archive"
REPO_ROOT="$(git -C "$LOOP_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
LAST_PRD_SOURCE_FILE="$LOOP_ROOT/.last_prd_source"

ARCHIVE_NAME=""
DRY_RUN=0
CLEAR_AFTER_ARCHIVE=0
RESET_TASK_BRANCHES=0
RESET_TASK_BRANCHES_EXPLICIT=0
SOURCE_PLAN_PATHS=()

usage() {
  cat <<USAGE
Usage:
  ./archive_state.sh [options]

Options:
  --name <label>   Optional archive label suffix (example: plan-1)
  --dry-run        Print what would be archived without writing files
  --clear-after-archive  Clear live loop artifacts after a successful archive
  --reset-task-branches  Reset local vibe/task-task-* branches to current HEAD
  --no-reset-task-branches  Disable task-branch reset even with --clear-after-archive
  -h, --help       Show this help

Behavior:
  Archives current loop state into:
    ./.codex/vibe-loop/archive/<timestamp>[-label]/

  Included when present:
    - prd.json
    - reports/
    - logs/
    - source plan/spec markdown files (from last PRD source and common root names)

  Clear-after-archive removes when present:
    - ./.codex/vibe-loop/prd.json
    - ./.codex/vibe-loop/reports/
    - ./.codex/vibe-loop/logs/
    - ./.codex/vibe-loop/HALT
    - ./.codex/vibe-loop/.last_prd_source

  Task branch reset:
    - When --clear-after-archive is used, local vibe/task-task-* branches
      are reset to current HEAD by default.
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
      --clear-after-archive)
        CLEAR_AFTER_ARCHIVE=1
        shift
        ;;
      --reset-task-branches)
        RESET_TASK_BRANCHES=1
        RESET_TASK_BRANCHES_EXPLICIT=1
        shift
        ;;
      --no-reset-task-branches)
        RESET_TASK_BRANCHES=0
        RESET_TASK_BRANCHES_EXPLICIT=1
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

normalize_source_path() {
  local raw="$1"
  local resolved=""
  if [[ -z "$raw" ]]; then
    echo ""
    return
  fi
  if [[ "$raw" = /* ]]; then
    resolved="$raw"
  elif [[ -n "$REPO_ROOT" ]]; then
    resolved="$REPO_ROOT/$raw"
  else
    resolved="$raw"
  fi
  if [[ -f "$resolved" ]]; then
    echo "$resolved"
  else
    echo ""
  fi
}

collect_source_plan_paths() {
  SOURCE_PLAN_PATHS=()
  local raw resolved candidate

  if [[ -f "$LAST_PRD_SOURCE_FILE" ]]; then
    raw="$(tr -d '\r' <"$LAST_PRD_SOURCE_FILE")"
    resolved="$(normalize_source_path "$raw")"
    if [[ -n "$resolved" ]] && ! path_in_source_plan_paths "$resolved"; then
      SOURCE_PLAN_PATHS+=("$resolved")
    fi
  fi

  if [[ -n "$REPO_ROOT" ]]; then
    for candidate in agent_import.md AGENT.md plan.md PLAN.md product_plan.md PRODUCT_PLAN.md spec.md SPEC.md; do
      resolved="$REPO_ROOT/$candidate"
      if [[ -f "$resolved" ]] && ! path_in_source_plan_paths "$resolved"; then
        SOURCE_PLAN_PATHS+=("$resolved")
      fi
    done
  fi
}

path_in_source_plan_paths() {
  local needle="$1"
  local existing
  for existing in "${SOURCE_PLAN_PATHS[@]}"; do
    if [[ "$existing" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

has_archiveable_state() {
  if [[ -f "$LOOP_ROOT/prd.json" || -d "$LOOP_ROOT/reports" || -d "$LOOP_ROOT/logs" ]]; then
    return 0
  fi
  if [[ "${#SOURCE_PLAN_PATHS[@]}" -gt 0 ]]; then
    return 0
  fi
  return 1
}

copy_source_plans() {
  local archive_dir="$1"
  local src rel dest
  if [[ "${#SOURCE_PLAN_PATHS[@]}" -eq 0 ]]; then
    return 0
  fi
  for src in "${SOURCE_PLAN_PATHS[@]}"; do
    if [[ -n "$REPO_ROOT" && "$src" == "$REPO_ROOT/"* ]]; then
      rel="${src#$REPO_ROOT/}"
    else
      rel="$(basename "$src")"
    fi
    dest="$archive_dir/source_specs/$rel"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  done
}

write_manifest() {
  local archive_dir="$1"
  local manifest="$archive_dir/manifest.txt"
  {
    echo "archived_at_utc: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "loop_root: $LOOP_ROOT"
    if [[ -n "$REPO_ROOT" ]]; then
      echo "repo_root: $REPO_ROOT"
      echo "git_head: $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      echo "git_branch: $(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo unknown)"
    else
      echo "repo_root: unknown"
      echo "git_head: unknown"
      echo "git_branch: unknown"
    fi
    echo "clear_after_archive: $CLEAR_AFTER_ARCHIVE"
  } >"$manifest"
}

clear_live_loop_state() {
  rm -rf "$LOOP_ROOT/logs" "$LOOP_ROOT/reports"
  rm -f "$LOOP_ROOT/prd.json" "$LOOP_ROOT/HALT" "$LAST_PRD_SOURCE_FILE"
}

reset_task_branches_to_base() {
  local base_ref base_short current branch reset_count failed_count
  if [[ -z "$REPO_ROOT" ]]; then
    echo "Skipping task branch reset: repository root not found."
    return 0
  fi

  base_ref="$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -z "$base_ref" ]]; then
    echo "Skipping task branch reset: could not resolve HEAD."
    return 0
  fi

  base_short="$(git -C "$REPO_ROOT" rev-parse --short "$base_ref" 2>/dev/null || echo unknown)"
  current="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
  reset_count=0
  failed_count=0

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    [[ "$branch" == "$current" ]] && continue
    if git -C "$REPO_ROOT" update-ref "refs/heads/$branch" "$base_ref"; then
      reset_count=$((reset_count + 1))
    else
      failed_count=$((failed_count + 1))
      echo "Could not reset task branch '$branch' to base $base_short; continuing."
    fi
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/vibe/task-task-*")

  if [[ "$reset_count" -gt 0 ]]; then
    echo "Reset $reset_count task branches to base $base_short"
  else
    echo "No local task branches needed reset"
  fi
  if [[ "$failed_count" -gt 0 ]]; then
    echo "$failed_count task branches could not be reset automatically"
  fi
}

main() {
  parse_args "$@"

  if [[ "$CLEAR_AFTER_ARCHIVE" == "1" && "$RESET_TASK_BRANCHES_EXPLICIT" == "0" ]]; then
    RESET_TASK_BRANCHES=1
  fi

  collect_source_plan_paths

  local has_state=0
  if has_archiveable_state; then
    has_state=1
  fi

  if [[ "$has_state" == "0" && "$CLEAR_AFTER_ARCHIVE" != "1" && "$RESET_TASK_BRANCHES" != "1" ]]; then
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
    if [[ "${#SOURCE_PLAN_PATHS[@]}" -gt 0 ]]; then
      for source_path in "${SOURCE_PLAN_PATHS[@]}"; do
        echo "Would copy source plan: $source_path"
      done
    fi
    if [[ "$CLEAR_AFTER_ARCHIVE" == "1" ]]; then
      echo "Would clear: $LOOP_ROOT/prd.json"
      echo "Would clear: $LOOP_ROOT/reports/"
      echo "Would clear: $LOOP_ROOT/logs/"
      echo "Would clear: $LOOP_ROOT/HALT"
      echo "Would clear: $LAST_PRD_SOURCE_FILE"
    fi
    if [[ "$RESET_TASK_BRANCHES" == "1" ]]; then
      echo "Would reset: local vibe/task-task-* branches to current HEAD"
    fi
    exit 0
  fi

  if [[ "$has_state" == "1" ]]; then
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
    copy_source_plans "$archive_dir"
    write_manifest "$archive_dir"
  else
    echo "No archiveable files found; applying cleanup actions only."
  fi

  if [[ "$CLEAR_AFTER_ARCHIVE" == "1" ]]; then
    clear_live_loop_state
    echo "Cleared live loop artifacts in $LOOP_ROOT"
  fi
  if [[ "$RESET_TASK_BRANCHES" == "1" ]]; then
    reset_task_branches_to_base
  fi

  if [[ "$has_state" == "1" ]]; then
    echo "Archived loop state: $archive_dir"
  fi
}

main "$@"
