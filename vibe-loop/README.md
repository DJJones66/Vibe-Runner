# Vibe Loop (Codex CLI)

Reusable write-enabled task runner.

## Files
- `runner.sh`: main execution loop
- `generate_prd.sh`: generate `prd.json` from prompt text or markdown via `codex exec`
  - Optional: use `--archive-state` to snapshot current `prd.json`, `reports/`, and `logs/` before replace
- `archive_state.sh`: manually archive current `prd.json`, `reports/`, and `logs/` into `archive/<timestamp>/`
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
