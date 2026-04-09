# Vibe Loop (Codex CLI)

Reusable write-enabled task runner.

## Files
- `runner.sh`: main execution loop
- `taskctl.py`: task selector, state updates, prompt rendering, validation
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
