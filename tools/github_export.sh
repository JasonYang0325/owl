#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IGNORE_FILE="$ROOT_DIR/.github-export-ignore"
DRY_RUN=0
DEST_DIR="/tmp/owl-github-export"

usage() {
  cat <<'EOF'
Usage:
  tools/github_export.sh [--dry-run] [DEST_DIR]

Examples:
  tools/github_export.sh
  tools/github_export.sh /tmp/owl-github-export-v2
  tools/github_export.sh --dry-run
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

if [[ $# -ge 1 ]]; then
  DEST_DIR="$1"
fi

if [[ ! -f "$IGNORE_FILE" ]]; then
  echo "[github_export] missing ignore file: $IGNORE_FILE" >&2
  exit 1
fi

if [[ "$DEST_DIR" == "/" || "$DEST_DIR" == "$ROOT_DIR" || -z "$DEST_DIR" ]]; then
  echo "[github_export] invalid destination: $DEST_DIR" >&2
  exit 1
fi

echo "[github_export] root: $ROOT_DIR"
echo "[github_export] ignore: $IGNORE_FILE"
echo "[github_export] dest: $DEST_DIR"

if [[ $DRY_RUN -eq 1 ]]; then
  rsync -avn --delete --exclude-from="$IGNORE_FILE" "$ROOT_DIR/" "$DEST_DIR/"
  exit 0
fi

rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

rsync -a --delete --exclude-from="$IGNORE_FILE" "$ROOT_DIR/" "$DEST_DIR/"

(
  cd "$DEST_DIR"
  find . -type f | LC_ALL=C sort > EXPORT_FILE_LIST.txt
)

echo "[github_export] done."
echo "[github_export] size: $(du -sh "$DEST_DIR" | awk '{print $1}')"
echo "[github_export] files: $(find "$DEST_DIR" -type f | wc -l | tr -d ' ')"
echo "[github_export] manifest: $DEST_DIR/EXPORT_FILE_LIST.txt"
