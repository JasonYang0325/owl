# Phase 36: Bookmarks UI

## 目标

用户可以通过 UI 添加/查看/管理书签：地址栏星标按钮 + 书签侧边栏。

## 范围

### 新增文件
- `Views/Sidebar/BookmarkListView.swift` — 书签列表视图
- `ViewModels/BookmarkViewModel.swift` — 书签数据管理

### 修改文件

| 文件 | 变更 |
|------|------|
| `Views/TopBar/AddressBarView.swift` | +星标按钮（当前页是否已收藏） |
| `Views/Sidebar/SidebarView.swift` | +书签面板切换 |
| `Views/Sidebar/SidebarToolbar.swift` | +书签图标按钮 |
| `ViewModels/BrowserViewModel.swift` | +bookmarkVM 属性, sidebar 模式切换 |
| `Tests/OWLBrowserTests.swift` | +Bookmark UI E2E 测试 |

## 依赖

- **Phase 35**（Bookmarks 服务层）：C-ABI 函数 + Swift wrapper

## 技术要点

### BookmarkViewModel

```swift
@MainActor
class BookmarkViewModel: ObservableObject {
    @Published var bookmarks: [BookmarkItem] = []
    @Published var isCurrentPageBookmarked: Bool = false

    func loadAll() async { ... }                    // OWLBridge_BookmarkGetAll
    func addCurrentPage(title: String, url: String) async { ... }  // OWLBridge_BookmarkAdd
    func remove(id: String) async { ... }           // OWLBridge_BookmarkRemove
    func checkCurrentPage(url: String?) { ... }     // 本地查找
}
```

### 星标按钮行为

- 空心星 ☆：当前页未收藏 → 点击添加
- 实心星 ★：当前页已收藏 → 点击移除
- 导航到新页面时自动检查是否已收藏（本地 O(n) 查找，书签量小可接受）

### 书签侧边栏

- 在 SidebarView 中增加"书签"标签页（与"标签页"列表并列）
- 每行显示：favicon placeholder + 标题 + 域名
- 点击书签 → 在当前标签页导航
- 右键/长按 → 编辑/删除（可用 contextMenu）

### 已知陷阱

- `isCurrentPageBookmarked` 需在每次 `url` 变化时更新（PageInfoCallback 触发）
- 书签列表可能有多层（parent_id），Phase 36 先做**平铺列表**，不做文件夹层级
- SwiftUI List + contextMenu 在 macOS 上有时不响应右键，可能需要 NSMenu 回退

## 验收标准

- [ ] AC-001: 地址栏显示星标按钮，当前页已收藏时显示实心星
- [ ] AC-002: 点击空心星添加当前页到书签，星标变为实心
- [ ] AC-003: 点击实心星移除书签，星标变为空心
- [ ] AC-004: 侧边栏可切换到书签视图，显示所有书签
- [ ] AC-005: 点击书签项在当前标签页导航到对应 URL
- [ ] AC-006: 可删除书签（右键菜单或滑动删除）
- [ ] AC-007: 书签列表在添加/删除后实时更新

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
