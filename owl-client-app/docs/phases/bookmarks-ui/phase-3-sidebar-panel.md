# Phase 3: 侧边栏书签面板

## 目标
- 用户可在侧边栏查看所有书签、点击导航、删除书签
- 对应 AC-004, AC-005, AC-006, AC-007

## 范围

### 新增文件
| 文件 | 说明 |
|------|------|
| `Views/Sidebar/BookmarkSidebarView.swift` | 书签面板主视图（header + list/empty/loading） |
| `Views/Sidebar/BookmarkRow.swift` | 单行书签项 |
| `Views/Sidebar/BookmarkEmptyState.swift` | 空状态视图 |

### 修改文件
| 文件 | 变更 |
|------|------|
| `Views/Sidebar/SidebarView.swift` | 添加 sidebarMode 切换逻辑（tabs / bookmarks） |
| `Views/Sidebar/SidebarToolbar.swift` | 书签按钮连接到 sidebarMode 切换，传入 isActive |

## 依赖
- Phase 1: BookmarkViewModel（bookmarks, loadAll, removeBookmark）、BrowserViewModel.sidebarMode、ToolbarIconButton.isActive

## 技术要点

### SidebarView 模式切换
```swift
// SidebarView body
if browserVM.sidebarMode == .tabs {
    // 现有标签列表
} else {
    BookmarkSidebarView()
}
```
- 使用条件渲染（if/else），tabs 面板状态保持不变

### BookmarkSidebarView
- Header："书签" 文字，36px 高，buttonFont
- 加载中：ProgressView() 居中
- 空状态：BookmarkEmptyState（引导文案）
- 列表：ScrollView + LazyVStack + ForEach(bookmarks)

### BookmarkRow
- 高度 44px，左 padding 12px，右 padding 8px
- FaviconPlaceholder：28x28，radiusSmall，surfaceSecondary，域名首字母大写 12pt semibold
- 标题：tabFont (13pt)，textPrimary，lineLimit(1)
- 域名：10pt，textTertiary，lineLimit(1)
- 标题等于 URL 时隐藏域名行
- contextMenu：删除（destructive）
- hover 删除按钮：hover 时右侧显示 trash icon

### SidebarToolbar 连接
- 书签按钮 onToggle：切换 sidebarMode
- isActive：sidebarMode == .bookmarks
- 切换到书签模式时触发 loadAll()

### 书签导航
- 点击书签行 → 当前标签页导航到 URL
- 调用 BrowserViewModel 的导航方法

### 实时更新
- 通过星标添加/删除书签时，bookmarks 数组通过 @Published 自动驱动列表刷新
- 切换到书签面板时调用 loadAll() 确保最新数据

### 已知陷阱
- macOS 不支持 swipeActions，只能用 contextMenu + hover 按钮
- ScrollView + LazyVStack 性能优于 List（macOS 上 List 有时行为异常）
- 空状态需 VStack + Spacer 实现居中
- compact 模式（36px）下不显示书签内容，仅 toolbar 可见

## 验收标准
- [ ] AC-004: 点击侧边栏书签按钮 → 面板切换到书签列表
- [ ] AC-005: 点击书签项 → 当前标签页导航到该 URL
- [ ] AC-006: 右键书签项 → contextMenu "删除" → 该项从列表消失
- [ ] AC-007: 侧边栏打开时通过星标添加书签 → 列表头部出现新项
- [ ] AC-SIDE-001: 书签面板加载时显示 ProgressView
- [ ] AC-SIDE-002: 无书签时显示引导文案
- [ ] AC-SIDE-003: hover 时书签行背景变色 + 删除按钮出现
- [ ] AC-SIDE-004: 再次点击书签按钮 → 切回标签列表
- [ ] AC-SIDE-005: 书签按钮在书签模式下显示蓝色（isActive）

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
