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
  --search               Enable web search for codex exec (if supported)
  --no-search            Disable web search for codex exec (default)
  --dry-run              Print generated PRD JSON to stdout without writing file
  -h, --help             Show this help

Environment:
  MODEL                  Codex model (default: gpt-5.4)
  REASONING_EFFORT       Optional reasoning effort (low|medium|high, model-dependent)
  SANDBOX                Codex sandbox mode (default: workspace-write)
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

  if [[ ! -f "$SCHEMA_FILE" ]]; then
    echo "Schema file missing: $SCHEMA_FILE" >&2
    exit 1
  fi
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

  python3 - "$last_msg" "$OUT_FILE" "$MODE" "$DRY_RUN" >"$normalized_out" <<'PY'
import datetime as dt
import json
import os
import sys
from typing import Any

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

generated = normalize(load_json(generated_path))

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
