# 下载管理系统 — Phase 总览

## 概述
- PRD: [docs/prd/download-manager.md](../../prd/download-manager.md)
- UI 设计: [docs/ui-design/download-manager/design.md](../../ui-design/download-manager/design.md)

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 预估行数 | AC 覆盖 |
|-------|------|------|------|---------|---------|
| 1 | Mojom + Host 核心 | pending | - | ~200 | AC-001 (底层) |
| 2 | Mojo 适配层 + Bridge C-ABI | pending | Phase 1 | ~250 | AC-001~007 (桥接) |
| 3 | Swift 服务层 + ViewModel | pending | Phase 2 | ~200 | AC-002, AC-006 |
| 4 | SwiftUI 下载面板 | pending | Phase 3 | ~250 | AC-001~008 (UI) |
| 5 | XCUITest 端到端验收 | pending | Phase 4 | ~200 | AC-001~008 |

## 依赖图

```
Phase 1 (Mojom + Host)
  └── Phase 2 (Mojo Adapter + Bridge)
        └── Phase 3 (Swift Service + ViewModel)
              └── Phase 4 (SwiftUI Panel)
                    └── Phase 5 (XCUITest)
```

## 跨 Phase 接口契约

### Phase 1 → Phase 2
- `downloads.mojom` 定义的 `DownloadService` / `DownloadObserver` / `DownloadItem` 接口
- `OWLDownloadManagerDelegate` 提供 `download::DownloadItem::Observer` 回调

### Phase 2 → Phase 3
- C-ABI 函数签名: `OWLBridge_Download*` 系列
- JSON 序列化格式: DownloadItem → JSON 映射

### Phase 3 → Phase 4
- `DownloadViewModel` 的 `@Published` 属性
- `DownloadItemVM` 的状态枚举和绑定接口

## 共享决策

1. **下载是 browser-context 级能力**，不挂在 WebViewObserver 上
2. **状态映射**: Chromium IN_PROGRESS+IsPaused() → Mojom kPaused（独立枚举值）
3. **持久化**: 当前版本 in-memory only，不跨 session
4. **保存路径**: ~/Downloads via NSSearchPathForDirectoriesInDomains
5. **quarantine xattr**: Phase 1 技术方案阶段调研确定实现方式

## 变更日志

- 2026-04-03: 初始拆分，5 个 phase
