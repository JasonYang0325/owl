#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CYCLE_ROOT="${OWL_MAINTENANCE_CYCLE_DIR:-/tmp/owl_harness/maintenance_cycle}"
RUN_ID="${OWL_MAINTENANCE_CYCLE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="$CYCLE_ROOT/$RUN_ID"
LOCK_DIR="${OWL_MAINTENANCE_CYCLE_LOCK_DIR:-/tmp/owl_harness/maintenance_cycle.lock}"

MAINT_STRICT="${OWL_MAINTENANCE_CYCLE_MAINT_STRICT:-${OWL_MAINTENANCE_CYCLE_STRICT:-0}}"
DOCS_STRICT="${OWL_MAINTENANCE_CYCLE_DOCS_STRICT:-${OWL_MAINTENANCE_CYCLE_STRICT:-0}}"
MAINT_HISTORY_FILE="${OWL_MAINTENANCE_CYCLE_HISTORY_FILE:-$CYCLE_ROOT/maintenance_history.jsonl}"
MAINT_HISTORY_WINDOW="${OWL_MAINTENANCE_CYCLE_HISTORY_WINDOW:-20}"
MAINT_HISTORY_MAX_ROWS="${OWL_MAINTENANCE_CYCLE_HISTORY_MAX_ROWS:-200}"
AUTO_PR_MODE="${OWL_MAINTENANCE_CYCLE_AUTO_PR:-${OWL_MAINTENANCE_CYCLE_CREATE_PR:-0}}"
AUTO_PR_DRY_RUN="${OWL_MAINTENANCE_CYCLE_PR_DRY_RUN:-${OWL_MAINTENANCE_PR_DRY_RUN:-1}}"
AUTO_PR_CREATE="${OWL_MAINTENANCE_CYCLE_PR_CREATE:-${OWL_MAINTENANCE_PR_CREATE_PR:-0}}"
AUTO_PR_FAIL_ON_ERROR="${OWL_MAINTENANCE_CYCLE_PR_FAIL_ON_ERROR:-0}"

mkdir -p "$RUN_DIR"
mkdir -p "$CYCLE_ROOT"

acquire_lock() {
  if [ -d "$LOCK_DIR" ]; then
    local pid_file="$LOCK_DIR/pid"
    if [ -f "$pid_file" ]; then
      local pid
      pid="$(cat "$pid_file")"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "Maintenance cycle already running in another process (pid=$pid). Skipping this invocation."
        exit 0
      fi
      rm -f "$pid_file"
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || {
      echo "Could not acquire maintenance lock: another cycle may be active."
      exit 0
    }
  fi

  mkdir "$LOCK_DIR"
  echo "$$" > "$LOCK_DIR/pid"
  trap 'rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

acquire_lock

MAINT_DIR="$RUN_DIR/maintenance"
mkdir -p "$MAINT_DIR"
MAINT_LOG="$RUN_DIR/harness_maintenance.log"
DOCS_LOG="$RUN_DIR/docs_consistency.log"
SUMMARY_JSON="$RUN_DIR/maintenance_cycle_summary.json"
PR_LOG="$RUN_DIR/harness_maintenance_pr.log"
PR_SUMMARY_JSON="$RUN_DIR/harness_maintenance_pr.json"

AUTO_PR_SUMMARY_FILE=""
AUTO_PR_LOG_FILE=""
if [ "$AUTO_PR_MODE" = "1" ]; then
  AUTO_PR_SUMMARY_FILE="$PR_SUMMARY_JSON"
  AUTO_PR_LOG_FILE="$PR_LOG"
fi

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"

maintenance_rc=0
(
  cd "$SCRIPT_DIR"
  OWL_HARNESS_MAINTENANCE_DIR="$MAINT_DIR" \
  OWL_HARNESS_MAINTENANCE_HISTORY="$MAINT_HISTORY_FILE" \
  OWL_HARNESS_MAINTENANCE_HISTORY_WINDOW="$MAINT_HISTORY_WINDOW" \
  OWL_HARNESS_MAINTENANCE_HISTORY_MAX_ROWS="$MAINT_HISTORY_MAX_ROWS" \
  OWL_HARNESS_MAINTENANCE_STRICT="$MAINT_STRICT" \
  ./run_harness_maintenance.sh
) >"$MAINT_LOG" 2>&1 || maintenance_rc=$?

docs_rc=0
(
  cd "$REPO_ROOT"
  python3 owl-client-app/scripts/check_docs_consistency.py
) >"$DOCS_LOG" 2>&1 || docs_rc=$?

pr_rc=0
if [ "$AUTO_PR_MODE" = "1" ]; then
  (
    cd "$REPO_ROOT"
    OWL_MAINTENANCE_PR_DRY_RUN="$AUTO_PR_DRY_RUN" \
    OWL_MAINTENANCE_PR_CREATE_PR="$AUTO_PR_CREATE" \
    OWL_MAINTENANCE_PR_ALLOW_DIRTY=1 \
    ./owl-client-app/scripts/run_harness_maintenance_pr.sh \
      --run-dir "$RUN_DIR" \
      --patch-summary "$PR_SUMMARY_JSON"
  ) >"$PR_LOG" 2>&1 || pr_rc=$?
fi

END_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
END_EPOCH="$(date +%s)"
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))
OVERALL_RC=0
if [ "$MAINT_STRICT" = "1" ] && [ "$maintenance_rc" -ne 0 ]; then
  OVERALL_RC=1
fi
if [ "$DOCS_STRICT" = "1" ] && [ "$docs_rc" -ne 0 ]; then
  OVERALL_RC=1
fi
if [ "$AUTO_PR_MODE" = "1" ] && [ "$AUTO_PR_FAIL_ON_ERROR" = "1" ] && [ "$pr_rc" -ne 0 ]; then
  OVERALL_RC=1
fi

python3 - \
  "$MAINT_DIR/harness_maintenance_report.json" \
  "$DOCS_LOG" \
  "$MAINT_LOG" \
  "$RUN_DIR" \
  "$MAINT_HISTORY_FILE" \
  "$SUMMARY_JSON" \
  "$START_TS" \
  "$END_TS" \
  "$DURATION_SECONDS" \
  "$maintenance_rc" \
  "$docs_rc" \
  "$pr_rc" \
  "$AUTO_PR_MODE" \
  "$AUTO_PR_DRY_RUN" \
  "$AUTO_PR_CREATE" \
  "$AUTO_PR_SUMMARY_FILE" \
  "$AUTO_PR_LOG_FILE" \
  "$MAINT_STRICT" \
  "$DOCS_STRICT" \
  "$OVERALL_RC" <<'PY'
import json
import sys
from pathlib import Path
from typing import Dict

report_path = Path(sys.argv[1])
docs_log = Path(sys.argv[2])
maint_log = Path(sys.argv[3])
run_dir = Path(sys.argv[4])
history_file = Path(sys.argv[5])
summary_path = Path(sys.argv[6])
start_ts = sys.argv[7]
end_ts = sys.argv[8]
duration_seconds = int(sys.argv[9])
maintenance_rc = int(sys.argv[10])
docs_rc = int(sys.argv[11])
pr_rc = int(sys.argv[12])
auto_pr_mode = sys.argv[13] == "1"
auto_pr_dry_run = sys.argv[14] == "1"
auto_pr_create = sys.argv[15] == "1"
pr_summary_file = Path(sys.argv[16]) if sys.argv[16] else None
pr_log_file = Path(sys.argv[17]) if sys.argv[17] else None
maintenance_strict = sys.argv[18] == "1"
docs_strict = sys.argv[19] == "1"
overall_rc = int(sys.argv[20])

counts = {"critical": 0, "warning": 0, "info": 0, "total": 0, "safe_actions": 0}
action_summary: Dict[str, int] = {"safe": 0, "executed": 0}
has_report = False
if report_path.exists():
    try:
        raw = json.loads(report_path.read_text(encoding="utf-8"))
        has_report = True
        counts.update(raw.get("counts", {}))
        action_summary.update(raw.get("action_summary", {}))
    except Exception:
        has_report = False

summary = {
    "generated_at": end_ts,
    "run_dir": str(run_dir),
    "status": "failed" if overall_rc else "passed",
    "duration_seconds": duration_seconds,
    "started_at": start_ts,
    "ended_at": end_ts,
    "maintenance": {
        "exit_code": maintenance_rc,
        "strict_mode": maintenance_strict,
        "history_file": str(history_file),
        "report_file": str(run_dir / "maintenance" / "harness_maintenance_report.json"),
        "actions_file": str(run_dir / "maintenance" / "harness_maintenance_actions.json"),
    "patch_file": str(run_dir / "maintenance" / "harness_maintenance.patch"),
    "counts": counts,
    "action_summary": action_summary,
    "log_file": str(maint_log),
    "auto_pr": {
      "enabled": auto_pr_mode,
      "dry_run": auto_pr_dry_run,
      "create_pr": auto_pr_create,
      "exit_code": pr_rc,
      "summary_file": str(pr_summary_file) if pr_summary_file else "",
      "log_file": str(pr_log_file) if pr_log_file else "",
    },
    },
    "docs_consistency": {
        "exit_code": docs_rc,
        "strict_mode": docs_strict,
        "report_file": str(docs_log),
    },
    "has_maintenance_report": has_report,
}

status = summary["status"].upper()
lines = [
    "",
    "Harness Maintenance Cycle Summary",
    f"Status: {status}",
    f"Run dir: {run_dir}",
    f"Started: {start_ts}",
    f"Ended: {end_ts}",
    f"Duration: {duration_seconds}s",
    f"Maintenance check: rc={maintenance_rc} strict={maintenance_strict}",
    f"Docs consistency: rc={docs_rc} strict={docs_strict}",
]
if auto_pr_mode:
    lines.append(f"Maintenance PR flow: rc={pr_rc} dry_run={auto_pr_dry_run} create_pr={auto_pr_create}")
if has_report:
    lines.append(
        f"Counts: critical={counts['critical']} warning={counts['warning']} "
        f"info={counts['info']} total={counts['total']} safe_actions={counts['safe_actions']}"
    )
    lines.append(
        f"Actions: safe={action_summary.get('safe', 0)} executed={action_summary.get('executed', 0)}"
    )
summary_path.write_text(json.dumps(summary, ensure_ascii=True, indent=2), encoding="utf-8")
print("\\n".join(lines))
print("")
print(f"Summary written: {summary_path}")
PY

if [ "$OVERALL_RC" -ne 0 ]; then
  exit 1
fi
