#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$SCRIPT_DIR"
PRD_FILE="$LOOP_ROOT/prd.json"
TASKCTL="$LOOP_ROOT/taskctl.py"
CODEX_MD="$LOOP_ROOT/CODEX.md"
LOG_DIR="$LOOP_ROOT/logs"
REPORT_DIR="$LOOP_ROOT/reports"
EVENT_LOG="$LOG_DIR/events.log"
RUN_LOG="$LOG_DIR/run.log"
HALT_FILE="$LOOP_ROOT/HALT"

MODEL="${MODEL:-gpt-5.4}"
REASONING_EFFORT="${REASONING_EFFORT:-}"
SANDBOX="${SANDBOX:-workspace-write}"
AUTO_PUSH="${AUTO_PUSH:-0}"
ALLOW_DIRTY_LOOP_FILES="${ALLOW_DIRTY_LOOP_FILES:-0}"
PREP_RESET_TASK_BRANCHES="${PREP_RESET_TASK_BRANCHES:-0}"
USE_SEARCH=0
AUTO_FIX_VALIDATION="${AUTO_FIX_VALIDATION:-0}"
MAX_AUTO_FIX_ATTEMPTS="${MAX_AUTO_FIX_ATTEMPTS:-1}"
AUTO_BLOCK_ENV_FAILURE="${AUTO_BLOCK_ENV_FAILURE:-1}"
CODEX_EXEC_MAX_RETRIES="${CODEX_EXEC_MAX_RETRIES:-3}"
CODEX_EXEC_RETRY_DELAY_SECONDS="${CODEX_EXEC_RETRY_DELAY_SECONDS:-20}"
DRY_RUN=0
STATUS_ONLY=0
STATUS_MILESTONES=0
TASK_ID=""
MAX_ITERATIONS=1
INTERRUPTED=0
PLAN_BASE_BRANCH=""
PLAN_WORKING_BRANCH=""
RESOLVED_BASE_BRANCH=""
RESOLVED_BASE_REF=""

mkdir -p "$LOG_DIR" "$REPORT_DIR"

log_event() {
  local msg="$1"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$ts] $msg" | tee -a "$EVENT_LOG"
}

on_interrupt() {
  INTERRUPTED=1
}

usage() {
  cat <<USAGE
Usage: ./runner.sh [max_iterations] [options]

Options:
  --task <ID>      Run only this pending task id
  --no-search      Disable web search for codex runs
  --search         Enable web search for codex runs (if supported by codex exec)
  --dry-run        Select tasks and log actions only (no codex execution)
  --reset-task-branches  Reset legacy local vibe/task-task-* branches to current HEAD before running
  --status         Print PRD status summary and exit
  --status-milestones  Print PRD milestone progress summary and exit
  -h, --help       Show this help

Environment:
  MODEL            Codex model (default: gpt-5.4)
  REASONING_EFFORT Optional reasoning effort passed via codex config override
  SANDBOX          Codex sandbox mode (default: workspace-write)
  AUTO_PUSH        1 to push branch after successful commit (default: 0)
  ALLOW_DIRTY_LOOP_FILES  1 to allow dirty changes limited to .codex/vibe-loop/** (default: 0)
  PREP_RESET_TASK_BRANCHES  1 to reset legacy local vibe/task-task-* branches to current HEAD before running (default: 0)
  AUTO_FIX_VALIDATION  1 to let codex attempt one-pass fixes after validation fails (default: 0)
  MAX_AUTO_FIX_ATTEMPTS  Number of validation auto-fix attempts (default: 1)
  AUTO_BLOCK_ENV_FAILURE  1 to mark blocked when validation fails from missing env/deps (default: 1)
  CODEX_EXEC_MAX_RETRIES  Number of retries for transient codex exec failures (default: 3)
  CODEX_EXEC_RETRY_DELAY_SECONDS  Delay between transient codex exec retries (default: 20)
  HALT=true        Stop before next task starts
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)
        TASK_ID="$2"
        shift 2
        ;;
      --no-search)
        USE_SEARCH=0
        shift
        ;;
      --search)
        USE_SEARCH=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --reset-task-branches)
        PREP_RESET_TASK_BRANCHES=1
        shift
        ;;
      --status)
        STATUS_ONLY=1
        shift
        ;;
      --status-milestones)
        STATUS_MILESTONES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          MAX_ITERATIONS="$1"
          shift
        else
          echo "Unknown argument: $1" >&2
          usage
          exit 2
        fi
        ;;
    esac
  done
}

require_tools() {
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
  command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
  command -v codex >/dev/null 2>&1 || { echo "codex CLI is required" >&2; exit 1; }
}

supports_exec_search() {
  codex exec --help 2>/dev/null | rg -q -- '--search'
}

validation_indicates_env_block() {
  local output_file="$1"
  if grep -Eqi \
    'EAI_AGAIN|ENOTFOUND|Temporary failure in name resolution|Could not resolve host|network_access=false|command not found|vitest: not found|pytest: command not found|npm: command not found|node: command not found|python: command not found|python3: command not found' \
    "$output_file"; then
    return 0
  fi

  # taskctl validate emits "Validation failed at step ...: <command>" even when
  # command discovery checks like `command -v tool` produce no stderr text.
  if grep -Eqi \
    'Validation failed at step [0-9]+: .*command -v[[:space:]]+[[:alnum:]_.-]+' \
    "$output_file"; then
    return 0
  fi

  return 1
}

codex_exec_is_transient_failure() {
  local output_file="$1"
  grep -Eqi \
    'Selected model is at capacity|at capacity|rate limit|429|503|temporarily unavailable|server overloaded|Please try again|try a different model|timed out|timeout|connection reset|ECONNRESET|ETIMEDOUT|failed to record rollout items: thread .* not found' \
    "$output_file"
}

is_valid_report_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != ~* ]] || return 1
  [[ "$path" != *$'\n'* ]] || return 1
  [[ "$path" != *$'\r'* ]] || return 1
  [[ "$path" != *".."* ]] || return 1
  [[ "$path" != *[[:space:]]* ]] || return 1
  [[ "$path" == *.md ]] || return 1
  [[ "$path" == */* ]] || return 1
  [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  return 0
}

ensure_clean_git() {
  if [[ "$ALLOW_DIRTY_LOOP_FILES" == "1" ]]; then
    if ! git -C "$REPO_ROOT" diff --quiet -- . ":(exclude).codex/vibe-loop/**" || \
       ! git -C "$REPO_ROOT" diff --cached --quiet -- . ":(exclude).codex/vibe-loop/**"; then
      log_event "Working tree has non-loop changes. Commit/stash changes before running loop."
      exit 1
    fi
    if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
      log_event "Working tree has .codex/vibe-loop changes; continuing because ALLOW_DIRTY_LOOP_FILES=1."
    fi
    return 0
  fi

  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    log_event "Working tree is dirty. Commit/stash changes before running loop."
    exit 1
  fi
}

reset_task_branches_to_base() {
  local base_ref base_short current branch reset_count failed_count
  base_ref="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
  base_short="$(git -C "$REPO_ROOT" rev-parse --short "$base_ref")"
  current="$(git -C "$REPO_ROOT" branch --show-current)"
  reset_count=0
  failed_count=0

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    [[ "$branch" == "$current" ]] && continue
    if git -C "$REPO_ROOT" update-ref "refs/heads/$branch" "$base_ref"; then
      reset_count=$((reset_count + 1))
    else
      failed_count=$((failed_count + 1))
      log_event "Could not reset legacy task branch '$branch' to base $base_short; continuing."
    fi
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/vibe/task-task-*")

  if [[ "$reset_count" -gt 0 ]]; then
    log_event "Reset $reset_count legacy task branches to base $base_short before run."
  else
    log_event "No legacy task branches needed reset before run."
  fi
  if [[ "$failed_count" -gt 0 ]]; then
    log_event "$failed_count legacy task branches could not be reset automatically."
  fi
}

ensure_loop_control_files() {
  local required
  local missing=0
  for required in "$TASKCTL" "$PRD_FILE" "$CODEX_MD"; do
    if [[ ! -f "$required" ]]; then
      log_event "Missing required loop file: $required"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    log_event "Loop control files are missing from the current branch."
    return 1
  fi
  return 0
}

get_task_json() {
  if [[ -n "$TASK_ID" ]]; then
    python3 "$TASKCTL" next "$PRD_FILE" --task "$TASK_ID" 2>>"$RUN_LOG"
  else
    python3 "$TASKCTL" next "$PRD_FILE" 2>>"$RUN_LOG"
  fi
}

extract_json_field() {
  local json_input="$1"
  local field="$2"
  JSON_INPUT="$json_input" python3 - "$field" <<'PY'
import json, os, sys
field = sys.argv[1]
data = json.loads(os.environ["JSON_INPUT"])
value = data.get(field)
if value is None:
    print("")
elif isinstance(value, (dict, list)):
    import json as j
    print(j.dumps(value))
else:
    print(str(value))
PY
}

load_prd_git_config() {
  local cfg
  cfg="$(python3 - "$PRD_FILE" <<'PY'
import json
import re
import sys
from typing import Any

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def slugify(value: Any, fallback: str) -> str:
    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    text = re.sub(r"-{2,}", "-", text).strip("-")
    return text or fallback

def sanitize_branch(value: Any) -> str:
    text = str(value or "").strip().replace("\\", "/")
    if not text:
        return ""
    text = re.sub(r"\s+", "-", text)
    text = re.sub(r"[^A-Za-z0-9._/\-]+", "-", text)
    text = re.sub(r"/{2,}", "/", text)
    text = re.sub(r"-{2,}", "-", text)
    parts = []
    for part in text.split("/"):
        cleaned = part.strip().strip(".").strip("-")
        if cleaned in {"", ".", ".."}:
            continue
        if cleaned.endswith(".lock"):
            cleaned = cleaned[: -len(".lock")]
        cleaned = cleaned.strip(".").strip("-")
        if cleaned:
            parts.append(cleaned)
    branch = "/".join(parts).strip("/")
    if (
        not branch
        or branch.startswith("-")
        or branch.endswith(".")
        or ".." in branch
        or "@{" in branch
    ):
        return ""
    return branch

git_cfg = data.get("git") if isinstance(data.get("git"), dict) else {}
project_slug = slugify(data.get("project"), "project")
base_branch = sanitize_branch(git_cfg.get("base_branch")) or "main"
working_branch = sanitize_branch(git_cfg.get("working_branch")) or f"prd/{project_slug}"
print(base_branch)
print(working_branch)
PY
)"
  PLAN_BASE_BRANCH="$(printf '%s\n' "$cfg" | sed -n '1p')"
  PLAN_WORKING_BRANCH="$(printf '%s\n' "$cfg" | sed -n '2p')"
}

resolve_base_branch_ref() {
  local base_branch="$1"
  local alternate_branch=""
  RESOLVED_BASE_BRANCH=""
  RESOLVED_BASE_REF=""
  if git -C "$REPO_ROOT" rev-parse --verify "$base_branch" >/dev/null 2>&1; then
    RESOLVED_BASE_BRANCH="$base_branch"
    RESOLVED_BASE_REF="$base_branch"
    return 0
  fi
  if git -C "$REPO_ROOT" rev-parse --verify "origin/$base_branch" >/dev/null 2>&1; then
    RESOLVED_BASE_BRANCH="$base_branch"
    RESOLVED_BASE_REF="origin/$base_branch"
    return 0
  fi

  if [[ "$base_branch" == "main" ]]; then
    alternate_branch="master"
  elif [[ "$base_branch" == "master" ]]; then
    alternate_branch="main"
  fi

  if [[ -n "$alternate_branch" ]]; then
    if git -C "$REPO_ROOT" rev-parse --verify "$alternate_branch" >/dev/null 2>&1; then
      RESOLVED_BASE_BRANCH="$alternate_branch"
      RESOLVED_BASE_REF="$alternate_branch"
      return 0
    fi
    if git -C "$REPO_ROOT" rev-parse --verify "origin/$alternate_branch" >/dev/null 2>&1; then
      RESOLVED_BASE_BRANCH="$alternate_branch"
      RESOLVED_BASE_REF="origin/$alternate_branch"
      return 0
    fi
  fi
  return 1
}

ensure_plan_working_branch() {
  local current base_ref requested_base_branch
  current="$(git -C "$REPO_ROOT" branch --show-current)"
  if [[ "$current" == "$PLAN_WORKING_BRANCH" ]]; then
    return 0
  fi

  if git -C "$REPO_ROOT" rev-parse --verify "$PLAN_WORKING_BRANCH" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" checkout "$PLAN_WORKING_BRANCH" >>"$RUN_LOG" 2>&1
    return 0
  fi

  if git -C "$REPO_ROOT" rev-parse --verify "origin/$PLAN_WORKING_BRANCH" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" checkout -b "$PLAN_WORKING_BRANCH" --track "origin/$PLAN_WORKING_BRANCH" >>"$RUN_LOG" 2>&1
    return 0
  fi

  requested_base_branch="$PLAN_BASE_BRANCH"
  if ! resolve_base_branch_ref "$requested_base_branch"; then
    log_event "Could not resolve base branch '$PLAN_BASE_BRANCH' (checked local and origin refs)."
    return 1
  fi
  base_ref="$RESOLVED_BASE_REF"
  if [[ -n "$RESOLVED_BASE_BRANCH" && "$RESOLVED_BASE_BRANCH" != "$requested_base_branch" ]]; then
    log_event "Base branch '$requested_base_branch' not found; using '$RESOLVED_BASE_BRANCH' for this repository."
    PLAN_BASE_BRANCH="$RESOLVED_BASE_BRANCH"
  fi

  git -C "$REPO_ROOT" checkout -b "$PLAN_WORKING_BRANCH" "$base_ref" >>"$RUN_LOG" 2>&1
  return 0
}

stage_repo_changes() {
  if [[ -z "$(git -C "$REPO_ROOT" ls-files ".codex/**")" ]]; then
    git -C "$REPO_ROOT" add -A -- . ":(exclude).codex/**" >>"$RUN_LOG" 2>&1
    return 0
  fi
  log_event "Tracked .codex files detected; using legacy staging for compatibility."
  git -C "$REPO_ROOT" add -A >>"$RUN_LOG" 2>&1
}

run_one_task() {
  local task_json="$1"
  local id title commit_message report_rel report_abs current_branch
  id="$(extract_json_field "$task_json" "id")"
  title="$(extract_json_field "$task_json" "title")"
  commit_message="$(extract_json_field "$task_json" "commit_message")"
  report_rel="$(extract_json_field "$task_json" "report")"

  if [[ -z "$commit_message" ]]; then
    commit_message="$id: $title"
  fi

  case "${report_rel,,}" in
    pending|retry|done|failed|blocked)
      report_rel=""
      ;;
  esac

  if ! is_valid_report_path "$report_rel"; then
    if [[ -n "$report_rel" ]]; then
      log_event "Task $id provided invalid report path; defaulting to reports/$id.md"
    fi
    report_rel="reports/${id}.md"
  fi

  report_abs="$LOOP_ROOT/$report_rel"
  mkdir -p "$(dirname "$report_abs")"
  current_branch="$(git -C "$REPO_ROOT" branch --show-current)"

  log_event "Starting $id on branch '$current_branch': $title"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_event "Dry run: skipped codex execution for $id"
    return 0
  fi

  if ! ensure_loop_control_files; then
    log_event "Task $id failed because required loop files are missing on this branch"
    return 1
  fi

  local prompt_file
  prompt_file="$(mktemp)"
  if ! python3 "$TASKCTL" render-prompt "$PRD_FILE" "$id" "$CODEX_MD" "$prompt_file" >>"$RUN_LOG" 2>&1; then
    python3 "$TASKCTL" mark "$PRD_FILE" "$id" "failed" "prompt render failed; see logs/run.log" >>"$RUN_LOG" 2>&1 || true
    log_event "Task $id failed during prompt rendering"
    rm -f "$prompt_file"
    return 1
  fi

  local last_msg
  last_msg="$(mktemp)"

  local -a cmd
  cmd=(codex exec -C "$REPO_ROOT" -m "$MODEL" -s "$SANDBOX" -o "$last_msg")
  if [[ -n "$REASONING_EFFORT" ]]; then
    cmd+=(-c "model_reasoning_effort=\"$REASONING_EFFORT\"")
  fi
  if [[ "$USE_SEARCH" == "1" ]]; then
    if supports_exec_search; then
      cmd+=(--search)
    else
      log_event "codex exec does not support --search on this CLI version; continuing without search."
    fi
  fi

  local exec_output_file exec_attempt exec_succeeded
  exec_output_file="$(mktemp)"
  exec_attempt=1
  exec_succeeded=0

  while [[ "$exec_attempt" -le "$CODEX_EXEC_MAX_RETRIES" ]]; do
    log_event "Running codex exec for $id (attempt $exec_attempt/$CODEX_EXEC_MAX_RETRIES)"
    if "${cmd[@]}" - <"$prompt_file" >"$exec_output_file" 2>&1; then
      cat "$exec_output_file" >>"$RUN_LOG"
      exec_succeeded=1
      break
    fi

    cat "$exec_output_file" >>"$RUN_LOG"
    if [[ "$INTERRUPTED" == "1" ]]; then
      python3 "$TASKCTL" mark "$PRD_FILE" "$id" "retry" "interrupted by user during codex exec; safe to rerun" >>"$RUN_LOG" 2>&1 || true
      log_event "Task $id interrupted by user during codex exec"
      rm -f "$prompt_file" "$last_msg" "$exec_output_file"
      return 130
    fi

    if codex_exec_is_transient_failure "$exec_output_file" && [[ "$exec_attempt" -lt "$CODEX_EXEC_MAX_RETRIES" ]]; then
      log_event "codex exec transient failure for $id; retrying in ${CODEX_EXEC_RETRY_DELAY_SECONDS}s"
      sleep "$CODEX_EXEC_RETRY_DELAY_SECONDS"
      ((exec_attempt++))
      continue
    fi
    break
  done

  if [[ "$exec_succeeded" != "1" ]]; then
    if codex_exec_is_transient_failure "$exec_output_file"; then
      python3 "$TASKCTL" mark "$PRD_FILE" "$id" "retry" "transient codex exec failure after ${CODEX_EXEC_MAX_RETRIES} attempts; safe to rerun" >>"$RUN_LOG" 2>&1 || true
      log_event "Task $id marked retry after transient codex exec failure"
      rm -f "$prompt_file" "$last_msg" "$exec_output_file"
      return 2
    fi
    python3 "$TASKCTL" mark "$PRD_FILE" "$id" "failed" "codex exec failed; see logs/run.log" >>"$RUN_LOG" 2>&1
    log_event "Task $id failed during codex exec"
    rm -f "$prompt_file" "$last_msg" "$exec_output_file"
    return 1
  fi
  rm -f "$exec_output_file"

  cp "$last_msg" "$report_abs"
  log_event "Wrote report: $report_rel"

  local validation_ok=0
  local validation_output_file
  validation_output_file="$(mktemp)"
  if python3 "$TASKCTL" validate "$PRD_FILE" "$id" "$REPO_ROOT" >"$validation_output_file" 2>&1; then
    cat "$validation_output_file" >>"$RUN_LOG"
    validation_ok=1
  else
    cat "$validation_output_file" >>"$RUN_LOG"
    log_event "Task $id failed validation on first pass"
    if [[ "$AUTO_BLOCK_ENV_FAILURE" == "1" ]] && validation_indicates_env_block "$validation_output_file"; then
      python3 "$TASKCTL" mark "$PRD_FILE" "$id" "blocked" "validation blocked by environment/dependencies; see logs/run.log" >>"$RUN_LOG" 2>&1
      log_event "Task $id blocked by environment/dependencies during validation"
      rm -f "$prompt_file" "$last_msg" "$validation_output_file"
      return 1
    fi
  fi

  if [[ "$validation_ok" == "0" && "$AUTO_FIX_VALIDATION" == "1" ]]; then
    local validation_json
    validation_json="$(python3 "$TASKCTL" field "$PRD_FILE" "$id" validation --json 2>>"$RUN_LOG")"
    local attempt=1
    while [[ "$attempt" -le "$MAX_AUTO_FIX_ATTEMPTS" && "$validation_ok" == "0" ]]; do
      log_event "Auto-fix attempt $attempt for $id after validation failure"

      local fix_prompt_file fix_msg_file
      fix_prompt_file="$(mktemp)"
      fix_msg_file="$(mktemp)"

      {
        cat "$CODEX_MD"
        echo
        echo "---"
        echo
        echo "Task ID: $id"
        echo "Title: $title"
        echo
        echo "Previous implementation failed validation. Fix the repository so ALL validation commands pass exactly."
        echo
        echo "Validation commands:"
        VALIDATION_JSON="$validation_json" python3 - <<'PY'
import json
import os

commands = json.loads(os.environ.get("VALIDATION_JSON", "[]"))
for cmd in commands:
    print(f"- {cmd}")
PY
        echo
        echo "Requirements:"
        echo "- Make minimal, targeted fixes."
        echo "- Do not broaden scope beyond this task."
        echo "- Do not modify validation commands or test/build scripts just to make checks pass."
        echo "- If blocked by missing dependencies, tools, network, or permissions, report it explicitly and stop."
        echo "- Re-run relevant checks mentally and leave a short summary."
      } >"$fix_prompt_file"

      local -a fix_cmd
      fix_cmd=(codex exec -C "$REPO_ROOT" -m "$MODEL" -s "$SANDBOX" -o "$fix_msg_file")
      if [[ -n "$REASONING_EFFORT" ]]; then
        fix_cmd+=(-c "model_reasoning_effort=\"$REASONING_EFFORT\"")
      fi
      if [[ "$USE_SEARCH" == "1" ]]; then
        if supports_exec_search; then
          fix_cmd+=(--search)
        fi
      fi

      if ! "${fix_cmd[@]}" - <"$fix_prompt_file" >>"$RUN_LOG" 2>&1; then
        if [[ "$INTERRUPTED" == "1" ]]; then
          python3 "$TASKCTL" mark "$PRD_FILE" "$id" "retry" "interrupted by user during auto-fix; safe to rerun" >>"$RUN_LOG" 2>&1 || true
          log_event "Task $id interrupted by user during auto-fix attempt $attempt"
          rm -f "$prompt_file" "$last_msg" "$validation_output_file" "$fix_prompt_file" "$fix_msg_file"
          return 130
        fi
        log_event "Auto-fix codex exec failed for $id on attempt $attempt"
      else
        {
          echo
          echo
          echo "## Auto-Fix Attempt $attempt"
          cat "$fix_msg_file"
        } >>"$report_abs"
      fi

      if python3 "$TASKCTL" validate "$PRD_FILE" "$id" "$REPO_ROOT" >"$validation_output_file" 2>&1; then
        cat "$validation_output_file" >>"$RUN_LOG"
        validation_ok=1
        log_event "Validation passed for $id after auto-fix attempt $attempt"
      else
        cat "$validation_output_file" >>"$RUN_LOG"
        if [[ "$AUTO_BLOCK_ENV_FAILURE" == "1" ]] && validation_indicates_env_block "$validation_output_file"; then
          python3 "$TASKCTL" mark "$PRD_FILE" "$id" "blocked" "validation blocked by environment/dependencies; see logs/run.log" >>"$RUN_LOG" 2>&1
          log_event "Task $id blocked by environment/dependencies during auto-fix validation"
          rm -f "$prompt_file" "$last_msg" "$validation_output_file" "$fix_prompt_file" "$fix_msg_file"
          return 1
        fi
      fi

      rm -f "$fix_prompt_file" "$fix_msg_file"
      ((attempt++))
    done
  fi

  if [[ "$validation_ok" == "0" ]]; then
    python3 "$TASKCTL" mark "$PRD_FILE" "$id" "failed" "validation failed; see logs/run.log" >>"$RUN_LOG" 2>&1
    log_event "Task $id failed validation"
    rm -f "$prompt_file" "$last_msg" "$validation_output_file"
    return 1
  fi

  # Mark done before commit so task-state updates are included in the same commit.
  python3 "$TASKCTL" mark "$PRD_FILE" "$id" "done" "report=$report_rel;commit_message=$commit_message" >>"$RUN_LOG" 2>&1

  stage_repo_changes
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    log_event "Task $id completed with no commit-able changes"
  else
    if git -C "$REPO_ROOT" commit -m "$commit_message" >>"$RUN_LOG" 2>&1; then
      local sha
      sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
      if [[ "$AUTO_PUSH" == "1" ]]; then
        git -C "$REPO_ROOT" push -u origin "$(git -C "$REPO_ROOT" branch --show-current)" >>"$RUN_LOG" 2>&1
        log_event "Pushed plan branch for $id"
      fi
      log_event "Task $id completed and committed ($sha): $commit_message"
    else
      python3 "$TASKCTL" mark "$PRD_FILE" "$id" "failed" "commit failed; see logs/run.log" >>"$RUN_LOG" 2>&1
      log_event "Task $id failed during commit"
      rm -f "$prompt_file" "$last_msg"
      return 1
    fi
  fi

  rm -f "$prompt_file" "$last_msg" "$validation_output_file"
  return 0
}

parse_args "$@"
require_tools
trap on_interrupt INT TERM

REPO_ROOT="$(git -C "$LOOP_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "Could not determine git repository root from $LOOP_ROOT" >&2
  exit 1
fi

if ! ensure_loop_control_files; then
  exit 1
fi

if [[ "$STATUS_ONLY" == "1" ]]; then
  python3 "$TASKCTL" summary "$PRD_FILE" 2>>"$RUN_LOG" | tee -a "$RUN_LOG"
  exit 0
fi

if [[ "$STATUS_MILESTONES" == "1" ]]; then
  python3 "$TASKCTL" milestones "$PRD_FILE" 2>>"$RUN_LOG" | tee -a "$RUN_LOG"
  exit 0
fi

load_prd_git_config
log_event "Runner start: model=$MODEL reasoning_effort=${REASONING_EFFORT:-default} sandbox=$SANDBOX search=$USE_SEARCH dry_run=$DRY_RUN auto_fix=$AUTO_FIX_VALIDATION auto_block_env=$AUTO_BLOCK_ENV_FAILURE allow_dirty_loop=$ALLOW_DIRTY_LOOP_FILES prep_reset_branches=$PREP_RESET_TASK_BRANCHES max_iterations=$MAX_ITERATIONS base_branch=$PLAN_BASE_BRANCH working_branch=$PLAN_WORKING_BRANCH"

if [[ "$PREP_RESET_TASK_BRANCHES" == "1" ]]; then
  reset_task_branches_to_base
fi

ensure_clean_git
if ! ensure_plan_working_branch; then
  log_event "Failed to checkout plan working branch '$PLAN_WORKING_BRANCH'."
  exit 1
fi
if ! ensure_loop_control_files; then
  log_event "Loop control files are missing on plan branch '$PLAN_WORKING_BRANCH'."
  exit 1
fi
log_event "Using plan branch '$PLAN_WORKING_BRANCH' (base '$PLAN_BASE_BRANCH')."

iter=1
while [[ "$iter" -le "$MAX_ITERATIONS" ]]; do
  if [[ "$INTERRUPTED" == "1" ]]; then
    log_event "Interrupt requested. Stopping loop."
    exit 130
  fi

  if [[ "${HALT:-false}" == "true" || -f "$HALT_FILE" ]]; then
    log_event "HALT detected. Stopping loop."
    break
  fi

  ensure_clean_git
  if ! ensure_loop_control_files; then
    log_event "Stopping loop because control files are missing."
    exit 1
  fi

  task_json="$(get_task_json)"
  if [[ -z "$task_json" ]]; then
    log_event "No pending tasks found."
    break
  fi

  if run_one_task "$task_json"; then
    :
  else
    rc="$?"
    if [[ "$rc" -eq 130 || "$INTERRUPTED" == "1" ]]; then
      log_event "Stopping loop due to user interrupt."
      exit 130
    fi
    if [[ "$rc" -eq 2 ]]; then
      log_event "Continuing loop after retryable task failure."
      sleep "$CODEX_EXEC_RETRY_DELAY_SECONDS"
      ((iter++))
      continue
    fi
    log_event "Stopping loop after failure."
    exit 1
  fi

  if [[ -n "$TASK_ID" ]]; then
    log_event "Specific task mode complete."
    break
  fi

  ((iter++))
done

log_event "Runner finished."
