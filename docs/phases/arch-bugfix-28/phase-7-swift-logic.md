# Phase 7: Swift 业务逻辑 (BH-019, BH-022, BH-025)

## Goal
修复 Swift 层的业务逻辑正确性问题。

## Scope
- **Modified**: `owl-client-app/ViewModels/HistoryViewModel.swift`, `owl-client-app/ViewModels/BookmarkViewModel.swift`, `owl-client-app/Services/HistoryService.swift`, `mojom/history.mojom`, `host/owl_history_service.cc`, Swift test files
- **Layers**: Swift + Mojom + Host (BH-025 跨层)

## Dependencies
- None

## Items

### BH-019: HistoryViewModel 删除竞态
- `commitPendingUndo()` 检查条目是否仍在 `entries` 中
- 若已被 `loadInitial` 覆盖则跳过后端删除

### BH-022: BookmarkViewModel 防重复
- `isAdding` 标志，async 挂起期间阻止重复
- 完成后重置标志

### BH-025: HistoryEntry visit_id
- Mojom `HistoryEntry` 新增 `int64 id` 字段
- Host 层 query 返回 `id` 列
- Swift `HistoryEntry.id` = `String(id)`
- Schema 已有 `id AUTOINCREMENT`，无需 migration

## Acceptance Criteria
- [ ] Swift Unit Test: 竞态场景下 undo 不重复删除
- [ ] Swift Unit Test: 快速双击只添加一次书签
- [ ] Swift Unit Test: 相同 URL 不同访问有唯一 ID
- [ ] 新增测试 ≥ 4

## Status
- [ ] Tech design review
- [ ] Development
- [ ] Code review
- [ ] Tests pass
