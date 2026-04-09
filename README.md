# Vibe Runner

Portable Codex execution loop for project backlogs defined in `prd.json`.

## Repository Layout
- `vibe-loop/`: core runtime files installed into target projects as `.codex/vibe-loop`
- `scripts/install.sh`: local install/update/uninstall using this checkout
- `scripts/bootstrap.sh`: curl-ready remote bootstrap with version + checksum verification
- `scripts/release-checksums.sh`: helper to generate SHA256 lines for release assets

## Local Development Usage
```bash
# install into current repository
./scripts/install.sh install

# update engine files in current repository
./scripts/install.sh update

# uninstall from current repository
./scripts/install.sh uninstall
```

## Curl Bootstrap (Pinned + Verified)
Recommended pattern:
```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- \
    --version v1.0.0 \
    --sha256 <release-archive-sha256>
```

Target a different repo path:
```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- \
    --version v1.0.0 \
    --sha256 <release-archive-sha256> \
    --target /path/to/target/repo
```

Update and uninstall:
```bash
# update
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --action update --version v1.1.0 --sha256 <sha>

# uninstall
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --action uninstall
```

## Checksum Flow
For a release archive, compute checksum:
```bash
./scripts/release-checksums.sh /path/to/v1.0.0.tar.gz
```

That prints lines in standard format:
```text
<sha256>  v1.0.0.tar.gz
```

You can also host a checksums file and install with:
```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/Vide-Runner/main/scripts/bootstrap.sh \
  | bash -s -- --version v1.0.0 --checksum-url https://example.com/checksums.txt
```
