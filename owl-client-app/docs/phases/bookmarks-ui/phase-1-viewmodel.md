# Phase 1: ViewModel + 基础组件

## 目标
- BookmarkViewModel 就绪，可被 UI 层调用进行书签 CRUD + 状态查询
- BrowserViewModel 扩展 sidebarMode 和 bookmarkVM
- ToolbarIconButton 支持 isActive 参数

## 范围

### 新增文件
| 文件 | 说明 |
|------|------|
| `ViewModels/BookmarkViewModel.swift` | 书签数据管理 ViewModel |

### 修改文件
| 文件 | 变更 |
|------|------|
| `ViewModels/BrowserViewModel.swift` | +`sidebarMode: SidebarMode`、+`bookmarkVM: BookmarkViewModel`、Tab 切换/URL 变化时调用 `updateCurrentURL` |
| `Views/Sidebar/SidebarToolbar.swift` | `ToolbarIconButton` 增加 `isActive: Bool` 参数 |

## 依赖
- Phase 35 已完成的 `Services/BookmarkService.swift`（`OWLBookmarkBridge` enum）
- 现有 `BookmarkItem` struct

## 技术要点

（完整接口设计见"技术方案 § 2. 接口设计"）

### 已知陷阱
- `OWLBookmarkBridge.add/remove/getAll` 是 async，需在 MainActor 上调用
- `loadAll()` 返回结果应按时间倒序（服务层返回顺序待开发时确认）
- `BookmarkItem` 在 `Services/BookmarkService.swift` 中定义，确认 access level
- `isBookmarked(url:)` 每次 View body 求值时调用，O(n) 在 <10000 书签时可接受

## 验收标准
- [ ] AC-VM-001: BookmarkViewModel 可调用 `loadAll()` 获取所有书签
- [ ] AC-VM-002: `addCurrentPage(title:url:)` 成功后 `bookmarks` 数组包含新项且 `isCurrentPageBookmarked == true`
- [ ] AC-VM-003: `removeBookmark(id:)` 成功后 `bookmarks` 数组不含该项且 `isCurrentPageBookmarked == false`
- [ ] AC-VM-004: `updateCurrentURL(url)` 后 `isCurrentPageBookmarked` 正确反映收藏状态
- [ ] AC-VM-005: BrowserViewModel.sidebarMode 可在 .tabs / .bookmarks 间切换
- [ ] AC-VM-006: ToolbarIconButton isActive=true 时显示 accentPrimary 颜色
- [ ] AC-VM-007: Tab 切换时 `bookmarkVM.currentURL` 自动更新

## 技术方案

### 1. 架构设计

```
BrowserViewModel (已有)
  ├── @Published sidebarMode: SidebarMode = .tabs  [新增]
  ├── bookmarkVM: BookmarkViewModel                [新增]
  └── activeTab?.url → View 直接传给 bookmarkVM.isBookmarked(url:)
                                  │
BookmarkViewModel (新增)           │
  ├── @Published bookmarks: [BookmarkItem]         │  ← 唯一数据源
  ├── @Published isLoading: Bool                    │
  ├── isBookmarked(url:) -> Bool                   │  ← 函数，非 computed property
  ├── bookmarkId(for:) -> String?                  │  ← 函数
  ├── loadAll() → OWLBookmarkBridge.getAll()
  ├── addCurrentPage() → OWLBookmarkBridge.add()
  └── removeBookmark() → OWLBookmarkBridge.remove()
                                  │
OWLBookmarkBridge (已有)          │
  └── C-ABI async/await wrappers ←┘
```

**核心简化**：移除 `currentURL` 和 Combine 订阅。星标状态通过函数求值：View 中 `bookmarkVM.isBookmarked(url: browserVM.activeTab?.url)` 自动随 `activeTab` 和 `bookmarks` 变化重绘（两者均为 @Published）。无需额外状态同步。

数据流：
- **URL 变化 / Tab 切换**：`activeTab?.url` 变化 → SwiftUI 自动重绘 → View 调用 `isBookmarked(url:)` → 星标 UI 更新
- **添加书签**：UI → bookmarkVM.addCurrentPage → OWLBookmarkBridge.add → 成功后插入 bookmarks 数组 → @Published 触发重绘 → isBookmarked 返回 true
- **删除书签**：UI → bookmarkVM.removeBookmark → OWLBookmarkBridge.remove → 成功后从 bookmarks 数组移除 → 同上

### 2. 接口设计

#### BookmarkViewModel

```swift
@MainActor
package class BookmarkViewModel: ObservableObject {
    // MARK: - Published State
    @Published package var bookmarks: [BookmarkItem] = []
    @Published package var isLoading: Bool = false

    // MARK: - Query Methods (函数式，无状态同步)
    package func isBookmarked(url: String?) -> Bool {
        bookmarkId(for: url) != nil
    }

    package func bookmarkId(for url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        return bookmarks.first(where: { $0.url == url })?.id
    }

    // MARK: - Mock Support
    package struct MockConfig {
        var bookmarks: [BookmarkItem] = []
    }
    private let mockConfig: MockConfig?

    package init(mockConfig: MockConfig? = nil) {
        self.mockConfig = mockConfig
        if let mockConfig {
            self.bookmarks = mockConfig.bookmarks
        }
    }

    // MARK: - Actions
    package func loadAll() async {
        if mockConfig != nil { return }
        isLoading = true
        defer { isLoading = false }
        #if canImport(OWLBridge)
        do {
            let items = try await OWLBookmarkBridge.getAll()
            bookmarks = items.reversed()  // 服务层按时间正序，反转为倒序（最新在前）
        } catch {
            NSLog("[OWL-Bookmark] loadAll failed: \(error)")
        }
        #endif
    }

    package func addCurrentPage(title: String, url: String) async -> Bool {
        if mockConfig != nil {
            let item = BookmarkItem(id: UUID().uuidString, title: title, url: url, parent_id: nil)
            bookmarks.insert(item, at: 0)
            return true
        }
        #if canImport(OWLBridge)
        do {
            let item = try await OWLBookmarkBridge.add(
                title: title.isEmpty ? url : title,
                url: url,
                parentId: nil
            )
            bookmarks.insert(item, at: 0)
            return true
        } catch {
            NSLog("[OWL-Bookmark] add failed: \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    package func removeBookmark(id: String) async -> Bool {
        if mockConfig != nil {
            bookmarks.removeAll(where: { $0.id == id })
            return true
        }
        #if canImport(OWLBridge)
        do {
            let success = try await OWLBookmarkBridge.remove(id: id)
            if success {
                bookmarks.removeAll(where: { $0.id == id })
            }
            return success
        } catch {
            NSLog("[OWL-Bookmark] remove failed: \(error)")
            return false
        }
        #else
        return false
        #endif
    }
}
```

**设计决策**：
- **无 `currentURL`**：移除了 Combine 订阅和状态同步。View 中直接传 `browserVM.activeTab?.url` 给 `isBookmarked(url:)`，SwiftUI 自动依赖追踪
- **无 `isOperating`**：add/remove 的加载状态由调用方（StarButton）用 `@State var isLoading` 管理，更简洁
- **MockConfig**：与 BrowserViewModel.MockConfig 模式一致，`#if canImport(OWLBridge)` 在 production 路径

#### SidebarMode 枚举

```swift
// 定义在 BrowserViewModel.swift 顶部（与 RightPanel 同文件模式）
package enum SidebarMode: Equatable {
    case tabs
    case bookmarks
}
```

#### BrowserViewModel 扩展

```swift
// 新增属性
@Published package var sidebarMode: SidebarMode = .tabs
package let bookmarkVM = BookmarkViewModel()

// 新增方法
package func toggleSidebarMode() {
    sidebarMode = sidebarMode == .tabs ? .bookmarks : .tabs
}
```

**不修改 `activateTab`**：无需任何修改，因为 `activeTab` 是 @Published，SwiftUI 自动感知变化。

#### ToolbarIconButton 扩展

```swift
struct ToolbarIconButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false  // 新增，默认 false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(
                    isActive ? OWL.accentPrimary :
                    (isHovered ? OWL.textPrimary : OWL.textSecondary)
                )
                .frame(maxWidth: .infinity)
                .frame(height: OWL.toolbarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
    }
}
```

### 3. 核心逻辑

#### URL 变化 → 星标状态更新流程（零同步代码）
1. `TabViewModel.PageInfoCallback` 触发，更新 `tabVM.url`（@Published）
2. `activeTab` 是 @Published，`activeTab?.url` 变化被 SwiftUI 感知
3. View body 中 `bookmarkVM.isBookmarked(url: browserVM.activeTab?.url)` 自动重新求值
4. 星标 UI 更新

无需 Combine、无需手动同步。

#### App 启动初始化
在 `BrowserViewModel` 创建首个 Tab 后：
```swift
Task {
    await bookmarkVM.loadAll()
}
```
无需 `updateCurrentURL`——View 会自动读取 `activeTab?.url`。

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `ViewModels/BookmarkViewModel.swift` | 新增 | ~70 行，含 MockConfig |
| `ViewModels/BrowserViewModel.swift` | 修改 | +SidebarMode 枚举, +sidebarMode, +bookmarkVM, +toggleSidebarMode（~15 行新增） |
| `Views/Sidebar/SidebarToolbar.swift` | 修改 | ToolbarIconButton 加 isActive 参数（改 3 行） |

### 5. 测试策略

#### 单元测试（OWLUnitTests）
- `BookmarkViewModelTests`：
  - `testLoadAll_mockMode`：MockConfig 预置数据后 bookmarks 非空
  - `testAddCurrentPage_mockMode`：add 后 bookmarks 包含新项，`isBookmarked(url:)` 返回 true
  - `testRemoveBookmark_mockMode`：remove 后 bookmarks 不含该项，`isBookmarked(url:)` 返回 false
  - `testIsBookmarked`：bookmarks 包含某 URL 时 `isBookmarked(url:)` 返回 true，不包含时返回 false
  - `testBookmarkId`：`bookmarkId(for:)` 返回正确的 id
  - `testAddWithEmptyTitle`：title 为空时使用 url 作为 fallback
  - `testIsBookmarked_nilURL`：url 为 nil 时返回 false
  - `testIsBookmarked_emptyURL`：url 为空字符串时返回 false

#### 集成测试（OWLBrowserTests，需 Host）
- `testBookmarkViewModel_realBridge`：通过 C-ABI 实际调用 add/getAll/remove

### 6. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| `getAll()` 返回顺序不确定 | `.reversed()` 确保最新在前；开发时验证服务层实际顺序 |
| `BookmarkItem` 的 `package` access level | 确认 `Services/BookmarkService.swift` 中的声明 |
| `isBookmarked` O(n) 查找每帧调用 | 书签量 <10000 时 O(n) 可接受；SwiftUI 只在依赖变化时重绘 |
| MockConfig 中 `BookmarkItem` 构造参数名 | 开发时对照 `BookmarkItem` 实际 init 签名（`parent_id` vs `parentId`） |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
