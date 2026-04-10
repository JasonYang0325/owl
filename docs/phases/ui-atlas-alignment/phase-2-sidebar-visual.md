# Phase 2: Sidebar 视觉重构

## 目标
将 Sidebar 的背景、顶部布局、Tab 选中态、底部工具栏全部对齐 Atlas 风格。

## 范围
- 修改：
  - `owl-client-app/Views/Sidebar/SidebarView.swift` — 背景色 + 顶部三层重构 + 移除搜索框
  - `owl-client-app/Views/Sidebar/SidebarToolbar.swift` — 精简为仅设置按钮
  - `owl-client-app/Views/Sidebar/TabRowView.swift` — 选中态颜色
  - `owl-client-app/Views/Sidebar/PinnedTabRow.swift` — 选中态颜色
  - `owl-client-app/Views/Shared/DesignTokens.swift` — sidebarWidth 常量

## 依赖
- 无前置依赖

## 技术要点

### 2.1 Sidebar 背景
- `.background(.ultraThinMaterial)` → `.background(OWL.surfacePrimary)`

### 2.2 SidebarView 三层重构
将 `SidebarView.body` 重构为：
1. **顶部固定区**（sidebarMode 分支之外）：`NewTabButton` + 新增 `BookmarkButton` + Divider
2. **中间内容区**（sidebarMode 分支内）：tabs/bookmarks/history/downloads
3. **底部工具栏**：仅设置

关键：顶部固定区在 `if/else sidebarMode` 之外，所有模式共享。
Compact 模式下整个顶部固定区隐藏（`if !isCompact` 包裹）。

### 2.3 BookmarkButton
- 新增组件，样式同 `NewTabButton`
- 图标：`bookmark`（SF Symbols），激活时 `OWL.accentPrimary`
- Toggle 语义：复用 `viewModel.toggleSidebarMode(.bookmarks)`
- `accessibilityIdentifier`: `"sidebarTopBookmarkButton"`

### 2.4 Tab 选中态
- TabRowView + PinnedTabRow 共用：
  - Active 背景：light `OWL.surfaceSecondary`(#F5F5F5)，dark `Color(hex: 0x333333)`
  - Active 文字：`OWL.textPrimary`（非白色）
  - Active 关闭按钮：`OWL.textSecondary`（非 white.opacity）
  - Active pin 图标：`OWL.textPrimary`
  - Hover 非选中：`surfaceSecondary.opacity(0.5)`

### 2.5 SidebarToolbar 精简
- 移除所有按钮，仅保留"设置"（gearshape + "设置" 文字，左对齐）
- 设置按钮点击以 `.sheet` 打开 `SettingsView`

### 2.6 移除搜索框
- 删除 `TabSearchField` 视图
- 删除 `searchText` @State
- 删除 `filteredPinnedTabs`/`filteredUnpinnedTabs` 过滤逻辑
- 直接使用 `viewModel.tabs.filter { $0.isPinned }` 等

### 2.7 DesignTokens
- `OWL.sidebarWidth` 从 140 改为 200

## 验收标准
- [ ] Sidebar 背景为纯色（light: white, dark: #1A1A1A），无渐变
- [ ] Sidebar 顶部有 "+ 添加标签页" 和 "书签" 两个入口，无搜索框
- [ ] 书签入口点击切换到书签视图，再次点击回到标签页列表
- [ ] 书签入口在 bookmarks 模式下图标为蓝色
- [ ] 选中 Tab 背景为浅灰，文字为深色
- [ ] Dark mode 下选中 Tab 对比度足够（#333333 vs #1A1A1A）
- [ ] 底部工具栏仅有 "设置"，点击打开 SettingsView sheet
- [ ] Sidebar 默认宽度为 200pt
- [ ] Compact 模式正常（顶部隐藏、36pt 宽 icon-only）

## 技术方案

### 1. 架构设计

5 个文件修改，无新增文件，无跨层变更。全部在 SwiftUI 视图层。

```
DesignTokens.swift   — sidebarWidth 常量 140→200
SidebarView.swift    — 背景色 + 三层重构 + 移除搜索框 + 新增 BookmarkButton
SidebarToolbar.swift — 精简为仅设置按钮 + sheet 导航
TabRowView.swift     — 选中态颜色
PinnedTabRow.swift   — 选中态颜色
```

### 2. 核心逻辑

#### 2.1 DesignTokens.swift
```swift
// 改: static let sidebarWidth: CGFloat = 140
// 为: static let sidebarWidth: CGFloat = 200
```

#### 2.2 SidebarView.swift — 三层重构

**现有结构**（简化）：
```swift
VStack {
    if history { HistorySidebarView }
    else if bookmarks { BookmarkSidebarView }
    else if downloads { DownloadSidebarView }
    else {
        // 仅 tabs 模式才显示
        TabSearchField(...)    // ← 删除
        NewTabButton(...)
        Divider
        ScrollView { tab list }
    }
    Divider
    SidebarToolbar(...)
}
.background(.ultraThinMaterial)  // ← 改为 surfacePrimary
```

**目标结构**：
```swift
VStack(spacing: 0) {
    // === 顶部固定区（所有模式共享，在 if/else 之外）===
    if !isCompact {
        NewTabButton { viewModel.createTab() }
            .padding(.horizontal, 10)
        BookmarkButton(                          // ← 新增
            isActive: viewModel.sidebarMode == .bookmarks,
            action: { viewModel.toggleSidebarMode(.bookmarks) }
        )
        .padding(.horizontal, 10)
        Divider().padding(.horizontal, 10).padding(.vertical, 4)
    }

    // === 中间内容区（sidebarMode 分支）===
    if viewModel.sidebarMode == .history && !isCompact {
        HistorySidebarView(...)
    } else if viewModel.sidebarMode == .bookmarks && !isCompact {
        BookmarkSidebarView(...)
    } else if viewModel.sidebarMode == .downloads && !isCompact {
        DownloadSidebarView(...)
    } else {
        ScrollView { /* tab list — 无过滤，直接用 viewModel.tabs */ }
    }

    // === 底部工具栏 ===
    Divider()
    SidebarToolbar(isCompact: isCompact)
}
.background(OWL.surfacePrimary)
```

**关键变更**：
- `TabSearchField` + `searchText` state + `filteredPinnedTabs`/`filteredUnpinnedTabs` 计算属性全部删除
- `NewTabButton` 从 `else` 分支内移到顶部（所有模式共享）
- Tab list 直接使用 `viewModel.tabs.filter { $0.isPinned }` 和 `viewModel.tabs.filter { !$0.isPinned }`

#### 2.3 BookmarkButton — 新增组件

在 `SidebarView.swift` 底部新增（与 `NewTabButton` 同文件）：
```swift
struct BookmarkButton: View {
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 14))
                Text("书签")
                    .font(OWL.tabFont)
                Spacer()
            }
            .foregroundColor(isActive ? OWL.accentPrimary :
                           (isHovered ? OWL.textPrimary : OWL.textSecondary))
            .fontWeight(isActive ? .medium : .regular)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("sidebarTopBookmarkButton")
    }
}
```

#### 2.4 TabRowView.swift — 选中态颜色

```swift
// Active tab 背景色（light/dark 分离，使用 DesignTokens.swift 中已有的 Color(light:dark:) 扩展）
private var backgroundColor: Color {
    if isActive {
        return Color(light: Color(hex: 0xF5F5F5), dark: Color(hex: 0x333333))
    }
    if isHovered { return OWL.surfaceSecondary.opacity(0.3) }  // 保持 0.3（dark 下可见性好于 0.5）
    return .clear
}

// 文字颜色：移除 isActive 条件分支，统一用 textPrimary
// 原: .foregroundColor(isActive ? .white : OWL.textPrimary)
// 改: .foregroundColor(OWL.textPrimary)

// Favicon 占位符：移除 isActive 条件分支
// 原: .fill(isActive ? .white.opacity(0.3) : OWL.textTertiary)
// 改: .fill(OWL.textTertiary)

// 关闭按钮：移除 isActive 条件分支
// 原: .foregroundColor(isActive ? .white.opacity(0.7) : OWL.textSecondary)
// 改: .foregroundColor(OWL.textSecondary)
```

**注意**：`Color(light:dark:)` 扩展在 `DesignTokens.swift` 第 48-53 行已定义，无需新增。hover opacity 保持 0.3（与现有代码一致，dark mode 下 0.5 对比度不足）。

#### 2.5 PinnedTabRow.swift — 同步修改

与 TabRowView 相同的 backgroundColor 逻辑 + pin.fill 图标颜色改为：
```swift
.foregroundColor(isActive ? OWL.textPrimary : OWL.textTertiary)
// 替代原来的: isActive ? .white.opacity(0.8) : OWL.textTertiary

// 文字颜色统一为 textPrimary（不再用 .white）
.foregroundColor(OWL.textPrimary)
```

#### 2.6 SidebarToolbar.swift — 精简

替换整个 body 为：
```swift
var body: some View {
    HStack(spacing: 6) {
        Button(action: { showSettings = true }) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                if !isCompact {
                    Text("设置")
                        .font(OWL.tabFont)
                }
            }
            .foregroundColor(isHovered ? OWL.textPrimary : OWL.textSecondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        Spacer()
    }
    .padding(.horizontal, 10)
    .frame(height: OWL.toolbarHeight)
    .sheet(isPresented: $showSettings) { SettingsView() }
}
```

新增 state：`@State private var showSettings = false` 和 `@State private var isHovered = false`

移除：所有 `ToolbarIconButton` 调用、`onTogglePanel`、`onToggleSidebarMode`、`sidebarMode`、`downloadBadgeCount` 参数（简化接口）。

### 3. 接口变更

| 组件 | 移除的参数 | 保留的参数 |
|------|-----------|-----------|
| `SidebarToolbar` | `onTogglePanel`, `onToggleSidebarMode`, `sidebarMode`, `downloadBadgeCount` | `isCompact` |
| `SidebarView` | — | 不变（`onTogglePanel` 参数保留，但不再传递给 SidebarToolbar） |

**调用点更新**：`SidebarToolbar` 在 `SidebarView.swift` 第 88-94 行调用（不在 BrowserWindow 中）。精简后改为 `SidebarToolbar(isCompact: isCompact)`，移除所有回调参数。`SidebarView` 的 `onTogglePanel` 参数保留（未来可能用于其他入口），但本次不再传递给 SidebarToolbar。

**有意的功能降级**（PRD 第 3.2.5 节已确认）：
- 历史/下载入口移除 — 代码中 `sidebarMode == .history/.downloads` 分支保留，但无 UI 触发入口。后续通过 macOS 菜单栏补齐
- AI/Agent/Console 面板入口移除 — `onTogglePanel` 不再从 SidebarToolbar 触发。面板功能仍存在，快捷键/右键菜单入口后续补齐
- 这些降级在 PRD 开放问题章节已关闭，非本 Phase 遗漏

### 4. 文件变更清单

| 文件 | 操作 | 改动量 |
|------|------|--------|
| `DesignTokens.swift` | 修改 | 1 行 |
| `SidebarView.swift` | 修改 | ~80 行（删搜索框 + 重构三层 + 新增 BookmarkButton） |
| `SidebarToolbar.swift` | 修改 | ~40 行（精简为设置按钮 + sheet） |
| `TabRowView.swift` | 修改 | ~15 行（颜色） |
| `PinnedTabRow.swift` | 修改 | ~10 行（颜色） |

### 5. 测试策略

- **编译验证**：`run_tests.sh cpp` 确认无编译错误
- **现有 GTest**：确认 504 个测试仍全部通过（本次无逻辑变更，仅视觉）
- **手动验证**：启动浏览器验证所有 9 个 AC
- **XCUITest**：后续统一 E2E 验收

### 6. 风险 & 缓解

| 风险 | 概率 | 缓解 |
|------|------|------|
| SidebarToolbar 接口变更导致 BrowserWindow 编译失败 | 中 | Dev Agent 同步更新 BrowserWindow 调用点 |
| 搜索框移除导致 filteredTabs 引用残留 | 低 | 全量删除 searchText + 过滤逻辑 |
| BookmarkButton toggle 逻辑不正确 | 低 | 复用现有 toggleSidebarMode 方法 |
| ToolbarIconButton 组件变为死代码 | 确定 | `ToolbarIconButton` 仅在 SidebarToolbar.swift 内引用，精简后一并删除 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
