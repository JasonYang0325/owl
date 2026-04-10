# 导航事件与错误处理 — Phase 总览

## 概述
- PRD: [docs/prd/navigation-events.md](../../prd/navigation-events.md)
- UI 设计稿: [docs/ui-design/navigation-events/design.md](../../ui-design/navigation-events/design.md)
- 模块设计: [docs/modules/module-f-navigation-events.md](../../modules/module-f-navigation-events.md)

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 预估行数 | AC |
|-------|------|------|------|---------|-----|
| 1 | Mojom + Host 导航事件 | pending | - | ~200 | AC-004 基础 |
| 2 | Bridge + Swift + 进度条/错误页 UI | pending | Phase 1 | ~280 | AC-001, AC-002, AC-005 |
| 3 | HTTP Auth 全栈 | pending | Phase 1 | ~250 | AC-003 |
| 4 | CLI 导航命令 | pending | Phase 2 | ~150 | AC-006, AC-007 |
| 5 | XCUITest E2E | pending | Phase 2, 3 | ~200 | AC-008 |

## 依赖图

```
Phase 1 (Mojom+Host)
   ├──► Phase 2 (Bridge+Swift+UI) ──► Phase 4 (CLI)
   └──► Phase 3 (HTTP Auth)          │
                │                     │
                └─────────┬───────────┘
                          ▼
                    Phase 5 (XCUITest)
```

Phase 2 和 Phase 3 可并行开发（互不依赖）。

## 跨 Phase 接口契约

### Phase 1 → Phase 2/3
- Mojom `NavigationEvent` struct（含 navigation_id）
- Mojom `WebViewObserver` 新增 4 个方法
- Mojom `WebViewHost` 新增 `RespondToAuthChallenge`
- Host 层 `OWLWebContents` 扩展接口

### Phase 2 → Phase 4
- TabViewModel `loadingProgress` / `navigationError` 属性
- `NavigationEventRing` 环形缓冲区

### Phase 2+3 → Phase 5
- 所有 UI 组件（ProgressBar, ErrorPageView 扩展, AuthAlertView）
- 测试用 HTML 页面

## 共享决策

1. **navigation_id** 使用 Chromium `NavigationHandle::GetNavigationId()`，int64
2. **导航失败语义**: `DidFinishNavigation(IsErrorPage/!HasCommitted)`，非 `DidFailLoad`
3. **Auth 入口**: `ContentBrowserClient::CreateLoginDelegate()`
4. **复用 ErrorPageView**: 扩展参数而非新建组件
5. **伪进度**: Task+sleep 而非 Timer.publish

## 变更日志

- 2026-04-04: 初始拆分，5 个 phase
