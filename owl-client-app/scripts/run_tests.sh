#!/bin/bash
# OWL Browser Test Runner — unified entry point for all test levels.
#
# Usage: ./scripts/run_tests.sh [level]
#
#   level:
#     cpp        — C++ GTest only (fastest, no Host needed)
#     unit       — Swift ViewModel unit tests (no Host needed)
#     harness    — code-driven harness (policy+case artifacts+stability gate)
#     integration— Swift cross-layer integration tests (needs Host binary)
#     pipeline   — Swift E2E pipeline tests (needs Host binary)
#     cli        — CLI integration tests (needs OWL Browser running)
#     xcuitest   — XCUITest UI tests (needs signing + GUI)
#     system     — CGEvent system tests (needs GUI session)
#     dual-e2e   — Playwright (CDP) + XCUITest+CDPHelper (dual driver)
#     docs       — documentation consistency lint
#     e2e        — harness (CI-safe, no GUI). Set OWL_LEGACY_E2E=1 for old path.
#     maintenance— periodic harness GC + maintenance scan output + PR smoke test
#     all        — everything
#     (default)  — e2e (= harness)

set +e
# Intentionally not using set -e / pipefail: grep/sed may return non-zero
# in parsing, and we handle failures via FAILED counter.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source "$SCRIPT_DIR/common.sh"

# === Structured log directory ===
setup_log_dir() {
    local base="/tmp/owl_test_logs"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    LOG_DIR="$base/run-$ts"
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_DIR=""
        export OWL_LOG_DIR=""
        return 0
    fi
    export OWL_LOG_DIR="$LOG_DIR"
}
setup_log_dir

# Capture all stdout+stderr to run.log (tee preserves terminal output).
# On macOS bash 3.2, process substitution PIDs are not waited on at exit,
# so we save the tee PID and explicitly wait in cleanup_tee().
TEE_PID=""
if [ -n "$LOG_DIR" ]; then
    exec > >(tee -a "$LOG_DIR/run.log") 2>&1
    TEE_PID=$!
fi

# Flush and wait for tee to finish writing before exit.
cleanup_tee() {
    if [ -n "$TEE_PID" ]; then
        # Close stdout/stderr so tee sees EOF, then wait for it.
        exec 1>&- 2>&-
        wait "$TEE_PID" 2>/dev/null || true
        TEE_PID=""
    fi
}

# Start timer for total duration
_OWL_TEST_START=$(date +%s)

LEVEL="${1:-e2e}"
# Optional test name filter (second argument). Applies to xcuitest and cpp.
TEST_FILTER="${2:-}"
PIPELINE_TIMEOUT="${OWL_TEST_TIMEOUT:-180}"
INTEGRATION_TIMEOUT="${OWL_INTEGRATION_TIMEOUT:-120}"
HARNESS_PROFILE="${OWL_HARNESS_PROFILE:-ci-core}"
HARNESS_TREND_ENABLED="${OWL_HARNESS_FLAKE_TREND:-1}"
HARNESS_TREND_HISTORY="${OWL_HARNESS_TREND_HISTORY:-/tmp/owl_harness_history/history.jsonl}"
HARNESS_TREND_WINDOW="${OWL_HARNESS_TREND_WINDOW:-20}"
HARNESS_TREND_MIN_RUNS="${OWL_HARNESS_TREND_MIN_RUNS:-5}"
HARNESS_TREND_MAX_RATE="${OWL_HARNESS_TREND_MAX_RATE:-0.35}"
HARNESS_TREND_MAX_CONSECUTIVE="${OWL_HARNESS_TREND_MAX_CONSECUTIVE:-2}"

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# Append a JSON test entry to the entries file (for summary.json).
# Usage: append_test_entry name status count pass fail
append_test_entry() {
    [ -z "$LOG_DIR" ] && return 0
    local name="$1" status="$2" count="$3" pass="$4" fail="$5"
    # Escape characters that break JSON: newlines, tabs, backslash, double-quote
    name=$(printf '%s' "$name" | tr '\n\t\r' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"name":"%s","status":"%s","count":%d,"pass":%d,"fail":%d}\n' \
        "$name" "$status" "$count" "$pass" "$fail" >> "$LOG_DIR/.test_entries"
}

report() {
    local name="$1" count="$2" pass="$3" fail="$4"
    TOTAL=$((TOTAL + count))
    PASSED=$((PASSED + pass))
    FAILED=$((FAILED + fail))
    if [ "$fail" -gt 0 ]; then
        echo -e "  ${RED}FAIL${NC} $name: $pass/$count passed, $fail failed"
        append_test_entry "$name" "failed" "$count" "$pass" "$fail"
    else
        echo -e "  ${GREEN}PASS${NC} $name: $pass/$count passed"
        append_test_entry "$name" "passed" "$count" "$pass" "$fail"
    fi
}

skip() {
    local name="$1" reason="$2"
    SKIPPED=$((SKIPPED + 1))
    echo -e "  ${YELLOW}SKIP${NC} $name: $reason"
    append_test_entry "$name" "skipped" 0 0 0
}

# === L0: C++ GTest ===
run_cpp_binary() {
    local target="$1"
    local binary="$BUILD_DIR/$target"

    echo "  Building $target..."
    "$NINJA" -C "$BUILD_DIR" "$target" 2>&1 | tail -3

    if [ ! -f "$binary" ]; then
        skip "$target" "binary not found at $binary"
        return 0
    fi

    local output
    local gtest_args=""
    if [ -n "$TEST_FILTER" ]; then
        gtest_args="--gtest_filter=*${TEST_FILTER}*"
    fi
    output=$("$binary" $gtest_args 2>&1) || true
    # Parse total from last "[N/TOTAL]" line
    local total
    total=$(echo "$output" | command grep -o '\[[0-9]*/[0-9]*\]' | tail -1 | sed 's/.*\///' | sed 's/\]//')
    total=${total:-0}
    if echo "$output" | command grep -q "SUCCESS: all tests passed"; then
        report "$target" "$total" "$total" "0"
    else
        local fail_count
        fail_count=$(echo "$output" | command grep "tests failed" | head -1 | awk '{print $1}')
        fail_count=${fail_count:-0}
        report "$target" "$total" "$((total - fail_count))" "$fail_count"
        # Show failed test names for debugging.
        echo "$output" | command grep "\[  FAILED  \]" 2>/dev/null || true
    fi
}

run_cpp() {
    echo -e "${CYAN}--- C++ GTest ---${NC}"
    run_cpp_binary "owl_host_unittests"
    run_cpp_binary "owl_client_unittests"
}

# === L1b: Swift ViewModel Unit Tests ===
run_unit() {
    echo -e "${CYAN}--- Swift ViewModel Unit Tests ---${NC}"
    local output
    output=$(swift test --filter OWLUnitTests 2>&1)
    local line
    line=$(echo "$output" | command grep "Executed" | tail -1)
    if [ -z "$line" ]; then
        skip "ViewModel Tests" "no test results"
        return 0
    fi
    local total fail
    total=$(echo "$line" | sed 's/.*Executed \([0-9]*\) test.*/\1/')
    fail=$(echo "$line" | sed 's/.*with \([0-9]*\) failure.*/\1/')
    report "ViewModel Tests" "$total" "$((total - fail))" "$fail"
}

# === L1a: Swift Cross-Layer Integration Tests ===
run_integration() {
    echo -e "${CYAN}--- Swift Cross-Layer Integration Tests ---${NC}"
    local host_app="$BUILD_DIR/OWL Host.app/Contents/MacOS/OWL Host"
    local host_bare="$BUILD_DIR/owl_host"
    local host_exec=""

    if [ -f "$host_app" ]; then
        host_exec="$host_app"
    elif [ -f "$host_bare" ]; then
        host_exec="$host_bare"
    else
        skip "Integration Tests" "Host binary not found. Build: $NINJA -C out/owl-host owl_host_app"
        return 0
    fi

    "$NINJA" -C "$BUILD_DIR" third_party/owl/bridge:OWLBridge 2>&1 | tail -1

    local tmpfile
    tmpfile=$(mktemp /tmp/owl_integration_XXXXXX)
    local test_rc=0

    if command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$INTEGRATION_TIMEOUT" \
            env OWL_HOST_PATH="$host_exec" \
            swift test --filter OWLIntegrationTests.OWLIntegrationTests >"$tmpfile" 2>&1
        test_rc=$?
    else
        env OWL_HOST_PATH="$host_exec" \
            swift test --filter OWLIntegrationTests.OWLIntegrationTests >"$tmpfile" 2>&1 &
        local test_pid=$!
        (sleep "$INTEGRATION_TIMEOUT" && kill "$test_pid" 2>/dev/null) >/dev/null 2>&1 &
        local timer_pid=$!
        wait $test_pid 2>/dev/null || true
        kill $timer_pid 2>/dev/null 2>&1; wait $timer_pid 2>/dev/null 2>&1
    fi

    local output
    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [ "$test_rc" -eq 142 ]; then
        skip "Integration Tests" "timed out or no results"
        echo "$output" | tail -5
        return 0
    fi

    local line
    line=$(echo "$output" | command grep "Executed" | tail -1)
    if [ -z "$line" ]; then
        skip "Integration Tests" "timed out or no results"
        echo "$output" | tail -5
        return 0
    fi

    local total fail
    total=$(echo "$line" | sed 's/.*Executed \([0-9]*\) test.*/\1/')
    fail=$(echo "$line" | sed 's/.*with \([0-9]*\) failure.*/\1/')
    report "Integration Tests" "$total" "$((total - fail))" "$fail"

    if [ "$fail" -gt 0 ]; then
        echo "$output" | command grep "failed" | head -10
    fi
}

# === L1: Swift E2E Pipeline Tests ===
run_pipeline() {
    echo -e "${CYAN}--- Swift E2E Pipeline Tests ---${NC}"
    local host_app="$BUILD_DIR/OWL Host.app/Contents/MacOS/OWL Host"
    local host_bare="$BUILD_DIR/owl_host"

    if [ ! -f "$host_app" ] && [ ! -f "$host_bare" ]; then
        skip "Pipeline Tests" "Host binary not found. Build: $NINJA -C out/owl-host owl_host_app"
        return 0
    fi

    # Rebuild OWLBridge.framework if needed
    "$NINJA" -C "$BUILD_DIR" third_party/owl/bridge:OWLBridge 2>&1 | tail -1

    local tmpfile
    tmpfile=$(mktemp /tmp/owl_pipeline_XXXXXX)
    # Match class exactly to avoid pulling in OWLSystemEventTests (GUI-required).
    local test_rc=0
    if command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$PIPELINE_TIMEOUT" \
            swift test --filter OWLBrowserTests.OWLBrowserTests >"$tmpfile" 2>&1
        test_rc=$?
    else
        swift test --filter OWLBrowserTests.OWLBrowserTests >"$tmpfile" 2>&1 &
        local test_pid=$!
        (sleep "$PIPELINE_TIMEOUT" && kill "$test_pid" 2>/dev/null) >/dev/null 2>&1 &
        local timer_pid=$!
        wait $test_pid 2>/dev/null || true
        kill $timer_pid 2>/dev/null 2>&1; wait $timer_pid 2>/dev/null 2>&1
    fi
    local output
    output=$(cat "$tmpfile")
    rm -f "$tmpfile"
    if [ "$test_rc" -eq 142 ]; then
        skip "Pipeline Tests" "timed out or no results"
        echo "$output" | tail -5
        return 0
    fi
    local line
    line=$(echo "$output" | command grep "Executed" | tail -1)
    if [ -z "$line" ]; then
        skip "Pipeline Tests" "timed out or no results"
        echo "$output" | tail -5
        return 0
    fi
    local total fail
    total=$(echo "$line" | sed 's/.*Executed \([0-9]*\) test.*/\1/')
    fail=$(echo "$line" | sed 's/.*with \([0-9]*\) failure.*/\1/')
    report "Pipeline Tests" "$total" "$((total - fail))" "$fail"

    # Show failures if any
    if [ "$fail" -gt 0 ]; then
        echo "$output" | command grep "failed" | head -10
    fi
}

# === L1c: Code-driven Harness (policy + artifacts + stability gate) ===
run_harness() {
    echo -e "${CYAN}--- Code-Driven Harness ---${NC}"
    local policy="$SCRIPT_DIR/harness_policy.json"
    local artifacts
    if [ -n "$LOG_DIR" ]; then
        artifacts="$LOG_DIR/harness"
    else
        artifacts="/tmp/owl_harness/manual-$(date +%Y%m%d-%H%M%S)"
    fi

    if [ ! -f "$policy" ]; then
        echo -e "  ${RED}missing harness policy:${NC} $policy"
        report "Harness" 1 0 1
        return 1
    fi

    local output
    output=$(python3 "$SCRIPT_DIR/run_harness.py" \
        --policy "$policy" \
        --profile "$HARNESS_PROFILE" \
        --project-dir "$SCRIPT_DIR/.." \
        --artifacts-dir "$artifacts" 2>&1)
    local rc=$?

    echo "$output"

    if [ "$HARNESS_TREND_ENABLED" = "1" ] && [ -f "$SCRIPT_DIR/check_flake_trend.py" ]; then
        local summary_file="$artifacts/harness_summary.json"
        if [ -f "$summary_file" ]; then
            echo -e "${CYAN}--- Harness Flake Trend ---${NC}"
            local trend_output trend_rc
            trend_output=$(python3 "$SCRIPT_DIR/check_flake_trend.py" \
                --summary "$summary_file" \
                --history "$HARNESS_TREND_HISTORY" \
                --window "$HARNESS_TREND_WINDOW" \
                --min-runs "$HARNESS_TREND_MIN_RUNS" \
                --max-rate "$HARNESS_TREND_MAX_RATE" \
                --max-consecutive "$HARNESS_TREND_MAX_CONSECUTIVE" 2>&1)
            trend_rc=$?
            echo "$trend_output"
            if [ $trend_rc -ne 0 ]; then
                echo -e "  ${RED}Harness flake trend gate failed.${NC}"
                rc=1
            fi
        fi
    fi

    if [ $rc -eq 0 ]; then
        report "Harness($HARNESS_PROFILE)" 1 1 0
    else
        report "Harness($HARNESS_PROFILE)" 1 0 1
    fi
    return $rc
}

# === L3: XCUITest UI Tests ===
XCUITEST_TIMEOUT="${OWL_XCUITEST_TIMEOUT:-120}"
XCUITEST_LOG_DIR="/tmp/owl_xcuitest_logs"

run_xcuitest() {
    echo -e "${CYAN}--- XCUITest UI Tests ---${NC}"

    if ! command -v xcodebuild &>/dev/null; then
        skip "XCUITest" "xcodebuild not found"
        return 0
    fi

    if [ ! -d "OWLBrowser.xcodeproj" ]; then
        skip "XCUITest" "OWLBrowser.xcodeproj not found"
        return 0
    fi

    # === Log directory setup ===
    mkdir -p "$XCUITEST_LOG_DIR"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local log_full="$XCUITEST_LOG_DIR/${ts}_full.log"
    local log_diag="$XCUITEST_LOG_DIR/${ts}_diagnostic.log"
    # Symlink for easy access
    ln -sf "$log_full" "$XCUITEST_LOG_DIR/latest_full.log"
    ln -sf "$log_diag" "$XCUITEST_LOG_DIR/latest_diagnostic.log"

    # Rebuild OWLBridge.framework + Host app
    "$NINJA" -C "$BUILD_DIR" owl_host_app third_party/owl/bridge:OWLBridge 2>&1 | tail -1

    # Phase 1: compile only (build-for-testing), no || true — compilation
    # failures must surface immediately.
    echo "  Compiling XCUITests..."
    local build_output
    build_output=$(xcodebuild build-for-testing \
        -project OWLBrowser.xcodeproj \
        -scheme OWLBrowserUITests \
        -destination 'platform=macOS' \
        -derivedDataPath /tmp/owl_xctest \
        2>&1)
    local build_rc=$?

    if [ $build_rc -ne 0 ]; then
        echo -e "  ${RED}XCUITest compilation failed:${NC}"
        echo "$build_output" | command grep "error:" | head -10
        echo "$build_output" > "$log_full"
        echo -e "  Log: $log_full"
        report "XCUITest" 0 0 1
        return 1
    fi

    # Phase 2: run tests (test-without-building) with timeout.
    local filter_flag=""
    if [ -n "$TEST_FILTER" ]; then
        filter_flag="-only-testing:OWLBrowserUITests/$TEST_FILTER"
        echo "  Running XCUITest filter: $TEST_FILTER (timeout ${XCUITEST_TIMEOUT}s)..."
    else
        echo "  Running XCUITests (timeout ${XCUITEST_TIMEOUT}s)..."
    fi
    local xc_tmpfile
    xc_tmpfile=$(mktemp /tmp/owl_xcuitest_XXXXXX)
    xcodebuild test-without-building \
        -project OWLBrowser.xcodeproj \
        -scheme OWLBrowserUITests \
        -destination 'platform=macOS' \
        -derivedDataPath /tmp/owl_xctest \
        $filter_flag \
        >"$xc_tmpfile" 2>&1 &
    local xc_pid=$!
    (sleep "$XCUITEST_TIMEOUT" && kill $xc_pid 2>/dev/null) &
    local timer_pid=$!
    wait $xc_pid 2>/dev/null
    local test_rc=$?
    kill $timer_pid 2>/dev/null 2>&1; wait $timer_pid 2>/dev/null 2>&1
    local test_output
    test_output=$(cat "$xc_tmpfile")
    rm -f "$xc_tmpfile"

    # === Save full log ===
    echo "$test_output" > "$log_full"

    # === Extract diagnostic log (structured for agent analysis) ===
    {
        echo "=== OWL XCUITest Diagnostic Log ==="
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Timeout: ${XCUITEST_TIMEOUT}s"
        echo "Exit code: $test_rc"
        echo ""

        echo "--- Test Results ---"
        echo "$test_output" | command grep "Test Case" || true
        echo ""

        echo "--- Assertion Failures ---"
        echo "$test_output" | command grep -E "error:.*XCT|error:.*failed|error:.*Failed" || true
        echo ""

        echo "--- App Logs ([OWL]) ---"
        echo "$test_output" | command grep "\[OWL\]" || true
        echo ""

        echo "--- Navigation Events ---"
        echo "$test_output" | command grep -E "Navigate|navigate|PageInfo|loadingProgress" || true
        echo ""

        echo "--- Bridge/Mojo Errors ---"
        echo "$test_output" | command grep -E "disconnected|not found|nullptr|DCHECK|FATAL" || true
        echo ""

        echo "--- Accessibility/UI ---"
        echo "$test_output" | command grep -E "identifier.*tab|sidebar|addressBar|keyboard focus|synthesize" || true
        echo ""

        echo "--- xcresult Bundle ---"
        echo "$test_output" | command grep "\.xcresult" | tail -1 || true
    } > "$log_diag"

    # SIGTERM from timeout → exit code 143 (128 + 15)
    if [ $test_rc -eq 143 ] || [ $test_rc -eq 137 ]; then
        echo -e "  ${YELLOW}XCUITest timed out (${XCUITEST_TIMEOUT}s) — may need Accessibility permission${NC}"
        echo "$test_output" | tail -5
        report "XCUITest" 0 0 0
        echo -e "  Logs: $XCUITEST_LOG_DIR/latest_*.log"
        return 0
    fi

    # Parse results
    local total pass fail
    total=$(echo "$test_output" | command grep "Test Case" | command grep -c "started" || true)
    pass=$(echo "$test_output" | command grep "Test Case" | command grep -c "passed" || true)
    fail=$(echo "$test_output" | command grep "Test Case" | command grep -c "failed" || true)
    total=${total:-0}
    pass=${pass:-0}
    fail=${fail:-0}

    # 0/0 likely means automation-mode failure; show tail for diagnosis
    if [ "$total" -eq 0 ]; then
        echo -e "  ${YELLOW}No test results detected. Last output:${NC}"
        echo "$test_output" | tail -5
    fi

    report "XCUITest" "$total" "$pass" "$fail"

    if [ "$fail" -gt 0 ]; then
        echo "$test_output" | command grep "failed" | head -10
    fi

    # Always print log paths for post-mortem analysis
    echo -e "  ${CYAN}Logs:${NC}"
    echo "    Full:       $XCUITEST_LOG_DIR/latest_full.log"
    echo "    Diagnostic: $XCUITEST_LOG_DIR/latest_diagnostic.log"
}

# === L2: CGEvent System Tests ===
run_system() {
    echo -e "${CYAN}--- CGEvent System Tests ---${NC}"
    echo -e "  ${YELLOW}WARNING${NC}: Do NOT move mouse or type during this test!"

    swift build --product OWLUITest 2>&1 | tail -1
    local output
    output=$(.build/debug/OWLUITest 2>&1) || true
    local total pass fail
    pass=$(echo "$output" | command grep -c "PASS")
    fail=$(echo "$output" | command grep -c "FAIL")
    total=$((pass + fail))
    report "CGEvent System" "$total" "$pass" "$fail"
}

# === CLI Integration Tests ===
run_cli() {
    echo -e "${CYAN}--- CLI Integration Tests ---${NC}"

    local cli_binary
    cli_binary="$SCRIPT_DIR/../.build/debug/OWLCLI"
    if [ ! -f "$cli_binary" ]; then
        skip "CLI Tests" "OWLCLI binary not found. Build: swift build --product OWLCLI"
        return 0
    fi

    # Release smoke mode: deterministic, no running browser prerequisite.
    if [ "${OWL_CLI_SMOKE_ONLY:-0}" = "1" ]; then
        local help_output help_rc
        help_output=$("$cli_binary" --help 2>&1)
        help_rc=$?
        if [ $help_rc -eq 0 ]; then
            report "CLI Tests" 1 1 0
        else
            report "CLI Tests" 1 0 1
            echo "  ❌ owl --help failed (exit=$help_rc)"
            echo "     output: $help_output"
        fi
        return 0
    fi

    local cli_script
    cli_script="$SCRIPT_DIR/test_cli.sh"

    if [ ! -f "$cli_script" ]; then
        skip "CLI Tests" "test_cli.sh not found"
        return 0
    fi

    local output
    output=$("$cli_script" 2>&1) || true
    local pass fail
    pass=$(echo "$output" | command grep -c "✅" || true)
    fail=$(echo "$output" | command grep -c "❌" || true)
    local total=$((pass + fail))
    report "CLI Tests" "$total" "$pass" "$fail"

    if [ "$fail" -gt 0 ]; then
        echo "$output" | command grep "❌" | head -10
    fi
}

# === Lint: Docs consistency ===
run_docs_lint() {
    if [ ! -f "scripts/check_architecture_boundaries.py" ]; then
        skip "Architecture Lint" "scripts/check_architecture_boundaries.py not found"
    else
        echo -e "${CYAN}--- Architecture Boundary Lint ---${NC}"
        local arch_output arch_rc
        arch_output=$(python3 scripts/check_architecture_boundaries.py 2>&1)
        arch_rc=$?
        echo "$arch_output"
        if [ $arch_rc -eq 0 ]; then
            report "Architecture Lint" 1 1 0
        else
            report "Architecture Lint" 1 0 1
        fi
        echo ""
    fi

    if [ ! -f "scripts/check_harness_quality.py" ]; then
        skip "Harness Policy Lint" "scripts/check_harness_quality.py not found"
    else
        echo -e "${CYAN}--- Harness Policy Lint ---${NC}"
        local policy_output policy_rc
        policy_output=$(python3 scripts/check_harness_quality.py 2>&1)
        policy_rc=$?
        echo "$policy_output"
        if [ $policy_rc -eq 0 ]; then
            report "Harness Policy Lint" 1 1 0
        else
            report "Harness Policy Lint" 1 0 1
        fi
        echo ""
    fi

    if [ ! -f "scripts/check_docs_consistency.py" ]; then
        skip "Docs Lint" "scripts/check_docs_consistency.py not found"
        return 0
    fi

    echo -e "${CYAN}--- Docs Consistency Lint ---${NC}"
    local output rc
    output=$(python3 scripts/check_docs_consistency.py 2>&1)
    rc=$?
    echo "$output"
    if [ $rc -eq 0 ]; then
        report "Docs Lint" 1 1 0
    else
        report "Docs Lint" 1 0 1
    fi
    echo ""
}

# === Harness maintenance / periodic GC scan ===
run_maintenance() {
    echo -e "${CYAN}--- Harness Maintenance ---${NC}"
    local maint_script="$SCRIPT_DIR/run_harness_maintenance.sh"
    local maint_pr_test_script="$SCRIPT_DIR/test_harness_maintenance_pr.sh"
    if [ ! -f "$maint_script" ] || [ ! -x "$maint_script" ]; then
        skip "Harness Maintenance" "run_harness_maintenance.sh not found or not executable"
        return 0
    fi

    local maintenance_output
    maintenance_output=$("$maint_script" 2>&1)
    local maint_rc=$?
    echo "$maintenance_output"

    if [ $maint_rc -eq 0 ]; then
        report "Harness Maintenance" 1 1 0
    else
        report "Harness Maintenance" 1 0 1
    fi

    if [ ! -x "$maint_pr_test_script" ]; then
        skip "Harness Maintenance PR Smoke" "test_harness_maintenance_pr.sh not found or not executable"
        return 0
    fi

    local maint_pr_test_output
    maint_pr_test_output=$("$maint_pr_test_script" 2>&1)
    local maint_pr_test_rc=$?
    echo "$maint_pr_test_output"
    if [ $maint_pr_test_rc -eq 0 ]; then
        report "Harness Maintenance PR Smoke" 1 1 0
    else
        report "Harness Maintenance PR Smoke" 1 0 1
    fi
}

# === Lint: XCUITest compliance + docs consistency ===
run_lint() {
    if [ -f "scripts/check_xcuitest.py" ]; then
        echo -e "${CYAN}--- XCUITest Lint ---${NC}"
        local output rc
        output=$(python3 scripts/check_xcuitest.py 2>&1)
        rc=$?
        echo "$output" | tail -20
        if [ $rc -eq 0 ]; then
            report "XCUITest Lint" 1 1 0
        else
            report "XCUITest Lint" 1 0 1
        fi
        echo ""
    else
        skip "XCUITest Lint" "scripts/check_xcuitest.py not found"
    fi

    run_docs_lint
}

# === Write summary.json and update latest symlink ===
write_summary() {
    [ -z "$LOG_DIR" ] && return 0

    local end_ts
    end_ts=$(date +%s)
    local duration=$(( end_ts - _OWL_TEST_START ))
    local iso_ts
    iso_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # JSON-escape LEVEL to prevent injection via crafted input
    local safe_level
    safe_level=$(printf '%s' "$LEVEL" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Build the tests array from collected entries (paste handles missing trailing newline)
    local tests_json
    if [ -f "$LOG_DIR/.test_entries" ]; then
        tests_json="[$(paste -sd ',' "$LOG_DIR/.test_entries")]"
        rm -f "$LOG_DIR/.test_entries"
    else
        tests_json="[]"
    fi

    # Atomic write: tmp then mv
    cat > "$LOG_DIR/.summary.tmp" <<ENDJSON
{
  "timestamp": "$iso_ts",
  "duration_seconds": $duration,
  "level": "$safe_level",
  "total": $TOTAL,
  "passed": $PASSED,
  "failed": $FAILED,
  "skipped": $SKIPPED,
  "log_dir": "$LOG_DIR",
  "tests": $tests_json
}
ENDJSON
    mv "$LOG_DIR/.summary.tmp" "$LOG_DIR/summary.json"

    # Update latest symlink only after summary.json is written
    ln -sfn "$LOG_DIR" /tmp/owl_test_logs/latest

    echo -e "  ${CYAN}Logs:${NC} $LOG_DIR"
}

# === Dual E2E helpers ===

# Global PID for cleanup (must be global so trap handler can access it)
OWL_APP_PID=""

section() {
    echo ""
    echo -e "${CYAN}=== $1 ===${NC}"
}

# Check if code signing identity is available for XCUITest
has_signing() {
    local count
    count=$(security find-identity -v -p codesigning 2>/dev/null \
        | command grep "valid identities found" | awk '{print $1}')
    [ "${count:-0}" -gt 0 ]
}

# Kill app + orphan Host processes
cleanup_owl_processes() {
    # 1. SIGTERM app (triggers applicationWillTerminate -> shutdown -> kill host)
    if [ -n "$OWL_APP_PID" ] && kill -0 "$OWL_APP_PID" 2>/dev/null; then
        kill "$OWL_APP_PID" 2>/dev/null
        # Wait for graceful exit (up to 5s)
        for i in $(seq 1 50); do
            kill -0 "$OWL_APP_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$OWL_APP_PID" 2>/dev/null || true
    fi
    OWL_APP_PID=""

    # 2. Wait for app's shutdown callback to kill host
    sleep 1

    # 3. Kill orphan owl_host processes (PPID=1)
    local orphan_hosts
    orphan_hosts=$(pgrep -f "owl_host" 2>/dev/null | while read pid; do
        if [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "1" ]; then
            echo "$pid"
        fi
    done)

    for pid in $orphan_hosts; do
        kill "$pid" 2>/dev/null
        sleep 0.3
        kill -9 "$pid" 2>/dev/null || true
    done
}

wait_for_cdp() {
    local port=$1 timeout=$2
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        if curl -sf "http://127.0.0.1:${port}/json" >/dev/null 2>&1; then
            echo -e "  ${GREEN}CDP ready on port ${port}${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "  ${RED}CDP not ready after ${timeout}s${NC}"
    return 1
}

# Parse Playwright JSON-style output into report() calls
parse_playwright_output() {
    local output
    output=$(cat)
    local total pass fail
    # Playwright outputs lines like "X passed", "X failed"
    pass=$(echo "$output" | command grep -oE '[0-9]+ passed' | head -1 | awk '{print $1}')
    fail=$(echo "$output" | command grep -oE '[0-9]+ failed' | head -1 | awk '{print $1}')
    pass=${pass:-0}
    fail=${fail:-0}
    total=$((pass + fail))
    report "Playwright Web Tests" "$total" "$pass" "$fail"
    if [ "$fail" -gt 0 ]; then
        echo "$output" | command grep -E "FAIL|Error|✘" | head -10
    fi
}

# Parse xcodebuild test output into report() calls
parse_xcuitest_output() {
    local output
    output=$(cat)
    local total pass fail
    total=$(echo "$output" | command grep "Test Case" | command grep -c "started" || true)
    pass=$(echo "$output" | command grep "Test Case" | command grep -c "passed" || true)
    fail=$(echo "$output" | command grep "Test Case" | command grep -c "failed" || true)
    total=${total:-0}
    pass=${pass:-0}
    fail=${fail:-0}
    report "XCUITest Dual Driver" "$total" "$pass" "$fail"
    if [ "$fail" -gt 0 ]; then
        echo "$output" | command grep "failed" | head -10
    fi
}

print_summary() {
    local pw_name="$1" pw_exit="$2" xcui_name="$3" xcui_exit="$4"
    echo ""
    echo -e "${CYAN}--- Dual E2E Summary ---${NC}"
    if [ "$pw_exit" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC} $pw_name"
    else
        echo -e "  ${RED}FAIL${NC} $pw_name (exit $pw_exit)"
    fi
    if [ "$xcui_exit" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC} $xcui_name"
    else
        echo -e "  ${RED}FAIL${NC} $xcui_name (exit $xcui_exit)"
    fi
}

# === Main ===
echo ""
echo -e "${CYAN}=== OWL Browser Test Runner ===${NC}"
echo "  Build dir: $BUILD_DIR"
echo "  Level: $LEVEL"
echo ""

case "$LEVEL" in
    cpp)
        run_cpp
        ;;
    unit)
        run_unit
        ;;
    harness)
        run_harness
        ;;
    integration)
        run_integration
        ;;
    pipeline)
        run_pipeline
        ;;
    cli)
        run_cli
        ;;
    xcuitest)
        run_lint
        run_xcuitest
        ;;
    docs)
        run_docs_lint
        ;;
    maintenance)
        run_maintenance
        ;;
    system)
        run_system
        ;;
    dual-e2e)
        # ═══════════════════════════════════════════════
        # Phase A: Playwright 纯 Web 测试
        # ═══════════════════════════════════════════════
        section "Phase A: Playwright Web Tests"

        export OWL_CDP_PORT=${OWL_CDP_PORT:-9222}
        export OWL_CLEAN_SESSION=1
        XCODEPROJ="$SCRIPT_DIR/../OWLBrowser.xcodeproj"

        # 构建（如果需要）
        if [ ! -f "$BUILD_DIR/owl_host" ]; then
            "$SCRIPT_DIR/build_all.sh"
        fi

        # 清理 stale 进程
        pkill -f "OWLBrowser" 2>/dev/null || true
        pkill -f "owl_host" 2>/dev/null || true
        sleep 1

        # 启动 app
        trap 'cleanup_owl_processes' EXIT
        OWL_CDP_PORT=$OWL_CDP_PORT OWL_CLEAN_SESSION=1 \
            swift run --package-path "$SCRIPT_DIR/.." OWLBrowser &
        OWL_APP_PID=$!

        # 等待 CDP 就绪
        wait_for_cdp "$OWL_CDP_PORT" 30

        # 运行 Playwright 测试
        PW_DIR="$SCRIPT_DIR/../playwright"
        PW_EXIT=0
        if [ -d "$PW_DIR" ] && [ -f "$PW_DIR/package.json" ]; then
            PW_OUTPUT=$( (cd "$PW_DIR" && OWL_CDP_PORT=$OWL_CDP_PORT npx playwright test 2>&1) ) \
                || PW_EXIT=$?
            echo "$PW_OUTPUT" | parse_playwright_output || true
        else
            skip "Playwright" "playwright directory not found"
            PW_EXIT=0
        fi

        # 杀掉 Phase A 的 app 实例
        cleanup_owl_processes

        # ═══════════════════════════════════════════════
        # Phase B: XCUITest + CDPHelper 跨层测试
        # ═══════════════════════════════════════════════
        section "Phase B: XCUITest Dual Driver Tests"

        XCUI_EXIT=0
        if has_signing; then
            # XCUITest 通过 XCUIApplication.launch() 自行启动 app
            XCUI_OUTPUT=$(xcodebuild test-without-building \
                -project "$XCODEPROJ" \
                -scheme OWLBrowserUITests \
                -destination 'platform=macOS' \
                -derivedDataPath /tmp/owl_xctest \
                -only-testing:OWLBrowserUITests/OWLDualDriverTests \
                2>&1) || XCUI_EXIT=$?
            echo "$XCUI_OUTPUT" | parse_xcuitest_output || true
        else
            skip "XCUITest Dual Driver" "no signing identity"
            XCUI_EXIT=0
        fi

        # 汇总
        print_summary "Playwright" $PW_EXIT "XCUITest Dual" $XCUI_EXIT
        [ $PW_EXIT -eq 0 ] && [ $XCUI_EXIT -eq 0 ]
        ;;
    e2e)
        if [ "${OWL_LEGACY_E2E:-0}" = "1" ]; then
            run_cpp
            run_unit
            run_integration
            run_pipeline
        else
            run_harness
        fi
        ;;
    all)
        run_lint
        run_cpp
        run_unit
        run_integration
        run_pipeline
        run_maintenance
        run_cli
        run_xcuitest
        run_system
        ;;
    *)
        echo "Unknown level: $LEVEL"
        echo "Usage: $0 [cpp|unit|harness|integration|pipeline|cli|xcuitest|system|dual-e2e|maintenance|docs|e2e|all]"
        exit 1
        ;;
esac

# === Summary ===
echo ""
echo -e "${CYAN}=== Summary ===${NC}"
if [ "$FAILED" -gt 0 ]; then
    echo -e "  ${RED}$PASSED/$TOTAL passed, $FAILED failed${NC}"
else
    echo -e "  ${GREEN}$PASSED/$TOTAL passed${NC}"
fi
[ "$SKIPPED" -gt 0 ] && echo -e "  ${YELLOW}$SKIPPED suites skipped${NC}"

write_summary
cleanup_tee

if [ "$FAILED" -gt 0 ]; then
    exit 1
else
    exit 0
fi
