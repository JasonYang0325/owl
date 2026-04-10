# 多标签管理 — Phase 总览

## 概述
- PRD: [docs/prd/multi-tab.md](../../prd/multi-tab.md)
- UI 设计稿: [docs/ui-design/multi-tab/design.md](../../ui-design/multi-tab/design.md)

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | AC 覆盖 | 预估行数 |
|-------|------|------|------|---------|---------|
| 1 | Host 多 WebView 基础设施 | pending | - | AC-001(部分), AC-003(部分) | ~250 |
| 2 | Swift 回调路由 + 渲染表面切换 | pending | Phase 1 | AC-001, AC-002, AC-003, AC-009 | ~300 |
| 3 | 新标签打开 | pending | Phase 2 | AC-007 | ~200 |
| 4 | 标签生命周期 UX | pending | Phase 2 | AC-005, AC-006 | ~250 |
| 5 | 会话恢复 | pending | Phase 4 | AC-004 | ~200 |
| 6 | XCUITest E2E | pending | Phase 1-5 | AC-008 | ~300 |

## 依赖关系图

```
Phase 1 (Host 基础设施)
  ↓
Phase 2 (Swift 回调路由)
  ↓          ↓
Phase 3    Phase 4
(新标签)   (Pin + Undo)
             ↓
           Phase 5
          (会话恢复)
             ↓
           Phase 6
          (XCUITest)
```

Phase 3 和 Phase 4 可并行开发（都只依赖 Phase 2）。

## 跨 Phase 接口契约

### Phase 1 → Phase 2
- Host 提供: `CreateWebView() => webview_id`, `DestroyWebView(webview_id)`, `SetActiveWebView(webview_id)`
- Bridge 提供: 所有 per-webview 回调携带 `webview_id`
- C-ABI 兼容层: `webview_id=0` 路由到活跃 WebView（debug build 打 LOG(WARNING)）

### Phase 2 → Phase 3/4
- BrowserViewModel 提供: `webviewIdMap[webview_id] → TabViewModel` 路由表
- BrowserViewModel 提供: `createTab(url:, foreground:, insertAfterActive:)` 统一创建方法
- TabViewModel 提供: `isPinned`, `isDeferred`, `isLoading` 属性

### Phase 4 → Phase 5
- TabViewModel 提供: `isPinned` 属性（会话恢复需序列化）
- BrowserViewModel 提供: `tabs` 数组保持稳定排序

## 共享决策

| 决策 | 内容 | 影响 Phase |
|------|------|-----------|
| OWLTabManager 为 tab 生命周期单一真相源 | Swift 层禁止直接调 C-ABI 创建/销毁 WebView | 1, 2, 3 |
| webview_id=0 兼容层 Module H 完成时移除 | 所有调用方必须在 Phase 6 前迁移 | 1, 2, 6 |
| PinnedTabRow 独立组件 | 不扩展 TabRowView，避免条件膨胀 | 4 |
| 延迟加载标签 | deferred 标签无真实 WebView，首次激活时创建 | 2, 5 |

## 变更日志

- 2026-04-05: 初始拆分，6 个 Phase
