# Phase 2: 地址栏星标按钮

## 目标
- 用户可在地址栏看到星标按钮，点击收藏/取消收藏当前页面
- 对应 AC-001, AC-002, AC-003, AC-008

## 范围

### 新增文件
| 文件 | 说明 |
|------|------|
| `Views/TopBar/StarButton.swift` | 星标按钮组件 |

### 修改文件
| 文件 | 变更 |
|------|------|
| `Views/TopBar/AddressBarView.swift` | 在 HStack 末尾添加 StarButton |

## 依赖
- Phase 1: BookmarkViewModel（isCurrentPageBookmarked, addCurrentPage, removeBookmark）

## 技术要点

### StarButton 组件
```swift
struct StarButton: View {
    let isBookmarked: Bool
    let isEnabled: Bool
    let isLoading: Bool
    let onToggle: () -> Void
    @State private var isHovered = false
    // ...
}
```

- 图标：`star` / `star.fill`（SF Symbols 15pt）
- 颜色：未收藏 textSecondary，已收藏 accentPrimary，禁用 textTertiary opacity 0.5
- 点击区域：28x28pt frame
- Hover 效果：与 ToolbarIconButton 一致
- 请求期间 disabled + opacity 0.5
- Tooltip：`.help("添加到书签")` / `.help("从书签移除")`

### AddressBarView 集成
- 在 ZoomIndicator 之后、HStack 闭合之前插入 StarButton
- Props 从 BrowserViewModel.bookmarkVM 的 computed properties 传入
- onToggle 调用 BookmarkViewModel 的 add/remove 方法

### 星标操作流程
1. 用户点击星标 → StarButton.onToggle()
2. 调用方检查 isBookmarked → 决定 add 或 remove
3. 设置 isLoading = true
4. 调用 async 方法 → 成功/失败后 isLoading = false
5. 成功时 bookmarks 数组已更新 → computed property 自动更新星标状态

### 已知陷阱
- AddressBarView 当前只接受 displayDomain, onNavigate, activeTab，需扩展参数
- 星标按钮在 compact/minimal 布局模式下也应显示（地址栏始终可见）
- 标题为空时用 URL 作为 fallback

## 验收标准
- [ ] AC-001: 地址栏显示星标按钮，已收藏页面显示蓝色实心星
- [ ] AC-002: 点击空心星 → 请求成功 → 星标变实心蓝色
- [ ] AC-003: 点击实心星 → 请求成功 → 星标变空心灰色
- [ ] AC-008: Tab 切换后星标状态正确更新
- [ ] AC-STAR-001: 空 URL 时星标灰色禁用
- [ ] AC-STAR-002: 请求中星标 opacity 0.5 且不可点击

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
