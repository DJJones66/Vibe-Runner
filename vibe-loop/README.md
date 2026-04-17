# Vibe Loop (Codex CLI)

Reusable write-enabled task runner.

## Files
- `runner.sh`: main execution loop
  - Supports `--reset-task-branches` (or `PREP_RESET_TASK_BRANCHES=1`) to normalize local task branches before run
  - Supports `ALLOW_DIRTY_LOOP_FILES=1` to allow dirty changes limited to `.codex/vibe-loop/**`
- `generate_prd.sh`: generate `prd.json` from prompt text or markdown via `codex exec`
  - Optional: use `--archive-state` to snapshot current `prd.json`, `reports/`, and `logs/` before replace
  - Includes validation linting to avoid unknown custom-CLI validation traps (for example `command -v <custom-tool>`)
- `archive_state.sh`: manually archive current `prd.json`, `reports/`, and `logs/` into `archive/<timestamp>/`
  - Also captures source plan markdown and a `manifest.txt` when available
  - Optional: `--clear-after-archive` clears live loop artifacts (`prd.json`, `reports/`, `logs/`, `HALT`) after successful archive copy
  - By default with `--clear-after-archive`, local `vibe/task-task-*` branches are reset to current HEAD
- `self_update.sh`: update Vibe Runner in-place from GitHub bootstrap
- `taskctl.py`: task selector, state updates, prompt rendering, validation
- `schemas/prd.schema.json`: output schema used for PRD generation
- `prd.json`: task backlog state
- `CODEX.md`: instruction block injected into each task prompt
- `logs/events.log`: high-level loop events
- `logs/run.log`: full command output

## Usage
```bash
cd .codex/vibe-loop
./runner.sh --status
./runner.sh 1
```
