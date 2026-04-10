#!/bin/bash
# Strict wrapper for release-gate script suites.
# Any skipped/no-op outcome is treated as failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LEVEL="${1:-}"
FILTER="${2:-}"

if [ "$LEVEL" != "cli" ] && [ "$LEVEL" != "xcuitest" ]; then
  echo "[strict-release] usage: $0 [cli|xcuitest]"
  exit 2
fi

TMP_LOG="$(mktemp "/tmp/owl_${LEVEL}_strict_XXXXXX.log")"
if [ "$LEVEL" = "cli" ]; then
  OWL_CLI_SMOKE_ONLY=1 "$SCRIPT_DIR/run_tests.sh" "$LEVEL" >"$TMP_LOG" 2>&1
elif [ "$LEVEL" = "xcuitest" ]; then
  if [ -z "$FILTER" ]; then
    FILTER="OWLBrowserUITests/testSettingsPanelsSmoke"
  fi
  OWL_XCUITEST_TIMEOUT="${OWL_XCUITEST_TIMEOUT:-300}" \
    "$SCRIPT_DIR/run_tests.sh" "$LEVEL" "$FILTER" >"$TMP_LOG" 2>&1
else
  "$SCRIPT_DIR/run_tests.sh" "$LEVEL" >"$TMP_LOG" 2>&1
fi
RUN_RC=$?
cat "$TMP_LOG"

if [ $RUN_RC -ne 0 ]; then
  echo "[strict-release] run_tests.sh exited non-zero: $RUN_RC"
  rm -f "$TMP_LOG"
  exit $RUN_RC
fi

SUMMARY_PATH="/tmp/owl_test_logs/latest/summary.json"
if [ ! -f "$SUMMARY_PATH" ]; then
  echo "[strict-release] missing summary.json at $SUMMARY_PATH"
  rm -f "$TMP_LOG"
  exit 3
fi

python3 - "$SUMMARY_PATH" "$LEVEL" <<'PY'
import json
import sys

summary_path, level = sys.argv[1], sys.argv[2]
with open(summary_path, "r", encoding="utf-8") as f:
    data = json.load(f)

target_name = "CLI Tests" if level == "cli" else "XCUITest"
tests = data.get("tests", [])
target = None
for item in tests:
    if item.get("name") == target_name:
        target = item
        break

if target is None:
    print(f"[strict-release] expected suite '{target_name}' not found in summary")
    sys.exit(10)

status = str(target.get("status", ""))
count = int(target.get("count", 0))
fail = int(target.get("fail", 0))
skipped_total = int(data.get("skipped", 0))

if status != "passed":
    print(f"[strict-release] {target_name} status={status}, expected passed")
    sys.exit(11)
if count <= 0:
    print(f"[strict-release] {target_name} executed 0 test cases")
    sys.exit(12)
if fail > 0:
    print(f"[strict-release] {target_name} has {fail} failing cases")
    sys.exit(13)
if skipped_total > 0:
    print(f"[strict-release] summary reports skipped={skipped_total}, expected 0")
    sys.exit(14)
PY
CHECK_RC=$?

rm -f "$TMP_LOG"

if [ $CHECK_RC -ne 0 ]; then
  exit $CHECK_RC
fi

echo "[strict-release] $LEVEL gate passed with non-skipped execution."
exit 0
