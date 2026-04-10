#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="${OWL_HARNESS_MAINTENANCE_DIR:-/tmp/owl_harness/maintenance}"
POLICY_FILE="${OWL_HARNESS_POLICY:-$SCRIPT_DIR/harness_policy.json}"
HISTORY_FILE="${OWL_HARNESS_MAINTENANCE_HISTORY:-$ARTIFACTS_DIR/harness_maintenance_history.jsonl}"
HISTORY_WINDOW="${OWL_HARNESS_MAINTENANCE_HISTORY_WINDOW:-20}"
HISTORY_MAX_ROWS="${OWL_HARNESS_MAINTENANCE_MAX_ROWS:-200}"
STRICT="${OWL_HARNESS_MAINTENANCE_STRICT:-0}"

mkdir -p "$ARTIFACTS_DIR"

echo "Generating harness maintenance artifacts..."
python3 "$SCRIPT_DIR/check_harness_maintenance.py" \
  --policy "$POLICY_FILE" \
  --json "$ARTIFACTS_DIR/harness_maintenance_report.json" \
  --report "$ARTIFACTS_DIR/harness_maintenance_report.md" \
  --actions "$ARTIFACTS_DIR/harness_maintenance_actions.json" \
  --patch "$ARTIFACTS_DIR/harness_maintenance.patch" \
  --history "$HISTORY_FILE" \
  --history-window "$HISTORY_WINDOW" \
  --history-max-rows "$HISTORY_MAX_ROWS" \
  $(if [ "$STRICT" = "1" ]; then echo "--ci"; fi)

echo "Artifacts:"
echo "  json:   $ARTIFACTS_DIR/harness_maintenance_report.json"
echo "  report: $ARTIFACTS_DIR/harness_maintenance_report.md"
echo "  actions: $ARTIFACTS_DIR/harness_maintenance_actions.json"
echo "  patch:  $ARTIFACTS_DIR/harness_maintenance.patch"
echo "  history: $HISTORY_FILE"
