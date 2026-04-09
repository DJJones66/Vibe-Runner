# Vibe Runner

Portable Codex execution loop for project backlogs defined in `prd.json`.

## How To Use
For full setup and operational docs (including all arguments and environment variables), see:
- [HOW_TO_USE.md](HOW_TO_USE.md)

The guide includes PRD generation from prompt or markdown via `.codex/vibe-loop/generate_prd.sh`.

## Repository Layout
- `vibe-loop/`: core runtime files installed into target projects as `.codex/vibe-loop`
- `scripts/install.sh`: local install/update/uninstall using this checkout
- `scripts/bootstrap.sh`: curl-ready remote bootstrap with version + checksum verification
- `scripts/release-checksums.sh`: helper to generate SHA256 lines for release assets

## Quick Start
```bash
# install into current repository
./scripts/install.sh install

# run one task from installed loop
cd .codex/vibe-loop
./runner.sh 1
```
