# OWL Browser — 基础能力模块总览

## 架构约定

每个模块贯穿全栈，统一开发模式：

```
Mojom 接口 → Host C++ → C-ABI Bridge → Swift ViewModel → SwiftUI View → Tests
```

## 模块列表

| ID | 模块 | 优先级 | 依赖 | 状态 |
|----|------|--------|------|------|
| A | [浏览历史系统](module-a-history.md) | P0 | 无 | done |
| B | [下载管理系统](module-b-downloads.md) | P0 | 无 | done |
| C | [权限与安全体系](module-c-permissions.md) | P1 | 无 | done |
| D | [Cookie 与存储管理](module-d-storage.md) | P1 | 无 | done |
| E | [右键上下文菜单](module-e-context-menu.md) | P1 | 无 | done |
| F | [导航事件与错误处理](module-f-navigation-events.md) | P1 | 无 | pending |
| G | [Console 与 JS 错误捕获](module-g-console.md) | P2 | 无 | pending |
| H | [多标签增强](module-h-tabs.md) | P2 | A | pending |
| I | [设置与偏好系统](module-i-settings.md) | P2 | C, D (部分) | pending |
| J | [打印支持](module-j-print.md) | P3 | 无 | pending |
| K | [网络请求监控](module-k-network.md) | P2 | 无 | pending |
| L | [全屏与媒体控制](module-l-media.md) | P3 | 无 | pending |

## 依赖图

```
独立（可并行）: A  B  C  D  E  F  G  J  K  L
有依赖:         H → A
                I → C + D (部分设置项)
```

## 建议并行开发批次

**Batch 1** (4 worktree): A + B + E + F
**Batch 2** (3 worktree): C + D + G
**Batch 3** (3 worktree): H + I + K
**Batch 4** (2 worktree): J + L

## 已完成能力（Phase 27-36）

- 基础导航 (GoBack/Forward/Reload/Stop)
- 输入事件 (Mouse/Key/Wheel/IME)
- 渲染表面 (CALayerHost)
- Find-in-Page
- Zoom 控制
- Bookmarks (服务层 + UI)
- 弹窗拦截 / 光标追踪

## 变更日志

- 2026-03-31: 初始拆分，12 个模块
