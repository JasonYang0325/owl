# UI Atlas 风格对齐 — Phase 总览

## 概述
- PRD: [docs/prd/ui-atlas-alignment.md](../../prd/ui-atlas-alignment.md)
- UI Design: [docs/ui-design/ui-atlas-alignment/design.md](../../ui-design/ui-atlas-alignment/design.md)
- Figma: https://www.figma.com/design/FoOTYbU1QvPJFvi7o0uLJc

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 涉及文件 | 预估行数 |
|-------|------|------|------|---------|---------|
| 1 | ContentArea 背景修复 | pending | - | ContentAreaView.swift | ~10 行 |
| 2 | Sidebar 视觉重构 | pending | - | SidebarView, SidebarToolbar, TabRowView, PinnedTabRow, DesignTokens | ~150 行 |
| 3 | Sidebar Toggle + 宽度调整 | pending | Phase 2 | TopBarView, BrowserWindow, DesignTokens | ~100 行 |

## 依赖关系

```
Phase 1 ─────────────────────────┐
                                  ├──→ 完成
Phase 2 ──→ Phase 3 ─────────────┘
```

Phase 1 和 Phase 2 可并行执行。Phase 3 需等 Phase 2 完成后再开始。

## 跨 Phase 接口契约

- Phase 2 → Phase 3：`SidebarView` 重构后的三层结构（顶部固定区/中间内容/底部工具栏）是 Phase 3 sidebar toggle 的前提
- Phase 3 使用 `DesignTokens.swift` 中 Phase 2 已更新的 `OWL.sidebarWidth`

## 共享决策

- 所有颜色变更使用 `OWL.*` design tokens，dark mode active tab 例外使用 `Color(hex: 0x333333)`
- `isSidebarManuallyVisible` 使用 `@AppStorage("owl.sidebar.manuallyVisible")`
- 功能入口移除（历史/下载/AI/Agent/Console）为有意降级

## 变更日志

- 初始拆分：3 个 Phase
