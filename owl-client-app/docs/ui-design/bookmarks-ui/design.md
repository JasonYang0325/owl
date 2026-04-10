# Bookmarks UI — UI 设计稿

## 1. 设计概述

### 设计目标
- 在现有 OWL Browser 界面中无缝集成书签功能
- 地址栏星标提供即时收藏反馈
- 侧边栏书签列表作为标签列表的替代视图，保持一致的视觉语言

### 设计原则
- **一致性**：复用现有 DesignTokens（OWL namespace），与标签列表/侧边栏保持同一视觉风格
- **简洁性**：平铺列表，无层级，最少交互步骤
- **即时反馈**：操作后 UI 立即响应（请求完成后更新）

## 2. 信息架构

```
浏览器窗口
├── TopBar
│   └── AddressBar
│       └── [新增] StarButton ← 星标按钮
├── Sidebar
│   ├── [模式切换] TabList / BookmarkList
│   │   ├── tabs → 现有标签列表
│   │   └── bookmarks → [新增] 书签列表
│   └── SidebarToolbar
│       └── BookmarkButton ← [已有占位] 触发模式切换
└── ContentArea
```

### 导航路径
- **收藏当前页**：浏览网页 → 点击地址栏星标 → 完成
- **查看书签列表**：点击侧边栏底部书签按钮 → 侧边栏切换到书签视图
- **通过书签导航**：书签列表 → 点击某项 → 当前标签页导航
- **删除书签**：书签列表 → 右键某项 → contextMenu "删除"（或 hover 后点击删除按钮）

## 3. 页面/组件设计

### 3.1 StarButton（地址栏星标按钮）

#### 布局

```
地址栏 HStack
┌──────────────────────────────────────────────────┐
│  🔒  │  搜索或输入 URL                  │ 100% │ ☆ │
│ lock │  NSTextField                      │ zoom │star│
└──────────────────────────────────────────────────┘
       ←── 现有内容 ──────────────────────→  ← 新增
```

- 位置：地址栏 HStack 最右侧，ZoomIndicator 之后
- 占位：15pt icon，无额外 padding（与 lock icon 保持同等大小）

#### 视觉规范

| 状态 | 图标 | 颜色 | 效果 |
|------|------|------|------|
| 未收藏（默认） | `star` | `OWL.textSecondary` (#8E8E93) | — |
| 未收藏（悬停） | `star` | `OWL.textPrimary` | — |
| 已收藏（默认） | `star.fill` | `OWL.accentPrimary` (#0A84FF) | — |
| 已收藏（悬停） | `star.fill` | `OWL.accentPrimary` 加深 | — |
| 禁用（空 URL） | `star` | `OWL.textTertiary` (#C7C7CC) | opacity 0.5 |
| 请求中 | `star` / `star.fill` | 同当前状态 | opacity 0.5, 不可点击 |

- 字体大小：15pt（与 lock.fill 一致）
- 按钮样式：`.plain`，无背景
- Hover 效果：颜色加深（与 SidebarToolbar 的 ToolbarIconButton 一致）
- 点击区域：最小 28x28pt（大于图标，提升可点击性）
- Tooltip：`.help("添加到书签")` / `.help("从书签移除")`

#### 交互设计

| 交互 | 行为 |
|------|------|
| 点击未收藏星标 | 按钮 disabled → 调用 add → 成功后 `star.fill` + 蓝色 → 恢复可点击 |
| 点击已收藏星标 | 按钮 disabled → 调用 remove → 成功后 `star` + 灰色 → 恢复可点击 |
| 点击禁用星标 | 无响应 |

#### 组件树

```swift
StarButton: View
├── Props:
│   ├── isBookmarked: Bool        // computed from BookmarkViewModel
│   ├── isEnabled: Bool           // false when URL is empty
│   ├── isLoading: Bool           // true during API call
│   ├── onToggle: () -> Void     // add or remove action
├── State:
│   └── isHovered: Bool
└── Body:
    └── Button(.plain)
        └── Image(systemName: isBookmarked ? "star.fill" : "star")
            .font(.system(size: 15))
            .foregroundStyle(color)
            .help(tooltip)
```

### 3.2 侧边栏模式切换

#### 布局

```
侧边栏（书签模式下）
┌────────────────────┐
│  书签               │  ← SidebarHeader（替代 TabSearchField + NewTabButton）
├────────────────────┤
│  ┌────────────────┐│
│  │ G  Google      ││  ← BookmarkRow
│  │    google.com  ││
│  ├────────────────┤│
│  │ W  Wikipedia   ││
│  │    wikipedia.. ││
│  ├────────────────┤│
│  │ H  HN          ││
│  │    news.ycom.. ││
│  └────────────────┘│
│                    │
│  (更多书签...)      │
├────────────────────┤
│ 📖  💬  🤖  ⚙️    │  ← SidebarToolbar（不变）
└────────────────────┘

侧边栏（空书签状态）
┌────────────────────┐
│  书签               │
├────────────────────┤
│                    │
│     ☆              │  ← 空状态插图（可选）
│  暂无书签。         │
│  点击地址栏的 ☆     │
│  即可收藏当前网页    │
│                    │
├────────────────────┤
│ 📖  💬  🤖  ⚙️    │
└────────────────────┘
```

#### 视觉规范

**SidebarHeader（书签模式头部）**
- 高度：36px（与 TabSearchField 区域一致）
- 内容：Text("书签")，字体 `OWL.buttonFont`（13pt medium）
- 颜色：`OWL.textPrimary`
- 左 padding：12px
- 底部 Divider

**BookmarkRow**
- 高度：44px（比 tabItemHeight 36px 略高，因为有副标题行）
- 左 padding：12px，右 padding：8px
- 结构：

```
┌─────────────────────────────────────┐
│  ┌──┐                               │
│  │Xx│  标题文字（单行截断）           │  44px
│  └──┘  域名（灰色小字，单行截断）     │
│  28x28                               │
└─────────────────────────────────────┘
   ↑        ↑
  icon    text
  area    area
```

- **Favicon placeholder**：
  - 尺寸：28x28pt
  - 圆角：`OWL.radiusSmall`（6pt）
  - 背景：`OWL.surfaceSecondary`（#F5F5F5 / #2A2A2A）
  - 文字：域名首字母（去除 `www.` 前缀后取 hostname 首字符），大写，12pt semibold
  - 颜色：`OWL.textSecondary`
- **标题**：`OWL.tabFont`（13pt），`OWL.textPrimary`，lineLimit(1)，truncationMode(.tail)。注：使用 tabFont 而非 captionFont，与标签列表视觉层级对齐
- **域名**：10pt，`OWL.textTertiary`，lineLimit(1)，truncationMode(.tail)
  - 当标题等于 URL 时：隐藏域名行，标题行居中
- **间距**：icon 与 text 间距 8px

**交互状态**

| 状态 | 背景 | 文字 |
|------|------|------|
| 默认 | 透明 | 标题 textPrimary，域名 textTertiary |
| 悬停 | `OWL.surfaceSecondary.opacity(0.3)` | 不变 |
| 按下 | `OWL.surfaceSecondary.opacity(0.5)` | 不变 |

**加载状态**

- 切换到书签面板时，`loadAll()` 返回前显示加载指示器
- 使用 `ProgressView()` 居中显示（系统原生 spinner）
- 加载完成后切换到列表视图或空状态
- 避免先闪"暂无书签"再突然出现列表

**右键菜单删除**

- 右键 contextMenu：
  - "删除书签"（destructive role，红色文字）
  - 图标：`trash`
- ~~左滑 swipeActions~~：**macOS 不支持 swipeActions**，仅 iOS/iPadOS 有效
- **替代方案**：hover 时在行右侧显示半透明删除按钮（`trash` icon，OWL.textTertiary，hover 变 OWL.error）

**操作失败反馈**

- 星标操作失败时：通过 `accessibilityAnnouncement` 通知 VoiceOver 用户
- 视觉上星标保持原状（PRD 定义），用户可重试

**空状态**

- 居中显示：使用 `VStack` + `Spacer()` 上下填充，确保垂直居中（非 ScrollView 默认顶部对齐）
- 星标图标：`star`，32pt，`OWL.textTertiary`
- 主文案："暂无书签"，`OWL.bodyFont`，`OWL.textSecondary`
- 副文案："点击地址栏的 ☆ 即可收藏当前网页"，`OWL.captionFont`，`OWL.textTertiary`
- 行间距：8px

#### 组件树

```swift
// 侧边栏模式切换
SidebarView: View
├── if sidebarMode == .tabs
│   └── [现有标签列表]
├── else if sidebarMode == .bookmarks
│   └── BookmarkSidebarView
│       ├── SidebarBookmarkHeader
│       ├── if bookmarks.isEmpty
│       │   └── BookmarkEmptyState
│       └── else
│           └── ScrollView
│               └── LazyVStack
│                   └── ForEach(bookmarks)
│                       └── BookmarkRow
│                           ├── FaviconPlaceholder
│                           ├── VStack(title + domain)
│                           ├── .contextMenu { DeleteButton }
│                           └── HoverDeleteButton (hover 时显示)
└── SidebarToolbar（bookmark 按钮连接到模式切换，需扩展 ToolbarIconButton 支持 isActive）
```

### 3.3 SidebarToolbar 书签按钮

#### 交互设计

- **当前行为**：空 closure
- **新行为**：切换 `sidebarMode` 在 `.tabs` 和 `.bookmarks` 之间
- **视觉反馈**：当 sidebarMode == .bookmarks 时，书签按钮高亮（`OWL.accentPrimary` 颜色）
- 图标保持 `bookmark`（不变），但颜色变化指示激活状态

| 状态 | 图标颜色 |
|------|---------|
| 未激活 | `OWL.textSecondary` |
| 未激活 + 悬停 | `OWL.textPrimary` |
| 激活（书签模式） | `OWL.accentPrimary` |
| 激活 + 悬停 | `OWL.accentPrimary`（保持不变，已是最强调色） |

**实现要点**：
- `ToolbarIconButton` 需新增 `isActive: Bool` 参数（或 `activeColor: Color?`）
- 当 `isActive == true` 时，foregroundColor 固定为 `OWL.accentPrimary`，忽略 hover 变色

## 4. 状态流转

### 星标按钮状态机

```
           URL 为空
              │
              ▼
         ┌─ disabled ─┐
         │   (灰色)    │
         └─────────────┘
              │ URL 有效
              ▼
     ┌── unchecked ──┐    checkCurrentPage
     │  (空心灰色)    │◄─── URL 变化 / Tab 切换
     └───────────────┘
          │                    │
    已收藏 │                    │ 未收藏
          ▼                    ▼
   ┌── bookmarked ──┐   ┌── not_bookmarked ──┐
   │  (实心蓝色)     │   │  (空心灰色)         │
   └────────────────┘   └────────────────────┘
     │ 点击              │ 点击
     ▼                   ▼
   ┌── removing ────┐   ┌── adding ──────────┐
   │  (实心, disabled│   │  (空心, disabled)   │
   │   opacity 0.5) │   │   opacity 0.5)     │
   └────────────────┘   └────────────────────┘
     │ 成功    │ 失败      │ 成功    │ 失败
     ▼         ▼           ▼         ▼
   not_      bookmarked  bookmarked  not_
   bookmarked                        bookmarked
```

### 侧边栏模式状态机

```
   ┌──── tabs ────┐
   │ (标签列表)    │
   └──────────────┘
      │ 点击书签按钮
      ▼
   ┌── bookmarks ─┐
   │ (书签列表)    │ ← loadAll() 触发
   └──────────────┘
      │ 再次点击书签按钮
      ▼
   ┌──── tabs ────┐
   │ (标签列表)    │
   └──────────────┘
```

## 5. 设计决策记录

| 决策 | 选择 | 原因 |
|------|------|------|
| 书签面板位置 | 侧边栏模式切换（非 RightPanel） | PRD 定义为与标签列表并列；侧边栏更符合浏览器书签栏惯例；RightPanel 用于 AI Chat 等辅助功能 |
| 书签行高 | 44px（大于 tabItemHeight 36px） | 需要容纳标题 + 域名两行文字 |
| favicon 实现 | 域名首字母 + 色块占位 | Phase 36 不做真实 favicon 获取，保持简洁 |
| 删除确认 | 无确认（直接删除） | 星标一键恢复，操作成本低；侧边栏删除通过 contextMenu 有一定防误触 |
| 删除入口 | contextMenu + hover 删除按钮（非 swipeActions） | macOS 不支持 swipeActions，hover 删除按钮是桌面端常见替代方案 |
| 侧边栏 compact 模式 | 书签模式下 compact 侧边栏不显示书签列表（仅显示 toolbar） | 36px 宽度无法显示书签内容，与标签列表 compact 行为一致。书签按钮激活高亮保留，指示当前模式 |
| sidebarMode 归属 | BrowserViewModel（非 View @State） | 需要跨组件响应（AddressBarView 星标 + SidebarView 列表），必须在 ViewModel 层 |

## 6. 架构集成要点

### BrowserViewModel 扩展
- 新增 `@Published var sidebarMode: SidebarMode = .tabs`（枚举 `.tabs` / `.bookmarks`）
- 新增 `bookmarkVM: BookmarkViewModel`（随 app 生命周期存在）
- `sidebarMode` 放在 ViewModel 层（非 View @State），因为 AddressBarView 中的星标也需要感知侧边栏模式

### AddressBarView 扩展
- 新增 props：`isBookmarked: Bool`、`isBookmarkEnabled: Bool`、`isBookmarkLoading: Bool`、`onToggleBookmark: () -> Void`
- 这些 props 由调用方从 `BrowserViewModel.bookmarkVM` 的 computed properties 传入

### ToolbarIconButton 扩展
- 新增 `isActive: Bool = false` 参数
- 当 `isActive` 时 foregroundColor 为 `OWL.accentPrimary`

## 7. 无障碍考量

- **星标按钮**：`.accessibilityLabel("书签")` + `.accessibilityValue(isBookmarked ? "已收藏" : "未收藏")`
- **操作失败**：通过 `AccessibilityNotification.Announcement` 通知"书签操作失败"
- **书签列表项**：每项作为 button role，label 包含标题和域名
- **删除操作**：contextMenu 中"删除"标记 destructive role
- **颜色对比度**：所有文字颜色在 light/dark mode 下均满足 WCAG AA（4.5:1）
- **键盘导航**：
  - 书签列表支持 Up/Down 箭头键选择，Enter 打开
  - 焦点首次进入列表时落在第一项
  - 删除后焦点移到下一项（若删除末尾项则移到上一项）
  - VoiceOver 用户通过 rotor 操作 contextMenu 触发删除
