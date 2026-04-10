# Browser Features — Phase 总览

## 概述

Phase 33-36：为 OWL Browser 补齐核心浏览功能。按用户影响力排序。

## 架构层级（每个 phase 都需要贯穿）

```
Mojom 接口 → Host C++ (stub + real) → ObjC++ Bridge → C-ABI → Swift ViewModel → SwiftUI UI
```

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 预估规模 |
|-------|------|------|------|---------|
| 33 | Find-in-Page | **开发完成 ✓ 代码评审 ✓ 测试通过 ✓** | - | ~250 行 |
| 34 | Zoom 控制 | **开发完成 ✓ 测试通过 ✓ 测试评审通过 ✓** | - | ~150 行 |
| 35 | Bookmarks 服务层 | **开发完成 ✓ 代码评审 ✓ 测试通过 ✓** | - | ~350 行 |
| 36 | Bookmarks UI | **开发完成 ✓ 测试通过 ✓ 测试评审通过 ✓** | Phase 35 | ~200 行 |

## 跨 Phase 接口契约

### Phase 35 → Phase 36
- `OWLBridge_BookmarkGetAll / Add / Remove / Update` C-ABI 函数
- `BookmarkItem` 结构体（id, title, url, parent_id）
- Swift async wrapper 在 OWLBridgeSwift 中

## 共享决策

- **C-ABI 优先**：所有新功能统一走 C-ABI → Swift 路径（不走 ObjC++ 直接调用）。Phase 32 的 GoBack/GoForward 走了 ObjC++ 直接路径，但新功能应统一为 C-ABI 以保持测试一致性。
- **Observer 回调模式**：新增的异步通知（find result、zoom change）统一用 `OWLBridge_Set*Callback` 模式（与 PageInfoCallback、RenderSurfaceCallback 一致）。
- **Stub/Real 分离**：Host 层保持 function pointer 模式（g_real_*_func），支持单元测试 mock。

## 已有基础设施

| 组件 | 状态 | 位置 |
|------|------|------|
| bookmarks.mojom | ✅ 已定义 | mojom/bookmarks.mojom |
| OWLBookmarkService | ✅ 已实现（内存存储） | host/owl_bookmark_service.h/.cc |
| Find-in-Page | ❌ 无 | — |
| Zoom | ⚠️ ZoomLevelDelegate 存在 | host/owl_content_browser_context.h |

## 变更日志

- 2026-03-31: 初始拆分
