#!/bin/bash
# OWL CLI Integration Test
# 前提: OWL Browser 已运行

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OWL="$SCRIPT_DIR/../.build/debug/OWLCLI"
PASS=0
FAIL=0

validate_json() {
    local payload="$1"; shift
    local expected_type="$1"; shift
    python3 - "$expected_type" "$@" <<'PY' <<<"$payload"
import json
import sys

expected_type = sys.argv[1]
required_keys = sys.argv[2:]

try:
    data = json.loads(sys.stdin.read())
except Exception as exc:
    print(f"invalid json: {exc}")
    sys.exit(1)

if expected_type == "object":
    if not isinstance(data, dict):
        print(f"expected object, got {type(data).__name__}")
        sys.exit(1)
    missing = [key for key in required_keys if key not in data]
    if missing:
        print(f"missing keys: {', '.join(missing)}")
        sys.exit(1)
elif expected_type == "array":
    if not isinstance(data, list):
        print(f"expected array, got {type(data).__name__}")
        sys.exit(1)
else:
    print(f"unknown expected type: {expected_type}")
    sys.exit(1)
PY
}

run_test() {
    local name="$1"; shift
    local expected_exit="$1"; shift
    local output
    local exit_code=0
    output=$("$@" 2>&1) || exit_code=$?

    if [[ $exit_code -eq $expected_exit ]]; then
        echo "  ✅ $name"
        ((PASS++))
    else
        echo "  ❌ $name (exit=$exit_code, expected=$expected_exit)"
        echo "     output: $output"
        ((FAIL++))
    fi
}

run_json_test() {
    local name="$1"; shift
    local expected_type="$1"; shift
    local required_keys=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        required_keys+=("$1")
        shift
    done
    shift

    local output
    local exit_code=0
    output=$("$@" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "  ❌ $name (exit=$exit_code, expected=0)"
        echo "     output: $output"
        ((FAIL++))
        return
    fi

    local validation
    if validation=$(validate_json "$output" "$expected_type" "${required_keys[@]}" 2>&1); then
        echo "  ✅ $name"
        ((PASS++))
    else
        echo "  ❌ $name (invalid json output)"
        echo "     output: $output"
        echo "     validation: $validation"
        ((FAIL++))
    fi
}

run_text_contains_test() {
    local name="$1"; shift
    local expected_fragment="$1"; shift
    local output
    local exit_code=0
    output=$("$@" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 && "$output" == *"$expected_fragment"* ]]; then
        echo "  ✅ $name"
        ((PASS++))
    else
        echo "  ❌ $name (expected output containing: $expected_fragment)"
        echo "     output: $output"
        ((FAIL++))
    fi
}

echo "=== OWL CLI Integration Tests ==="

# 基础: 帮助信息
run_test "owl --help shows subcommands" 0 "$OWL" --help

# 导航命令（需浏览器运行）
run_json_test "owl page info returns JSON object" object title url loading -- "$OWL" page info

# Cookie 命令
run_json_test "owl cookie list returns JSON array" array -- "$OWL" cookie list
run_text_contains_test "owl cookie delete prints deleted count" "Deleted " "$OWL" cookie delete nonexistent.example.com

# 清除数据
run_text_contains_test "owl clear-data --cookies prints success" "Browsing data cleared successfully." "$OWL" clear-data --cookies

# 存储用量
run_json_test "owl storage usage returns JSON array" array -- "$OWL" storage usage

# 错误情况（这些不需要浏览器运行就能测）
# run_test "owl unknown command" 1 "$OWL" unknown-cmd

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
