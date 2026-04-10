#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_SCRIPT="$REPO_ROOT/owl-client-app/scripts/run_harness_maintenance_pr.sh"
POLICY_TEMPLATE="$REPO_ROOT/owl-client-app/scripts/harness_policy.json"

FAILED=0

usage() {
  cat <<USAGE
Usage:
  test_harness_maintenance_pr.sh

This script validates key execution paths of run_harness_maintenance_pr.sh:
  1) dry-run no-action path
  2) no-dry-run commit path
  3) create-pr path when gh is unavailable
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

TMP_DIR="$(mktemp -d -t owl-maint-pr-test-XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

json_value() {
  local file="$1"
  local path="$2"
  python3 - "$file" "$path" <<'PY'
import json
import sys

path = sys.argv[2].split(".")
obj = json.load(open(sys.argv[1], encoding="utf-8"))
for key in path:
    if isinstance(obj, list):
        obj = obj[int(key)]
    else:
        obj = obj[key]
if isinstance(obj, bool):
    print(str(obj).lower())
else:
    print(obj)
PY
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $label (expect '$expected', got '$actual')"
    FAILED=$((FAILED + 1))
  else
    echo "PASS: $label"
  fi
}

assert_command_ok() {
  local cmd_desc="$1"
  shift
  if "$@" >/tmp/test_harness_maintenance_pr.log 2>&1; then
    echo "PASS: $cmd_desc"
  else
    echo "FAIL: $cmd_desc"
    cat /tmp/test_harness_maintenance_pr.log
    FAILED=$((FAILED + 1))
  fi
}

write_json() {
  local file="$1"
  local content="$2"
  printf '%s\n' "$content" >"$file"
}

make_fixture_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir/third_party/owl/owl-client-app/scripts"
  cp "$PR_SCRIPT" "$repo_dir/third_party/owl/owl-client-app/scripts/run_harness_maintenance_pr.sh"
  cp "$POLICY_TEMPLATE" "$repo_dir/third_party/owl/owl-client-app/scripts/harness_policy.json"
  chmod +x "$repo_dir/third_party/owl/owl-client-app/scripts/run_harness_maintenance_pr.sh"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.name "maintenance-pr-test"
  git -C "$repo_dir" config user.email "maintenance-pr-test@example.com"
  git -C "$repo_dir" add "third_party/owl/owl-client-app/scripts/run_harness_maintenance_pr.sh" \
    "third_party/owl/owl-client-app/scripts/harness_policy.json"
  git -C "$repo_dir" commit -q -m "fixture base"
}

set_policy_duplicate_required_use_cases() {
  local policy_file="$1"
  python3 - "$policy_file" <<'PY'
import json
import sys

path = sys.argv[1]
doc = json.loads(open(path, encoding="utf-8").read())
doc["profiles"]["ci-core"]["required_use_cases"] = [
    "cpp_host_smoke",
    "cpp_host_smoke",
    "cross_layer_navigation_dom",
    "cross_layer_navigation_replace_dom",
]
open(path, "w", encoding="utf-8").write(json.dumps(doc, ensure_ascii=True, indent=2) + "\n")
PY
}

write_maintenance_fixtures() {
  local run_dir="$1"
  local mode="$2"
  mkdir -p "$run_dir/maintenance"

  if [[ "$mode" == "no_action" ]]; then
    write_json "$run_dir/maintenance/harness_maintenance_actions.json" '{"actions": []}'
    write_json "$run_dir/maintenance/harness_maintenance_report.json" '{"counts": {"safe_actions": 0}}'
    return
  fi

  local actions='{
  "actions": [
    {
      "operation": "dedupe-string-list",
      "target": "profiles.ci-core.required_use_cases",
      "before": [
        "cpp_host_smoke",
        "cpp_host_smoke",
        "cross_layer_navigation_dom",
        "cross_layer_navigation_replace_dom"
      ],
      "after": [
        "cpp_host_smoke",
        "cross_layer_navigation_dom",
        "cross_layer_navigation_replace_dom"
      ]
    }
  ]
}'
  write_json "$run_dir/maintenance/harness_maintenance_actions.json" "$actions"
  write_json "$run_dir/maintenance/harness_maintenance_report.json" '{"counts": {"safe_actions": 1}}'
}

run_dir="$TMP_DIR/no_action"
repo_dir="$TMP_DIR/repo_no_action"
mkdir -p "$run_dir"
make_fixture_repo "$repo_dir"
write_maintenance_fixtures "$run_dir" "no_action"

echo "--- case 1: dry-run no-action path"
assert_command_ok "dry-run no-action exits 0" \
  "$PR_SCRIPT" \
  --run-dir "$run_dir" \
  --repo-root "$repo_dir" \
  --policy "$repo_dir/third_party/owl/owl-client-app/scripts/harness_policy.json" \
  --patch-summary "$run_dir/harness_maintenance_pr.json" \
  --dry-run
status="$(json_value "$run_dir/harness_maintenance_pr.json" "status")"
assert_eq "$status" "no_action" "dry-run status"

run_dir="$TMP_DIR/no_dry_run_commit"
repo_dir="$TMP_DIR/repo_no_dry"
mkdir -p "$run_dir"
make_fixture_repo "$repo_dir"
set_policy_duplicate_required_use_cases "$repo_dir/third_party/owl/owl-client-app/scripts/harness_policy.json"
write_maintenance_fixtures "$run_dir" "commit"
policy_path="$repo_dir/third_party/owl/owl-client-app/scripts/harness_policy.json"
git -C "$repo_dir" add "$policy_path" >/dev/null
git -C "$repo_dir" commit -q -m "prepare duplicate use case"

echo "--- case 2: no-dry-run commit path"
assert_command_ok "no-dry-run commit exits 0" \
  "$repo_dir/third_party/owl/owl-client-app/scripts/run_harness_maintenance_pr.sh" \
  --run-dir "$run_dir" \
  --repo-root "$repo_dir" \
  --policy "$policy_path" \
  --patch-summary "$run_dir/harness_maintenance_pr.json" \
  --no-dry-run \
  --allow-dirty
status="$(json_value "$run_dir/harness_maintenance_pr.json" "status")"
assert_eq "$status" "committed" "no-dry-run status"
applied_count="$(json_value "$run_dir/harness_maintenance_pr.json" "applied_action_count")"
assert_eq "$applied_count" "1" "applied action count"

commit_sha="$(json_value "$run_dir/harness_maintenance_pr.json" "commit_sha")"
if [[ -z "$commit_sha" ]]; then
  echo "FAIL: missing commit_sha in no-dry-run summary"
  FAILED=$((FAILED + 1))
else
  git -C "$repo_dir" show "$commit_sha:third_party/owl/owl-client-app/scripts/harness_policy.json" > "$TMP_DIR/committed_policy.json"
  python3 - "$TMP_DIR/committed_policy.json" <<'PY'
import json
import sys

policy_path = sys.argv[1]
doc = json.loads(open(policy_path, encoding="utf-8").read())
required_use_cases = doc["profiles"]["ci-core"]["required_use_cases"]
if len(required_use_cases) != len(set(required_use_cases)):
    raise SystemExit("dedupe not applied")
PY
fi

run_dir="$TMP_DIR/create_pr_missing_gh"
repo_dir="$TMP_DIR/repo_missing_gh"
mkdir -p "$run_dir"
make_fixture_repo "$repo_dir"
set_policy_duplicate_required_use_cases "$repo_dir/third_party/owl/owl-client-app/scripts/harness_policy.json"
write_maintenance_fixtures "$run_dir" "commit"
policy_path="$repo_dir/third_party/owl/owl-client-app/scripts/harness_policy.json"
git -C "$repo_dir" add "$policy_path" >/dev/null
git -C "$repo_dir" commit -q -m "prepare duplicate use case"

bin_dir="$TMP_DIR/no-gh-bin"
mkdir -p "$bin_dir"
  for cmd in bash git python3 date dirname mktemp command cat; do
    wrapper="$(command -v "$cmd" || true)"
    if [[ "$cmd" == "bash" ]]; then
      wrapper="/bin/bash"
    fi
    if [[ -z "$wrapper" ]]; then
      wrapper="/bin/$cmd"
    fi
    cat > "$bin_dir/$cmd" <<BIN
#!/bin/sh
exec $wrapper "\$@"
BIN
  done
cat > "$bin_dir/command" <<'BIN'
#!/bin/sh
exec /bin/command "$@"
BIN
chmod +x "$bin_dir"/*

echo "--- case 3: create-pr without gh should fail"
set +e
env PATH="$bin_dir" \
  "$repo_dir/third_party/owl/owl-client-app/scripts/run_harness_maintenance_pr.sh" \
  --run-dir "$run_dir" \
  --repo-root "$repo_dir" \
  --policy "$policy_path" \
  --patch-summary "$run_dir/harness_maintenance_pr.json" \
  --no-dry-run \
  --allow-dirty \
  --create-pr
rc=$?
set -e
if [[ "$rc" -ne 1 ]]; then
  echo "FAIL: create-pr without gh should exit 1 (got $rc)"
  FAILED=$((FAILED + 1))
else
  echo "PASS: create-pr without gh exits 1"
fi
status="$(json_value "$run_dir/harness_maintenance_pr.json" "status")"
assert_eq "$status" "create_pr_tool_missing" "create-pr missing gh status"

if [[ "$FAILED" -ne 0 ]]; then
  echo "FAILED: $FAILED checks failed"
  exit 1
fi

echo "PASS: all checks passed"
exit 0
