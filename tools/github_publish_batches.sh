#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: github_publish_batches.sh [options]

Options:
  -d, --export-dir DIR   destination directory for export (default: /tmp/owl-github-export)
  -b, --batch N          run only one batch: 1|2|3|4|5
  --skip-export           do not run github_export.sh again; assumes export already exists
  --dry-run               print actions only, do not modify git state
  -h, --help             show this help

Behavior:
  - Runs tools/github_export.sh unless --skip-export is set.
  - Initializes git repo in export dir if needed (unless --dry-run).
  - Commits batches in order:
      1) export boundary files
      2) core runtime bridge/mojom/host/client
      3) app main sources
      4) tests/harness
      5) docs
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export_dir="/tmp/owl-github-export"
batch_filter="all"
dry_run=0
skip_export=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--export-dir)
      export_dir="$2"
      shift 2
      ;;
    -b|--batch)
      batch_filter="$2"
      shift 2
      ;;
    --skip-export)
      skip_export=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

validate_batch() {
  if [[ "$batch_filter" != "all" && ! "$batch_filter" =~ ^[1-5]$ ]]; then
    echo "--batch must be 1,2,3,4,5 or all" >&2
    exit 1
  fi
}

run_export() {
  if (( skip_export == 1 )); then
    return
  fi
  if (( dry_run == 1 )); then
    "${repo_root}/tools/github_export.sh" --dry-run
    return
  fi

  "${repo_root}/tools/github_export.sh" "$export_dir"
}

run_batch() {
  local idx="$1"
  local msg="$2"
  shift 2
  local files=("$@")
  local existing=()

  for item in "${files[@]}"; do
    if [[ -e "$item" ]]; then
      existing+=("$item")
    fi
  done

  if (( ${#existing[@]} == 0 )); then
    echo "[batch $idx] no matching files, skip"
    return
  fi

  if (( dry_run == 1 )); then
    printf '[batch %s] would run: git add %s && git commit -m %q\n' "$idx" "${existing[*]}" "$msg"
    return
  fi

  git add "${existing[@]}"
  if git diff --cached --quiet; then
    echo "[batch $idx] no diff staged, skip commit"
    return
  fi
  git commit -m "$msg"
}

if (( dry_run == 1 )); then
  echo "[dry-run] export_dir=$export_dir"
  echo "[dry-run] batch_filter=$batch_filter"
fi

validate_batch
run_export

if (( dry_run == 1 )); then
  echo "[dry-run] skipping repo init and commits"
else
  mkdir -p "$export_dir"
  cd "$export_dir"
  if [[ ! -d .git ]]; then
    git init
    git checkout -b main
    echo "[git] init and checkout main"
  fi
fi

# Batch 1
if [[ "$batch_filter" == "all" || "$batch_filter" == "1" ]]; then
  run_batch 1 "chore(repo): define github export boundary" \
    ".gitignore" \
    ".github-export-ignore" \
    "README.md" \
    "tools/github_export.sh" \
    "tools/github_publish_batches.sh" \
    "docs/GITHUB_UPLOAD_PLAN.md" \
    "docs/GITHUB_FIRST_PUSH_ORDER.md"
fi

# Batch 2
if [[ "$batch_filter" == "all" || "$batch_filter" == "2" ]]; then
  run_batch 2 "feat(core): bridge + mojom + host/client runtime" \
    "bridge" \
    "mojom" \
    "host" \
    "client" \
    "BUILD.gn"
fi

# Batch 3
if [[ "$batch_filter" == "all" || "$batch_filter" == "3" ]]; then
  run_batch 3 "feat(app): owl-client-app main sources" \
    "owl-client-app/App" \
    "owl-client-app/CLI" \
    "owl-client-app/Models" \
    "owl-client-app/Resources" \
    "owl-client-app/Services" \
    "owl-client-app/ViewModels" \
    "owl-client-app/Views" \
    "owl-client-app/Package.swift" \
    "owl-client-app/Package.resolved" \
    "owl-client-app/project.yml" \
    "owl-client-app/OWLBrowser.xcodeproj" \
    "owl-client-app/OWLBrowser.entitlements"
fi

# Batch 4
if [[ "$batch_filter" == "all" || "$batch_filter" == "4" ]]; then
  run_batch 4 "test(harness): tests + scripts" \
    "owl-client-app/TestKit" \
    "owl-client-app/Tests" \
    "owl-client-app/UITests" \
    "owl-client-app/scripts" \
    "docs/TESTING.md" \
    "docs/TESTING-ROADMAP.md"
fi

# Batch 5
if [[ "$batch_filter" == "all" || "$batch_filter" == "5" ]]; then
  run_batch 5 "docs: architecture and phase docs" \
    "docs/" \
    "owl-client-app/docs/"
fi

if (( dry_run == 1 )); then
  echo "[dry-run] done"
  exit 0
fi

if [[ "$(git status --porcelain | wc -l | tr -d ' ')" != "0" ]]; then
  echo "[warn] there are remaining staged/unstaged changes after batch run"
  git status --short
else
  echo "[done] all requested batches committed"
fi
