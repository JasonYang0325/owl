#!/usr/bin/env python3
"""
check_xcuitest.py — XCUITest 合规检查器（OWL Browser）

把 Phase E 调试出的 4 条规则变成可执行断言，防止回归。
每条规则都有根本原因注释。

用法：
    python3 scripts/check_xcuitest.py [--strict]
    python3 scripts/check_xcuitest.py Views/TopBar/AddressBarView.swift

退出码：
    0  全部通过
    1  发现违规
"""

import re
import sys
import os
from pathlib import Path
from typing import NamedTuple

# ──────────────────────────────────────────────────────────────────────────────
# 数据结构
# ──────────────────────────────────────────────────────────────────────────────

class Violation(NamedTuple):
    rule: str
    file: str
    line: int
    message: str
    hint: str

violations: list[Violation] = []

def warn(rule, path, line, message, hint):
    violations.append(Violation(rule, str(path), line, message, hint))

# ──────────────────────────────────────────────────────────────────────────────
# 辅助：读取文件，去掉行注释（不处理块注释，够用）
# ──────────────────────────────────────────────────────────────────────────────

def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return []

def is_comment(line: str) -> bool:
    return line.lstrip().startswith("//")

# ──────────────────────────────────────────────────────────────────────────────
# 规则 1：NSViewRepresentable 含 Coordinator 时，updateNSView 必须同步 parent
#
# 根本原因：Coordinator 只在 makeCoordinator() 创建一次，SwiftUI 每次渲染都
# 产生新的 struct，如果 updateNSView 不同步，coordinator.parent 永远是首次
# 渲染时的值（可能 onNavigate = nil），导致 XCUITest 触发的回调是空操作。
# ──────────────────────────────────────────────────────────────────────────────

RULE1 = "R1:coordinator-parent-sync"

def check_rule1(path: Path, lines: list[str]):
    src = "\n".join(lines)

    # 只检查包含 NSViewRepresentable 的文件
    if "NSViewRepresentable" not in src:
        return
    # 且包含 Coordinator class
    if "class Coordinator" not in src and "final class Coordinator" not in src:
        return

    # 找到所有 updateNSView 函数体
    # 简单策略：找 func updateNSView，然后往后找第一个平衡的 {}
    for i, line in enumerate(lines):
        if re.search(r'\bfunc updateNSView\b', line):
            # 收集函数体
            body_lines, start_line = _extract_block(lines, i)
            body = "\n".join(body_lines)
            if "context.coordinator.parent = self" not in body:
                warn(
                    RULE1, path, i + 1,
                    "updateNSView 缺少 `context.coordinator.parent = self`",
                    "在 updateNSView 第一行加: context.coordinator.parent = self\n"
                    "原因：不同步会导致 coordinator 持有陈旧闭包（onNavigate 可能为 nil）"
                )

# ──────────────────────────────────────────────────────────────────────────────
# 规则 2：NSViewRepresentable 创建 NSTextField 用于 AX 时，必须设置 staticText role
#
# 根本原因：SwiftUI 宿主层屏蔽了 NSTextField 默认的 AX role 推导，结果是
# AXUnknown。app.staticTexts["id"] 只查 AXStaticText，故找不到元素。
# ──────────────────────────────────────────────────────────────────────────────

RULE2 = "R2:ax-statictext-role"

def check_rule2(path: Path, lines: list[str]):
    src = "\n".join(lines)
    if "NSViewRepresentable" not in src:
        return

    # 检查 makeNSView 返回 NSTextField 的情况
    for i, line in enumerate(lines):
        if re.search(r'\bfunc makeNSView\b', line):
            body_lines, _ = _extract_block(lines, i)
            body = "\n".join(body_lines)
            # 只检查创建了 NSTextField 的 makeNSView
            if "NSTextField()" not in body and "NSTextField(frame:" not in body:
                continue
            # 只检查只读 AX label 用途（isEditable = false）
            # 可编辑地址栏 NSTextField 不需要 staticText role（否则反而错误）
            if "isEditable = false" not in body:
                continue
            if "setAccessibilityRole(.staticText)" not in body:
                warn(
                    RULE2, path, i + 1,
                    "makeNSView 创建 NSTextField 但缺少 setAccessibilityRole(.staticText)",
                    "在 makeNSView 中加: field.setAccessibilityRole(.staticText)\n"
                    "原因：SwiftUI 宿主层会覆盖 NSTextField 的 AX role 为 AXUnknown，"
                    "导致 app.staticTexts[\"id\"] 找不到元素"
                )

# ──────────────────────────────────────────────────────────────────────────────
# 规则 3：updateNSView 修改 stringValue 后必须调用 NSAccessibility.post
#
# 根本原因：SwiftUI 对视觉上不可见（frame 极小 + 裁切）的 NSTextField 可能
# 不会自动发 AX 变更通知。XCUITest 的 XCTNSPredicateExpectation 依赖通知
# 触发 snapshot 刷新。没有通知 = XCUITest 永远拿到缓存快照 = 15s 超时。
# ──────────────────────────────────────────────────────────────────────────────

RULE3 = "R3:ax-post-notification"

def check_rule3(path: Path, lines: list[str]):
    src = "\n".join(lines)
    if "NSViewRepresentable" not in src:
        return

    # R3 仅适用于只读 AX label（isEditable = false）
    # 可编辑 NSTextField（如地址栏）由 AppKit 自动处理 AX 通知
    if "isEditable = false" not in src:
        return

    for i, line in enumerate(lines):
        if re.search(r'\bfunc updateNSView\b', line):
            body_lines, _ = _extract_block(lines, i)
            body = "\n".join(body_lines)
            # 检查有 stringValue 赋值但没有 NSAccessibility.post 的情况
            # 用正则匹配任意变量名（不硬编码 "= value"）
            if re.search(r'\.stringValue\s*=\s*\w+', body):
                if "NSAccessibility.post" not in body:
                    warn(
                        RULE3, path, i + 1,
                        "updateNSView 修改 stringValue 但缺少 NSAccessibility.post(element:notification:)",
                        "修改 stringValue 后加: NSAccessibility.post(element: field, notification: .valueChanged)\n"
                        "原因：没有通知时 XCUITest 使用缓存快照，15s 后超时"
                    )

# ──────────────────────────────────────────────────────────────────────────────
# 规则 4：SwiftUI Text + .clipped() + .accessibilityLabel 反模式
#
# 根本原因：SwiftUI 对 frame 极小 + clipped 的 Text 不发 AX 布局变更通知，
# XCUITest 拿到的 label 是初始渲染时的值（通常为空），永远不更新。
# ──────────────────────────────────────────────────────────────────────────────

RULE4 = "R4:no-clipped-ax-text"

def check_rule4(path: Path, lines: list[str]):
    # 在 UITests 目录中不检查
    if "UITests" in str(path):
        return

    src = "\n".join(lines)
    # 找含有 .clipped() 且附近有 .accessibilityLabel 或 .accessibilityIdentifier 的 Text 块
    # 简单启发：在同一个链式调用中（相邻行）同时出现这三者
    window = 8  # 检查 8 行窗口
    for i, line in enumerate(lines):
        if is_comment(line):
            continue
        if re.search(r'\bText\s*\(', line):
            chunk = "\n".join(lines[i:i+window])
            has_clipped = ".clipped()" in chunk
            has_ax = ".accessibilityLabel(" in chunk or ".accessibilityIdentifier(" in chunk
            has_frame_small = re.search(r'\.frame\(width:\s*[012]', chunk)
            if has_clipped and has_ax and has_frame_small:
                warn(
                    RULE4, path, i + 1,
                    "Text() + .frame(小尺寸) + .clipped() + .accessibilityLabel 反模式",
                    "改用 AccessibleLabel（NSViewRepresentable NSTextField）\n"
                    "原因：SwiftUI 对裁切的极小 Text 不发 AX 通知，XCUITest label 永远是初始值"
                )

# ──────────────────────────────────────────────────────────────────────────────
# 辅助：提取函数体（简单括号平衡，不处理字符串内的括号）
# ──────────────────────────────────────────────────────────────────────────────

def _extract_block(lines: list[str], start: int) -> tuple[list[str], int]:
    """从 start 行开始，找到 { 然后收集到平衡的 } 为止。"""
    body = []
    depth = 0
    found_open = False
    for i in range(start, min(start + 80, len(lines))):
        line = lines[i]
        for ch in line:
            if ch == '{':
                depth += 1
                found_open = True
            elif ch == '}':
                depth -= 1
        body.append(line)
        if found_open and depth == 0:
            break
    return body, start

# ──────────────────────────────────────────────────────────────────────────────
# 主入口
# ──────────────────────────────────────────────────────────────────────────────

def check_file(path: Path):
    lines = read_lines(path)
    if not lines:
        return
    check_rule1(path, lines)
    check_rule2(path, lines)
    check_rule3(path, lines)
    check_rule4(path, lines)

def main():
    args = sys.argv[1:]
    strict = "--strict" in args
    targets = [a for a in args if not a.startswith("--")]

    base = Path(__file__).parent.parent  # owl-client-app/

    if targets:
        files = [Path(t) if os.path.isabs(t) else base / t for t in targets]
    else:
        # 默认扫描所有 Swift 源文件（排除测试和临时文件）
        files = [
            p for p in base.rglob("*.swift")
            if ".build" not in str(p) and "DerivedData" not in str(p)
        ]

    for f in sorted(files):
        check_file(f)

    if not violations:
        print("✓ XCUITest 合规检查通过（0 个违规）")
        sys.exit(0)

    # 按规则分组输出
    by_rule: dict[str, list[Violation]] = {}
    for v in violations:
        by_rule.setdefault(v.rule, []).append(v)

    rule_meta = {
        RULE1: "coordinator.parent 同步",
        RULE2: "AX role = staticText",
        RULE3: "NSAccessibility.post 通知",
        RULE4: "禁止 clipped Text 作为 AX label",
    }

    total = len(violations)
    print(f"✗ 发现 {total} 个 XCUITest 合规违规\n")

    for rule, vs in by_rule.items():
        label = rule_meta.get(rule, rule)
        print(f"── {rule}：{label} ({'严重' if rule != RULE4 else '警告'}) ──")
        for v in vs:
            rel = os.path.relpath(v.file, base)
            print(f"  {rel}:{v.line}  {v.message}")
            for hint_line in v.hint.split("\n"):
                print(f"    → {hint_line}")
        print()

    if strict or any(v.rule != RULE4 for v in violations):
        sys.exit(1)
    # RULE4 单独存在时只警告，不 --strict 时不 fail
    sys.exit(0)

if __name__ == "__main__":
    main()
