# Bookmarks UI — Phase 总览

## 概述
- PRD: [docs/prd/bookmarks-ui.md](../../prd/bookmarks-ui.md)
- UI 设计稿: [docs/ui-design/bookmarks-ui/design.md](../../ui-design/bookmarks-ui/design.md)

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 预估代码量 | 备注 |
|-------|------|------|------|-----------|------|
| 1 | ViewModel + 基础组件 | pending | - | ~120 行 | BookmarkViewModel、BrowserViewModel 扩展、ToolbarIconButton 扩展 |
| 2 | 地址栏星标按钮 | pending | Phase 1 | ~100 行 | StarButton 组件、AddressBarView 集成 |
| 3 | 侧边栏书签面板 | pending | Phase 1 | ~200 行 | BookmarkSidebarView、SidebarView 模式切换、删除功能 |

## 跨 Phase 接口契约

### Phase 1 → Phase 2
- `BookmarkViewModel.isCurrentPageBookmarked: Bool`（computed property）
- `BookmarkViewModel.currentPageBookmarkId: String?`（computed property）
- `BookmarkViewModel.addCurrentPage(title:url:) async`
- `BookmarkViewModel.removeBookmark(id:) async`
- `BookmarkViewModel.updateCurrentURL(_ url: String?)`
- `BrowserViewModel.bookmarkVM: BookmarkViewModel`

### Phase 1 → Phase 3
- `BookmarkViewModel.bookmarks: [BookmarkItem]`
- `BookmarkViewModel.loadAll() async`
- `BookmarkViewModel.removeBookmark(id:) async`
- `BrowserViewModel.sidebarMode: SidebarMode`（.tabs / .bookmarks）
- `ToolbarIconButton(icon:label:isActive:action:)`

## 共享决策

1. **sidebarMode 在 BrowserViewModel 层**：跨组件响应需求（AddressBarView + SidebarView）
2. **macOS 无 swipeActions**：删除通过 contextMenu + hover 删除按钮实现
3. **无乐观更新**：等请求结果再更新 UI，点击期间 disable 按钮
4. **loadAll() 按时间倒序**：与本地插入头部一致
5. **isCurrentPageBookmarked 为 computed property**：从 bookmarks + currentURL 自动计算

## 变更日志
（拆分初始版本）
