#!/usr/bin/env python3
"""Enforce lightweight architecture dependency boundaries for OWL Swift layers."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Set


IMPORT_RE = re.compile(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_\.]*)\s*$")


@dataclass(frozen=True)
class Rule:
    name: str
    message: str
    scope_prefixes: tuple[str, ...] = ()
    scope_exact: tuple[str, ...] = ()
    forbidden_imports: tuple[str, ...] = ()
    exempt_prefixes: tuple[str, ...] = ()
    exempt_exact: tuple[str, ...] = ()
    allowed_importers_for_module: str = ""
    allowed_importer_prefixes: tuple[str, ...] = ()
    allowed_importer_exact: tuple[str, ...] = ()


def iter_swift_files(root: Path) -> Iterable[Path]:
    yield from sorted(root.rglob("*.swift"))


def parse_imports(path: Path) -> Set[str]:
    imports: Set[str] = set()
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="utf-8", errors="ignore")
    for line in text.splitlines():
        match = IMPORT_RE.match(line)
        if not match:
            continue
        module = match.group(1).split(".", 1)[0]
        imports.add(module)
    return imports


def in_scope(rel_path: str, *, prefixes: tuple[str, ...], exact: tuple[str, ...]) -> bool:
    if rel_path in exact:
        return True
    return any(rel_path.startswith(prefix) for prefix in prefixes)


def validate(
    import_map: Dict[str, Set[str]],
    rules: List[Rule],
) -> List[str]:
    findings: List[str] = []
    for rel_path, imports in sorted(import_map.items()):
        for rule in rules:
            if rule.allowed_importers_for_module:
                module = rule.allowed_importers_for_module
                if module not in imports:
                    continue
                if not in_scope(
                    rel_path,
                    prefixes=rule.allowed_importer_prefixes,
                    exact=rule.allowed_importer_exact,
                ):
                    findings.append(
                        f"[{rule.name}] {rel_path}: import `{module}` is not allowed in this layer. "
                        f"{rule.message}"
                    )
                continue

            if not in_scope(rel_path, prefixes=rule.scope_prefixes, exact=rule.scope_exact):
                continue
            if in_scope(rel_path, prefixes=rule.exempt_prefixes, exact=rule.exempt_exact):
                continue
            for forbidden in rule.forbidden_imports:
                if forbidden in imports:
                    findings.append(
                        f"[{rule.name}] {rel_path}: forbidden import `{forbidden}`. {rule.message}"
                    )
    return findings


def build_rules() -> List[Rule]:
    return [
        Rule(
            name="models-pure",
            scope_prefixes=("owl-client-app/Models/",),
            forbidden_imports=("OWLBridge", "SwiftUI", "AppKit"),
            message="Models must stay platform/UI independent.",
        ),
        Rule(
            name="cli-no-bridge",
            scope_prefixes=("owl-client-app/CLI/",),
            forbidden_imports=("OWLBridge",),
            message="CLI should depend on OWLBrowserLib/services, not call C-ABI bridge directly.",
        ),
        Rule(
            name="unit-no-bridge",
            scope_prefixes=("owl-client-app/Tests/Unit/",),
            forbidden_imports=("OWLBridge",),
            message="Unit tests must remain hermetic and avoid direct bridge dependency.",
        ),
        Rule(
            name="viewmodel-no-appkit",
            scope_prefixes=("owl-client-app/ViewModels/",),
            forbidden_imports=("AppKit",),
            message="Keep ViewModels independent from AppKit-specific UI APIs.",
        ),
        Rule(
            name="service-swiftui-exception",
            scope_prefixes=("owl-client-app/Services/",),
            forbidden_imports=("SwiftUI",),
            exempt_exact=("owl-client-app/Services/PermissionBridge.swift",),
            message=(
                "Services should not depend on SwiftUI. If this is intentional, move UI coupling to "
                "View/ViewModel or explicitly add a reviewed exception."
            ),
        ),
        Rule(
            name="bridge-import-scope",
            allowed_importers_for_module="OWLBridge",
            allowed_importer_prefixes=(
                "owl-client-app/Services/",
                "owl-client-app/ViewModels/",
                "owl-client-app/Tests/",
                "owl-client-app/TestKit/",
                "owl-client-app/UITest/",
            ),
            allowed_importer_exact=(
                "owl-client-app/Views/BrowserWindow.swift",
                "owl-client-app/Views/Content/WebContentRepresentable.swift",
                "owl-client-app/Views/Content/RemoteLayerView.swift",
            ),
            message=(
                "Bridge access should stay in Services/ViewModels/TestKit/UITest boundary; UI is allowed only in "
                "explicit adapter files."
            ),
        ),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description="Check architecture dependency boundaries.")
    parser.add_argument(
        "--repo-root",
        default="",
        help="Path to repository root (default: inferred from script location).",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    repo_root = Path(args.repo_root).resolve() if args.repo_root else script_dir.parents[1]
    client_root = repo_root / "owl-client-app"
    if not client_root.exists():
        print(f"Architecture boundary check failed: missing directory: {client_root}")
        return 1

    import_map: Dict[str, Set[str]] = {}
    for abs_path in iter_swift_files(client_root):
        rel_path = abs_path.relative_to(repo_root).as_posix()
        import_map[rel_path] = parse_imports(abs_path)

    rules = build_rules()
    findings = validate(import_map, rules)
    if findings:
        print("Architecture boundary check failed:")
        for finding in findings:
            print(f"- {finding}")
        return 1

    print("Architecture boundary check passed.")
    print(f"- scanned files: {len(import_map)}")
    print(f"- active rules: {len(rules)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
