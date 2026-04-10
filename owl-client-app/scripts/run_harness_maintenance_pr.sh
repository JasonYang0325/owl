#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  run_harness_maintenance_pr.sh --run-dir <run_dir> [options]

Options:
  --run-dir <dir>               Required run directory that contains maintenance artifacts
  --repo-root <dir>              Repository root (default: detected from script location)
  --policy <path>                Policy path to patch
  --report <path>                Maintenance report JSON (default: <run_dir>/maintenance/harness_maintenance_report.json)
  --actions <path>               Actions JSON (default: <run_dir>/maintenance/harness_maintenance_actions.json)
  --patch-summary <path>         PR summary output (default: <run_dir>/harness_maintenance_pr.json)
  --dry-run / --no-dry-run       Preview only / apply changes
  --create-pr / --no-create-pr    Create PR through gh CLI (when not dry-run)
  --allow-dirty / --no-allow-dirty  Allow dirty git working tree
  --help

Environment defaults:
  OWL_MAINTENANCE_PR_DRY_RUN         Set to 1/0 (default 1)
  OWL_MAINTENANCE_PR_CREATE_PR       Set to 1/0 (default 0)
  OWL_MAINTENANCE_PR_ALLOW_DIRTY      Set to 1/0 (default 0)
  OWL_MAINTENANCE_PR_BRANCH_PREFIX    Branch prefix (default: owl/maintenance)
  OWL_MAINTENANCE_PR_BASE_BRANCH      Optional gh base branch
  OWL_MAINTENANCE_PR_SUMMARY_TITLE     PR title override
USAGE
}

RUN_DIR=""
REPO_ROOT="${REPO_ROOT_DEFAULT}"
POLICY_FILE=""
REPORT_FILE=""
ACTIONS_FILE=""
PATCH_SUMMARY_FILE=""

DRY_RUN="${OWL_MAINTENANCE_PR_DRY_RUN:-1}"
CREATE_PR="${OWL_MAINTENANCE_PR_CREATE_PR:-0}"
ALLOW_DIRTY="${OWL_MAINTENANCE_PR_ALLOW_DIRTY:-0}"
BRANCH_PREFIX="${OWL_MAINTENANCE_PR_BRANCH_PREFIX:-owl/maintenance}"
BASE_BRANCH="${OWL_MAINTENANCE_PR_BASE_BRANCH:-}"
PR_TITLE="${OWL_MAINTENANCE_PR_SUMMARY_TITLE:-chore: apply safe harness maintenance actions}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir)
      RUN_DIR="$2"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --policy)
      POLICY_FILE="$2"
      shift 2
      ;;
    --report)
      REPORT_FILE="$2"
      shift 2
      ;;
    --actions)
      ACTIONS_FILE="$2"
      shift 2
      ;;
    --patch-summary)
      PATCH_SUMMARY_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-dry-run)
      DRY_RUN=0
      shift
      ;;
    --create-pr)
      CREATE_PR=1
      shift
      ;;
    --no-create-pr)
      CREATE_PR=0
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --no-allow-dirty)
      ALLOW_DIRTY=0
      shift
      ;;
    --help)
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

RUN_DIR="${RUN_DIR:-${OWL_MAINTENANCE_PR_RUN_DIR:-}}"
if [ -z "$RUN_DIR" ]; then
  echo "Missing required --run-dir or OWL_MAINTENANCE_PR_RUN_DIR"
  usage
  exit 1
fi

REPORT_FILE="${REPORT_FILE:-${OWL_MAINTENANCE_PR_REPORT:-$RUN_DIR/maintenance/harness_maintenance_report.json}}"
ACTIONS_FILE="${ACTIONS_FILE:-${OWL_MAINTENANCE_PR_ACTIONS:-$RUN_DIR/maintenance/harness_maintenance_actions.json}}"
POLICY_FILE="${POLICY_FILE:-${OWL_MAINTENANCE_PR_POLICY:-$SCRIPT_DIR/harness_policy.json}}"
PATCH_SUMMARY_FILE="${PATCH_SUMMARY_FILE:-${OWL_MAINTENANCE_PR_PATCH_SUMMARY:-$RUN_DIR/harness_maintenance_pr.json}}"

PR_BODY_FILE="$RUN_DIR/harness_maintenance_pr_body.md"
PR_LOG_FILE="$RUN_DIR/harness_maintenance_pr.log"

write_summary() {
  local status="$1"
  local branch="$2"
  local commit_sha="$3"
  local pr_url="$4"
  local applied_count="$5"
  local action_count="$6"
  local safe_action_count="$7"
  local pr_title="$8"

  python3 - "$PATCH_SUMMARY_FILE" "$RUN_DIR" "$POLICY_FILE" "$status" \
    "$branch" "$commit_sha" "$pr_url" "$DRY_RUN" "$CREATE_PR" \
    "$applied_count" "$action_count" "$safe_action_count" "$pr_title" "$ACTIONS_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

summary_path = Path(sys.argv[1])
run_dir = sys.argv[2]
policy_path = sys.argv[3]
status = sys.argv[4]
branch = sys.argv[5]
commit_sha = sys.argv[6]
pr_url = sys.argv[7]
dry_run = sys.argv[8] == "1"
create_pr = sys.argv[9] == "1"
applied_count = int(sys.argv[10])
action_count = int(sys.argv[11])
safe_action_count = int(sys.argv[12])
pr_title = sys.argv[13]
actions_path = Path(sys.argv[14])

actions = []
if actions_path.exists():
    raw = json.loads(actions_path.read_text(encoding="utf-8"))
    raw_actions = raw.get("actions", [])
    if isinstance(raw_actions, list):
        actions = [
            {
                "operation": action.get("operation"),
                "target": action.get("target"),
                "issue_id": action.get("issue_id", ""),
            }
            for action in raw_actions[:20]
            if isinstance(action, dict)
        ]

summary = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "run_dir": str(run_dir),
    "policy_path": str(policy_path),
    "status": status,
    "dry_run": dry_run,
    "create_pr_requested": create_pr,
    "action_count": action_count,
    "safe_action_count": safe_action_count,
    "applied_action_count": applied_count,
    "branch": branch,
    "commit_sha": commit_sha,
    "pr_title": pr_title,
    "pr_url": pr_url,
    "actions": actions,
}
summary_path.write_text(json.dumps(summary, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
}

if [ ! -f "$REPORT_FILE" ]; then
  echo "Maintenance report not found: $REPORT_FILE"
  exit 1
fi
if [ ! -f "$ACTIONS_FILE" ]; then
  echo "Maintenance actions not found: $ACTIONS_FILE"
  exit 1
fi
if [ ! -f "$POLICY_FILE" ]; then
  echo "Policy file not found: $POLICY_FILE"
  exit 1
fi

if ! git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Not inside a git repository: $REPO_ROOT"
  exit 1
fi

case "$POLICY_FILE" in
  "$REPO_ROOT"/*)
    ;;
  *)
    echo "Policy file must be inside repository root ($REPO_ROOT): $POLICY_FILE"
    exit 1
    ;;
esac

if [ ! -d "$REPO_ROOT/third_party/owl/owl-client-app" ] && [ ! -d "$REPO_ROOT/owl-client-app" ]; then
  echo "Repository root does not look like Owl project root: $REPO_ROOT"
  exit 1
fi

read -r safe_actions total_actions < <(
  python3 - "$REPORT_FILE" "$ACTIONS_FILE" <<'PY'
import json
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
actions_path = Path(sys.argv[2])

safe_actions = 0
total_actions = 0

if report_path.exists():
    report = json.loads(report_path.read_text(encoding="utf-8"))
    counts = report.get("counts", {})
    if isinstance(counts, dict):
        safe_actions = int(counts.get("safe_actions", 0))

if actions_path.exists():
    actions = json.loads(actions_path.read_text(encoding="utf-8"))
    action_rows = actions.get("actions", [])
    if isinstance(action_rows, list):
        total_actions = len(action_rows)

print(f"{safe_actions} {total_actions}")
PY
)

if [ "$safe_actions" -eq 0 ] || [ "$total_actions" -eq 0 ]; then
  write_summary "no_action" "" "" "" 0 "$total_actions" "$safe_actions" "$PR_TITLE"
  echo "No applicable maintenance actions found."
  exit 0
fi

if [ "$DRY_RUN" = "0" ] && [ "$ALLOW_DIRTY" != "1" ]; then
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    echo "Git working tree is dirty. Set OWL_MAINTENANCE_PR_ALLOW_DIRTY=1 to proceed."
    exit 1
  fi
fi

applied_count="$(python3 - "$ACTIONS_FILE" "$POLICY_FILE" <<'PY'
import json
import sys
from pathlib import Path
from typing import Any, Dict, List

actions_path = Path(sys.argv[1])
policy_path = Path(sys.argv[2])

actions_doc = json.loads(actions_path.read_text(encoding="utf-8"))
actions = actions_doc.get("actions", [])
if not isinstance(actions, list):
    print("0")
    raise SystemExit(1)

policy = json.loads(policy_path.read_text(encoding="utf-8"))


def set_nested(root: Dict[str, Any], target: str, value: List[str]) -> bool:
    cursor: Any = root
    parts = target.split(".")
    for part in parts[:-1]:
        if not isinstance(cursor, dict) or part not in cursor:
            return False
        cursor = cursor[part]
    if not isinstance(cursor, dict):
        return False
    cursor[parts[-1]] = value
    return True


applied = 0
for action in actions:
    if not isinstance(action, dict):
        continue
    if action.get("operation") != "dedupe-string-list":
        continue
    target = action.get("target", "")
    before = action.get("before")
    after = action.get("after")
    if not isinstance(target, str) or not isinstance(before, list) or not isinstance(after, list):
        continue

    cursor: Any = policy
    valid = True
    for part in target.split("."):
        if not isinstance(cursor, dict) or part not in cursor:
            valid = False
            break
        cursor = cursor[part]
    if not valid or cursor != before:
        continue
    if set_nested(policy, target, after):
        applied += 1

if applied > 0:
    policy_path.write_text(json.dumps(policy, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")

print(applied)
PY
)"

if [ "$applied_count" -eq 0 ]; then
  write_summary "applied_no_changes" "" "" "" "$applied_count" "$total_actions" "$safe_actions" "$PR_TITLE"
  echo "No safe actions applied (no policy content drift or incompatible baseline)."
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  write_summary "dry_run" "" "" "" "$applied_count" "$total_actions" "$safe_actions" "$PR_TITLE"
  echo "Dry run complete. Applied actions: $applied_count"
  echo "Use --no-dry-run to commit."
  exit 0
fi

branch="${BRANCH_PREFIX}/harness-maintenance-$(date -u +%Y%m%dT%H%M%SZ)"
original_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"

policy_path_in_repo="$POLICY_FILE"
if [[ "$policy_path_in_repo" == "$REPO_ROOT/"* ]]; then
  policy_path_in_repo="${policy_path_in_repo#$REPO_ROOT/}"
fi

git -C "$REPO_ROOT" checkout -B "$branch"
git -C "$REPO_ROOT" add "$policy_path_in_repo"

if git -C "$REPO_ROOT" diff --cached --quiet -- "$policy_path_in_repo"; then
  git -C "$REPO_ROOT" checkout "$original_branch" >/dev/null
  write_summary "staged_no_changes" "$branch" "" "" "$applied_count" "$total_actions" "$safe_actions" "$PR_TITLE"
  echo "No staged changes after applying actions."
  exit 0
fi

if ! git -C "$REPO_ROOT" commit --no-gpg-sign -m "$PR_TITLE" "$policy_path_in_repo"; then
  git -C "$REPO_ROOT" checkout "$original_branch" >/dev/null
  echo "Failed to commit maintenance patch."
  exit 1
fi
commit_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"

if [ "$CREATE_PR" = "1" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    git -C "$REPO_ROOT" checkout "$original_branch" >/dev/null
    write_summary "create_pr_tool_missing" "$branch" "$commit_sha" "" "$applied_count" "$total_actions" "$safe_actions" "$PR_TITLE"
    echo "gh CLI is required for automatic PR creation."
    exit 1
  fi

  {
    echo "# Automated harness maintenance PR"
    echo
    echo "- Run dir: \`$RUN_DIR\`"
    echo "- Policy: \`$policy_path_in_repo\`"
    echo "- Commit: \`$commit_sha\`"
    echo
    echo "## Summary"
    echo "- Total actions: $total_actions"
    echo "- Safe actions selected: $safe_actions"
    echo "- Applied actions: $applied_count"
    echo
    echo "## Safety"
    echo "- Only dedupe-only safe actions are included."
  } > "$PR_BODY_FILE"

  if [ -n "$BASE_BRANCH" ]; then
    if ! pr_url="$(gh pr create --title "$PR_TITLE" --body-file "$PR_BODY_FILE" --base "$BASE_BRANCH" --head "$branch" 2>"$PR_LOG_FILE")"; then
      git -C "$REPO_ROOT" checkout "$original_branch" >/dev/null
      echo "gh pr create failed."
      exit 1
    fi
  else
    if ! pr_url="$(gh pr create --title "$PR_TITLE" --body-file "$PR_BODY_FILE" --head "$branch" 2>"$PR_LOG_FILE")"; then
      git -C "$REPO_ROOT" checkout "$original_branch" >/dev/null
      echo "gh pr create failed."
      exit 1
    fi
  fi
  write_summary "created" "$branch" "$commit_sha" "$pr_url" "$applied_count" "$total_actions" "$safe_actions" "$PR_TITLE"
  echo "Created PR: $pr_url"
else
  write_summary "committed" "$branch" "$commit_sha" "" "$applied_count" "$total_actions" "$safe_actions" "$PR_TITLE"
  echo "Committed maintenance changes to branch: $branch"
fi

git -C "$REPO_ROOT" checkout "$original_branch" >/dev/null
exit 0
