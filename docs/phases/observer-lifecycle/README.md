# Unified Observer Lifecycle — Phase 总览

## 概述
- PRD: `docs/prd/unified-observer-lifecycle.md`
- 技术方案: `docs/phases/observer-lifecycle/unified-observer-lifecycle.md`

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 备注 |
|-------|------|------|------|------|
| 1 | 统一 Callback 注册 + SSL 时序修复 | pending | - | Swift + Bridge 层 |
| 2 | Permission Host→Observer 打通 | pending | - | Host C++ 层 |
| 3 | History 推送管线 | pending | - | 全栈（Host + Mojom + Bridge + Swift） |

## 跨 Phase 接口契约

三个 Phase 互相独立，无跨 Phase 接口依赖。共享的架构基础：
- `WebViewObserver` Mojom 接口（已存在，不变）
- `g_real_web_contents` 全局指针（已存在，Phase 2 新增 `FromWebContents` 方法）
- `OWLHistoryService` 类（已存在，Phase 3 新增 `SetChangeCallback`）

## 共享决策

1. **所有 callback 在 WebView Ready 后注册**（Phase 1 实现，Phase 2/3 遵循）
2. **DCHECK + release 安全网**（Bridge 层的统一时序契约）
3. **信号与数据分离**（History 推送只发信号，Swift pull 权威数据）
4. **RFH 寻址**（Permission 通过 Chromium 原生 API 路由，非全局 delegate）

## 变更日志

- 2026-04-03: 初始拆分，3 个 phase
