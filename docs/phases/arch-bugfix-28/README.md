# Architecture Bugfix Batch — Phase Overview

## Overview
- PRD: [docs/prd/arch-bugfix-28.md](../../prd/arch-bugfix-28.md)
- Bug Hunt Report: [docs/bug-hunt/architecture-review-2026-04-07.md](../../bug-hunt/architecture-review-2026-04-07.md)
- Total: 27 fixes (BH-003 test-only, BH-024 deferred)

## Phase List

| Phase | Name | Items | Status | Depends | Notes |
|-------|------|-------|--------|---------|-------|
| 1 | WebView 路由重构 | BH-001 | pending | - | 最高优先级，最大单项重构 |
| 2 | Host 服务生命周期 | BH-002,005,009,016 | pending | - | 可与 Phase 1 并行准备 |
| 3 | Bridge 内存安全 | BH-004,006,011,014 | pending | Phase 1(BH-011 部分) |
| 4 | Host 配置与安全 | BH-007,017,021 | pending | Phase 2(BH-007 影响 BH-005) |
| 5 | Client 层修复 | BH-013,015,020,023,028 | pending | - | 全部独立 |
| 6 | Swift 并发安全 | BH-008,012,018 | pending | - | 全部独立 |
| 7 | Swift 业务逻辑 | BH-019,022,025 | pending | - | 全部独立 |
| 8 | 清理与维护 | BH-003,010,026,027 | pending | Phase 1(BH-010) |

## Cross-Phase Interface Contracts

- Phase 1 → Phase 3: BH-011 需要从 BH-001 的重新键控 map 中按 webview_id 查找
- Phase 1 → Phase 8: BH-010 需要 BH-001 的 webview_id-keyed map
- Phase 2 → Phase 4: BH-005 的 PermissionManager 统一依赖 BH-007 的数据路径修复
- Phase 2 provides: DestroyInternal() 幂等方法，所有后续 Phase 的服务访问依赖此保证

## Shared Decisions

1. `base::flat_map<uint64_t, RealWebContents*>` 替代 `std::map`（缓存友好）
2. Cursor swizzle 保留 `g_active_webview_id`（Chromium callback 签名限制）
3. `BarrierCallback` 聚合判断替代 fast-fail（Mojo 请求不可取消）
4. `os_unfair_lock` 替代 `@MainActor`（C-ABI 兼容性）
5. Schema 已有 `id AUTOINCREMENT`，BH-025 无需 migration
