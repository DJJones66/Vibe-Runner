#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$SCRIPT_DIR"
SCHEMA_FILE="$LOOP_ROOT/schemas/prd.schema.json"
OUT_FILE="$LOOP_ROOT/prd.json"
LAST_PRD_SOURCE_FILE="$LOOP_ROOT/.last_prd_source"

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

  if [[ -x "$LOOP_ROOT/archive_state.sh" ]]; then
    (
      cd "$LOOP_ROOT"
      ./archive_state.sh --name prd-replace
    )
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

detect_repo_base_branch() {
  local repo_root="$1"
  local branch

  branch="$(git -C "$repo_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  branch="${branch#origin/}"
  if [[ -n "$branch" ]]; then
    echo "$branch"
    return 0
  fi

  if git -C "$repo_root" rev-parse --verify main >/dev/null 2>&1; then
    echo "main"
    return 0
  fi
  if git -C "$repo_root" rev-parse --verify master >/dev/null 2>&1; then
    echo "master"
    return 0
  fi

  branch="$(git -C "$repo_root" branch --show-current)"
  if [[ -n "$branch" ]]; then
    echo "$branch"
    return 0
  fi

  echo "main"
}

persist_last_prd_source() {
  local repo_root="$1"
  local abs_md

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  if [[ -z "$INPUT_MD" ]]; then
    rm -f "$LAST_PRD_SOURCE_FILE"
    return 0
  fi

  if command -v realpath >/dev/null 2>&1; then
    abs_md="$(realpath "$INPUT_MD")"
  else
    abs_md="$(cd "$(dirname "$INPUT_MD")" && pwd)/$(basename "$INPUT_MD")"
  fi

  if [[ -n "$repo_root" && "$abs_md" == "$repo_root/"* ]]; then
    printf '%s\n' "${abs_md#$repo_root/}" >"$LAST_PRD_SOURCE_FILE"
  else
    printf '%s\n' "$abs_md" >"$LAST_PRD_SOURCE_FILE"
  fi
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

  local plan_name_hint source_hash base_branch_hint repo_base_branch_hint
  if [[ -n "$INPUT_MD" ]]; then
    plan_name_hint="$(basename "$INPUT_MD")"
    plan_name_hint="${plan_name_hint%.*}"
  else
    plan_name_hint="prompt-plan"
  fi
  repo_base_branch_hint="$(detect_repo_base_branch "$repo_root")"
  source_hash="$(printf '%s' "$source_text" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:8])')"
  base_branch_hint="$(printf '%s\n' "$source_text" | python3 - <<'PY'
import re
import sys

text = sys.stdin.read()
patterns = [
    r"(?im)^\s*base_branch\s*:\s*([A-Za-z0-9._/\-]+)\s*$",
    r"(?im)^\s*sub_branch_of\s*:\s*([A-Za-z0-9._/\-]+)\s*$",
    r"(?im)^\s*branch_from\s*:\s*([A-Za-z0-9._/\-]+)\s*$",
]
for pattern in patterns:
    m = re.search(pattern, text)
    if m:
        print(m.group(1).strip())
        break
PY
)"

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

Git Strategy:

* Use a single working branch for the full PRD plan and commit each task on that branch.
* Set `git.base_branch` to the repository's primary branch (typically `main` or `master`) unless the source explicitly requests a different base branch.
* If the source includes directives like `base_branch: ...`, `sub_branch_of: ...`, or `branch_from: ...`, use that value for `git.base_branch`.
* Set `git.working_branch` to a stable branch name for this plan (do not use per-task branches).
* Set `git.branch_strategy` to `"plan-branch"`.

Task Structure:

* Generate between 5 and 20 tasks unless the scope clearly requires otherwise.
* Use deterministic task IDs in the format TASK-001, TASK-002, TASK-003, etc.
* Assign priorities as ascending integers starting at 1 (TASK-001 has priority 1, etc.).
* All tasks must have status set to "pending".
* Each task must include: id, title, prompt, priority, status, depends_on, acceptance, validation, commit_message, report.
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
* Do not require project-specific CLI binaries via `command -v <tool>` unless that CLI is already defined by this repository's existing command surface.
* For project-specific functionality, prefer direct repo-native execution (for example `python -m ...`, `python -c ...`, `node path/to/script`, or `./scripts/...`) over custom global CLI assumptions.
* If using `python -c`, the inline snippet must be syntactically valid exactly as written.
* Do not place block statements like `def`, `class`, `try`, `for`, `while`, or `if` after semicolons in `python -c` one-liners.
* Do not use no-op validations such as `echo`, `true`, or `exit 0` as substitutes for real checks.
* Do not redefine build/test scripts in task prompts purely to make validation pass.

Consistency:

* Ensure task IDs, priorities, and dependencies are consistent and logically ordered.
* Ensure no duplicate task IDs.
* Ensure all referenced dependencies exist.

PROMPT_HEADER
    echo "Repository base branch hint: $repo_base_branch_hint"
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

  python3 - "$last_msg" "$OUT_FILE" "$MODE" "$DRY_RUN" "$repo_root" "$source_hash" "$plan_name_hint" "$base_branch_hint" "$repo_base_branch_hint" >"$normalized_out" <<'PY'
import datetime as dt
import json
import os
import re
import shlex
import sys
from typing import Any, Optional

generated_path, out_path, mode, dry_run, repo_root, source_hash, plan_name_hint, base_branch_hint, repo_base_branch_hint = sys.argv[1:10]
repo_root = os.path.abspath(repo_root)

COMMON_COMMAND_V_TOOLS = {
    "bash",
    "sh",
    "python",
    "python3",
    "pip",
    "pip3",
    "node",
    "npm",
    "npx",
    "pnpm",
    "yarn",
    "pytest",
    "uv",
    "git",
    "curl",
    "jq",
    "make",
    "docker",
    "docker-compose",
    "go",
    "java",
    "javac",
    "ruby",
    "bundle",
    "cargo",
    "rustc",
}

def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def slugify(value: Any, fallback: str) -> str:
    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    text = re.sub(r"-{2,}", "-", text).strip("-")
    return text or fallback

def sanitize_branch_name(value: Any) -> str:
    text = str(value or "").strip().replace("\\", "/")
    if not text:
        return ""

    text = re.sub(r"\s+", "-", text)
    text = re.sub(r"[^A-Za-z0-9._/\-]+", "-", text)
    text = re.sub(r"/{2,}", "/", text)
    text = re.sub(r"-{2,}", "-", text)

    parts: list[str] = []
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

def discover_repo_cli_names(root: str) -> set[str]:
    names: set[str] = set()

    if not os.path.isdir(root):
        return names

    candidate_dirs = [
        "scripts",
        "bin",
        ".codex/vibe-loop/bin",
    ]
    for rel_dir in candidate_dirs:
        abs_dir = os.path.join(root, rel_dir)
        if not os.path.isdir(abs_dir):
            continue
        for entry in os.listdir(abs_dir):
            abs_path = os.path.join(abs_dir, entry)
            if not os.path.isfile(abs_path):
                continue
            names.add(entry)
            stem, ext = os.path.splitext(entry)
            if ext in {".sh", ".py", ".bash"} and stem:
                names.add(stem)

    for entry in os.listdir(root):
        abs_path = os.path.join(root, entry)
        if os.path.isfile(abs_path) and os.access(abs_path, os.X_OK):
            names.add(entry)
            stem, ext = os.path.splitext(entry)
            if ext in {".sh", ".py", ".bash"} and stem:
                names.add(stem)

    pyproject_path = os.path.join(root, "pyproject.toml")
    if os.path.isfile(pyproject_path):
        try:
            import tomllib  # Python 3.11+

            with open(pyproject_path, "rb") as f:
                pyproject = tomllib.load(f)
            project_scripts = pyproject.get("project", {}).get("scripts", {})
            if isinstance(project_scripts, dict):
                for key in project_scripts.keys():
                    if isinstance(key, str) and key.strip():
                        names.add(key.strip())
            poetry_scripts = pyproject.get("tool", {}).get("poetry", {}).get("scripts", {})
            if isinstance(poetry_scripts, dict):
                for key in poetry_scripts.keys():
                    if isinstance(key, str) and key.strip():
                        names.add(key.strip())
        except Exception:
            pass

    package_json_path = os.path.join(root, "package.json")
    if os.path.isfile(package_json_path):
        try:
            with open(package_json_path, "r", encoding="utf-8") as f:
                package_data = json.load(f)
            bin_field = package_data.get("bin")
            if isinstance(bin_field, str):
                package_name = package_data.get("name")
                if isinstance(package_name, str) and package_name.strip():
                    names.add(package_name.split("/")[-1])
            elif isinstance(bin_field, dict):
                for key in bin_field.keys():
                    if isinstance(key, str) and key.strip():
                        names.add(key.strip())
        except Exception:
            pass

    return names

def normalize(prd: dict[str, Any]) -> dict[str, Any]:
    prd.setdefault("project", "Vibe Runner Backlog")
    prd.setdefault("version", "1.0")
    prd.setdefault("notes", {"definition_of_done": "All tasks are done."})
    prd.setdefault("tasks", [])
    prd["updated_at"] = now_iso()

    project_slug = slugify(prd.get("project"), "project")
    plan_slug = slugify(plan_name_hint, "plan")
    hash_suffix = slugify(source_hash, "00000000")[:8]
    default_working_branch = f"prd/{project_slug}/{plan_slug}-{hash_suffix}"

    git_cfg = prd.get("git")
    if not isinstance(git_cfg, dict):
        git_cfg = {}
    base_branch = (
        sanitize_branch_name(git_cfg.get("base_branch"))
        or sanitize_branch_name(base_branch_hint)
        or sanitize_branch_name(repo_base_branch_hint)
        or "main"
    )
    working_branch = sanitize_branch_name(git_cfg.get("working_branch")) or default_working_branch
    prd["git"] = {
        "base_branch": base_branch,
        "working_branch": working_branch,
        "branch_strategy": "plan-branch",
    }

    for task in prd["tasks"]:
        task.setdefault("status", "pending")
        task.setdefault("depends_on", [])
        task.setdefault("acceptance", [])
        task.setdefault("validation", [])

        task_id = str(task.get("id", "")).strip()
        if not task_id:
            raise ValueError("task id is required")

        report_value = str(task.get("report", "")).strip()
        if report_value.lower() in {"pending", "retry", "done", "failed", "blocked"}:
            report_value = ""
        task["report"] = report_value or f"reports/{task_id}.md"
        task.pop("branch", None)

        title = str(task.get("title", "")).strip()
        default_commit = f"{task_id}: {title}" if title else f"{task_id}: complete task"
        commit_message = str(task.get("commit_message", "")).strip()
        task["commit_message"] = commit_message or default_commit

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

def extract_bash_lc_inner(command: str) -> Optional[str]:
    m_single = re.match(r"^\s*bash\s+-lc\s+'(.*)'\s*$", command, flags=re.DOTALL)
    if m_single:
        return m_single.group(1)
    m_double = re.match(r'^\s*bash\s+-lc\s+"(.*)"\s*$', command, flags=re.DOTALL)
    if m_double:
        return m_double.group(1)
    return None

def extract_command_v_target(command: str) -> Optional[str]:
    subject = extract_bash_lc_inner(command)
    if subject is None:
        subject = command

    try:
        parts = shlex.split(subject, posix=True)
    except ValueError as exc:
        raise ValueError(f"invalid shell quoting in validation command: {exc}") from exc

    for idx, token in enumerate(parts):
        if token != "command":
            continue
        if idx + 2 >= len(parts):
            continue
        if parts[idx + 1] != "-v":
            continue
        target = parts[idx + 2].strip()
        if not target or target.startswith("-"):
            continue
        return os.path.basename(target)

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

def validate_generated_tasks(prd: dict[str, Any], known_repo_clis: set[str]) -> None:
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

            command_v_target = extract_command_v_target(command)
            if command_v_target:
                if command_v_target not in COMMON_COMMAND_V_TOOLS and command_v_target not in known_repo_clis:
                    raise ValueError(
                        f"task {task_id}: validation[{index}] checks custom CLI '{command_v_target}' with "
                        "`command -v`, but it is not discoverable from this repository. "
                        "Prefer repo-native execution (python -m/python -c/./scripts/*), or validate a known tool."
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
known_repo_clis = discover_repo_cli_names(repo_root)
validate_generated_tasks(generated, known_repo_clis)

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
  persist_last_prd_source "$repo_root"
  rm -f "$prompt_file" "$last_msg" "$normalized_out"
}

main "$@"
