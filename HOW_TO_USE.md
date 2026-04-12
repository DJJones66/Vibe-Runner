# Vibe Runner - How To Use

This guide covers how to install, update, uninstall, and operate Vibe Runner, including all supported arguments and environment variables.

## What Gets Installed
When installed into a target project, Vibe Runner is placed at:

```text
.codex/vibe-loop/
```

Installed files:
- `runner.sh`
- `taskctl.py`
- `CODEX.md`
- `prd.json`
- `logs/`
- `reports/`

## Prerequisites
For local install/update/uninstall:
- `bash`
- `cp`, `mkdir`, `rm`

For runtime task execution (`runner.sh`):
- `codex` CLI (authenticated)
- `python3`
- `git`
- `rg` (recommended for best compatibility in search checks)

For remote bootstrap:
- `curl`
- `tar`
- `sha256sum`

## Before Running Tasks: Choose One Environment Setup
Vibe Runner executes validation commands from your project tasks.  
If your project dependencies are not installed, tasks can fail even when code is correct.

Use one of these three setups before running the loop.

### Option A: Python `venv` (simple local setup)
Best for: most local Python + frontend projects on one machine.

Run from your target project root:

```bash
cd /path/to/your-project
python3 -m venv .venv
source .venv/bin/activate

# install backend deps (example)
pip install -r backend/requirements.txt

# install frontend deps (example)
cd frontend && npm install && cd ..
```

Why this helps:
- Keeps project packages isolated from your system Python.
- Makes Python validations predictable.

Validation command style to prefer in PRD tasks:
- `.venv/bin/python -m pytest ...`
- `.venv/bin/python ...`

### Option B: Conda environment (managed data-science friendly setup)
Best for: teams already using Anaconda/Miniconda.

Run from your target project root:

```bash
cd /path/to/your-project
conda create -n agentic-workflow python=3.12 -y
conda activate agentic-workflow

# install backend deps (example)
pip install -r backend/requirements.txt

# install frontend deps (example)
cd frontend && npm install && cd ..
```

Why this helps:
- Reproducible named environment.
- Easy reset/recreate when dependencies drift.

Validation command style to prefer in PRD tasks:
- `conda run -n agentic-workflow python -m pytest ...`
- `conda run -n agentic-workflow python ...`

### Option C: Docker / Compose (isolated, closest to deployment)
Best for: minimizing host setup differences.

Run from your target project root:

```bash
cd /path/to/your-project
docker compose build
docker compose up -d

# example validations inside containers
docker compose run --rm backend pytest -q
docker compose run --rm frontend npm run build
```

Why this helps:
- No dependency pollution on host machine.
- Consistent tool versions for every run.

Important:
- If you use Docker for validation, write PRD validation commands to call `docker compose run ...` explicitly.
- Otherwise runner will execute host commands and may fail due missing local dependencies.

## Tell The Agent Which Environment You Use (`CODEX.md`)
You can explicitly tell the implementation agent how to run checks in your project.

File to edit in your target project:
- `.codex/vibe-loop/CODEX.md`

Why do this:
- Removes guesswork for the agent.
- Helps the agent run the same commands you would run manually.
- Reduces “works on my machine” mismatches.

Add one short section that matches your setup:

Example for `venv`:
```md
## Project Environment
- Use the Python virtual environment at `.venv`.
- Run Python commands with `.venv/bin/python`.
- Run tests with `.venv/bin/python -m pytest`.
```

Example for `conda`:
```md
## Project Environment
- Use conda environment `agentic-workflow`.
- Run Python commands with `conda run -n agentic-workflow python`.
- Run tests with `conda run -n agentic-workflow python -m pytest`.
```

Example for `docker compose`:
```md
## Project Environment
- Run backend validations in Docker.
- Use `docker compose run --rm backend ...` for backend checks.
- Use `docker compose run --rm frontend ...` for frontend checks.
```

Non-technical checklist:
1. Pick one environment style (`venv`, `conda`, or `docker`).
2. Make sure the setup commands complete successfully.
3. Add matching instructions to `.codex/vibe-loop/CODEX.md`.
4. Generate PRD and run the loop.

## Environment Variable Usage Patterns
Use either style:

```bash
# one-command scope
MODEL=gpt-5.4 REASONING_EFFORT=medium ./runner.sh 1
```

```bash
# shell-session scope
export MODEL=gpt-5.4
export REASONING_EFFORT=medium
./runner.sh 1
```

## 1) Local Installer Script
Path:
- `scripts/install.sh`

Usage:
```bash
./scripts/install.sh install [target_repo]
./scripts/install.sh update [target_repo]
./scripts/install.sh uninstall [target_repo]
```

Arguments:
- `install`
  - Installs Vibe Runner into `target_repo/.codex/vibe-loop`.
- `update`
  - Re-copies engine files into `target_repo/.codex/vibe-loop`.
- `uninstall`
  - Removes `target_repo/.codex/vibe-loop`.
- `[target_repo]` (optional)
  - Path to target project.
  - Default: current directory.

Environment variables:
- `FORCE=1`
  - Overwrites target `CODEX.md` and `prd.json` during `install` or `update`.
  - Default behavior preserves existing `CODEX.md` and `prd.json`.

Examples:
```bash
# install into current directory
./scripts/install.sh install

# install into a specific repo
./scripts/install.sh install /home/hex/Project/Orbis

# update and overwrite CODEX.md/prd.json
FORCE=1 ./scripts/install.sh update /home/hex/Project/Orbis

# uninstall
./scripts/install.sh uninstall /home/hex/Project/Orbis
```

More examples:
```bash
# update current repo in place
./scripts/install.sh update

# force overwrite template files during install
FORCE=1 ./scripts/install.sh install /home/hex/Project/Orbis

# uninstall from current repo
./scripts/install.sh uninstall
```

## 2) Remote Bootstrap Script (curl | bash)
Path:
- `scripts/bootstrap.sh`

Usage:
```bash
bootstrap.sh [options]
```

Options:
- `--action <install|update|uninstall>`
  - Operation to run.
  - Default: `install`.
- `--target <path>`
  - Target repository path.
  - Default: current directory.
- `--repo-url <url>`
  - Vibe Runner repository base URL (no trailing slash).
  - Default: `https://github.com/DJJones66/Vibe-Runner`.
- `--version <tag-or-branch>`
  - Version to fetch.
  - Default: `main`.
  - Recommended: release tag (for example `v1.0.0`).
- `--sha256 <hex>`
  - Expected SHA256 of the downloaded archive.
- `--checksum-url <url>`
  - URL to checksum file in format `<sha>  <filename>`.
  - If provided and `--sha256` is absent, bootstrap resolves expected SHA from this file.
- `--allow-unsigned`
  - Skips checksum requirement.
  - Not recommended for production usage.
- `--force`
  - Passes `FORCE=1` to local installer behavior (overwrite `CODEX.md` and `prd.json`).
- `--keep-tmp`
  - Keeps temp download/extract directory for debugging.
- `-h`, `--help`
  - Shows help text.

Environment variable equivalents:
- `VIBE_RUNNER_REPO_URL`
- `VIBE_RUNNER_VERSION`
- `VIBE_RUNNER_SHA256`
- `VIBE_RUNNER_CHECKSUM_URL`
- `FORCE=1`

Security behavior:
- By default, checksum verification is required.
- Provide either:
  - `--sha256 <hex>`, or
  - `--checksum-url <url>`.
- You can bypass with `--allow-unsigned`, but that is less safe.

Examples:
```bash
# install defaults (current dir target, default repo URL, version main)
curl -fsSL https://raw.githubusercontent.com/DJJones66/Vibe-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --allow-unsigned

# install pinned release with explicit checksum
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --version v1.0.0 --sha256 <sha256>

# update with checksums file lookup
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --action update --version v1.1.0 --checksum-url https://example.com/checksums.txt

# uninstall
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --action uninstall
```

More examples:
```bash
# install into a specific target path
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- \
    --action install \
    --target /home/hex/Project/Orbis \
    --version v1.0.0 \
    --sha256 <sha256>

# use env vars instead of flags
VIBE_RUNNER_VERSION=v1.0.0 \
VIBE_RUNNER_SHA256=<sha256> \
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s --

# use a custom repo URL fork
curl -fsSL https://raw.githubusercontent.com/<your-org>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- \
    --repo-url https://github.com/<your-org>/Vide-Runner \
    --version v1.0.0 \
    --sha256 <sha256>

# dev-only unsigned install (not recommended)
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --version main --allow-unsigned
```

## 3) Running the Loop in a Project
Path in target project:
- `.codex/vibe-loop/runner.sh`

Usage:
```bash
cd .codex/vibe-loop
./runner.sh [max_iterations] [options]
```

Arguments:
- `[max_iterations]` (optional positional integer)
  - Number of tasks to process in this run.
  - Default: `1`.

Options:
- `--task <ID>`
  - Runs only the specified pending/retry task if dependency checks pass.
- `--no-search`
  - Disables Codex web search flag.
- `--search`
  - Enables Codex web search flag (only if `codex exec` supports `--search`).
- `--dry-run`
  - Selects/logs tasks but does not run `codex exec`.
- `--status`
  - Prints task status summary and exits.
- `--status-milestones`
  - Prints milestone progress summary and exits.
- `-h`, `--help`
  - Shows help text.

Environment variables:
- `MODEL`
  - Codex model name.
  - Default: `gpt-5.4`.
- `REASONING_EFFORT`
  - Optional model reasoning effort passed to `codex exec` using `-c model_reasoning_effort="..."`.
  - Common values: `low`, `medium`, `high` (model-dependent).
  - If omitted, Codex default/profile behavior is used.
- `SANDBOX`
  - Codex sandbox mode.
  - Default: `workspace-write`.
- `AUTO_PUSH`
  - `1` pushes branch after successful commit.
  - Default: `0`.
- `AUTO_FIX_VALIDATION`
  - `1` enables auto-fix pass after validation failure.
  - Default: `0` (strict mode).
- `MAX_AUTO_FIX_ATTEMPTS`
  - Number of auto-fix attempts.
  - Default: `1`.
- `AUTO_BLOCK_ENV_FAILURE`
  - `1` marks task `blocked` when validation fails due missing dependencies/tools/network.
  - Default: `1`.
- `HALT=true`
  - Stops before starting next task.

Additional stop control:
- Creating `.codex/vibe-loop/HALT` also stops the loop.

Common examples:
```bash
# status only
./runner.sh --status

# run next 3 tasks
./runner.sh 3

# run specific task id once
./runner.sh --task TASK-010 1

# run with search enabled
./runner.sh 2 --search

# run with explicit reasoning effort
REASONING_EFFORT=high ./runner.sh 1

# dry run
./runner.sh 2 --dry-run
```

More examples:
```bash
# use a different model with lower reasoning effort
MODEL=gpt-5.4 REASONING_EFFORT=low ./runner.sh 1

# use explicit sandbox mode
SANDBOX=workspace-write ./runner.sh 1

# disable auto-fix after validation failures
AUTO_FIX_VALIDATION=0 ./runner.sh 1

# allow up to 3 auto-fix attempts
MAX_AUTO_FIX_ATTEMPTS=3 ./runner.sh 1

# auto-block tasks when validation fails due environment/dependency issues
AUTO_BLOCK_ENV_FAILURE=1 ./runner.sh 1

# push branch automatically after successful commit
AUTO_PUSH=1 ./runner.sh 1

# combine multiple env vars for a tuned run
MODEL=gpt-5.4 REASONING_EFFORT=high AUTO_FIX_VALIDATION=1 MAX_AUTO_FIX_ATTEMPTS=2 ./runner.sh 2 --search
```

Recommended strict production run:
```bash
MODEL=gpt-5.3-codex \
REASONING_EFFORT=high \
SANDBOX=workspace-write \
AUTO_FIX_VALIDATION=0 \
AUTO_BLOCK_ENV_FAILURE=1 \
./runner.sh 9999
```

## 4) Task Controller CLI (`taskctl.py`)
Path in target project:
- `.codex/vibe-loop/taskctl.py`

General usage:
```bash
python3 taskctl.py <command> [args]
```

Commands and arguments:
- `next <prd> [--task <ID>]`
  - Returns next runnable task JSON.
  - Optional `--task` filters to one task ID and validates readiness.
- `mark <prd> <task_id> <status> <note>`
  - Updates task status and appends a history entry.
- `summary <prd>`
  - Prints status counts.
- `milestones <prd>`
  - Prints progress grouped by milestone.
- `field <prd> <task_id> <field> [--json]`
  - Prints a task field.
  - `--json` prints JSON-encoded output.
- `render-prompt <prd> <task_id> <codex_md> <out>`
  - Renders the Codex prompt for a task to output file.
- `validate <prd> <task_id> <repo_root>`
  - Executes each validation command from the task.

Examples:
```bash
# get next runnable task
python3 taskctl.py next prd.json

# mark a task retry
python3 taskctl.py mark prd.json TASK-012 retry "manual retry requested"

# print milestones
python3 taskctl.py milestones prd.json
```

More examples:
```bash
# get a specific task if runnable
python3 taskctl.py next prd.json --task TASK-010

# read a field as JSON
python3 taskctl.py field prd.json TASK-010 validation --json

# render prompt payload to a temp file
python3 taskctl.py render-prompt prd.json TASK-010 CODEX.md /tmp/task-010.prompt.txt

# run validation commands for a task
python3 taskctl.py validate prd.json TASK-010 /path/to/your/repo
```

## 5) Release Checksum Helper
Path:
- `scripts/release-checksums.sh`

Usage:
```bash
./scripts/release-checksums.sh <archive> [archive...]
```

Arguments:
- `<archive>`
  - Path to tarball/asset.
- `[archive...]`
  - Additional archives.

Output format:
```text
<sha256>  <filename>
```

## 6) PRD Generation Script (`generate_prd.sh`)
Path in target project:
- `.codex/vibe-loop/generate_prd.sh`

Purpose:
- Converts either inline prompt text or a markdown spec into a valid `prd.json` using `codex exec`.
- Enforces JSON shape using `.codex/vibe-loop/schemas/prd.schema.json`.

Usage:
```bash
cd .codex/vibe-loop
./generate_prd.sh [options]
```

Input options (choose one):
- `--prompt "<text>"`
  - Generate PRD from inline text.
- `--from-md <file.md>`
  - Generate PRD from markdown file content.

Other options:
- `--out <path>`
  - Output PRD path.
  - Default: `./prd.json`.
- `--mode <replace|append>`
  - `replace`: overwrite output PRD with generated PRD.
  - `append`: append generated tasks into existing PRD.
  - In `append`, script fails if generated task IDs already exist.
- `--search`
  - Enable web search for codex exec (if supported by your CLI build).
- `--no-search`
  - Disable search (default).
- `--dry-run`
  - Print resulting PRD JSON to stdout without writing file.
- `-h`, `--help`
  - Show help text.

Environment variables:
- `MODEL`
  - Model for generation (default: `gpt-5.4`).
- `REASONING_EFFORT`
  - Optional reasoning effort (`low`, `medium`, `high`, model-dependent).
- `SANDBOX`
  - Codex sandbox mode (default: `workspace-write`).

Examples:
```bash
# replace prd.json from a simple prompt
./generate_prd.sh --prompt "Build a SaaS billing backend MVP with auth, subscriptions, invoices, and webhooks."

# generate from markdown spec into a new output file
./generate_prd.sh --from-md /path/to/PRODUCT_PLAN.md --out /tmp/new-prd.json

# preview generated PRD without writing
./generate_prd.sh --from-md /path/to/PRODUCT_PLAN.md --dry-run

# append generated tasks to existing prd.json
./generate_prd.sh --prompt "Add admin dashboard and reporting tasks." --mode append

# run with explicit model + reasoning effort
MODEL=gpt-5.4 REASONING_EFFORT=high ./generate_prd.sh --from-md /path/to/PRODUCT_PLAN.md
```

## 7) `prd.json` Task Expectations
`runner.sh` and `taskctl.py` expect a task list in `prd.json` with fields like:
- `id`
- `title`
- `priority`
- `status` (`pending`, `retry`, `done`, `failed`, etc.)
- `depends_on` (array of task IDs)
- `prompt`
- `acceptance` (array)
- `validation` (array of shell commands)
- `branch` (optional)
- `report` (optional)

If `branch` is missing, default branch naming is:
- `vibe/task-<lowercased-task-id>`

If `report` is missing, default report path is:
- `reports/<TASK_ID>.md`
