# UI Atlas 风格对齐 — UI 设计稿

## 1. 设计概述

**设计目标**：将 OWL 浏览器的视觉风格对齐 Atlas 浏览器，重点改造 Sidebar 和 ContentArea，修复 WebContent 透明背景 bug。

**设计原则**：
- **简洁**：减少视觉噪音，移除渐变背景、多余图标
- **层级清晰**：选中态柔和不刺眼，用灰度差而非强色彩区分
- **一致性**：与 Atlas 保持相同的布局逻辑和视觉语言
- **遵循现有 token 体系**：优先使用 `OWL.*` design tokens

## 2. 信息架构

```
BrowserWindow
├── TopBar (48pt)
│   ├── [72pt spacer - window controls]
│   ├── [Sidebar Toggle Button] ← NEW
│   ├── Navigation Buttons (back/forward/reload)
│   ├── [Spacer]
│   ├── Address Bar (max 600pt)
│   └── [Spacer]
├── HStack
│   ├── Sidebar (200pt default, 160-280 drag)
│   │   ├── Top Fixed Area ← RESTRUCTURED
│   │   │   ├── "+ 添加标签页" button
│   │   │   └── "书签" button (toggle)
│   │   ├── Content Area (scrollable)
│   │   │   ├── [tabs mode] Tab list
│   │   │   ├── [bookmarks mode] BookmarkSidebarView
│   │   │   ├── [history mode] HistorySidebarView
│   │   │   └── [downloads mode] DownloadSidebarView
│   │   └── Bottom Toolbar ← SIMPLIFIED
│   │       └── "设置" button only
│   ├── Divider
│   └── ContentArea ← BACKGROUND FIX
│       └── ZStack
│           ├── OWL.surfacePrimary (底层兜底背景)
│           ├── WelcomeView / RemoteLayerView / ErrorPage / Loading
│           └── Overlays (FindBar, SSLError, etc.)
```

## 3. 页面/组件设计

### 3.1 ContentArea 背景修复

#### 布局
无布局变更。仅在 `ContentAreaView` 的 ZStack 底层增加不透明背景色。

#### 视觉规范
- 背景色：`OWL.surfacePrimary`
  - Light: `#FFFFFF`
  - Dark: `#1A1A1A`
- 位置：ZStack 所有内容分支之前

#### 交互设计
无交互变更。背景色为静态填充。

### 3.2 Sidebar 背景

#### 视觉规范
- **当前**：`.ultraThinMaterial`（系统毛玻璃，透过底层渐变色导致视觉杂乱）
- **目标**：`OWL.surfacePrimary`
  - Light: `#FFFFFF`（纯白，与 Atlas 一致）
  - Dark: `#1A1A1A`

### 3.3 Sidebar 顶部固定区域

#### 布局

```
┌──────────────────────┐
│ + 添加标签页          │  ← NewTabButton (unchanged style)
│ 🔖 书签              │  ← BookmarkButton (NEW)
├──────────────────────┤  ← Divider
│                      │
│  [Tab list / Content]│  ← sidebarMode 分支内容
│                      │
```

**关键实现约束**：顶部固定区域必须在 `SidebarView.body` 的 VStack 最外层，**在 sidebarMode if/else 分支之外**。当前代码中 tabs 模式下的搜索框/NewTabButton 在 `else` 分支内，必须重构为三层结构：
1. 顶部固定区（所有模式共享）
2. 中间内容（sidebarMode 分支）
3. 底部工具栏（所有模式共享）

#### 视觉规范

**BookmarkButton**：
- 样式与 `NewTabButton` 一致：左对齐，图标 + 文字
- 图标：`bookmark`（SF Symbols），14pt
- 文字：`OWL.tabFont`（13pt）
- 默认色：`OWL.textSecondary`（#8E8E93）
- Hover 色：`OWL.textPrimary`
- 激活态（`sidebarMode == .bookmarks`）：
  - 图标色：`OWL.accentPrimary`（#0A84FF）
  - 文字：`OWL.textPrimary`，`weight: .medium`
- padding：与 NewTabButton 相同（horizontal 10, vertical 6）
- Compact 模式（`isCompact == true`）：**整个顶部固定区域隐藏**（NewTabButton + BookmarkButton + Divider 全部隐藏），与现有代码行为一致（`if !isCompact` 包裹）。Compact sidebar 仅 36pt 宽，无法容纳文字按钮。书签/新标签页通过 Cmd+T 和菜单栏访问，此为已知体验限制

#### 交互设计
- 默认态 → hover → 文字变深
- 点击：toggle `sidebarMode`（tabs ↔ bookmarks）
- 从 history/downloads 模式点击：切换到 bookmarks
- **BookmarkButton 始终回到 tabs**：无论从哪个模式进入 bookmarks，再次点击 BookmarkButton 统一回到 `.tabs`（不保留 previousMode，保持简单确定性）

### 3.4 Tab 选中态

#### 布局
无布局变更。仅颜色修改。

#### 视觉规范

**TabRowView & PinnedTabRow 共用规则**：

| 状态 | 背景色 | 文字色 | 图标色 | 关闭按钮色 |
|------|--------|--------|--------|-----------|
| 默认 | transparent | `textPrimary` | `textTertiary` | — |
| Hover | `surfaceSecondary.opacity(0.5)` | `textPrimary` | `textTertiary` | `textSecondary` |
| Active | 见下方 | `textPrimary` | `textTertiary` | `textSecondary` |
| Active+Hover | 同 Active | `textPrimary` | `textTertiary` | `textPrimary` |

**Active 背景色（关键变更）**：
- Light mode: `OWL.surfaceSecondary`（#F5F5F5）
- Dark mode: `Color(hex: 0x333333)`（非全局 token，仅 tab active 使用，灰度差 = 0x33-0x1A = 25/255。注意：`Color(hex:)` 扩展已在 `DesignTokens.swift` 中定义，实现时直接使用，**不要**用 `OWL.surfaceSecondary` 替代）

**PinnedTabRow 特殊**：
- pin.fill 图标：active 时 `OWL.textPrimary`（替代原 `.white.opacity(0.8)`）
- 无关闭按钮

### 3.5 Sidebar 底部工具栏

#### 布局

```
┌──────────────────────┐
│ ⚙ 设置               │  ← 左对齐，icon + text
└──────────────────────┘
  40pt height
```

#### 视觉规范
- 图标：`gearshape`，15pt
- 文字："设置"，`OWL.tabFont`（13pt）
- 默认色：`OWL.textSecondary`
- Hover 色：`OWL.textPrimary`
- 布局：HStack(spacing: 6)，左对齐，padding horizontal 10
- 整体高度：`OWL.toolbarHeight`（40pt）

#### 交互设计
- 点击：以 `.sheet` 打开 `SettingsView`（已存在于 `Views/Settings/SettingsView.swift`）
- Sheet 呈现时 sidebar 保持原样，无 dimming 效果（系统默认 sheet 行为）

#### 动画规格
- Sheet 呈现/消失：系统默认 `.sheet` 动画

### 3.6 Sidebar Toggle 按钮

#### 布局

```
TopBar (48pt):
┌─[traffic lights]─[Toggle]─[◀][▶][↻]────[address bar]────────┐
│  72pt spacer      28x28    NavigationButtons                  │
```

Toggle 在 72pt spacer 之后，NavigationButtons 之前。

#### 视觉规范
- 图标：`sidebar.left`（SF Symbols），14pt
- 按钮尺寸：28x28pt
- 默认色：`OWL.textSecondary`
- Hover：`OWL.surfaceSecondary` 背景 + `OWL.textPrimary` 图标
- 圆角：`OWL.radiusSmall`（6pt）
- accessibilityIdentifier: `"sidebarToggleButton"`

#### 交互设计
- 点击：toggle `isSidebarManuallyVisible`
- 快捷键：`Cmd+Shift+L`（在 BrowserWindow hidden button 区域注册）
- minimal 模式下隐藏
- Sidebar 隐藏后按钮仍可见（在 TopBar 中）
- `accessibilityValue`：sidebar 展开时为 `"expanded"`，收起时为 `"collapsed"`

#### 动画规格
- Sidebar 展开/收起：`.easeInOut(duration: 0.2)`，配合 `withAnimation`
- ContentArea 宽度变化随 sidebar 动画自动跟随（SwiftUI 布局动画）

### 3.7 Sidebar 宽度

- 默认宽度：200pt（原 140pt）
- 拖拽范围：160pt - 280pt（原 120-240）
- Compact 模式：36pt（不变）

## 4. 状态流转

### Sidebar 可见性状态机

```
           ┌─────────────────────────┐
           │   layoutMode changes    │
           └────────┬────────────────┘
                    ▼
    ┌───────────── minimal ──────────────┐
    │  sidebar forced hidden             │
    │  toggle button hidden              │
    │  isSidebarManuallyVisible preserved│
    └───────────────┬────────────────────┘
                    │ window width >= 600
                    ▼
    ┌───────── compact/full ─────────────┐
    │  sidebar visible =                 │
    │    isSidebarManuallyVisible        │
    │  toggle button visible             │
    └───────────────┬────────────────────┘
                    │ user clicks toggle
                    ▼
    ┌───────── toggle action ────────────┐
    │  isSidebarManuallyVisible.toggle() │
    │  persisted via @AppStorage         │
    └────────────────────────────────────┘
```

### Sidebar Mode 切换

```
    tabs ←──── BookmarkButton click ────→ bookmarks
     ↑                                        │
     └── BookmarkButton click (from bookmarks)┘
     
    history/downloads ── BookmarkButton click ──→ bookmarks
```

## 5. 设计决策记录

| 决策 | 方案 | 替代方案 | 理由 |
|------|------|---------|------|
| Sidebar 背景 | 纯色 `surfacePrimary` | `.thinMaterial` | Atlas 使用纯色，毛玻璃在深色桌面背景下效果不可控 |
| Active tab 颜色 | 浅灰 | 浅蓝（降低饱和度） | Atlas 使用灰色系，与整体简洁风格一致 |
| Dark mode active tab | #333333 | surfaceSecondary(#2A2A2A) | #2A2A2A 与 #1A1A1A 对比度不足，#333333 提供 ~25/255 灰度差 |
| 底部工具栏 | 仅设置 | 设置 + 更多（dropdown） | Atlas 仅有设置，简洁优先 |
| Toggle state 持久化 | @AppStorage | @State (不持久) | 用户偏好应跨 session 保持 |
| WebContent 背景修复 | SwiftUI ZStack 底层 | NSView layer 背景色 | 避免 CALayerHost/compositor 冲突 |

## 6. 无障碍考量

- 所有按钮有 `accessibilityIdentifier` 和 `accessibilityLabel`
- Active tab 与非 active tab 在 light/dark 模式下对比度充分
- Sidebar toggle 按钮在 VoiceOver 中报读为 "切换侧栏"
- BookmarkButton 激活态使用 `accentPrimary`（通过 WCAG AA 对比度）
