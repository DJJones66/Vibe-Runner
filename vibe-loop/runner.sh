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
RESET_DIVERGED_TASK_BRANCH="${RESET_DIVERGED_TASK_BRANCH:-0}"
ALLOW_DIRTY_LOOP_FILES="${ALLOW_DIRTY_LOOP_FILES:-0}"
PREP_RESET_TASK_BRANCHES="${PREP_RESET_TASK_BRANCHES:-0}"
USE_SEARCH=0
AUTO_FIX_VALIDATION="${AUTO_FIX_VALIDATION:-0}"
MAX_AUTO_FIX_ATTEMPTS="${MAX_AUTO_FIX_ATTEMPTS:-1}"
AUTO_BLOCK_ENV_FAILURE="${AUTO_BLOCK_ENV_FAILURE:-1}"
DRY_RUN=0
STATUS_ONLY=0
STATUS_MILESTONES=0
TASK_ID=""
MAX_ITERATIONS=1

mkdir -p "$LOG_DIR" "$REPORT_DIR"

log_event() {
  local msg="$1"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$ts] $msg" | tee -a "$EVENT_LOG"
}

usage() {
  cat <<USAGE
Usage: ./runner.sh [max_iterations] [options]

Options:
  --task <ID>      Run only this pending task id
  --no-search      Disable web search for codex runs
  --search         Enable web search for codex runs (if supported by codex exec)
  --dry-run        Select tasks and log actions only (no codex execution)
  --reset-task-branches  Reset local vibe/task-task-* branches to current HEAD before running
  --status         Print PRD status summary and exit
  --status-milestones  Print PRD milestone progress summary and exit
  -h, --help       Show this help

Environment:
  MODEL            Codex model (default: gpt-5.4)
  REASONING_EFFORT Optional reasoning effort passed via codex config override
  SANDBOX          Codex sandbox mode (default: workspace-write)
  AUTO_PUSH        1 to push branch after successful commit (default: 0)
  RESET_DIVERGED_TASK_BRANCH  1 to auto-reset an existing task branch to the current base if it diverged (default: 0)
  ALLOW_DIRTY_LOOP_FILES  1 to allow dirty changes limited to .codex/vibe-loop/** (default: 0)
  PREP_RESET_TASK_BRANCHES  1 to reset local vibe/task-task-* branches to current HEAD before running (default: 0)
  AUTO_FIX_VALIDATION  1 to let codex attempt one-pass fixes after validation fails (default: 0)
  MAX_AUTO_FIX_ATTEMPTS  Number of validation auto-fix attempts (default: 1)
  AUTO_BLOCK_ENV_FAILURE  1 to mark blocked when validation fails from missing env/deps (default: 1)
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
    'EAI_AGAIN|ENOTFOUND|Temporary failure in name resolution|Could not resolve host|network_access=false|command not found|vitest: not found|pytest: command not found|npm: command not found|node: command not found|python: command not found|python3: command not found|Cannot find module|Cannot find type definition file|ModuleNotFoundError|No module named' \
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
      log_event "Could not reset task branch '$branch' to base $base_short; continuing."
    fi
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/vibe/task-task-*")

  if [[ "$reset_count" -gt 0 ]]; then
    log_event "Reset $reset_count task branches to base $base_short before run."
  else
    log_event "No existing task branches needed reset before run."
  fi
  if [[ "$failed_count" -gt 0 ]]; then
    log_event "$failed_count task branches could not be reset automatically."
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
    log_event "Loop control files are missing. A checked-out task branch likely removed .codex/vibe-loop."
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

checkout_task_branch() {
  local branch="$1"
  local base_ref="$2"
  local current
  local base_short
  current="$(git -C "$REPO_ROOT" branch --show-current)"
  base_short="$(git -C "$REPO_ROOT" rev-parse --short "$base_ref")"

  if [[ "$current" == "$branch" ]]; then
    return 0
  fi

  if git -C "$REPO_ROOT" rev-parse --verify "$branch" >/dev/null 2>&1; then
    if git -C "$REPO_ROOT" merge-base --is-ancestor "$base_ref" "$branch"; then
      git -C "$REPO_ROOT" checkout "$branch" >>"$RUN_LOG" 2>&1
    else
      if [[ "$RESET_DIVERGED_TASK_BRANCH" == "1" ]]; then
        log_event "Branch '$branch' diverged from base $base_short; resetting branch to current base."
        git -C "$REPO_ROOT" checkout -B "$branch" "$base_ref" >>"$RUN_LOG" 2>&1
      else
        log_event "Branch '$branch' diverged from base $base_short; refusing checkout (set RESET_DIVERGED_TASK_BRANCH=1 to auto-reset)."
        return 1
      fi
    fi
  else
    git -C "$REPO_ROOT" checkout -b "$branch" "$base_ref" >>"$RUN_LOG" 2>&1
  fi
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
  local id title branch report_rel report_abs base_ref
  id="$(extract_json_field "$task_json" "id")"
  title="$(extract_json_field "$task_json" "title")"
  branch="$(extract_json_field "$task_json" "branch")"
  report_rel="$(extract_json_field "$task_json" "report")"

  if [[ -z "$branch" ]]; then
    branch="vibe/task-${id,,}"
  fi

  if [[ -z "$report_rel" ]]; then
    report_rel="reports/${id}.md"
  fi

  report_abs="$LOOP_ROOT/$report_rel"
  mkdir -p "$(dirname "$report_abs")"

  log_event "Starting $id on branch '$branch': $title"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_event "Dry run: skipped codex execution for $id"
    return 0
  fi

  base_ref="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
  if ! checkout_task_branch "$branch" "$base_ref"; then
    python3 "$TASKCTL" mark "$PRD_FILE" "$id" "failed" "branch checkout failed; see logs/run.log" >>"$RUN_LOG" 2>&1 || true
    log_event "Task $id failed during branch checkout"
    return 1
  fi
  if ! ensure_loop_control_files; then
    log_event "Task $id failed because required loop files were removed after checkout"
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

  log_event "Running codex exec for $id"
  if ! "${cmd[@]}" - <"$prompt_file" >>"$RUN_LOG" 2>&1; then
    python3 "$TASKCTL" mark "$PRD_FILE" "$id" "failed" "codex exec failed; see logs/run.log" >>"$RUN_LOG" 2>&1
    log_event "Task $id failed during codex exec"
    rm -f "$prompt_file" "$last_msg"
    return 1
  fi

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
  python3 "$TASKCTL" mark "$PRD_FILE" "$id" "done" "report=$report_rel" >>"$RUN_LOG" 2>&1

  stage_repo_changes
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    log_event "Task $id completed with no commit-able changes"
  else
    if git -C "$REPO_ROOT" commit -m "vibe(loop): complete $id - $title" >>"$RUN_LOG" 2>&1; then
      local sha
      sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
      if [[ "$AUTO_PUSH" == "1" ]]; then
        git -C "$REPO_ROOT" push -u origin "$(git -C "$REPO_ROOT" branch --show-current)" >>"$RUN_LOG" 2>&1
        log_event "Pushed branch for $id"
      fi
      log_event "Task $id completed and committed ($sha)"
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

log_event "Runner start: model=$MODEL reasoning_effort=${REASONING_EFFORT:-default} sandbox=$SANDBOX search=$USE_SEARCH dry_run=$DRY_RUN auto_fix=$AUTO_FIX_VALIDATION auto_block_env=$AUTO_BLOCK_ENV_FAILURE allow_dirty_loop=$ALLOW_DIRTY_LOOP_FILES prep_reset_branches=$PREP_RESET_TASK_BRANCHES max_iterations=$MAX_ITERATIONS"

if [[ "$PREP_RESET_TASK_BRANCHES" == "1" ]]; then
  reset_task_branches_to_base
fi

iter=1
while [[ "$iter" -le "$MAX_ITERATIONS" ]]; do
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

  if ! run_one_task "$task_json"; then
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
