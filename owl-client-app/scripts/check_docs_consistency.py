#!/usr/bin/env python3
"""Validate key OWL docs stay consistent with executable source-of-truth."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_optional_text(path: Path) -> str:
    if not path.exists():
        return ""
    return read_text(path)


def extract_default_e2e_mode(run_tests_text: str) -> str:
    match = re.search(r"^\s*e2e\)\s*\n(?P<body>.*?)^\s*;;\s*$", run_tests_text, flags=re.M | re.S)
    if not match:
        return "unknown"
    body = match.group("body")
    if "run_harness" in body:
        return "harness"
    if "run_cpp" in body and "run_unit" in body and "run_pipeline" in body:
        return "legacy"
    return "unknown"


def parse_modules_status(modules_readme_text: str) -> Dict[str, str]:
    status: Dict[str, str] = {}
    row_re = re.compile(
        r"^\|\s*([A-L])\s*\|[^|]*\|[^|]*\|[^|]*\|\s*(done|pending)\s*\|$",
        flags=re.M,
    )
    for mod_id, mod_status in row_re.findall(modules_readme_text):
        status[mod_id] = mod_status
    return status


def parse_backlog_module_status(backlog_text: str) -> Dict[str, str]:
    per_module: Dict[str, List[str]] = {}

    # Current backlog rows:
    # - [MOD-E-SWIFT] P0 | DONE | ...
    row_re = re.compile(
        r"^\- \[MOD-([A-L])(?:-[A-Z0-9-]+)?\]\s+P\d+\s+\|\s+([A-Z_]+)\s+\|",
        flags=re.M,
    )
    # Archived rows:
    # - [MOD-A] DONE | 2026-03-31 | ...
    archive_re = re.compile(
        r"^\- \[MOD-([A-L])(?:-[A-Z0-9-]+)?\]\s+(DONE|TODO|IN_PROGRESS|BLOCKED)\s+\|",
        flags=re.M,
    )

    for mod_id, raw_status in row_re.findall(backlog_text):
        per_module.setdefault(mod_id, []).append(raw_status)
    for mod_id, raw_status in archive_re.findall(backlog_text):
        per_module.setdefault(mod_id, []).append(raw_status)

    status: Dict[str, str] = {}
    for mod_id, raw_statuses in per_module.items():
        normalized = [normalize_backlog_status(s) for s in raw_statuses]
        status[mod_id] = "done" if normalized and all(s == "done" for s in normalized) else "pending"
    return status


def normalize_backlog_status(raw_status: str) -> str:
    if raw_status == "DONE":
        return "done"
    return "pending"


def check_links_exist(markdown_text: str, base_dir: Path) -> List[str]:
    findings: List[str] = []
    link_re = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
    for target in link_re.findall(markdown_text):
        if target.startswith(("http://", "https://", "#")):
            continue
        rel = target.split("#", 1)[0]
        path = (base_dir / rel).resolve()
        if not path.exists():
            findings.append(f"missing link target: {rel}")
    return findings


def extract_section(text: str, heading: str) -> str:
    heading_re = re.compile(rf"^##+\s+{re.escape(heading)}\s*$")
    lines = text.splitlines()

    start = None
    for index, line in enumerate(lines):
        if heading_re.match(line.strip()):
            start = index + 1
            break
    if start is None:
        return ""

    end = len(lines)
    heading_boundary_re = re.compile(r"^##+\s+")
    for index in range(start, len(lines)):
        if heading_boundary_re.match(lines[index]):
            end = index
            break
    return "\n".join(lines[start:end]).strip()


def split_file_token_candidates(token: str) -> List[str]:
    cleaned = token.strip().strip("`").strip()
    cleaned = re.split(r"[（(\\[]", cleaned)[0].strip()
    if not cleaned or " " in cleaned:
        return []
    if cleaned.startswith(("http://", "https://", "#")):
        return []

    pair_match = re.match(r"^(?P<base>.+)\.(?P<ext1>[A-Za-z0-9]+)/(?:\.(?P<ext2>[A-Za-z0-9]+))$", cleaned)
    if pair_match:
        base = pair_match.group("base")
        ext1 = pair_match.group("ext1")
        ext2 = pair_match.group("ext2")
        return [f"{base}.{ext1}", f"{base}.{ext2}"]

    return [cleaned]


def extract_file_candidates(section: str) -> List[str]:
    candidates: List[str] = []

    for link in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", section):
        candidates.extend(split_file_token_candidates(link.group(1)))

    for code in re.findall(r"`([^`]*)`", section):
        candidates.extend(split_file_token_candidates(code))

    for file_ref in re.findall(r"(?<!`)([\\w./-]+\\.[A-Za-z0-9]+)(?!`)", section):
        candidates.extend(split_file_token_candidates(file_ref))

    return sorted(set(candidates))


def validate_module_file_list(
    module_path: Path, module_name: str, module_status: str, repo_root: Path
) -> Tuple[List[str], List[str]]:
    findings: List[str] = []
    warnings: List[str] = []
    text = module_path.read_text(encoding="utf-8")

    section = extract_section(text, "文件清单")
    if not section:
        findings.append(f"module doc docs/modules/{module_name} missing required sections: ## 文件清单")
        return findings, warnings

    candidates = extract_file_candidates(section)
    if not candidates:
        findings.append(f"module doc docs/modules/{module_name} has empty 文件清单 or no file paths.")
        return findings, warnings

    for target in candidates:
        path = (repo_root / target).resolve()
        if not path.exists():
            if module_status == "done":
                findings.append(f"module doc docs/modules/{module_name} references missing file: {target}")
            else:
                warnings.append(
                    f"module doc docs/modules/{module_name} references missing file: {target} (pending module)"
                )
    return findings, warnings


def check_agent_coverage(module_status: Dict[str, str]) -> Tuple[List[str], List[str]]:
    script_path = Path(__file__).resolve()
    repo_root = script_path.parents[2]

    required_files = [
        repo_root / "AGENT.md",
        repo_root / "docs" / "AGENT.md",
        repo_root / "docs" / "modules" / "AGENT.md",
        repo_root / "bridge" / "AGENT.md",
        repo_root / "client" / "AGENT.md",
        repo_root / "host" / "AGENT.md",
        repo_root / "mojom" / "AGENT.md",
        repo_root / "owl-client-app" / "AGENT.md",
        repo_root / "tools" / "AGENT.md",
        repo_root / "third_party" / "AGENT.md",
    ]

    findings: List[str] = []
    warnings: List[str] = []
    for path in required_files:
        rel = path.relative_to(repo_root)
        if not path.exists():
            findings.append(f"missing required agent file: {rel}")
            continue
        if not path.is_file():
            findings.append(f"required agent path exists but is not file: {rel}")

    modules_dir = repo_root / "docs" / "modules"
    module_list = [
        p.relative_to(modules_dir)
        for p in modules_dir.glob("module-[a-l]-*.md")
        if p.is_file()
    ]
    if not module_list:
        findings.append("docs/modules must contain module-* docs for A-L")

    for module in module_list:
        if "AGENT" in module.name.upper():
            continue
        module_path = modules_dir / module.name
        module_match = re.match(r"module-([A-L])-", module.name)
        module_id = module_match.group(1) if module_match else "?"
        module_state = module_status.get(module_id, "pending")
        text = module_path.read_text(encoding="utf-8")
        if not text:
            findings.append(f"module doc is empty: docs/modules/{module.name}")
            continue
        required_sections = ("## 目标", "## 验收标准", "## 测试计划", "## 文件清单")
        if not all(section in text for section in required_sections):
            missing = [section for section in required_sections if section not in text]
            findings.append(
                f"module doc docs/modules/{module.name} missing required sections: "+", ".join(missing)
            )
            continue
        find_f, warn_f = validate_module_file_list(module_path, module.name, module_state, repo_root)
        findings.extend(find_f)
        warnings.extend(warn_f)

    return findings, warnings


def main() -> int:
    script_path = Path(__file__).resolve()
    repo_root = script_path.parents[2]

    run_tests = repo_root / "owl-client-app" / "scripts" / "run_tests.sh"
    claude = repo_root / "CLAUDE.md"
    arch = repo_root / "docs" / "ARCHITECTURE.md"
    modules = repo_root / "docs" / "modules" / "README.md"
    backlog = repo_root / "docs" / "BACKLOG.md"
    owl_test_cmd = repo_root / ".claude" / "commands" / "owl-test.md"

    findings: List[str] = []
    warnings: List[str] = []

    run_tests_text = read_text(run_tests)
    claude_text = read_optional_text(claude)
    arch_text = read_text(arch)
    modules_text = read_text(modules)
    backlog_text = read_text(backlog)
    owl_test_text = read_optional_text(owl_test_cmd)

    default_e2e_mode = extract_default_e2e_mode(run_tests_text)
    if default_e2e_mode == "harness":
        if not claude_text:
            warnings.append("CLAUDE.md missing; optional e2e-gate skipped in export tree.")
        if not owl_test_text:
            warnings.append(".claude/commands/owl-test.md missing; optional e2e-gate skipped in export tree.")

    if default_e2e_mode == "harness" and claude_text:
        if not re.search(r"默认.*harness", claude_text):
            findings.append("CLAUDE.md should state default e2e is harness.")
        if "默认 e2e（cpp + unit + pipeline）" in claude_text:
            findings.append("CLAUDE.md still mentions legacy default e2e path.")

    if default_e2e_mode == "harness" and owl_test_text:
        if not re.search(r"`e2e`\s+—\s+harness（默认）", owl_test_text):
            findings.append(".claude/commands/owl-test.md should state e2e default is harness.")
        if "`e2e` — cpp + unit + pipeline（默认）" in owl_test_text:
            findings.append(".claude/commands/owl-test.md still mentions legacy default e2e path.")

    if "跨层集成测试占位" in arch_text:
        findings.append("docs/ARCHITECTURE.md still marks OWLIntegrationTests as placeholder.")

    module_status = parse_modules_status(modules_text)
    backlog_status = parse_backlog_module_status(backlog_text)
    for mod_id in sorted(module_status.keys()):
        if mod_id not in backlog_status:
            findings.append(f"docs/modules/README.md module {mod_id} missing in docs/BACKLOG.md.")
            continue
        if module_status[mod_id] != backlog_status[mod_id]:
            findings.append(
                f"module {mod_id} status mismatch: modules/README={module_status[mod_id]}, "
                f"BACKLOG={backlog_status[mod_id]}."
            )

    findings.extend(check_links_exist(claude_text, repo_root))
    module_findings, module_warnings = check_agent_coverage(module_status)
    findings.extend(module_findings)
    warnings.extend(module_warnings)

    if findings:
        print("Docs consistency check failed:")
        for item in findings:
            print(f"- {item}")
        return 1

    if warnings:
        print("Docs consistency check passed with warnings:")
        for item in warnings:
            print(f"- {item}")
    else:
        print("Docs consistency check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
