#!/usr/bin/env bash
set -euo pipefail

ACTION="install"
TARGET_REPO="$PWD"
REPO_URL="${VIBE_RUNNER_REPO_URL:-https://github.com/REPLACE_ME/Vide-Runner}"
VERSION="${VIBE_RUNNER_VERSION:-}"
SHA256="${VIBE_RUNNER_SHA256:-}"
CHECKSUM_URL="${VIBE_RUNNER_CHECKSUM_URL:-}"
FORCE="${FORCE:-0}"
ALLOW_UNSIGNED=0
KEEP_TMP=0

usage() {
  cat <<USAGE
Vibe Runner bootstrap installer

Usage:
  bootstrap.sh [options]

Options:
  --action <install|update|uninstall>   Operation to perform (default: install)
  --target <path>                       Target repository path (default: current directory)
  --repo-url <url>                      Repo URL without trailing slash
  --version <tag-or-branch>             Version to install (recommended: tag, e.g. v1.2.3)
  --sha256 <hex>                        Expected SHA256 for downloaded archive
  --checksum-url <url>                  URL to checksums file (format: '<sha>  <filename>')
  --allow-unsigned                      Allow install without checksum verification
  --force                               Overwrite target CODEX.md/prd.json
  --keep-tmp                            Keep temp download directory for debugging
  -h, --help                            Show this help

Environment variable equivalents:
  VIBE_RUNNER_REPO_URL
  VIBE_RUNNER_VERSION
  VIBE_RUNNER_SHA256
  VIBE_RUNNER_CHECKSUM_URL
  FORCE=1

Examples:
  curl -fsSL <raw-url>/bootstrap.sh | bash -s -- --version v1.0.0 --sha256 <sha>
  curl -fsSL <raw-url>/bootstrap.sh | bash -s -- --action update --version v1.1.0 --sha256 <sha>
  curl -fsSL <raw-url>/bootstrap.sh | bash -s -- --action uninstall
USAGE
}

require_tools() {
  command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
  command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
  command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action)
        ACTION="$2"
        shift 2
        ;;
      --target)
        TARGET_REPO="$2"
        shift 2
        ;;
      --repo-url)
        REPO_URL="$2"
        shift 2
        ;;
      --version)
        VERSION="$2"
        shift 2
        ;;
      --sha256)
        SHA256="$2"
        shift 2
        ;;
      --checksum-url)
        CHECKSUM_URL="$2"
        shift 2
        ;;
      --allow-unsigned)
        ALLOW_UNSIGNED=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --keep-tmp)
        KEEP_TMP=1
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

resolve_archive_url() {
  if [[ -z "$VERSION" ]]; then
    VERSION="main"
    echo "[vibe-runner] no --version provided; defaulting to branch '$VERSION' (not pinned)" >&2
  fi

  if [[ "$VERSION" == "main" || "$VERSION" == "master" ]]; then
    printf '%s/archive/refs/heads/%s.tar.gz' "${REPO_URL%/}" "$VERSION"
  else
    printf '%s/archive/refs/tags/%s.tar.gz' "${REPO_URL%/}" "$VERSION"
  fi
}

resolve_sha_from_checksums() {
  local checksums_file="$1"
  local archive_name="$2"

  local line
  line="$(grep -E "[[:space:]]${archive_name}\$" "$checksums_file" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    echo "$line" | awk '{print $1}'
    return
  fi

  awk 'NR==1 {print $1}' "$checksums_file"
}

verify_checksum() {
  local archive_path="$1"
  local expected="$2"

  if [[ -z "$expected" ]]; then
    if [[ "$ALLOW_UNSIGNED" == "1" ]]; then
      echo "[vibe-runner] warning: checksum verification skipped (--allow-unsigned)" >&2
      return 0
    fi
    echo "Checksum is required. Provide --sha256 or --checksum-url, or use --allow-unsigned." >&2
    exit 2
  fi

  local actual
  actual="$(sha256sum "$archive_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for downloaded archive." >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

run_uninstall_only() {
  local dest_loop="$TARGET_REPO/.codex/vibe-loop"
  if [[ -d "$dest_loop" ]]; then
    rm -rf "$dest_loop"
    echo "[vibe-runner] uninstall complete"
    echo "removed: $dest_loop"
  else
    echo "[vibe-runner] nothing to uninstall at $dest_loop"
  fi
}

main() {
  parse_args "$@"

  case "$ACTION" in
    install|update|uninstall)
      ;;
    *)
      echo "Invalid --action: $ACTION" >&2
      usage
      exit 2
      ;;
  esac

  if [[ "$ACTION" == "uninstall" ]]; then
    run_uninstall_only
    exit 0
  fi

  require_tools

  mkdir -p "$TARGET_REPO"
  TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if [[ "$KEEP_TMP" != "1" ]]; then
    trap "rm -rf '$tmp_dir'" EXIT
  fi

  local archive_url
  archive_url="$(resolve_archive_url)"
  local archive_name
  archive_name="$(basename "$archive_url")"
  local archive_path="$tmp_dir/$archive_name"

  echo "[vibe-runner] downloading: $archive_url"
  curl -fsSL "$archive_url" -o "$archive_path"

  if [[ -z "$SHA256" && -n "$CHECKSUM_URL" ]]; then
    local checksums_path="$tmp_dir/checksums.txt"
    curl -fsSL "$CHECKSUM_URL" -o "$checksums_path"
    SHA256="$(resolve_sha_from_checksums "$checksums_path" "$archive_name")"
  fi

  verify_checksum "$archive_path" "$SHA256"

  tar -xzf "$archive_path" -C "$tmp_dir"
  local src_root
  src_root="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"

  if [[ -z "$src_root" || ! -f "$src_root/scripts/install.sh" ]]; then
    echo "Downloaded archive does not contain scripts/install.sh" >&2
    exit 1
  fi

  echo "[vibe-runner] running $ACTION into: $TARGET_REPO"
  FORCE="$FORCE" "$src_root/scripts/install.sh" "$ACTION" "$TARGET_REPO"
}

main "$@"
