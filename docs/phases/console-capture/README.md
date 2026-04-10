# Console 与 JS 错误捕获 — Phase 总览

## 概述
- PRD: [docs/prd/console-capture.md](../../prd/console-capture.md)
- UI 设计: [docs/ui-design/console-capture/design.md](../../ui-design/console-capture/design.md)

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 预估行数 | AC |
|-------|------|------|------|---------|-----|
| 1 | Mojom + Host Console 捕获 | pending | - | ~150 | AC-001, AC-002 基础 |
| 2 | Bridge + Swift + Console 面板 UI | pending | Phase 1 | ~350 | AC-001~006 |
| 3 | CLI + XCUITest | pending | Phase 2 | ~200 | AC-007, AC-008 |

## 依赖图

```
Phase 1 (Mojom+Host) → Phase 2 (Bridge+Swift+UI) → Phase 3 (CLI+XCUITest)
```

线性依赖，无法并行。

## 跨 Phase 接口契约

### Phase 1 → Phase 2
- Mojom ConsoleLevel enum + ConsoleMessage struct (含 timestamp)
- Host OnDidAddMessageToConsole → Mojo OnConsoleMessage

### Phase 2 → Phase 3
- ConsoleViewModel（消息缓冲 + 过滤逻辑）
- BrowserControl 协议扩展

## 变更日志
- 2026-04-05: 初始拆分，3 个 phase
