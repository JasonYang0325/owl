#!/usr/bin/env python3
"""Generate periodic harness maintenance artifacts (garbage-collection suggestions)."""

from __future__ import annotations

import argparse
import copy
import difflib
import json
import sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Sequence, Set, Tuple


SELECTOR_EXPR_KEYS = ("case", "case_regex", "case_glob", "case_prefix")


@dataclass
class Issue:
    severity: str
    issue_id: str
    location: str
    summary: str
    detail: str
    remediation: str


@dataclass
class Action:
    issue_id: str
    severity: str
    target: str
    operation: str
    before: List[str]
    after: List[str]
    rationale: str


def _dedupe_preserve_order(values: Sequence[str]) -> List[str]:
    seen: Set[str] = set()
    deduped: List[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        deduped.append(value)
    return deduped


def as_str_list(
    raw: object,
    field_name: str,
    findings: List[Issue],
    allow_empty: bool = True,
) -> List[str]:
    values: List[str] = []
    if raw is None:
        if not allow_empty:
            findings.append(
                Issue(
                    severity="critical",
                    issue_id="missing-list",
                    location=field_name,
                    summary=f"Missing required list: `{field_name}`",
                    detail="List field is missing.",
                    remediation=f"Define `{field_name}` as a non-empty JSON array.",
                )
            )
        return values
    if not isinstance(raw, list):
        findings.append(
            Issue(
                severity="critical",
                issue_id="bad-list-type",
                location=field_name,
                summary=f"`{field_name}` must be a list",
                detail="Policy JSON type is not an array.",
                remediation=f"Convert `{field_name}` to a JSON array.",
            )
        )
        return values
    for idx, item in enumerate(raw):
        if not isinstance(item, str) or not item.strip():
            findings.append(
                Issue(
                    severity="critical",
                    issue_id="invalid-list-item",
                    location=f"{field_name}[{idx}]",
                    summary=f"List item must be a non-empty string",
                    detail=f"Encountered non-string or blank value in `{field_name}`.",
                    remediation="Fix this entry and keep IDs as strings.",
                )
            )
            continue
        values.append(item.strip())
    if not allow_empty and not values:
        findings.append(
            Issue(
                severity="critical",
                issue_id="empty-list",
                location=field_name,
                summary=f"`{field_name}` must not be empty",
                detail="Empty list in required field.",
                remediation=f"Add at least one value to `{field_name}`.",
            )
        )
    return values


def selector_has_expression(selector: Dict[str, object]) -> bool:
    return any(key in selector for key in SELECTOR_EXPR_KEYS)


def load_policy(path: Path) -> Dict[str, object]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("policy root must be an object")
    return data


def use_case_domains(use_case_id: str, use_case_cfg: Dict[str, object], issues: List[Issue]) -> Set[str]:
    raw = use_case_cfg.get("domains")
    if raw is None:
        issues.append(
            Issue(
                severity="warning",
                issue_id="missing-use-case-domains",
                location=f"use_cases.{use_case_id}.domains",
                summary="Use case missing `domains`",
                detail="Domain tags are optional today but reduce maintenance insight.",
                remediation="Add 1+ domain tags for this use case.",
            )
        )
        return set()
    if not isinstance(raw, list):
        issues.append(
            Issue(
                severity="warning",
                issue_id="bad-use-case-domains",
                location=f"use_cases.{use_case_id}.domains",
                summary="`domains` must be a list",
                detail="Domain metadata is not an array.",
                remediation="Convert `domains` to an array of strings.",
            )
        )
        return set()
    values: Set[str] = set()
    for item in raw:
        if isinstance(item, str) and item.strip():
            values.add(item.strip())
        else:
            issues.append(
                Issue(
                    severity="warning",
                    issue_id="invalid-domain-value",
                    location=f"use_cases.{use_case_id}.domains",
                    summary="Invalid domain value",
                    detail="Each domain entry must be a non-empty string.",
                    remediation="Use non-empty string tags such as `navigation` or `storage`.",
                )
            )
    if not values:
        issues.append(
            Issue(
                severity="warning",
                issue_id="empty-domains",
                location=f"use_cases.{use_case_id}.domains",
                summary="Empty domain list",
                detail="No domain tag provides lower visibility in domain coverage checks.",
                remediation="Add at least one domain tag.",
            )
        )
    return values


def selector_suite_ids(use_cases: Dict[str, object], use_case_ids: List[str]) -> Set[str]:
    linked: Set[str] = set()
    for use_case_id in use_case_ids:
        cfg = use_cases.get(use_case_id)
        if not isinstance(cfg, dict):
            continue
        selectors = cfg.get("selectors")
        if not isinstance(selectors, list):
            continue
        for selector in selectors:
            if not isinstance(selector, dict):
                continue
            suite_id = selector.get("suite")
            if isinstance(suite_id, str) and suite_id.strip():
                linked.add(suite_id.strip())
    return linked


def analyze(policy: Dict[str, object]) -> Tuple[List[Issue], Dict[str, int]]:
    issues: List[Issue] = []
    suites = policy.get("suites")
    use_cases = policy.get("use_cases")
    profiles = policy.get("profiles")

    if not isinstance(suites, dict):
        issues.append(
            Issue(
                severity="critical",
                issue_id="missing-suites",
                location="policy.suites",
                summary="`suites` must be an object",
                detail="Cannot build maintenance graph without suite definitions.",
                remediation="Define `suites` as an object keyed by suite id.",
            )
        )
        suites = {}
    if not isinstance(use_cases, dict):
        issues.append(
            Issue(
                severity="critical",
                issue_id="missing-use-cases",
                location="policy.use_cases",
                summary="`use_cases` must be an object",
                detail="Cannot build maintenance graph without use cases.",
                remediation="Define `use_cases` as an object keyed by use-case id.",
            )
        )
        use_cases = {}
    if not isinstance(profiles, dict):
        issues.append(
            Issue(
                severity="critical",
                issue_id="missing-profiles",
                location="policy.profiles",
                summary="`profiles` must be an object",
                detail="Cannot build maintenance graph without profile definitions.",
                remediation="Define `profiles` as an object keyed by profile id.",
            )
        )
        profiles = {}

    globally_referenced_suites: Set[str] = set()
    globally_referenced_use_cases: Set[str] = set()
    stale_use_case_ids: Set[str] = set(use_cases.keys())
    stale_suite_ids: Set[str] = set(suites.keys())

    for use_case_id, raw_uc in use_cases.items():
        if not isinstance(raw_uc, dict):
            issues.append(
                Issue(
                    severity="critical",
                    issue_id="bad-use-case-object",
                    location=f"use_cases.{use_case_id}",
                    summary="Use case definition must be an object",
                    detail="Detected non-object definition.",
                    remediation="Replace with a map containing selectors and metadata.",
                )
            )
            continue

        use_case_domains(use_case_id, raw_uc, issues)
        selectors = raw_uc.get("selectors")
        if not isinstance(selectors, list) or not selectors:
            issues.append(
                Issue(
                    severity="critical",
                    issue_id="bad-use-case-selectors",
                    location=f"use_cases.{use_case_id}.selectors",
                    summary="Use case must define selector list",
                    detail="Missing/empty selectors weakens coverage semantics.",
                    remediation="Add at least one selector mapping this use case to suite cases.",
                )
            )
            continue
        for idx, selector_raw in enumerate(selectors):
            if not isinstance(selector_raw, dict):
                issues.append(
                    Issue(
                        severity="critical",
                        issue_id="bad-use-case-selector",
                        location=f"use_cases.{use_case_id}.selectors[{idx}]",
                        summary="Selector must be an object",
                        detail="Non-object selector entry.",
                        remediation="Define selector as map with suite and expression keys.",
                    )
                )
                continue
            suite_id = selector_raw.get("suite")
            if not isinstance(suite_id, str) or not suite_id.strip():
                issues.append(
                    Issue(
                        severity="critical",
                        issue_id="missing-selector-suite",
                        location=f"use_cases.{use_case_id}.selectors[{idx}].suite",
                        summary="Selector missing suite reference",
                        detail="Each selector must target a suite id.",
                        remediation="Add a valid `suite` string.",
                    )
                )
            elif suite_id not in suites:
                issues.append(
                    Issue(
                        severity="critical",
                        issue_id="unknown-selector-suite",
                        location=f"use_cases.{use_case_id}.selectors[{idx}].suite",
                        summary=f"Selector references unknown suite `{suite_id}`",
                        detail="Suite id is not defined under `suites`.",
                        remediation="Either define the suite or update selector to known suite.",
                    )
                )
            if not selector_has_expression(selector_raw):
                issues.append(
                    Issue(
                        severity="warning",
                        issue_id="selector-no-expression",
                        location=f"use_cases.{use_case_id}.selectors[{idx}]",
                        summary="Selector has no case expression",
                        detail=f"Needs one of {', '.join(SELECTOR_EXPR_KEYS)}.",
                        remediation="Add `case`, `case_regex`, `case_glob`, or `case_prefix`.",
                    )
                )

    for profile_id, raw_profile in profiles.items():
        if not isinstance(raw_profile, dict):
            issues.append(
                Issue(
                    severity="critical",
                    issue_id="bad-profile-object",
                    location=f"profiles.{profile_id}",
                    summary="Profile definition must be an object",
                    detail="Non-object profile definition detected.",
                    remediation="Replace with a map containing suites/use_cases arrays.",
                )
            )
            continue

        suite_ids = as_str_list(
            raw_profile.get("suites"),
            f"profiles.{profile_id}.suites",
            issues,
            allow_empty=False,
        )
        use_case_ids = as_str_list(
            raw_profile.get("use_cases"),
            f"profiles.{profile_id}.use_cases",
            issues,
            allow_empty=False,
        )
        required_use_case_ids = as_str_list(
            raw_profile.get("required_use_cases"),
            f"profiles.{profile_id}.required_use_cases",
            issues,
            allow_empty=True,
        )

        for idx, suite_id in enumerate(suite_ids):
            if suite_id in suite_ids[:idx]:
                issues.append(
                    Issue(
                        severity="warning",
                        issue_id="duplicate-profile-suite",
                        location=f"profiles.{profile_id}.suites[{idx}]",
                        summary="Duplicate suite entry",
                        detail=f"Suite `{suite_id}` appears multiple times in the profile.",
                        remediation="Deduplicate suite list.",
                    )
                )
        for idx, use_case_id in enumerate(use_case_ids):
            if use_case_id in use_case_ids[:idx]:
                issues.append(
                    Issue(
                        severity="warning",
                        issue_id="duplicate-profile-use-case",
                        location=f"profiles.{profile_id}.use_cases[{idx}]",
                        summary="Duplicate use case entry",
                        detail=f"Use case `{use_case_id}` appears multiple times in the profile.",
                        remediation="Deduplicate use case list.",
                    )
                )

        globally_referenced_suites.update(suite_ids)
        globally_referenced_use_cases.update(use_case_ids)
        for suite_id in suite_ids:
            if suite_id not in suites:
                issues.append(
                    Issue(
                        severity="critical",
                        issue_id="profile-suite-unknown",
                        location=f"profiles.{profile_id}.suites",
                        summary=f"Profile references unknown suite `{suite_id}`",
                        detail="Suite not found in `suites` section.",
                        remediation="Fix suite id or add suite definition.",
                    )
                )
        for use_case_idx, use_case_id in enumerate(use_case_ids):
            if use_case_id not in use_cases:
                issues.append(
                    Issue(
                        severity="critical",
                        issue_id="profile-use-case-unknown",
                        location=f"profiles.{profile_id}.use_cases",
                        summary=f"Profile references unknown use case `{use_case_id}`",
                        detail="Use case not found in `use_cases` section.",
                        remediation="Fix use case id or add use case definition.",
                    )
                )
            else:
                selectors = use_cases[use_case_id].get("selectors", [])  # type: ignore[index]
                if isinstance(selectors, list):
                    for selector_idx, selector in enumerate(selectors):
                        if not isinstance(selector, dict):
                            continue
                        selector_suite = selector.get("suite")
                        if (
                            isinstance(selector_suite, str)
                            and selector_suite.strip()
                            and selector_suite not in suite_ids
                        ):
                            issues.append(
                                Issue(
                                    severity="warning",
                                    issue_id="selector-outside-profile-suite",
                                    location=(
                                        f"profiles.{profile_id}.use_cases[{use_case_idx}]"
                                        f".selectors[{selector_idx}]"
                                    ),
                                    summary="Selector suite outside profile scope",
                                    detail=(
                                        f"Use case `{use_case_id}` selector points to suite `{selector_suite}`, "
                                        f"but profile `{profile_id}` does not run that suite."
                                    ),
                                    remediation="Either add suite to profile.suites or adjust selector.",
                                )
                            )

        required_suites = [s for s in suite_ids if isinstance(suites.get(s), dict) and bool(suites.get(s, {}).get("required", False))]  # type: ignore[union-attr]
        linked_suites = selector_suite_ids(use_cases, use_case_ids)
        for required_suite in required_suites:
            if required_suite not in linked_suites:
                issues.append(
                    Issue(
                        severity="warning",
                        issue_id="required-suite-unlinked",
                        location=f"profiles.{profile_id}.suites",
                        summary=f"Required suite `{required_suite}` lacks use-case coverage",
                        detail="No selector in profile use-cases reaches this required suite.",
                        remediation="Add or adjust use-case selector to include this suite.",
                    )
                )

        required_domains = set(as_str_list(raw_profile.get("required_domains"), f"profiles.{profile_id}.required_domains", issues))
        try:
            raw_min_domain_coverage = raw_profile.get("min_domain_coverage", 1.0)
            min_domain_coverage = float(raw_min_domain_coverage)
        except (TypeError, ValueError):
            issues.append(
                Issue(
                    severity="warning",
                    issue_id="bad-min-domain-coverage",
                    location=f"profiles.{profile_id}.min_domain_coverage",
                    summary="Invalid domain coverage threshold",
                    detail=f"`{raw_profile.get('min_domain_coverage')}` is not numeric.",
                    remediation="Set `min_domain_coverage` to a number in [0.0, 1.0].",
                )
            )
            min_domain_coverage = 1.0

        min_domain_coverage = min(1.0, max(0.0, min_domain_coverage))
        if required_domains:
            covered: Set[str] = set()
            for use_case_id in required_use_case_ids:
                uc_cfg = use_cases.get(use_case_id)
                if isinstance(uc_cfg, dict):
                    covered.update(use_case_domains(use_case_id, uc_cfg, issues))
            missing_domains = sorted(d for d in required_domains if d not in covered)
            covered_count = len(required_domains - set(missing_domains))
            coverage_ratio = covered_count / len(required_domains)
            if coverage_ratio + 1e-9 < min_domain_coverage:
                issues.append(
                    Issue(
                        severity="warning",
                        issue_id="profile-domain-coverage-ratio",
                        location=f"profiles.{profile_id}.required_domains",
                        summary=(
                            f"Domain coverage {coverage_ratio:.2f} below required threshold "
                            f"{min_domain_coverage:.2f}"
                        ),
                        detail=(
                            "Required domains are not covered by required use cases above threshold."
                        ),
                        remediation=(
                            "Increase required_use_cases coverage or lower `min_domain_coverage`."
                        ),
                    )
                )
            if missing_domains:
                issues.append(
                    Issue(
                        severity="warning",
                        issue_id="profile-domain-coverage",
                        location=f"profiles.{profile_id}.required_domains",
                        summary=f"Profile misses required domains: {', '.join(missing_domains)}",
                        detail="Domain coverage target not met by required_use_cases set.",
                        remediation="Add at least one required use case covering each missing domain.",
                    )
                )

        obs = raw_profile.get("observability_assertions")
        if isinstance(obs, dict):
            for key in ("max_suite_final_duration_sec", "max_suite_total_attempt_duration_sec"):
                suite_limits = obs.get(key)
                if isinstance(suite_limits, dict):
                    for suite_id, limit in suite_limits.items():
                        if suite_id not in suite_ids:
                            issues.append(
                                Issue(
                                    severity="warning",
                                    issue_id="observability-suite-not-in-profile",
                                    location=f"profiles.{profile_id}.observability_assertions.{key}.{suite_id}",
                                    summary=f"Observability assertion references suite `{suite_id}` not in profile",
                                    detail="Threshold for suite not scheduled in this profile.",
                                    remediation="Remove entry or add suite to profile.suites.",
                                )
                            )
                        if not isinstance(limit, (int, float)) or float(limit) <= 0:
                            issues.append(
                                Issue(
                                    severity="warning",
                                    issue_id="bad-observability-limit",
                                    location=f"profiles.{profile_id}.observability_assertions.{key}.{suite_id}",
                                    summary="Invalid suite assertion limit",
                                    detail="Suite-level limits must be positive numbers.",
                                    remediation="Set a positive numeric threshold in seconds.",
                                )
                            )

    unused_suites = sorted(stale_suite_ids - globally_referenced_suites)
    for suite_id in unused_suites:
        suite_cfg = suites[suite_id]
        reason = "not referenced by any profile"
        if isinstance(suite_cfg, dict) and suite_cfg.get("required", False):
            issues.append(
                Issue(
                    severity="critical",
                    issue_id="unused-required-suite",
                    location=f"suites.{suite_id}",
                    summary=f"Required suite `{suite_id}` is unused",
                    detail=f"Suite is marked required but {reason}.",
                    remediation="Either add this suite to at least one profile or mark it optional.",
                )
            )
        else:
            issues.append(
                Issue(
                    severity="info",
                    issue_id="unused-suite",
                    location=f"suites.{suite_id}",
                    summary=f"Suite `{suite_id}` is unused",
                    detail=f"{reason}.",
                    remediation="Either remove this suite from policy or move it into active profiles.",
                )
            )

    unused_use_cases = sorted(stale_use_case_ids - globally_referenced_use_cases)
    for use_case_id in unused_use_cases:
        uc_cfg = use_cases[use_case_id]
        if isinstance(uc_cfg, dict) and uc_cfg.get("required", False):
            issues.append(
                Issue(
                    severity="critical",
                    issue_id="unused-required-use-case",
                    location=f"use_cases.{use_case_id}",
                    summary=f"Required use case `{use_case_id}` is unused",
                    detail="Required use case is not listed in any profile use_cases.",
                    remediation="Either add this use case to at least one profile or remove required=true.",
                )
            )
        else:
            issues.append(
                Issue(
                    severity="info",
                    issue_id="unused-use-case",
                    location=f"use_cases.{use_case_id}",
                    summary=f"Use case `{use_case_id}` is unused",
                    detail="Not referenced by any profile.",
                    remediation="Either remove this use case or schedule it in a profile.",
                )
            )

    if profiles.get("ci-core") and profiles.get("release-nightly"):
        ci_suites = set(
            as_str_list(
                profiles["ci-core"].get("suites"),  # type: ignore[index]
                "profiles.ci-core.suites",
                [],
                allow_empty=True,
            )
        )
        nightly_suites = set(
            as_str_list(
                profiles["release-nightly"].get("suites"),  # type: ignore[index]
                "profiles.release-nightly.suites",
                [],
                allow_empty=True,
            )
        )
        missing_from_nightly = sorted(s for s in ci_suites if s not in nightly_suites)
        if missing_from_nightly:
            issues.append(
                Issue(
                    severity="warning",
                    issue_id="nightly-incomplete-core",
                    location="profiles.release-nightly.suites",
                    summary="Nightly profile does not include all ci-core suites",
                    detail=f"Missing: {', '.join(missing_from_nightly)}",
                    remediation="Add missing core suites to release-nightly profile.",
                )
            )

    severity_counts = {
        "critical": sum(1 for issue in issues if issue.severity == "critical"),
        "warning": sum(1 for issue in issues if issue.severity == "warning"),
        "info": sum(1 for issue in issues if issue.severity == "info"),
    }
    return issues, severity_counts


def collect_safe_actions(policy: Dict[str, object], findings: List[Issue]) -> List[Action]:
    actions: List[Action] = []
    profiles = policy.get("profiles")
    if not isinstance(profiles, dict):
        return actions

    for profile_id, raw_profile in profiles.items():
        if not isinstance(raw_profile, dict):
            continue

        for field in ("suites", "use_cases"):
            raw_values = raw_profile.get(field)
            if not isinstance(raw_values, list):
                continue

            normalized: List[str] = []
            for item in raw_values:
                if isinstance(item, str):
                    normalized_value = item.strip()
                    if normalized_value:
                        normalized.append(normalized_value)

            deduped = _dedupe_preserve_order(normalized)
            if deduped != normalized:
                target = f"profiles.{profile_id}.{field}"
                findings.append(
                    Issue(
                        severity="warning",
                        issue_id="auto-fixable-duplicate-list",
                        location=target,
                        summary="List contains duplicate entries that are safe to dedupe",
                        detail="Duplicate values can be removed without changing effective policy behavior.",
                        remediation="Use the generated action plan patch to normalize this list.",
                    )
                )
                actions.append(
                    Action(
                        issue_id="duplicate-list-dedupe",
                        severity="warning",
                        target=target,
                        operation="dedupe-string-list",
                        before=normalized,
                        after=deduped,
                        rationale=(
                            f"Normalize {target} by removing duplicate IDs from profile `{profile_id}` "
                            "while preserving order."
                        ),
                    )
                )

    return actions


def to_int(value: object) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def load_history(path: Path, window: int) -> List[Dict[str, object]]:
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
    if window > 0:
        rows = rows[-window:]
    return rows


def write_history(path: Path, rows: List[Dict[str, object]], max_rows: int) -> None:
    if max_rows > 0 and len(rows) > max_rows:
        rows = rows[-max_rows:]
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(row, ensure_ascii=True) + "\n" for row in rows)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def build_trend(current: Dict[str, int], history: List[Dict[str, object]]) -> Dict[str, object]:
    previous = history[-1] if history else {}
    trend: Dict[str, object] = {
        "previous_run": previous,
        "delta": {},
    }
    if not previous:
        return trend
    prev_counts = previous.get("counts", {}) if isinstance(previous, dict) else {}
    delta = {}
    for level in ("critical", "warning", "info", "total", "safe_actions"):
        curr = current.get(level, 0)
        if not isinstance(curr, int):
            curr = to_int(curr)
        prev = to_int(prev_counts.get(level, 0)) if isinstance(prev_counts, dict) else 0
        delta[level] = curr - prev
    trend["delta"] = delta
    return trend


def set_json_path(root: Dict[str, object], target: str, value: List[str]) -> bool:
    parts = target.split(".")
    cursor: Any = root
    for part in parts[:-1]:
        if not isinstance(cursor, dict) or part not in cursor:
            return False
        cursor = cursor[part]
    if not isinstance(cursor, dict):
        return False
    cursor[parts[-1]] = value
    return True


def apply_autofix_actions(policy: Dict[str, object], actions: Sequence[Action]) -> Tuple[Dict[str, object], int]:
    patched = copy.deepcopy(policy)
    applied = 0
    for action in actions:
        if action.operation != "dedupe-string-list":
            continue
        if set_json_path(patched, action.target, action.after):
            applied += 1
    return patched, applied


def build_patch_text(original_policy_path: Path, patched_policy: Dict[str, object]) -> str:
    original = original_policy_path.read_text(encoding="utf-8").splitlines()
    normalized = json.dumps(patched_policy, ensure_ascii=True, indent=2, sort_keys=False).splitlines()
    return "\n".join(
        difflib.unified_diff(
            original,
            normalized,
            fromfile=str(original_policy_path),
            tofile=f"{original_policy_path}.autofix",
            lineterm="",
        )
    )


def summarize_action_count(actions: Sequence[Action]) -> Dict[str, int]:
    return {
        "safe": len(actions),
        "executed": len(actions),
    }


def render_markdown(
    issues: List[Issue],
    actions: List[Action],
    action_count: Dict[str, int],
    policy_path: Path,
    trend: Dict[str, object],
) -> str:
    lines: List[str] = [
        "# Harness Maintenance Plan",
        "",
        f"- Policy: `{policy_path}`",
        f"- Generated: {datetime.now(timezone.utc).isoformat()}",
        "",
        "## Summary",
    ]
    critical = [i for i in issues if i.severity == "critical"]
    warning = [i for i in issues if i.severity == "warning"]
    info = [i for i in issues if i.severity == "info"]
    lines.append(f"- critical: {len(critical)}")
    lines.append(f"- warning: {len(warning)}")
    lines.append(f"- info: {len(info)}")
    lines.append(f"- total: {len(issues)}")
    lines.append(f"- safe_actions: {action_count['safe']}")
    lines.append(f"- executed_actions: {action_count['executed']}")
    if trend.get("delta"):
        delta = trend["delta"]
        if isinstance(delta, dict):
            for key in ("critical", "warning", "info", "total", "safe_actions"):
                if key not in delta:
                    continue
                lines.append(f"- delta {key}: {delta[key]}")
    lines.append("")

    for title, group in (
        ("Critical", critical),
        ("Warnings", warning),
        ("Info", info),
    ):
        lines.append(f"## {title}")
        if not group:
            lines.append("- None")
            lines.append("")
            continue
        for item in sorted(group, key=lambda i: (i.location, i.issue_id)):
            lines.append(f"- [{item.severity.upper()}] `{item.location}`")
            lines.append(f"  - {item.summary}")
            lines.append(f"  - {item.detail}")
            lines.append(f"  - Remediation: {item.remediation}")
        lines.append("")

    lines.append("## Suggested Maintenance Actions")
    if not actions:
        lines.append("- None")
    else:
        for action in sorted(actions, key=lambda a: a.target):
            lines.append(
                f"- [{action.severity.upper()}] {action.operation} on `{action.target}`"
            )
            lines.append(f"  - issue: {action.issue_id}")
            lines.append(f"  - {action.rationale}")
            lines.append(f"  - before: {action.before}")
            lines.append(f"  - after: {action.after}")
    lines.append("")
    lines.append("## Minimal One-Liner")
    lines.append("```bash")
    lines.append(
        "python3 scripts/check_harness_maintenance.py --policy scripts/harness_policy.json "
        "--json /tmp/harness_maintenance.json --report /tmp/harness_maintenance.md "
        "--actions /tmp/harness_maintenance_actions.json --patch /tmp/harness_maintenance.patch "
        "--history /tmp/harness_maintenance_history.jsonl"
    )
    lines.append("```")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate harness maintenance cleanup suggestions.")
    parser.add_argument(
        "--policy",
        default="",
        help="Path to harness policy JSON (default: scripts/harness_policy.json relative to script dir).",
    )
    parser.add_argument(
        "--json",
        dest="json_path",
        default="",
        help="Write machine-readable report to this JSON path.",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Write markdown plan to this path.",
    )
    parser.add_argument(
        "--actions",
        default="",
        help="Write safe action list JSON to this path.",
    )
    parser.add_argument(
        "--patch",
        default="",
        help="Write unified patch for safe actions to this path.",
    )
    parser.add_argument(
        "--history",
        default="",
        help="Append run record to this JSONL history file.",
    )
    parser.add_argument(
        "--history-window",
        type=int,
        default=20,
        help="How many recent history rows to compare for trend.",
    )
    parser.add_argument(
        "--history-max-rows",
        type=int,
        default=200,
        help="Maximum history rows retained on disk.",
    )
    parser.add_argument(
        "--ci",
        action="store_true",
        help="Exit non-zero when critical or warning issues are present.",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    policy_path = Path(args.policy).resolve() if args.policy else script_dir / "harness_policy.json"
    if not policy_path.exists():
        print(f"Harness maintenance check failed: policy not found: {policy_path}")
        return 1

    try:
        policy = load_policy(policy_path)
    except Exception as exc:
        print(f"Harness maintenance check failed: cannot parse policy: {exc}")
        return 1

    issues, counts = analyze(policy)
    action_items = collect_safe_actions(policy, issues)
    action_count = summarize_action_count(action_items)
    counts["total"] = counts["critical"] + counts["warning"] + counts["info"]
    counts["safe_actions"] = action_count["safe"]
    patched_policy = policy
    if action_items:
        patched_policy, action_count["executed"] = apply_autofix_actions(policy, action_items)

    trend: Dict[str, object] = {}
    if args.history:
        history_path = Path(args.history)
        history = load_history(history_path, max(args.history_window, 0))
        trend = build_trend(counts, history)
        history.append(
            {
                "policy_path": str(policy_path),
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "counts": counts,
            }
        )
        try:
            write_history(history_path, history, max(args.history_max_rows, 0))
        except Exception as exc:
            print(f"Harness maintenance check failed: cannot write history: {exc}")
            return 1
    else:
        trend = {"previous_run": {}, "delta": {}}

    issues_sorted = sorted(
        issues,
        key=lambda i: (
            {"critical": 0, "warning": 1, "info": 2}.get(i.severity, 3),
            i.location,
            i.issue_id,
        ),
    )

    if args.json_path:
        out = {
            "policy_path": str(policy_path),
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "counts": counts,
            "trend": trend,
            "issues": [asdict(issue) for issue in issues_sorted],
            "actions": [asdict(action) for action in action_items],
            "action_summary": action_count,
        }
        out_path = Path(args.json_path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(out, ensure_ascii=True, indent=2), encoding="utf-8")
        print(f"Wrote JSON report: {out_path}")

    if args.actions:
        actions_path = Path(args.actions)
        actions_path.parent.mkdir(parents=True, exist_ok=True)
        actions_path.write_text(
            json.dumps(
                {
                    "policy_path": str(policy_path),
                    "generated_at": datetime.now(timezone.utc).isoformat(),
                    "actions": [asdict(action) for action in action_items],
                    "summary": action_count,
                },
                ensure_ascii=True,
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"Wrote action file: {actions_path}")

    if args.patch:
        patch_path = Path(args.patch)
        patch_path.parent.mkdir(parents=True, exist_ok=True)
        if action_count["safe"]:
            patch_text = build_patch_text(policy_path, patched_policy)
        else:
            patch_text = "# No safe maintenance actions were generated.\n"
        patch_path.write_text(patch_text, encoding="utf-8")
        print(f"Wrote patch file: {patch_path}")

    if args.report:
        report = render_markdown(issues_sorted, action_items, action_count, policy_path, trend)
        report_path = Path(args.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(report, encoding="utf-8")
        print(f"Wrote markdown report: {report_path}")
    else:
        for issue in issues_sorted:
            print(f"[{issue.severity.upper()}] {issue.location}: {issue.summary}")
            print(f"  {issue.detail}")
            print(f"  remediation: {issue.remediation}")

    if args.ci and (counts["critical"] + counts["warning"] > 0):
        print("Harness maintenance check failed: critical or warning issues found.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
