#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$SCRIPT_DIR"
SCHEMA_FILE="$LOOP_ROOT/schemas/prd.schema.json"
OUT_FILE="$LOOP_ROOT/prd.json"

MODEL="${MODEL:-gpt-5.4}"
REASONING_EFFORT="${REASONING_EFFORT:-}"
SANDBOX="${SANDBOX:-workspace-write}"
USE_SEARCH=0
MODE="replace"
ARCHIVE_ON_REPLACE="${ARCHIVE_ON_REPLACE:-0}"
DRY_RUN=0
INPUT_PROMPT=""
INPUT_MD=""

usage() {
  cat <<USAGE
Usage:
  ./generate_prd.sh [options]

Input (choose one):
  --prompt "<text>"      Generate from inline text prompt
  --from-md <file.md>    Generate from markdown spec file

Options:
  --out <path>           Output PRD file path (default: ./prd.json)
  --mode <replace|append>
                         replace: overwrite output PRD
                         append: append generated tasks into existing PRD (fails on duplicate ids)
  --archive-state        Archive existing prd/reports/logs before replace
  --no-archive-state     Disable archival before replace (default)
  --search               Enable web search for codex exec (if supported)
  --no-search            Disable web search for codex exec (default)
  --dry-run              Print generated PRD JSON to stdout without writing file
  -h, --help             Show this help

Environment:
  MODEL                  Codex model (default: gpt-5.4)
  REASONING_EFFORT       Optional reasoning effort (low|medium|high, model-dependent)
  SANDBOX                Codex sandbox mode (default: workspace-write)
  ARCHIVE_ON_REPLACE     1 to archive existing loop state before replace (default: 0)
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt)
        INPUT_PROMPT="$2"
        shift 2
        ;;
      --from-md)
        INPUT_MD="$2"
        shift 2
        ;;
      --out)
        OUT_FILE="$2"
        shift 2
        ;;
      --mode)
        MODE="$2"
        shift 2
        ;;
      --archive-state)
        ARCHIVE_ON_REPLACE=1
        shift
        ;;
      --no-archive-state)
        ARCHIVE_ON_REPLACE=0
        shift
        ;;
      --search)
        USE_SEARCH=1
        shift
        ;;
      --no-search)
        USE_SEARCH=0
        shift
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

require_tools() {
  command -v codex >/dev/null 2>&1 || { echo "codex CLI is required" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
  command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
  command -v rg >/dev/null 2>&1 || { echo "rg is required" >&2; exit 1; }
}

supports_exec_search() {
  codex exec --help 2>/dev/null | rg -q -- '--search'
}

validate_inputs() {
  if [[ -n "$INPUT_PROMPT" && -n "$INPUT_MD" ]]; then
    echo "Use either --prompt or --from-md, not both." >&2
    exit 2
  fi

  if [[ -z "$INPUT_PROMPT" && -z "$INPUT_MD" ]]; then
    echo "You must provide --prompt or --from-md." >&2
    exit 2
  fi

  if [[ -n "$INPUT_MD" && ! -f "$INPUT_MD" ]]; then
    echo "Markdown input not found: $INPUT_MD" >&2
    exit 1
  fi

  if [[ "$MODE" != "replace" && "$MODE" != "append" ]]; then
    echo "Invalid --mode value: $MODE (expected replace or append)" >&2
    exit 2
  fi

  if [[ "$ARCHIVE_ON_REPLACE" != "0" && "$ARCHIVE_ON_REPLACE" != "1" ]]; then
    echo "Invalid ARCHIVE_ON_REPLACE value: $ARCHIVE_ON_REPLACE (expected 0 or 1)" >&2
    exit 2
  fi

  if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "Schema file missing: $SCHEMA_FILE" >&2
    exit 1
  fi
}

archive_current_state() {
  if [[ "$MODE" != "replace" || "$DRY_RUN" == "1" || "$ARCHIVE_ON_REPLACE" != "1" ]]; then
    return 0
  fi

  if [[ ! -f "$LOOP_ROOT/prd.json" && ! -d "$LOOP_ROOT/reports" && ! -d "$LOOP_ROOT/logs" ]]; then
    return 0
  fi

  local ts archive_dir
  ts="$(date -u +"%Y%m%d-%H%M%S")"
  archive_dir="$LOOP_ROOT/archive/$ts"
  if [[ -e "$archive_dir" ]]; then
    archive_dir="${archive_dir}-$$"
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

  echo "Archived previous loop state: $archive_dir"
}

build_source_text() {
  if [[ -n "$INPUT_PROMPT" ]]; then
    echo "$INPUT_PROMPT"
    return
  fi
  cat "$INPUT_MD"
}

main() {
  parse_args "$@"
  require_tools
  validate_inputs

  local repo_root
  repo_root="$(git -C "$LOOP_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    echo "Could not determine git repository root from $LOOP_ROOT" >&2
    exit 1
  fi

  local source_text
  source_text="$(build_source_text)"

  local prompt_file last_msg normalized_out
  prompt_file="$(mktemp)"
  last_msg="$(mktemp)"
  normalized_out="$(mktemp)"

  {
    cat <<'PROMPT_HEADER'
Generate a complete Vibe Runner PRD JSON document.

Requirements:

* Return valid JSON only. Do not include any prose, comments, or markdown.
* Output must be deterministic: identical input must produce identical JSON output.
* Match the provided JSON schema exactly.
* Do not include any fields not defined in the schema.

General:

* Populate all meaningful fields; do not rely on defaults unless necessary.
* Do not include placeholder text such as "TODO", "TBD", or "to be implemented".
* Do not hallucinate tools, APIs, files, or technologies not implied by the input.

Task Structure:

* Generate between 5 and 20 tasks unless the scope clearly requires otherwise.
* Use deterministic task IDs in the format TASK-001, TASK-002, TASK-003, etc.
* Assign priorities as ascending integers starting at 1 (TASK-001 has priority 1, etc.).
* All tasks must have status set to "pending".
* Each task must include: id, title, prompt, priority, status, depends_on, acceptance, validation.
* If the project requires runtime dependencies (for example Python packages, Node modules, toolchains, containers), make the first task an environment-readiness task that verifies prerequisites and installs dependencies.

Task Design:

* Each task must represent a single, atomic, testable unit of work.
* Tasks must not overlap in responsibility.
* Avoid trivial setup-only tasks unless required for execution.
* Avoid combining multiple unrelated concerns into one task.
* Tasks must be written so an autonomous coding agent can execute them without additional clarification.
* Include concrete implementation details when implied (file paths, modules, endpoints, commands).

Dependencies:

* depends_on must only reference valid task IDs present in the output.
* A task may only depend on tasks with lower priority numbers.
* Do not create circular dependencies.
* Only include dependencies when they are strictly necessary.

Acceptance Criteria:

* acceptance must be a list of specific, measurable, binary (pass/fail) conditions.
* Each criterion must describe an observable outcome.
* Avoid vague language such as "works correctly", "is robust", or "is optimized".

Validation Commands:

* validation must be a list of executable shell commands.
* Commands must directly verify the acceptance criteria.
* Use common, widely available tools (bash, python, node, curl, pytest, etc.).
* Commands must be realistic and runnable in a standard development environment.
* Do not include placeholder or non-functional commands.
* If using `python -c`, the inline snippet must be syntactically valid exactly as written.
* Do not place block statements like `def`, `class`, `try`, `for`, `while`, or `if` after semicolons in `python -c` one-liners.
* Do not use no-op validations such as `echo`, `true`, or `exit 0` as substitutes for real checks.
* Do not redefine build/test scripts in task prompts purely to make validation pass.

Consistency:

* Ensure task IDs, priorities, and dependencies are consistent and logically ordered.
* Ensure no duplicate task IDs.
* Ensure all referenced dependencies exist.

PROMPT_HEADER
    echo
    echo "Source input:"
    echo
    echo "$source_text"
  } >"$prompt_file"

  local -a cmd
  cmd=(codex exec -C "$repo_root" -m "$MODEL" -s "$SANDBOX" --output-schema "$SCHEMA_FILE" -o "$last_msg")
  if [[ -n "$REASONING_EFFORT" ]]; then
    cmd+=(-c "model_reasoning_effort=\"$REASONING_EFFORT\"")
  fi
  if [[ "$USE_SEARCH" == "1" ]]; then
    if supports_exec_search; then
      cmd+=(--search)
    else
      echo "codex exec does not support --search on this CLI version; continuing without search." >&2
    fi
  fi

  if ! "${cmd[@]}" - <"$prompt_file" >/dev/null; then
    echo "codex exec failed while generating PRD." >&2
    rm -f "$prompt_file" "$last_msg" "$normalized_out"
    exit 1
  fi

  archive_current_state

  python3 - "$last_msg" "$OUT_FILE" "$MODE" "$DRY_RUN" >"$normalized_out" <<'PY'
import datetime as dt
import json
import os
import re
import shlex
import sys
from typing import Any, Optional

generated_path, out_path, mode, dry_run = sys.argv[1:5]

def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def normalize(prd: dict[str, Any]) -> dict[str, Any]:
    prd.setdefault("project", "Vibe Runner Backlog")
    prd.setdefault("version", "1.0")
    prd.setdefault("notes", {"definition_of_done": "All tasks are done."})
    prd.setdefault("tasks", [])
    prd["updated_at"] = now_iso()

    for task in prd["tasks"]:
        task.setdefault("status", "pending")
        task.setdefault("depends_on", [])
        task.setdefault("acceptance", [])
        task.setdefault("validation", [])

        task_id = str(task.get("id", "")).strip()
        if not task_id:
            raise ValueError("task id is required")

        task.setdefault("report", f"reports/{task_id}.md")
        task.setdefault("branch", f"vibe/task-{task_id.lower()}")

    return prd

def extract_python_c_snippet(command: str) -> Optional[str]:
    try:
        parts = shlex.split(command, posix=True)
    except ValueError as exc:
        raise ValueError(f"invalid shell quoting in validation command: {exc}") from exc

    for idx, token in enumerate(parts):
        base = os.path.basename(token)
        if base not in {"python", "python3", "py"}:
            continue

        j = idx + 1
        while j < len(parts):
            arg = parts[j]
            if arg == "-c":
                if j + 1 >= len(parts):
                    raise ValueError("python -c is missing inline code")
                return parts[j + 1]
            if arg.startswith("-c") and arg != "-c":
                return arg[2:]
            j += 1
        return None

    return None

def looks_like_noop_validation(command: str) -> bool:
    stripped = command.strip()
    lowered = stripped.lower()

    if lowered in {"true", ":", "exit 0"}:
        return True

    if re.fullmatch(r"echo(\s+.+)?", lowered):
        # Bare echo-only command is not a meaningful validation.
        if "|" not in stripped and "&&" not in stripped and ";" not in stripped:
            return True

    return False

def validate_generated_tasks(prd: dict[str, Any]) -> None:
    for task in prd.get("tasks", []):
        task_id = str(task.get("id", "")).strip() or "<missing-id>"
        validations = task.get("validation", [])
        if not isinstance(validations, list):
            raise ValueError(f"task {task_id}: validation must be a list")

        for index, command in enumerate(validations, start=1):
            if not isinstance(command, str) or not command.strip():
                raise ValueError(f"task {task_id}: validation[{index}] must be a non-empty string")

            if looks_like_noop_validation(command):
                raise ValueError(
                    f"task {task_id}: validation[{index}] appears to be a no-op check; "
                    "use a real executable verification command"
                )

            snippet = extract_python_c_snippet(command)
            if snippet is None:
                continue

            try:
                compile(snippet, "<python -c>", "exec")
            except SyntaxError as exc:
                raise ValueError(
                    f"task {task_id}: validation[{index}] has invalid python -c syntax "
                    f"(line {exc.lineno}, column {exc.offset}): {exc.msg}"
                ) from exc

generated = normalize(load_json(generated_path))
validate_generated_tasks(generated)

if mode == "append" and os.path.exists(out_path):
    existing = normalize(load_json(out_path))
    existing_ids = {str(task["id"]) for task in existing.get("tasks", [])}
    new_ids = [str(task["id"]) for task in generated.get("tasks", [])]
    duplicates = sorted(set(new_ids).intersection(existing_ids))
    if duplicates:
        raise ValueError(
            "duplicate task ids found in append mode: " + ", ".join(duplicates)
        )
    existing["tasks"].extend(generated.get("tasks", []))
    existing["updated_at"] = now_iso()
    final = existing
else:
    final = generated

if dry_run == "1":
    print(json.dumps(final, indent=2))
else:
    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(final, f, indent=2)
        f.write("\n")
    print(f"Wrote PRD: {out_path}")
PY

  cat "$normalized_out"
  rm -f "$prompt_file" "$last_msg" "$normalized_out"
}

main "$@"
