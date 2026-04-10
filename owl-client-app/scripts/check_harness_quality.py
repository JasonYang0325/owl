#!/usr/bin/env python3
"""Validate harness policy quality and profile coverage invariants."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple


SELECTOR_EXPR_KEYS = ("case", "case_regex", "case_glob", "case_prefix")


def load_json(path: Path) -> Dict[str, object]:
    with path.open("r", encoding="utf-8") as fp:
        data = json.load(fp)
    if not isinstance(data, dict):
        raise ValueError("policy root must be a JSON object")
    return data


def as_str_list(
    raw: object,
    *,
    field_name: str,
    findings: List[str],
    allow_empty: bool = True,
) -> List[str]:
    if raw is None:
        if allow_empty:
            return []
        findings.append(f"{field_name} is missing")
        return []
    if not isinstance(raw, list):
        findings.append(f"{field_name} must be a list")
        return []
    values: List[str] = []
    for idx, item in enumerate(raw):
        if not isinstance(item, str) or not item.strip():
            findings.append(f"{field_name}[{idx}] must be a non-empty string")
            continue
        values.append(item.strip())
    if not allow_empty and not values:
        findings.append(f"{field_name} must not be empty")
    return values


def selector_has_expression(selector: Dict[str, object]) -> bool:
    return any(key in selector for key in SELECTOR_EXPR_KEYS)


def use_case_domains(
    use_case_id: str,
    use_case_cfg: Dict[str, object],
    findings: List[str],
) -> Set[str]:
    domains = as_str_list(
        use_case_cfg.get("domains"),
        field_name=f"use_cases.{use_case_id}.domains",
        findings=findings,
        allow_empty=False,
    )
    return set(domains)


def collect_profile_suite_links(
    use_case_ids: List[str],
    use_cases: Dict[str, object],
) -> Set[str]:
    linked: Set[str] = set()
    for use_case_id in use_case_ids:
        cfg = use_cases.get(use_case_id)
        if not isinstance(cfg, dict):
            continue
        selectors = cfg.get("selectors", [])
        if not isinstance(selectors, list):
            continue
        for selector in selectors:
            if not isinstance(selector, dict):
                continue
            suite_id = selector.get("suite")
            if isinstance(suite_id, str) and suite_id:
                linked.add(suite_id)
    return linked


def validate(
    policy: Dict[str, object],
) -> Tuple[List[str], List[str]]:
    findings: List[str] = []
    notes: List[str] = []

    suites = policy.get("suites")
    profiles = policy.get("profiles")
    use_cases = policy.get("use_cases")
    if not isinstance(suites, dict):
        findings.append("suites must be an object")
        suites = {}
    if not isinstance(profiles, dict):
        findings.append("profiles must be an object")
        profiles = {}
    if not isinstance(use_cases, dict):
        findings.append("use_cases must be an object")
        use_cases = {}

    all_use_case_domains: Set[str] = set()
    globally_referenced_suites: Set[str] = set()
    globally_referenced_use_cases: Set[str] = set()

    for use_case_id, raw_cfg in use_cases.items():
        if not isinstance(raw_cfg, dict):
            findings.append(f"use_cases.{use_case_id} must be an object")
            continue

        selectors = raw_cfg.get("selectors")
        if not isinstance(selectors, list) or not selectors:
            findings.append(f"use_cases.{use_case_id}.selectors must be a non-empty list")
        else:
            for idx, raw_selector in enumerate(selectors):
                if not isinstance(raw_selector, dict):
                    findings.append(f"use_cases.{use_case_id}.selectors[{idx}] must be an object")
                    continue
                suite_id = raw_selector.get("suite")
                if not isinstance(suite_id, str) or not suite_id:
                    findings.append(f"use_cases.{use_case_id}.selectors[{idx}].suite must be a non-empty string")
                elif suite_id not in suites:
                    findings.append(f"use_cases.{use_case_id}.selectors[{idx}].suite references unknown suite `{suite_id}`")
                if not selector_has_expression(raw_selector):
                    findings.append(
                        f"use_cases.{use_case_id}.selectors[{idx}] needs one of "
                        f"{', '.join(SELECTOR_EXPR_KEYS)}"
                    )

        all_use_case_domains.update(use_case_domains(use_case_id, raw_cfg, findings))

    for profile_id, raw_cfg in profiles.items():
        if not isinstance(raw_cfg, dict):
            findings.append(f"profiles.{profile_id} must be an object")
            continue

        suite_ids = as_str_list(
            raw_cfg.get("suites"),
            field_name=f"profiles.{profile_id}.suites",
            findings=findings,
            allow_empty=False,
        )
        if len(suite_ids) != len(set(suite_ids)):
            findings.append(f"profiles.{profile_id}.suites contains duplicate entries")
        use_case_ids = as_str_list(
            raw_cfg.get("use_cases"),
            field_name=f"profiles.{profile_id}.use_cases",
            findings=findings,
            allow_empty=False,
        )
        if len(use_case_ids) != len(set(use_case_ids)):
            findings.append(f"profiles.{profile_id}.use_cases contains duplicate entries")
        required_use_case_ids = as_str_list(
            raw_cfg.get("required_use_cases"),
            field_name=f"profiles.{profile_id}.required_use_cases",
            findings=findings,
            allow_empty=True,
        )
        globally_referenced_suites.update(suite_ids)
        globally_referenced_use_cases.update(use_case_ids)

        for suite_id in suite_ids:
            if suite_id not in suites:
                findings.append(f"profiles.{profile_id}.suites references unknown suite `{suite_id}`")
        for use_case_id in use_case_ids:
            if use_case_id not in use_cases:
                findings.append(f"profiles.{profile_id}.use_cases references unknown use case `{use_case_id}`")
        for use_case_id in required_use_case_ids:
            if use_case_id not in use_case_ids:
                findings.append(
                    f"profiles.{profile_id}.required_use_cases contains `{use_case_id}` "
                    "that is not listed in use_cases"
                )
        for use_case_id in use_case_ids:
            uc_raw = use_cases.get(use_case_id)
            if not isinstance(uc_raw, dict):
                continue
            selectors = uc_raw.get("selectors", [])
            if not isinstance(selectors, list):
                continue
            for idx, selector in enumerate(selectors):
                if not isinstance(selector, dict):
                    continue
                suite_id = selector.get("suite")
                if isinstance(suite_id, str) and suite_id and suite_id not in suite_ids:
                    findings.append(
                        f"profiles.{profile_id}.use_cases includes `{use_case_id}` but selector[{idx}] suite "
                        f"`{suite_id}` is not in this profile's suites"
                    )

        linked_suites = collect_profile_suite_links(use_case_ids, use_cases)
        required_suite_ids: List[str] = []
        missing_required_suite_links: List[str] = []
        for suite_id in suite_ids:
            suite_cfg = suites.get(suite_id)
            if not isinstance(suite_cfg, dict):
                continue
            if bool(suite_cfg.get("required", False)):
                required_suite_ids.append(suite_id)
                if suite_id not in linked_suites:
                    missing_required_suite_links.append(suite_id)
        if missing_required_suite_links:
            findings.append(
                f"profiles.{profile_id} has required suites with no use-case selector: "
                + ", ".join(sorted(missing_required_suite_links))
            )

        required_domains = set(
            as_str_list(
                raw_cfg.get("required_domains"),
                field_name=f"profiles.{profile_id}.required_domains",
                findings=findings,
                allow_empty=True,
            )
        )
        if not required_domains:
            for use_case_id in required_use_case_ids:
                uc_cfg = use_cases.get(use_case_id)
                if isinstance(uc_cfg, dict):
                    required_domains.update(use_case_domains(use_case_id, uc_cfg, findings))

        raw_min_cov = raw_cfg.get("min_domain_coverage", 1.0)
        try:
            min_cov = float(raw_min_cov)
        except (TypeError, ValueError):
            min_cov = 1.0
            findings.append(f"profiles.{profile_id}.min_domain_coverage must be numeric")
        min_cov = max(0.0, min(1.0, min_cov))

        covered_domains: Set[str] = set()
        for use_case_id in required_use_case_ids:
            uc_cfg = use_cases.get(use_case_id)
            if isinstance(uc_cfg, dict):
                covered_domains.update(use_case_domains(use_case_id, uc_cfg, findings))
        missing_domains = sorted(d for d in required_domains if d not in covered_domains)
        coverage = 1.0
        if required_domains:
            coverage = len(required_domains.intersection(covered_domains)) / len(required_domains)
        if coverage + 1e-9 < min_cov:
            findings.append(
                f"profiles.{profile_id} domain coverage {coverage:.2f} below min_domain_coverage {min_cov:.2f}"
            )
        if missing_domains and min_cov >= 0.999:
            findings.append(f"profiles.{profile_id} missing required domains: {', '.join(missing_domains)}")

        unknown_domains = sorted(d for d in required_domains if d not in all_use_case_domains)
        if unknown_domains:
            findings.append(
                f"profiles.{profile_id}.required_domains contains unknown domains: "
                + ", ".join(unknown_domains)
            )

        observability_raw = raw_cfg.get("observability_assertions")
        if observability_raw is not None:
            if not isinstance(observability_raw, dict):
                findings.append(f"profiles.{profile_id}.observability_assertions must be an object")
            else:
                for key in ("max_total_attempt_duration_sec", "max_required_final_duration_sec"):
                    if key not in observability_raw:
                        continue
                    raw_limit = observability_raw.get(key)
                    try:
                        limit = float(raw_limit)
                    except (TypeError, ValueError):
                        findings.append(f"profiles.{profile_id}.observability_assertions.{key} must be numeric")
                        continue
                    if limit <= 0:
                        findings.append(f"profiles.{profile_id}.observability_assertions.{key} must be > 0")

                for map_key in ("max_suite_final_duration_sec", "max_suite_total_attempt_duration_sec"):
                    raw_map = observability_raw.get(map_key)
                    if raw_map is None:
                        continue
                    if not isinstance(raw_map, dict):
                        findings.append(
                            f"profiles.{profile_id}.observability_assertions.{map_key} must be an object"
                        )
                        continue
                    for suite_id, raw_limit in raw_map.items():
                        sid = str(suite_id)
                        try:
                            limit = float(raw_limit)
                        except (TypeError, ValueError):
                            findings.append(
                                f"profiles.{profile_id}.observability_assertions.{map_key}.{sid} must be numeric"
                            )
                            continue
                        if limit <= 0:
                            findings.append(
                                f"profiles.{profile_id}.observability_assertions.{map_key}.{sid} must be > 0"
                            )
                        if sid not in suite_ids:
                            findings.append(
                                f"profiles.{profile_id}.observability_assertions.{map_key} references suite "
                                f"`{sid}` not listed in profile suites"
                            )

        linked_required_suites = len([suite_id for suite_id in required_suite_ids if suite_id in linked_suites])
        notes.append(
            f"profile {profile_id}: {len(required_domains.intersection(covered_domains))}/"
            f"{len(required_domains) if required_domains else 0} required domains covered; "
            f"{linked_required_suites}/{len(required_suite_ids)} required suites linked to use-cases"
        )

    ci_core = profiles.get("ci-core")
    release_nightly = profiles.get("release-nightly")
    if isinstance(ci_core, dict) and isinstance(release_nightly, dict):
        ci_suites = set(as_str_list(ci_core.get("suites"), field_name="profiles.ci-core.suites", findings=[], allow_empty=True))
        nightly_suites = set(
            as_str_list(
                release_nightly.get("suites"),
                field_name="profiles.release-nightly.suites",
                findings=[],
                allow_empty=True,
            )
        )
        if not ci_suites.issubset(nightly_suites):
            findings.append("profiles.release-nightly.suites should include all ci-core suites")

    unused_suites = sorted(str(sid) for sid in suites.keys() if str(sid) not in globally_referenced_suites)
    if unused_suites:
        findings.append("unused suites not referenced by any profile: " + ", ".join(unused_suites))

    unused_use_cases = sorted(str(uid) for uid in use_cases.keys() if str(uid) not in globally_referenced_use_cases)
    if unused_use_cases:
        findings.append("unused use_cases not referenced by any profile: " + ", ".join(unused_use_cases))

    return findings, notes


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate OWL harness policy quality invariants.")
    parser.add_argument(
        "--policy",
        default="",
        help="Path to harness policy JSON (default: scripts/harness_policy.json relative to script dir).",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    policy_path = Path(args.policy).resolve() if args.policy else script_dir / "harness_policy.json"

    if not policy_path.exists():
        print(f"Harness quality check failed: missing policy file: {policy_path}")
        return 1

    try:
        policy = load_json(policy_path)
    except Exception as exc:  # pragma: no cover
        print(f"Harness quality check failed: cannot parse policy: {exc}")
        return 1

    findings, notes = validate(policy)
    if findings:
        print("Harness quality check failed:")
        for finding in findings:
            print(f"- {finding}")
        return 1

    print("Harness quality check passed.")
    for note in notes:
        print(f"- {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
