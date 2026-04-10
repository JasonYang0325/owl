#!/usr/bin/env python3
"""Track harness flaky trend and fail on persistent instability."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple


@dataclass
class SuiteTrend:
    suite_id: str
    required: bool
    runs: int
    flaky_events: int
    flaky_rate: float
    consecutive_flaky: int


def load_summary(path: Path) -> Dict[str, object]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("summary root must be an object")
    return data


def load_history(path: Path) -> List[Dict[str, object]]:
    if not path.exists():
        return []
    rows: List[Dict[str, object]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def build_record(summary: Dict[str, object]) -> Dict[str, object]:
    suites_raw = summary.get("suites", [])
    suites: Dict[str, Dict[str, object]] = {}
    if isinstance(suites_raw, list):
        for item in suites_raw:
            if not isinstance(item, dict):
                continue
            suite_id = str(item.get("id", "")).strip()
            if not suite_id:
                continue
            suites[suite_id] = {
                "required": bool(item.get("required", False)),
                "status": str(item.get("status", "")),
                "flaky": bool(item.get("flaky", False)),
            }
    return {
        "timestamp_utc": str(summary.get("timestamp_utc", "")),
        "profile": str(summary.get("profile", "")),
        "run_id": str(summary.get("run_id", "")),
        "suites": suites,
    }


def write_history(path: Path, rows: List[Dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(row, ensure_ascii=True) + "\n" for row in rows)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def suite_trends(
    history: List[Dict[str, object]],
    profile: str,
    window: int,
) -> List[SuiteTrend]:
    filtered = [row for row in history if str(row.get("profile", "")) == profile]
    if window > 0:
        filtered = filtered[-window:]

    suite_ids: set[str] = set()
    for row in filtered:
        suites = row.get("suites", {})
        if isinstance(suites, dict):
            suite_ids.update(str(k) for k in suites.keys())

    trends: List[SuiteTrend] = []
    for suite_id in sorted(suite_ids):
        runs = 0
        flaky_events = 0
        required_any = False
        consecutive_flaky = 0

        for row in filtered:
            suites = row.get("suites", {})
            if not isinstance(suites, dict):
                continue
            suite = suites.get(suite_id)
            if not isinstance(suite, dict):
                continue
            runs += 1
            flaky = bool(suite.get("flaky", False))
            required_any = required_any or bool(suite.get("required", False))
            if flaky:
                flaky_events += 1

        for row in reversed(filtered):
            suites = row.get("suites", {})
            if not isinstance(suites, dict):
                continue
            suite = suites.get(suite_id)
            if not isinstance(suite, dict):
                continue
            if bool(suite.get("flaky", False)):
                consecutive_flaky += 1
                continue
            break

        flaky_rate = (flaky_events / runs) if runs > 0 else 0.0
        trends.append(
            SuiteTrend(
                suite_id=suite_id,
                required=required_any,
                runs=runs,
                flaky_events=flaky_events,
                flaky_rate=flaky_rate,
                consecutive_flaky=consecutive_flaky,
            )
        )
    return trends


def evaluate(
    trends: List[SuiteTrend],
    *,
    min_runs: int,
    max_rate: float,
    max_consecutive: int,
) -> Tuple[List[str], List[str]]:
    notes: List[str] = []
    violations: List[str] = []
    for trend in trends:
        if not trend.required:
            continue
        notes.append(
            f"{trend.suite_id}: runs={trend.runs}, flaky={trend.flaky_events}, "
            f"rate={trend.flaky_rate:.2f}, consecutive={trend.consecutive_flaky}"
        )
        if trend.runs >= min_runs and trend.flaky_rate > max_rate:
            violations.append(
                f"required suite `{trend.suite_id}` flaky rate {trend.flaky_rate:.2f} > {max_rate:.2f} "
                f"over last {trend.runs} runs"
            )
        if trend.consecutive_flaky >= max_consecutive:
            violations.append(
                f"required suite `{trend.suite_id}` has {trend.consecutive_flaky} consecutive flaky runs "
                f"(threshold {max_consecutive})"
            )
    return violations, notes


def main() -> int:
    parser = argparse.ArgumentParser(description="Check flaky trend from harness summary history.")
    parser.add_argument("--summary", required=True, help="Current harness_summary.json path.")
    parser.add_argument("--history", required=True, help="JSONL history file path.")
    parser.add_argument("--window", type=int, default=20, help="Number of recent runs to keep/analyze.")
    parser.add_argument("--max-history", type=int, default=200, help="Max history rows retained on disk.")
    parser.add_argument("--min-runs", type=int, default=5, help="Minimum runs before applying flake-rate gate.")
    parser.add_argument("--max-rate", type=float, default=0.35, help="Max allowed flaky rate for required suites.")
    parser.add_argument(
        "--max-consecutive",
        type=int,
        default=2,
        help="Max allowed consecutive flaky runs for required suites.",
    )
    args = parser.parse_args()

    summary_path = Path(args.summary).resolve()
    history_path = Path(args.history).resolve()
    if not summary_path.exists():
        print(f"Flake trend check skipped: summary not found: {summary_path}")
        return 0

    try:
        summary = load_summary(summary_path)
    except Exception as exc:
        print(f"Flake trend check failed: invalid summary: {exc}")
        return 1

    try:
        history = load_history(history_path)
    except Exception as exc:
        print(f"Flake trend check failed: cannot read history: {exc}")
        return 1

    current = build_record(summary)
    history.append(current)
    if args.max_history > 0 and len(history) > args.max_history:
        history = history[-args.max_history :]

    try:
        write_history(history_path, history)
    except Exception as exc:
        print(f"Flake trend check failed: cannot write history: {exc}")
        return 1

    profile = str(current.get("profile", ""))
    trends = suite_trends(history=history, profile=profile, window=max(args.window, 1))
    violations, notes = evaluate(
        trends,
        min_runs=max(args.min_runs, 1),
        max_rate=max(min(args.max_rate, 1.0), 0.0),
        max_consecutive=max(args.max_consecutive, 1),
    )

    if violations:
        print("Flake trend check failed:")
        for violation in violations:
            print(f"- {violation}")
        if notes:
            print("Flake trend snapshot:")
            for note in notes:
                print(f"- {note}")
        return 1

    print("Flake trend check passed.")
    print(f"- profile: {profile}")
    print(f"- tracked suites: {len(trends)}")
    if notes:
        print("Flake trend snapshot:")
        for note in notes:
            print(f"- {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

