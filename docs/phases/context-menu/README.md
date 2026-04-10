# 右键上下文菜单 — Phase 总览

## 概述

- PRD: [docs/prd/context-menu.md](../../prd/context-menu.md)
- UI 设计: [docs/ui-design/context-menu/design.md](../../ui-design/context-menu/design.md)
- 模块文档: [docs/modules/module-e-context-menu.md](../../modules/module-e-context-menu.md)

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 预估行数 | AC 覆盖 |
|-------|------|------|------|---------|---------|
| 1 | 基础管线 + 空白区域菜单 | pending | 无 | ~150 | AC-004a, AC-005e |
| 2 | 链接 + 文本 + 可编辑区域菜单 | pending | Phase 1 | ~150 | AC-001, AC-003, AC-005a/b/d/f |
| 3 | 图片菜单 + 安全加固 + XCUITest | pending | Phase 2 | ~120 | AC-002, AC-004b, AC-005c, AC-006 |

## 依赖关系图

```
Phase 1 (管线 + Page菜单)
   ↓
Phase 2 (Link + Selection + Editable)
   ↓
Phase 3 (Image + Security + XCUITest)
```

## 跨 Phase 接口契约

### Phase 1 → Phase 2
- Mojom `ContextMenuParams` struct 和 `OnContextMenu`/`ExecuteContextMenuAction` 接口已就绪
- Bridge `OWLBridge_ContextMenuCallback` 和 `OWLBridge_ExecuteContextMenuAction` C-ABI 已就绪
- Swift 侧 NSMenu 构建框架（`ContextMenuHandler`）已就绪，Phase 2 只需扩展菜单项

### Phase 2 → Phase 3
- 新标签页创建逻辑（Phase 2 为 Link 实现）可被 Phase 3 搜索操作复用
- WebContents 剪贴板操作（Phase 2 为 Editable 实现）可被 Phase 3 复制图片复用

## 共享决策

- `menu_id` 采用 Host 侧递增 uint64，导航时自动递增
- 所有菜单项操作通过 `ExecuteContextMenuAction(menu_id, action_id)` 统一分发
- action_id 枚举在 Phase 1 定义，Phase 2/3 扩展

## 变更日志

- 2026-04-04: 初始拆分，3 个 phase
