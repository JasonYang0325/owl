#!/usr/bin/env python3
"""Code-driven OWL test harness runner.

Goals:
- Keep test strategy/policy in code (`harness_policy.json`) instead of docs-only.
- Produce complete, machine-readable artifacts (suite/case/junit/summary).
- Add deterministic retry/flaky detection for agent self-loop iteration.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple


SWIFT_CASE_RE = re.compile(r"^[^\s/]+(?:\.[^\s/]+)*/[^\s]+$")
SWIFT_TESTCASE_LINE_RE = re.compile(
    r"Test Case '-\[(?P<classname>[^\s\]]+)\s+(?P<name>[^\]]+)\]'\s+(?P<status>passed|failed)"
)
SWIFT_EXEC_SUMMARY_RE = re.compile(
    r"Executed\s+(?P<tests>\d+)\s+test(?:s)?(?:,\s+with\s+(?P<failures>\d+)\s+failure(?:s)?(?:\s+\((?P<unexpected>\d+)\s+unexpected\))?)?"
)


@dataclass
class CommandResult:
    command: List[str]
    returncode: int
    duration_sec: float
    timed_out: bool
    log_path: Path


@dataclass
class ParsedJUnit:
    tests: int = 0
    failures: int = 0
    errors: int = 0
    skipped: int = 0
    cases: List[Dict[str, object]] = field(default_factory=list)


@dataclass
class SuiteAttempt:
    index: int
    status: str
    command: List[str]
    returncode: int
    duration_sec: float
    timed_out: bool
    tests: int
    failures: int
    errors: int
    skipped: int
    log_path: str
    xunit_path: Optional[str]


@dataclass
class SuiteResult:
    suite_id: str
    required: bool
    status: str
    flaky: bool
    reason: str
    attempts: List[SuiteAttempt]
    tests: int
    failures: int
    errors: int
    skipped: int
    discovered_cases: List[str]
    case_results: List[Dict[str, object]]
    final_xunit_path: Optional[Path]
    failure_hints: List[str]


@dataclass
class UseCaseSelectorResult:
    suite: str
    expression: str
    min_matches: int
    min_passed: int
    matched_count: int
    passed_count: int
    status: str
    reason: str
    matched_cases: List[str]


@dataclass
class UseCaseResult:
    use_case_id: str
    description: str
    required: bool
    status: str
    reason: str
    selector_mode: str
    selectors: List[UseCaseSelectorResult]


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def chromium_src_from_script(script_dir: Path) -> Path:
    # .../chromium/src/third_party/owl/owl-client-app/scripts
    # parents[3] => .../chromium/src
    if len(script_dir.parents) >= 4:
        return script_dir.parents[3]
    return script_dir


def discover_host_path(build_dir: Path) -> Optional[Path]:
    app = build_dir / "OWL Host.app" / "Contents" / "MacOS" / "OWL Host"
    if app.exists():
        return app
    bare = build_dir / "owl_host"
    if bare.exists():
        return bare
    return None


def shell_join(parts: List[str]) -> str:
    out: List[str] = []
    for p in parts:
        if re.search(r"[^\w@%+=:,./-]", p):
            out.append("'" + p.replace("'", "'\"'\"'") + "'")
        else:
            out.append(p)
    return " ".join(out)


def run_command(
    command: List[str],
    *,
    cwd: Path,
    env: Dict[str, str],
    timeout_sec: int,
    log_path: Path,
) -> CommandResult:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.time()
    timed_out = False
    with log_path.open("w", encoding="utf-8", errors="replace") as f:
        f.write(f"$ {shell_join(command)}\n\n")
        f.flush()
        proc = subprocess.Popen(
            command,
            cwd=str(cwd),
            env=env,
            stdout=f,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            rc = proc.wait(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            timed_out = True
            proc.kill()
            rc = 124
            f.write(f"\n[HARNESS] timeout after {timeout_sec}s\n")
    duration = time.time() - started
    return CommandResult(
        command=command,
        returncode=rc,
        duration_sec=duration,
        timed_out=timed_out,
        log_path=log_path,
    )


def parse_int(value: Optional[str], fallback: int = 0) -> int:
    if value is None:
        return fallback
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return fallback


def parse_float(value: Optional[str], fallback: float = 0.0) -> float:
    if value is None:
        return fallback
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def parse_junit(path: Path, kind: str) -> ParsedJUnit:
    if not path.exists():
        return ParsedJUnit()
    try:
        tree = ET.parse(path)
    except ET.ParseError:
        return ParsedJUnit()
    root = tree.getroot()

    suites: List[ET.Element]
    if root.tag == "testsuite":
        suites = [root]
    elif root.tag == "testsuites":
        suites = list(root.findall("testsuite"))
        if not suites:
            suites = [root]
    else:
        suites = list(root.findall(".//testsuite"))

    parsed = ParsedJUnit()
    for suite in suites:
        parsed.tests += parse_int(suite.attrib.get("tests"), 0)
        parsed.failures += parse_int(suite.attrib.get("failures"), 0)
        parsed.errors += parse_int(suite.attrib.get("errors"), 0)
        parsed.skipped += parse_int(suite.attrib.get("skipped"), 0)

        for case in suite.findall("testcase"):
            classname = case.attrib.get("classname", "").strip()
            name = case.attrib.get("name", "").strip()
            duration = parse_float(case.attrib.get("time"), 0.0)
            failure = case.find("failure")
            error = case.find("error")
            skipped = case.find("skipped")
            if failure is not None or error is not None:
                status = "failed"
                node = failure if failure is not None else error
                message = (node.attrib.get("message") if node is not None else "") or ""
            elif skipped is not None:
                status = "skipped"
                message = skipped.attrib.get("message", "")
            else:
                status = "passed"
                message = ""

            if kind == "gtest":
                case_key = f"{classname}.{name}" if classname else name
            else:
                case_key = f"{classname}/{name}" if classname else name

            parsed.cases.append(
                {
                    "case": case_key,
                    "classname": classname,
                    "name": name,
                    "status": status,
                    "duration_sec": duration,
                    "message": message,
                }
            )

    if parsed.tests == 0 and parsed.cases:
        parsed.tests = len(parsed.cases)
        parsed.failures = sum(1 for c in parsed.cases if c["status"] == "failed")
        parsed.skipped = sum(1 for c in parsed.cases if c["status"] == "skipped")
    return parsed


def parse_swift_list_tests(text: str) -> List[str]:
    out: List[str] = []
    for line in text.splitlines():
        item = line.strip()
        if SWIFT_CASE_RE.match(item):
            out.append(item)
    return sorted(set(out))


def swift_case_matches_filter(case_name: str, filt: str) -> bool:
    if not filt:
        return True
    # SwiftPM filter supports patterns like:
    # - Target: "OWLUnitTests"
    # - Target.Class: "OWLBrowserTests.OWLBrowserTests"
    # - Target.Class/testCase
    if case_name == filt:
        return True
    return case_name.startswith(filt + ".") or case_name.startswith(filt + "/")


def parse_gtest_list_tests(text: str) -> List[str]:
    out: List[str] = []
    suite = ""
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        if line.startswith("Running ") or line.startswith("Google Test"):
            continue
        if not line.startswith(" ") and line.endswith("."):
            suite = line.strip()
            continue
        if line.startswith(" ") and suite:
            case = line.strip()
            if not case:
                continue
            # Drop inline comments emitted by gtest list.
            if "#" in case:
                case = case.split("#", 1)[0].strip()
            # Exclude disabled tests from discovery inventory. They are listed
            # by gtest but intentionally not executed.
            if suite.startswith("DISABLED_") or case.startswith("DISABLED_"):
                continue
            if case:
                out.append(f"{suite}{case}")
    return sorted(set(out))


def parse_swift_test_log(text: str) -> ParsedJUnit:
    parsed = ParsedJUnit()
    case_status: Dict[str, Dict[str, object]] = {}
    summary_tests_max = 0
    summary_failures_max = 0

    for line in text.splitlines():
        m = SWIFT_TESTCASE_LINE_RE.search(line)
        if m:
            classname = m.group("classname").strip()
            name = m.group("name").strip()
            status = m.group("status").strip()
            key = f"{classname}/{name}"
            case_status[key] = {
                "case": key,
                "classname": classname,
                "name": name,
                "status": status,
                "duration_sec": 0.0,
                "message": "" if status == "passed" else "failed",
            }
            continue

        sm = SWIFT_EXEC_SUMMARY_RE.search(line)
        if sm:
            summary_tests_max = max(summary_tests_max, parse_int(sm.group("tests"), 0))
            summary_failures_max = max(summary_failures_max, parse_int(sm.group("failures"), 0))

    parsed.cases = list(case_status.values())
    if parsed.cases:
        parsed.tests = len(parsed.cases)
        parsed.failures = sum(1 for c in parsed.cases if c["status"] == "failed")
    else:
        parsed.tests = summary_tests_max
        parsed.failures = summary_failures_max
    return parsed


def write_suite_junit_from_cases(
    suite_id: str,
    case_results: List[Dict[str, object]],
    out_path: Path,
) -> None:
    tests = [c for c in case_results if c["status"] in ("passed", "failed", "skipped")]
    failures = sum(1 for c in tests if c["status"] == "failed")
    skipped = sum(1 for c in tests if c["status"] == "skipped")

    ts = ET.Element(
        "testsuite",
        {
            "name": suite_id,
            "tests": str(len(tests)),
            "failures": str(failures),
            "errors": "0",
            "skipped": str(skipped),
            "time": "0",
        },
    )
    for case in tests:
        case_name = str(case["case"])
        if "/" in case_name:
            classname, name = case_name.split("/", 1)
        elif "." in case_name:
            classname, name = case_name.rsplit(".", 1)
        else:
            classname, name = suite_id, case_name
        tc = ET.SubElement(
            ts,
            "testcase",
            {
                "classname": classname,
                "name": name,
                "time": str(case.get("duration_sec", 0.0)),
            },
        )
        status = str(case["status"])
        message = str(case.get("message", ""))
        if status == "failed":
            node = ET.SubElement(tc, "failure", {"message": message or "failed"})
            node.text = message
        elif status == "skipped":
            ET.SubElement(tc, "skipped", {"message": message or "skipped"})

    out_path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(ts).write(out_path, encoding="utf-8", xml_declaration=True)


def merge_junit(paths: List[Path], out_path: Path) -> None:
    root = ET.Element("testsuites")
    total_tests = 0
    total_failures = 0
    total_errors = 0
    total_skipped = 0

    for p in paths:
        if not p.exists():
            continue
        try:
            tree = ET.parse(p)
        except ET.ParseError:
            continue
        src = tree.getroot()
        suites: List[ET.Element]
        if src.tag == "testsuite":
            suites = [src]
        elif src.tag == "testsuites":
            suites = list(src.findall("testsuite"))
            if not suites:
                suites = [src]
        else:
            suites = list(src.findall(".//testsuite"))
        for suite in suites:
            total_tests += parse_int(suite.attrib.get("tests"), 0)
            total_failures += parse_int(suite.attrib.get("failures"), 0)
            total_errors += parse_int(suite.attrib.get("errors"), 0)
            total_skipped += parse_int(suite.attrib.get("skipped"), 0)
            root.append(suite)

    root.set("tests", str(total_tests))
    root.set("failures", str(total_failures))
    root.set("errors", str(total_errors))
    root.set("skipped", str(total_skipped))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(out_path, encoding="utf-8", xml_declaration=True)


def expand_value(value: str, variables: Dict[str, str]) -> str:
    out = value
    for k, v in variables.items():
        out = out.replace(f"${k}", v)
    return out


def expand_values(values: List[str], variables: Dict[str, str]) -> List[str]:
    return [expand_value(v, variables) for v in values]


def parse_script_command(suite_cfg: Dict[str, object], vars_map: Dict[str, str]) -> List[str]:
    raw = suite_cfg.get("command")
    if isinstance(raw, list):
        return expand_values([str(x) for x in raw], vars_map)
    if isinstance(raw, str):
        return shlex.split(expand_value(raw, vars_map))
    return []


def parse_script_cwd(
    suite_cfg: Dict[str, object],
    *,
    project_dir: Path,
    vars_map: Dict[str, str],
) -> Path:
    raw = suite_cfg.get("cwd", "")
    if not isinstance(raw, str) or not raw:
        return project_dir
    expanded = Path(expand_value(raw, vars_map))
    if not expanded.is_absolute():
        expanded = (project_dir / expanded).resolve()
    return expanded


def parse_script_skip(
    suite_cfg: Dict[str, object],
    *,
    log_text: str,
) -> Tuple[bool, str]:
    if not bool(suite_cfg.get("treat_skip_as_skipped", False)):
        return (False, "")
    patterns_raw = suite_cfg.get("skip_patterns", [])
    if isinstance(patterns_raw, list):
        patterns = [str(x) for x in patterns_raw if str(x).strip()]
    else:
        patterns = []
    if not patterns:
        patterns = [r"\bSKIP\b"]

    for pat in patterns:
        try:
            if re.search(pat, log_text, flags=re.IGNORECASE):
                return (True, f"matched skip pattern `{pat}`")
        except re.error:
            if pat in log_text:
                return (True, f"matched skip marker `{pat}`")
    return (False, "")


def parse_script_result(
    discovered_cases: List[str],
    *,
    status: str,
    reason: str,
    duration_sec: float,
) -> ParsedJUnit:
    cases = discovered_cases if discovered_cases else ["script::run"]
    normalized = status if status in ("passed", "failed", "skipped") else "failed"
    return ParsedJUnit(
        tests=len(cases),
        failures=len(cases) if normalized == "failed" else 0,
        errors=0,
        skipped=len(cases) if normalized == "skipped" else 0,
        cases=[
            {
                "case": case_name,
                "status": normalized,
                "duration_sec": duration_sec,
                "message": reason if normalized != "passed" else "",
            }
            for case_name in cases
        ],
    )


def list_suite_cases(
    suite_cfg: Dict[str, object],
    *,
    project_dir: Path,
    suite_dir: Path,
    env: Dict[str, str],
    timeout_sec: int,
    vars_map: Dict[str, str],
) -> Tuple[List[str], Optional[Path]]:
    kind = str(suite_cfg["kind"])
    list_log = suite_dir / "list_tests.log"
    if kind == "script":
        raw_cases = suite_cfg.get("fixed_cases", [])
        if isinstance(raw_cases, list):
            fixed_cases = [str(x) for x in raw_cases if str(x).strip()]
        else:
            fixed_cases = []
        if not fixed_cases:
            fixed_cases = ["script::run"]
        list_log.write_text(
            "[HARNESS] script suite uses fixed_cases from policy\n"
            + "\n".join(fixed_cases)
            + "\n",
            encoding="utf-8",
        )
        return fixed_cases, list_log

    if kind == "swift":
        filt = str(suite_cfg.get("filter", ""))
        cmd = ["swift", "test", "list", "--skip-build"]
        res = run_command(cmd, cwd=project_dir, env=env, timeout_sec=timeout_sec, log_path=list_log)
        text = list_log.read_text(encoding="utf-8", errors="replace")
        all_cases = parse_swift_list_tests(text)
        return [c for c in all_cases if swift_case_matches_filter(c, filt)], res.log_path

    binary = expand_value(str(suite_cfg["binary"]), vars_map)
    cmd = [binary, "--gtest_list_tests"]
    res = run_command(cmd, cwd=project_dir, env=env, timeout_sec=timeout_sec, log_path=list_log)
    text = list_log.read_text(encoding="utf-8", errors="replace")
    return parse_gtest_list_tests(text), res.log_path


def build_targets(
    targets: List[str],
    *,
    build_dir: Path,
    cwd: Path,
    env: Dict[str, str],
    log_path: Path,
) -> CommandResult:
    ninja = "autoninja" if shutil.which("autoninja") else "ninja"
    cmd = [ninja, "-C", str(build_dir)] + targets
    return run_command(cmd, cwd=cwd, env=env, timeout_sec=900, log_path=log_path)


def infer_nonzero_reason(log_text: str, returncode: int) -> str:
    signal_match = re.search(r"unexpected signal code\s+(\d+)", log_text)
    if signal_match:
        return f"xctest crashed (signal {signal_match.group(1)})"
    fatal_match = re.search(r"fatal error:\s*(.+)", log_text, flags=re.IGNORECASE)
    if fatal_match:
        return f"fatal error: {fatal_match.group(1).strip()}"
    return f"process exited with code {returncode}"


def run_suite(
    suite_id: str,
    suite_cfg: Dict[str, object],
    *,
    project_dir: Path,
    artifacts_dir: Path,
    build_dir: Path,
    host_path: Optional[Path],
    env: Dict[str, str],
    vars_map: Dict[str, str],
) -> SuiteResult:
    required = bool(suite_cfg.get("required", True))
    kind = str(suite_cfg["kind"])
    retries = int(suite_cfg.get("retries", 0))
    stability_runs = max(int(suite_cfg.get("stability_runs", 1)), 1)
    timeout_sec = int(suite_cfg.get("timeout_sec", 300))
    failure_hints = [str(x) for x in suite_cfg.get("failure_hints", [])]

    suite_artifacts = artifacts_dir / "suites" / suite_id
    suite_artifacts.mkdir(parents=True, exist_ok=True)

    if bool(suite_cfg.get("requires_host_binary", False)) and host_path is None:
        return SuiteResult(
            suite_id=suite_id,
            required=required,
            status="skipped",
            flaky=False,
            reason="host binary not found",
            attempts=[],
            tests=0,
            failures=0,
            errors=0,
            skipped=0,
            discovered_cases=[],
            case_results=[],
            final_xunit_path=None,
            failure_hints=failure_hints,
        )

    targets = [str(x) for x in suite_cfg.get("build_targets", [])]
    if targets:
        build_log = suite_artifacts / "build.log"
        build_res = build_targets(
            targets,
            build_dir=build_dir,
            cwd=project_dir,
            env=env,
            log_path=build_log,
        )
        if build_res.returncode != 0:
            if bool(suite_cfg.get("skip_if_build_fails", False)):
                return SuiteResult(
                    suite_id=suite_id,
                    required=required,
                    status="skipped",
                    flaky=False,
                    reason="build failed (marked skippable by policy)",
                    attempts=[],
                    tests=0,
                    failures=0,
                    errors=0,
                    skipped=0,
                    discovered_cases=[],
                    case_results=[],
                    final_xunit_path=None,
                    failure_hints=failure_hints,
                )
            return SuiteResult(
                suite_id=suite_id,
                required=required,
                status="failed",
                flaky=False,
                reason="build failed",
                attempts=[],
                tests=0,
                failures=0,
                errors=0,
                skipped=0,
                discovered_cases=[],
                case_results=[],
                final_xunit_path=None,
                failure_hints=failure_hints,
            )

    if kind == "gtest":
        binary = Path(expand_value(str(suite_cfg["binary"]), vars_map))
        if not binary.exists():
            return SuiteResult(
                suite_id=suite_id,
                required=required,
                status="skipped" if bool(suite_cfg.get("skip_if_build_fails", False)) else "failed",
                flaky=False,
                reason=f"binary not found: {binary}",
                attempts=[],
                tests=0,
                failures=0,
                errors=0,
                skipped=0,
                discovered_cases=[],
                case_results=[],
                final_xunit_path=None,
                failure_hints=failure_hints,
            )

    discovered_cases, _ = list_suite_cases(
        suite_cfg,
        project_dir=project_dir,
        suite_dir=suite_artifacts,
        env=env,
        timeout_sec=min(timeout_sec, 180),
        vars_map=vars_map,
    )

    attempts: List[SuiteAttempt] = []
    ever_failed = False
    final_status = "failed"
    final_reason = "no attempts run"
    final_parsed = ParsedJUnit()
    final_xunit: Optional[Path] = None
    successful_runs = 0
    max_attempts = retries + stability_runs

    for attempt_index in range(1, max_attempts + 1):
        attempt_dir = suite_artifacts / f"attempt-{attempt_index}"
        attempt_dir.mkdir(parents=True, exist_ok=True)
        xunit_path = attempt_dir / "junit.xml"
        log_path = attempt_dir / "output.log"

        if kind == "script":
            cmd = parse_script_command(suite_cfg, vars_map)
            if not cmd:
                parsed = parse_script_result(
                    discovered_cases,
                    status="failed",
                    reason="missing script command in policy",
                    duration_sec=0.0,
                )
                attempts.append(
                    SuiteAttempt(
                        index=attempt_index,
                        status="failed",
                        command=[],
                        returncode=2,
                        duration_sec=0.0,
                        timed_out=False,
                        tests=parsed.tests,
                        failures=parsed.failures,
                        errors=parsed.errors,
                        skipped=parsed.skipped,
                        log_path=str(log_path),
                        xunit_path=None,
                    )
                )
                final_status = "failed"
                final_reason = "missing script command in policy"
                final_parsed = parsed
                break

            script_cwd = parse_script_cwd(suite_cfg, project_dir=project_dir, vars_map=vars_map)
            res = run_command(cmd, cwd=script_cwd, env=env, timeout_sec=timeout_sec, log_path=log_path)
            log_text = log_path.read_text(encoding="utf-8", errors="replace")

            if res.timed_out:
                status = "failed"
                reason = f"timeout after {timeout_sec}s"
            elif res.returncode != 0:
                status = "failed"
                reason = infer_nonzero_reason(log_text, res.returncode)
            else:
                skipped_by_pattern, skip_reason = parse_script_skip(suite_cfg, log_text=log_text)
                if skipped_by_pattern:
                    status = "skipped"
                    reason = skip_reason
                else:
                    status = "passed"
                    reason = "ok"
            parsed = parse_script_result(
                discovered_cases,
                status=status,
                reason=reason,
                duration_sec=res.duration_sec,
            )
        elif kind == "swift":
            cmd = ["swift", "test", "--xunit-output", str(xunit_path)]
            filt = str(suite_cfg.get("filter", ""))
            if filt:
                cmd.extend(["--filter", filt])
            res = run_command(cmd, cwd=project_dir, env=env, timeout_sec=timeout_sec, log_path=log_path)
            parsed = parse_junit(xunit_path, kind)
            if parsed.tests == 0 and parsed.failures == 0 and parsed.errors == 0:
                log_text = log_path.read_text(encoding="utf-8", errors="replace")
                parsed = parse_swift_test_log(log_text)
        else:
            binary = expand_value(str(suite_cfg["binary"]), vars_map)
            cmd = [binary, f"--gtest_output=xml:{xunit_path}"]
            res = run_command(cmd, cwd=project_dir, env=env, timeout_sec=timeout_sec, log_path=log_path)
            parsed = parse_junit(xunit_path, kind)

        if kind != "script":
            if res.timed_out:
                status = "failed"
                reason = f"timeout after {timeout_sec}s"
            elif res.returncode != 0:
                status = "failed"
                if parsed.failures > 0 or parsed.errors > 0:
                    reason = "tests failed"
                else:
                    log_text = log_path.read_text(encoding="utf-8", errors="replace")
                    reason = infer_nonzero_reason(log_text, res.returncode)
            elif parsed.failures > 0 or parsed.errors > 0:
                status = "failed"
                reason = "tests failed"
            else:
                status = "passed"
                reason = "ok"

        attempts.append(
            SuiteAttempt(
                index=attempt_index,
                status=status,
                command=cmd,
                returncode=res.returncode,
                duration_sec=res.duration_sec,
                timed_out=res.timed_out,
                tests=parsed.tests,
                failures=parsed.failures,
                errors=parsed.errors,
                skipped=parsed.skipped,
                log_path=str(log_path),
                xunit_path=str(xunit_path) if xunit_path.exists() else None,
            )
        )

        if status == "passed":
            successful_runs += 1
            final_status = "passed" if successful_runs >= stability_runs else "pending_stability"
            final_reason = (
                "ok"
                if successful_runs >= stability_runs
                else f"stability check pass {successful_runs}/{stability_runs}"
            )
            final_parsed = parsed
            final_xunit = xunit_path if xunit_path.exists() else None
            if successful_runs >= stability_runs:
                break
            continue
        if status == "skipped":
            final_status = "skipped"
            final_reason = reason
            final_parsed = parsed
            final_xunit = xunit_path if xunit_path.exists() else None
            break

        ever_failed = True
        final_status = "failed"
        final_reason = reason
        final_parsed = parsed
        final_xunit = xunit_path if xunit_path.exists() else None
        remaining_attempts = max_attempts - attempt_index
        needed_passes = stability_runs - successful_runs
        if remaining_attempts < needed_passes:
            break

    if successful_runs < stability_runs and final_status not in ("failed", "skipped"):
        final_status = "failed"
        final_reason = (
            f"stability check incomplete ({successful_runs}/{stability_runs} passes)"
        )

    flaky = final_status == "passed" and ever_failed

    status_map: Dict[str, Dict[str, object]] = {}
    for c in final_parsed.cases:
        status_map[str(c["case"])] = c

    case_results: List[Dict[str, object]] = []
    if final_status == "passed" and not status_map and discovered_cases:
        for case_name in discovered_cases:
            status_map[case_name] = {
                "case": case_name,
                "status": "passed",
                "duration_sec": 0.0,
                "message": "",
            }

    for case_name in discovered_cases:
        if case_name in status_map:
            c = status_map[case_name]
            case_results.append(
                {
                    "case": case_name,
                    "status": c["status"],
                    "duration_sec": c["duration_sec"],
                    "message": c["message"],
                    "discovered": True,
                }
            )
        else:
            case_results.append(
                {
                    "case": case_name,
                    "status": "not_run",
                    "duration_sec": 0.0,
                    "message": "",
                    "discovered": True,
                }
            )
    for case_name, c in status_map.items():
        if case_name not in discovered_cases:
            case_results.append(
                {
                    "case": case_name,
                    "status": c["status"],
                    "duration_sec": c["duration_sec"],
                    "message": c["message"],
                    "discovered": False,
                }
            )

    if final_xunit is None:
        synthetic = suite_artifacts / "final.junit.xml"
        write_suite_junit_from_cases(suite_id, case_results, synthetic)
        final_xunit = synthetic

    return SuiteResult(
        suite_id=suite_id,
        required=required,
        status=final_status,
        flaky=flaky,
        reason=final_reason,
        attempts=attempts,
        tests=final_parsed.tests,
        failures=final_parsed.failures,
        errors=final_parsed.errors,
        skipped=final_parsed.skipped,
        discovered_cases=discovered_cases,
        case_results=case_results,
        final_xunit_path=final_xunit,
        failure_hints=failure_hints,
    )


def write_cases_jsonl(path: Path, suite_results: List[SuiteResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for suite in suite_results:
            for case in suite.case_results:
                row = {
                    "suite": suite.suite_id,
                    "required": suite.required,
                    "suite_status": suite.status,
                    "suite_flaky": suite.flaky,
                    "case": case["case"],
                    "status": case["status"],
                    "duration_sec": case["duration_sec"],
                    "message": case["message"],
                    "discovered": case["discovered"],
                }
                f.write(json.dumps(row, ensure_ascii=True) + "\n")


def selector_expression(selector_cfg: Dict[str, object]) -> str:
    if "case_regex" in selector_cfg:
        return f"regex:{selector_cfg['case_regex']}"
    if "case_glob" in selector_cfg:
        return f"glob:{selector_cfg['case_glob']}"
    if "case_prefix" in selector_cfg:
        return f"prefix:{selector_cfg['case_prefix']}"
    if "case" in selector_cfg:
        return f"exact:{selector_cfg['case']}"
    return "all"


def selector_matches_case(case_name: str, selector_cfg: Dict[str, object]) -> bool:
    if "case_regex" in selector_cfg:
        try:
            return re.search(str(selector_cfg["case_regex"]), case_name) is not None
        except re.error:
            return False
    if "case_glob" in selector_cfg:
        return fnmatch.fnmatch(case_name, str(selector_cfg["case_glob"]))
    if "case_prefix" in selector_cfg:
        return case_name.startswith(str(selector_cfg["case_prefix"]))
    if "case" in selector_cfg:
        return case_name == str(selector_cfg["case"])
    return True


def evaluate_use_cases(
    *,
    use_case_cfg: Dict[str, object],
    profile: Dict[str, object],
    suite_results: List[SuiteResult],
) -> List[UseCaseResult]:
    suite_map = {s.suite_id: s for s in suite_results}
    use_case_ids = [str(x) for x in profile.get("use_cases", list(use_case_cfg.keys()))]
    required_overrides = set(str(x) for x in profile.get("required_use_cases", []))
    results: List[UseCaseResult] = []

    for use_case_id in use_case_ids:
        cfg_raw = use_case_cfg.get(use_case_id)
        if not isinstance(cfg_raw, dict):
            results.append(
                UseCaseResult(
                    use_case_id=use_case_id,
                    description="",
                    required=True,
                    status="failed",
                    reason="use case missing in policy",
                    selector_mode="all",
                    selectors=[],
                )
            )
            continue

        cfg = cfg_raw
        description = str(cfg.get("description", ""))
        selectors_cfg = cfg.get("selectors", [])
        selector_mode = str(cfg.get("selector_mode", "all"))
        required = bool(cfg.get("required", False) or use_case_id in required_overrides)

        selector_results: List[UseCaseSelectorResult] = []
        for raw_selector in selectors_cfg:
            if not isinstance(raw_selector, dict):
                continue
            selector = raw_selector
            suite_id = str(selector.get("suite", ""))
            expression = selector_expression(selector)
            min_matches = max(int(selector.get("min_matches", 1)), 0)
            require_passed = bool(selector.get("require_passed", True))
            min_passed = max(int(selector.get("min_passed", min_matches if require_passed else 0)), 0)

            suite = suite_map.get(suite_id)
            if suite is None:
                selector_results.append(
                    UseCaseSelectorResult(
                        suite=suite_id,
                        expression=expression,
                        min_matches=min_matches,
                        min_passed=min_passed,
                        matched_count=0,
                        passed_count=0,
                        status="failed",
                        reason=f"suite `{suite_id}` not found",
                        matched_cases=[],
                    )
                )
                continue

            matched_cases = [c for c in suite.case_results if selector_matches_case(str(c["case"]), selector)]
            matched_count = len(matched_cases)
            passed_count = sum(1 for c in matched_cases if c["status"] == "passed")

            if matched_count < min_matches:
                status = "failed"
                reason = f"matched {matched_count}, expected >= {min_matches}"
            elif require_passed and passed_count < min_passed:
                status = "failed"
                reason = f"passed {passed_count}, expected >= {min_passed}"
            else:
                status = "passed"
                reason = "ok"

            selector_results.append(
                UseCaseSelectorResult(
                    suite=suite_id,
                    expression=expression,
                    min_matches=min_matches,
                    min_passed=min_passed,
                    matched_count=matched_count,
                    passed_count=passed_count,
                    status=status,
                    reason=reason,
                    matched_cases=[str(c["case"]) for c in matched_cases],
                )
            )

        if not selector_results:
            results.append(
                UseCaseResult(
                    use_case_id=use_case_id,
                    description=description,
                    required=required,
                    status="failed",
                    reason="no selectors configured",
                    selector_mode=selector_mode,
                    selectors=[],
                )
            )
            continue

        if selector_mode == "any":
            passed = any(s.status == "passed" for s in selector_results)
        else:
            passed = all(s.status == "passed" for s in selector_results)

        result = UseCaseResult(
            use_case_id=use_case_id,
            description=description,
            required=required,
            status="passed" if passed else "failed",
            reason="ok" if passed else "selector checks failed",
            selector_mode=selector_mode,
            selectors=selector_results,
        )
        results.append(result)

    return results


def write_use_case_coverage(path: Path, use_cases: List[UseCaseResult]) -> None:
    rows: List[Dict[str, object]] = []
    for uc in use_cases:
        rows.append(
            {
                "id": uc.use_case_id,
                "description": uc.description,
                "required": uc.required,
                "status": uc.status,
                "reason": uc.reason,
                "selector_mode": uc.selector_mode,
                "selectors": [
                    {
                        "suite": s.suite,
                        "expression": s.expression,
                        "status": s.status,
                        "reason": s.reason,
                        "min_matches": s.min_matches,
                        "min_passed": s.min_passed,
                        "matched_count": s.matched_count,
                        "passed_count": s.passed_count,
                        "matched_cases": s.matched_cases,
                    }
                    for s in uc.selectors
                ],
            }
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(rows, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def write_case_inventory(path: Path, suite_results: List[SuiteResult]) -> None:
    inventory = {
        s.suite_id: {
            "discovered_count": len(s.discovered_cases),
            "discovered_cases": sorted(s.discovered_cases),
        }
        for s in suite_results
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(inventory, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def compute_observability_metrics(
    suite_results: List[SuiteResult],
    suites_cfg: Dict[str, object],
) -> Dict[str, object]:
    total_attempt_duration = 0.0
    required_final_duration = 0.0
    required_total_attempt_duration = 0.0
    total_attempts = 0
    suites: Dict[str, Dict[str, object]] = {}

    for s in suite_results:
        cfg_raw = suites_cfg.get(s.suite_id, {})
        kind = str(cfg_raw.get("kind", "unknown")) if isinstance(cfg_raw, dict) else "unknown"
        attempt_durations = [max(float(a.duration_sec), 0.0) for a in s.attempts]
        total_duration = sum(attempt_durations)
        final_duration = attempt_durations[-1] if attempt_durations else 0.0
        attempts_count = len(attempt_durations)
        retries_observed = max(0, attempts_count - 1)

        total_attempt_duration += total_duration
        total_attempts += attempts_count
        if s.required:
            required_final_duration += final_duration
            required_total_attempt_duration += total_duration

        suites[s.suite_id] = {
            "kind": kind,
            "required": s.required,
            "status": s.status,
            "flaky": s.flaky,
            "attempts": attempts_count,
            "retries_observed": retries_observed,
            "final_attempt_duration_sec": round(final_duration, 3),
            "total_attempt_duration_sec": round(total_duration, 3),
        }

    def top_slowest(metric_key: str) -> List[Dict[str, object]]:
        ordered = sorted(
            suites.items(),
            key=lambda item: float(item[1].get(metric_key, 0.0)),
            reverse=True,
        )
        return [
            {
                "suite": suite_id,
                metric_key: suite_data.get(metric_key, 0.0),
                "required": suite_data.get("required", False),
                "status": suite_data.get("status", ""),
            }
            for suite_id, suite_data in ordered[:5]
            if float(suite_data.get(metric_key, 0.0)) > 0.0
        ]

    return {
        "totals": {
            "suite_count": len(suite_results),
            "total_attempts": total_attempts,
            "total_attempt_duration_sec": round(total_attempt_duration, 3),
            "required_final_duration_sec": round(required_final_duration, 3),
            "required_total_attempt_duration_sec": round(required_total_attempt_duration, 3),
        },
        "slowest_final_attempt_suites": top_slowest("final_attempt_duration_sec"),
        "slowest_total_attempt_suites": top_slowest("total_attempt_duration_sec"),
        "suites": suites,
    }


def evaluate_observability_assertions(
    *,
    profile: Dict[str, object],
    metrics: Dict[str, object],
) -> Tuple[List[str], Dict[str, object]]:
    cfg_raw = profile.get("observability_assertions", {})
    if not isinstance(cfg_raw, dict):
        return [], {"configured": {}, "violations": []}
    cfg = cfg_raw

    violations: List[str] = []
    configured: Dict[str, object] = {}
    totals_raw = metrics.get("totals", {})
    totals = totals_raw if isinstance(totals_raw, dict) else {}
    suite_metrics_raw = metrics.get("suites", {})
    suite_metrics = suite_metrics_raw if isinstance(suite_metrics_raw, dict) else {}

    def read_limit(key: str) -> Optional[float]:
        if key not in cfg:
            return None
        raw_value = cfg.get(key)
        try:
            value = float(raw_value)
        except (TypeError, ValueError):
            violations.append(f"observability_assertions.{key} must be numeric")
            return None
        if value <= 0:
            violations.append(f"observability_assertions.{key} must be > 0")
            return None
        configured[key] = round(value, 3)
        return value

    max_total_attempt_duration = read_limit("max_total_attempt_duration_sec")
    if max_total_attempt_duration is not None:
        measured = parse_float(str(totals.get("total_attempt_duration_sec", 0.0)), 0.0)
        if measured > max_total_attempt_duration:
            violations.append(
                "observability: total attempt duration "
                f"{measured:.3f}s exceeds max_total_attempt_duration_sec={max_total_attempt_duration:.3f}s"
            )

    max_required_final_duration = read_limit("max_required_final_duration_sec")
    if max_required_final_duration is not None:
        measured = parse_float(str(totals.get("required_final_duration_sec", 0.0)), 0.0)
        if measured > max_required_final_duration:
            violations.append(
                "observability: required suites final duration "
                f"{measured:.3f}s exceeds max_required_final_duration_sec={max_required_final_duration:.3f}s"
            )

    def check_suite_limit_map(
        cfg_key: str,
        metric_key: str,
    ) -> None:
        raw_map = cfg.get(cfg_key)
        if raw_map is None:
            return
        if not isinstance(raw_map, dict):
            violations.append(f"observability_assertions.{cfg_key} must be an object")
            return
        configured_map: Dict[str, float] = {}
        for suite_id, raw_limit in raw_map.items():
            sid = str(suite_id)
            try:
                limit = float(raw_limit)
            except (TypeError, ValueError):
                violations.append(f"observability_assertions.{cfg_key}.{sid} must be numeric")
                continue
            if limit <= 0:
                violations.append(f"observability_assertions.{cfg_key}.{sid} must be > 0")
                continue
            configured_map[sid] = round(limit, 3)
            suite_raw = suite_metrics.get(sid)
            if not isinstance(suite_raw, dict):
                violations.append(f"observability_assertions.{cfg_key} references unknown suite `{sid}`")
                continue
            measured = parse_float(str(suite_raw.get(metric_key, 0.0)), 0.0)
            if measured > limit:
                violations.append(
                    "observability: suite "
                    f"`{sid}` {metric_key}={measured:.3f}s exceeds {cfg_key}={limit:.3f}s"
                )
        if configured_map:
            configured[cfg_key] = configured_map

    check_suite_limit_map("max_suite_final_duration_sec", "final_attempt_duration_sec")
    check_suite_limit_map("max_suite_total_attempt_duration_sec", "total_attempt_duration_sec")

    return violations, {"configured": configured, "violations": violations}


def suite_repro_command(suite_id: str, suite_cfg: Dict[str, object], vars_map: Dict[str, str]) -> str:
    kind = str(suite_cfg.get("kind", ""))
    if kind == "script":
        cmd = parse_script_command(suite_cfg, vars_map)
        if cmd:
            return shell_join(cmd)
        return f"# missing script command for suite {suite_id}"
    if kind == "swift":
        filt = str(suite_cfg.get("filter", ""))
        if filt:
            return f"swift test --filter {filt}"
        return "swift test"
    if kind == "gtest":
        binary = expand_value(str(suite_cfg.get("binary", "")), vars_map)
        return f"{binary} --gtest_filter=<Suite>.<Case>"
    return f"# no repro command for suite {suite_id}"


def write_playbook(
    *,
    path: Path,
    suite_results: List[SuiteResult],
    suites_cfg: Dict[str, object],
    use_cases: List[UseCaseResult],
    vars_map: Dict[str, str],
) -> None:
    lines: List[str] = []
    lines.append("# OWL Harness Playbook")
    lines.append("")
    lines.append("## Failing Suites")
    failing = [s for s in suite_results if s.status != "passed"]
    if not failing:
        lines.append("- none")
    for s in failing:
        suite_cfg = suites_cfg.get(s.suite_id, {})
        lines.append(f"- `{s.suite_id}` ({s.status}): {s.reason}")
        lines.append(f"  Repro: `{suite_repro_command(s.suite_id, suite_cfg, vars_map)}`")
        failed_cases = [c for c in s.case_results if c["status"] == "failed"][:5]
        if failed_cases:
            lines.append(f"  Top failing cases: {', '.join(str(c['case']) for c in failed_cases)}")

    lines.append("")
    lines.append("## Use-Case Coverage Gaps")
    failed_use_cases = [u for u in use_cases if u.status != "passed"]
    if not failed_use_cases:
        lines.append("- none")
    for uc in failed_use_cases:
        tag = "required" if uc.required else "optional"
        lines.append(f"- `{uc.use_case_id}` ({tag}): {uc.description or uc.reason}")
        for sel in uc.selectors:
            if sel.status == "passed":
                continue
            lines.append(
                f"  Selector `{sel.suite}` `{sel.expression}` failed: "
                f"{sel.reason} (matched={sel.matched_count}, passed={sel.passed_count})"
            )

    lines.append("")
    lines.append("## Loop Command")
    lines.append("- `scripts/run_tests.sh harness`")
    path.write_text("\n".join(lines), encoding="utf-8")


def compute_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(64 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def write_artifact_manifest(path: Path, artifact_paths: Dict[str, Path]) -> None:
    rows: Dict[str, object] = {}
    for name, p in artifact_paths.items():
        exists = p.exists()
        rows[name] = {
            "path": str(p),
            "exists": exists,
            "size_bytes": p.stat().st_size if exists else 0,
            "sha256": compute_sha256(p) if exists else "",
        }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(rows, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def make_report(
    *,
    summary: Dict[str, object],
    suite_results: List[SuiteResult],
    use_cases: List[UseCaseResult],
    violations: List[str],
    output_path: Path,
) -> None:
    lines: List[str] = []
    lines.append("# OWL Harness Report")
    lines.append("")
    lines.append(f"- Run ID: `{summary['run_id']}`")
    lines.append(f"- Timestamp (UTC): `{summary['timestamp_utc']}`")
    lines.append(f"- Profile: `{summary['profile']}`")
    lines.append(f"- Policy version: `{summary['policy_version']}`")
    lines.append(f"- Build dir: `{summary['build_dir']}`")
    lines.append(f"- Host path: `{summary['host_path']}`")
    lines.append("")
    lines.append("## Suite Results")
    lines.append("")
    lines.append("| Suite | Required | Status | Flaky | Tests | Failures | Attempts |")
    lines.append("|------|----------|--------|-------|-------|----------|----------|")
    for s in suite_results:
        lines.append(
            f"| `{s.suite_id}` | {'yes' if s.required else 'no'} | "
            f"`{s.status}` | {'yes' if s.flaky else 'no'} | "
            f"{s.tests} | {s.failures + s.errors} | {len(s.attempts)} |"
        )
    lines.append("")
    lines.append("## Use-Case Coverage")
    lines.append("")
    lines.append("| Use Case | Required | Status | Mode |")
    lines.append("|---------|----------|--------|------|")
    for uc in use_cases:
        lines.append(
            f"| `{uc.use_case_id}` | {'yes' if uc.required else 'no'} | "
            f"`{uc.status}` | `{uc.selector_mode}` |"
        )
    lines.append("")

    observability_raw = summary.get("observability", {})
    if isinstance(observability_raw, dict):
        metrics_raw = observability_raw.get("metrics", {})
        assertions_raw = observability_raw.get("assertions", {})
        metrics = metrics_raw if isinstance(metrics_raw, dict) else {}
        assertions = assertions_raw if isinstance(assertions_raw, dict) else {}
        totals_raw = metrics.get("totals", {})
        totals = totals_raw if isinstance(totals_raw, dict) else {}

        lines.append("## Observability Metrics")
        lines.append("")
        lines.append(
            f"- Total attempt duration: `{totals.get('total_attempt_duration_sec', 0.0)}s` "
            f"across `{totals.get('total_attempts', 0)}` attempts"
        )
        lines.append(
            f"- Required suites final duration: `{totals.get('required_final_duration_sec', 0.0)}s`"
        )
        lines.append(
            f"- Required suites total attempt duration: `{totals.get('required_total_attempt_duration_sec', 0.0)}s`"
        )
        configured_raw = assertions.get("configured", {})
        configured = configured_raw if isinstance(configured_raw, dict) else {}
        if configured:
            lines.append("- Configured assertions:")
            for key, value in configured.items():
                lines.append(f"  - `{key}`: `{value}`")
        lines.append("")

    if violations:
        lines.append("## Policy Violations")
        for v in violations:
            lines.append(f"- {v}")
        lines.append("")
    else:
        lines.append("## Policy Status")
        lines.append("- PASS")
        lines.append("")

    lines.append("## Failure Hints")
    for s in suite_results:
        if s.status == "passed":
            continue
        if not s.failure_hints:
            continue
        lines.append(f"- `{s.suite_id}`:")
        for hint in s.failure_hints:
            lines.append(f"  - {hint}")
    lines.append("")
    output_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run OWL code-driven harness with policy and artifacts.")
    parser.add_argument("--policy", required=True, help="Path to harness policy JSON.")
    parser.add_argument("--profile", default="ci-core", help="Policy profile to run.")
    parser.add_argument("--artifacts-dir", default="", help="Output artifact directory (default: /tmp/owl_harness/<run_id>).")
    parser.add_argument("--project-dir", default="", help="owl-client-app directory (default: script parent).")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    project_dir = Path(args.project_dir).resolve() if args.project_dir else script_dir.parent
    policy_path = Path(args.policy).resolve()

    if not policy_path.exists():
        print(f"[HARNESS] policy not found: {policy_path}", file=sys.stderr)
        return 2

    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    profiles = policy.get("profiles", {})
    suites_cfg = policy.get("suites", {})
    use_case_cfg = policy.get("use_cases", {})
    if args.profile not in profiles:
        print(f"[HARNESS] unknown profile: {args.profile}", file=sys.stderr)
        return 2

    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    artifacts_dir = (
        Path(args.artifacts_dir).resolve()
        if args.artifacts_dir
        else Path("/tmp/owl_harness") / run_id
    )
    artifacts_dir.mkdir(parents=True, exist_ok=True)

    chromium_src = Path(os.environ.get("CHROMIUM_SRC", str(chromium_src_from_script(script_dir))))
    build_dir = Path(os.environ.get("OWL_HOST_DIR", str(chromium_src / "out" / "owl-host"))).resolve()
    host_path = discover_host_path(build_dir)

    env = os.environ.copy()
    env["CHROMIUM_SRC"] = str(chromium_src)
    env["OWL_HOST_DIR"] = str(build_dir)
    env["OWL_ENABLE_TEST_JS"] = "1"
    if host_path is not None:
        env["OWL_HOST_PATH"] = str(host_path)

    vars_map = {
        "CHROMIUM_SRC": str(chromium_src),
        "BUILD_DIR": str(build_dir),
        "PROJECT_DIR": str(project_dir),
        "SCRIPT_DIR": str(script_dir),
        "HOST_PATH": str(host_path) if host_path else "",
    }

    profile = profiles[args.profile]
    suite_ids = [str(x) for x in profile.get("suites", [])]

    suite_results: List[SuiteResult] = []
    for suite_id in suite_ids:
        if suite_id not in suites_cfg:
            suite_results.append(
                SuiteResult(
                    suite_id=suite_id,
                    required=True,
                    status="failed",
                    flaky=False,
                    reason="suite missing in policy",
                    attempts=[],
                    tests=0,
                    failures=0,
                    errors=0,
                    skipped=0,
                    discovered_cases=[],
                    case_results=[],
                    final_xunit_path=None,
                    failure_hints=[],
                )
            )
            continue
        result = run_suite(
            suite_id,
            suites_cfg[suite_id],
            project_dir=project_dir,
            artifacts_dir=artifacts_dir,
            build_dir=build_dir,
            host_path=host_path,
            env=env,
            vars_map=vars_map,
        )
        suite_results.append(result)

    violations: List[str] = []
    flaky_count = 0
    for s in suite_results:
        suite_cfg = suites_cfg.get(s.suite_id, {})
        min_discovered = int(suite_cfg.get("min_discovered_cases", 1 if s.required else 0))
        max_not_run = int(suite_cfg.get("max_not_run_cases", 0 if s.required else 999999))
        not_run_count = sum(1 for c in s.case_results if c["status"] == "not_run")

        if s.flaky:
            flaky_count += 1
        if s.required and s.status != "passed":
            violations.append(f"Required suite `{s.suite_id}` is `{s.status}` ({s.reason}).")
        if s.flaky and not bool(suite_cfg.get("allow_flaky", False)):
            violations.append(f"Suite `{s.suite_id}` is flaky (failed then passed).")
        if len(s.discovered_cases) < min_discovered:
            violations.append(
                f"Suite `{s.suite_id}` discovered {len(s.discovered_cases)} cases, expected >= {min_discovered}."
            )
        if not_run_count > max_not_run:
            violations.append(
                f"Suite `{s.suite_id}` has {not_run_count} not_run cases, exceeds max_not_run_cases={max_not_run}."
            )

    max_flaky = int(profile.get("max_flaky_suites", 0))
    if flaky_count > max_flaky:
        violations.append(
            f"Flaky suite count {flaky_count} exceeds profile max_flaky_suites={max_flaky}."
        )

    use_case_results = evaluate_use_cases(
        use_case_cfg=use_case_cfg if isinstance(use_case_cfg, dict) else {},
        profile=profile,
        suite_results=suite_results,
    )
    for uc in use_case_results:
        if uc.required and uc.status != "passed":
            violations.append(f"Required use case `{uc.use_case_id}` failed ({uc.reason}).")

    observability_metrics = compute_observability_metrics(suite_results, suites_cfg)
    observability_violations, observability_assertions = evaluate_observability_assertions(
        profile=profile,
        metrics=observability_metrics,
    )
    violations.extend(observability_violations)

    passed_suites = sum(1 for s in suite_results if s.status == "passed")
    failed_suites = sum(1 for s in suite_results if s.status == "failed")
    skipped_suites = sum(1 for s in suite_results if s.status == "skipped")

    summary = {
        "run_id": run_id,
        "timestamp_utc": now_iso(),
        "profile": args.profile,
        "policy_version": policy.get("version", 0),
        "project_dir": str(project_dir),
        "build_dir": str(build_dir),
        "host_path": str(host_path) if host_path else "",
        "artifacts_dir": str(artifacts_dir),
        "suite_totals": {
            "total": len(suite_results),
            "passed": passed_suites,
            "failed": failed_suites,
            "skipped": skipped_suites,
            "flaky": flaky_count,
        },
        "suite_discovery": {
            s.suite_id: {
                "discovered_cases": len(s.discovered_cases),
                "not_run_cases": sum(1 for c in s.case_results if c["status"] == "not_run"),
            }
            for s in suite_results
        },
        "case_totals": {
            "total": sum(len(s.case_results) for s in suite_results),
            "passed": sum(1 for s in suite_results for c in s.case_results if c["status"] == "passed"),
            "failed": sum(1 for s in suite_results for c in s.case_results if c["status"] == "failed"),
            "skipped": sum(1 for s in suite_results for c in s.case_results if c["status"] == "skipped"),
            "not_run": sum(1 for s in suite_results for c in s.case_results if c["status"] == "not_run"),
        },
        "use_case_totals": {
            "total": len(use_case_results),
            "passed": sum(1 for u in use_case_results if u.status == "passed"),
            "failed": sum(1 for u in use_case_results if u.status != "passed"),
            "required_total": sum(1 for u in use_case_results if u.required),
            "required_failed": sum(1 for u in use_case_results if u.required and u.status != "passed"),
        },
        "observability": {
            "metrics": observability_metrics,
            "assertions": observability_assertions,
        },
        "policy_violations": violations,
        "suites": [
            {
                "id": s.suite_id,
                "required": s.required,
                "status": s.status,
                "reason": s.reason,
                "flaky": s.flaky,
                "tests": s.tests,
                "failures": s.failures,
                "errors": s.errors,
                "skipped": s.skipped,
                "attempts": [
                    {
                        "index": a.index,
                        "status": a.status,
                        "returncode": a.returncode,
                        "timed_out": a.timed_out,
                        "duration_sec": round(a.duration_sec, 3),
                        "tests": a.tests,
                        "failures": a.failures,
                        "errors": a.errors,
                        "skipped": a.skipped,
                        "command": a.command,
                        "log_path": a.log_path,
                        "xunit_path": a.xunit_path,
                    }
                    for a in s.attempts
                ],
            }
            for s in suite_results
        ],
        "use_cases": [
            {
                "id": u.use_case_id,
                "description": u.description,
                "required": u.required,
                "status": u.status,
                "reason": u.reason,
                "selector_mode": u.selector_mode,
                "selectors": [
                    {
                        "suite": sel.suite,
                        "expression": sel.expression,
                        "status": sel.status,
                        "reason": sel.reason,
                        "min_matches": sel.min_matches,
                        "min_passed": sel.min_passed,
                        "matched_count": sel.matched_count,
                        "passed_count": sel.passed_count,
                    }
                    for sel in u.selectors
                ],
            }
            for u in use_case_results
        ],
    }

    summary_path = artifacts_dir / "harness_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    metrics_path = artifacts_dir / "harness_metrics.json"
    metrics_payload = {
        "run_id": run_id,
        "timestamp_utc": summary["timestamp_utc"],
        "profile": args.profile,
        "metrics": observability_metrics,
        "assertions": observability_assertions,
    }
    metrics_path.write_text(json.dumps(metrics_payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    cases_path = artifacts_dir / "harness_cases.jsonl"
    write_cases_jsonl(cases_path, suite_results)

    inventory_path = artifacts_dir / "harness_case_inventory.json"
    write_case_inventory(inventory_path, suite_results)

    use_case_path = artifacts_dir / "harness_usecase_coverage.json"
    write_use_case_coverage(use_case_path, use_case_results)

    merged_junit_path = artifacts_dir / "harness_junit.xml"
    final_xunits = [s.final_xunit_path for s in suite_results if s.final_xunit_path is not None]
    merge_junit([p for p in final_xunits if p is not None], merged_junit_path)

    report_path = artifacts_dir / "harness_report.md"
    make_report(
        summary=summary,
        suite_results=suite_results,
        use_cases=use_case_results,
        violations=violations,
        output_path=report_path,
    )

    playbook_path = artifacts_dir / "harness_playbook.md"
    write_playbook(
        path=playbook_path,
        suite_results=suite_results,
        suites_cfg=suites_cfg,
        use_cases=use_case_results,
        vars_map=vars_map,
    )

    manifest_path = artifacts_dir / "harness_manifest.json"
    write_artifact_manifest(
        manifest_path,
        {
            "summary": summary_path,
            "metrics": metrics_path,
            "cases": cases_path,
            "case_inventory": inventory_path,
            "use_case_coverage": use_case_path,
            "junit": merged_junit_path,
            "report": report_path,
            "playbook": playbook_path,
        },
    )

    latest_link = artifacts_dir.parent / "latest"
    try:
        if latest_link.exists() or latest_link.is_symlink():
            latest_link.unlink()
        latest_link.symlink_to(artifacts_dir)
    except OSError:
        pass

    print("[HARNESS] profile:", args.profile)
    print("[HARNESS] suites:", f"{passed_suites}/{len(suite_results)} passed",
          f"({failed_suites} failed, {skipped_suites} skipped, {flaky_count} flaky)")
    print(
        "[HARNESS] use-cases:",
        f"{summary['use_case_totals']['passed']}/{summary['use_case_totals']['total']} passed",
        f"({summary['use_case_totals']['required_failed']} required failed)",
    )
    print("[HARNESS] summary:", summary_path)
    print("[HARNESS] metrics:", metrics_path)
    print("[HARNESS] cases:", cases_path)
    print("[HARNESS] case_inventory:", inventory_path)
    print("[HARNESS] usecase_coverage:", use_case_path)
    print("[HARNESS] junit:", merged_junit_path)
    print("[HARNESS] report:", report_path)
    print("[HARNESS] playbook:", playbook_path)
    print("[HARNESS] manifest:", manifest_path)

    if violations:
        print("[HARNESS] policy violations:")
        for v in violations:
            print(f"  - {v}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
