# UI Atlas 风格对齐 — PRD

## 1. 背景与目标

OWL 浏览器当前 UI 布局与 Atlas 浏览器存在多处视觉差异：彩色渐变 sidebar 背景、多余的搜索框、过多的底部工具栏图标、亮蓝色 tab 选中态等。此外，WebContent 区域背景透明导致页面导航时漏出窗口背景，是影响体验的 bug。

**目标**：将 OWL 的视觉风格对齐 Atlas，修复 WebContent 透明背景问题，使浏览器呈现专业统一的外观。

**成功指标**：
- WebContent 区域从 about:blank 导航到任意 URL 全程无透明漏底（可测试：50 次导航 0 帧白底外露）
- Sidebar 视觉与 Atlas 一致（背景纯色、顶部简洁、底部精简、选中态柔和）
- 顶部工具栏有 sidebar toggle 按钮，可收起/展开 sidebar

## 2. 用户故事

- **US-1**: As a 用户, I want 网页内容区域始终有不透明背景, so that 导航时不会看到窗口底色漏出
  - **AC-1a**: ContentArea 在所有状态（加载中、WelcomeView、RemoteLayerView、ErrorPage）下背景均为不透明色
  - **AC-1b**: Dark mode 下背景为 `OWL.surfacePrimary` dark 变体（#1A1A1A），light mode 下为白色
- **US-2**: As a 用户, I want sidebar 背景干净简洁, so that 视觉不杂乱
  - **AC-2a**: Sidebar 背景为 `OWL.surfacePrimary`，无彩色渐变
- **US-3**: As a 用户, I want sidebar 布局清晰, so that 常用功能触手可及且界面不拥挤
  - **AC-3a**: Sidebar 顶部有 "+ 添加标签页" 和 "书签" 两个入口，无搜索框
  - **AC-3b**: 书签入口点击后切换到书签视图，再次点击回到标签页列表
  - **AC-3c**: Sidebar 底部仅有 "设置" 入口
  - **AC-3d**: 历史/下载可通过 macOS 菜单栏 View 菜单访问
- **US-4**: As a 用户, I want tab 选中态柔和, so that 视觉层级清晰但不刺眼
  - **AC-4a**: 选中 tab 背景为浅灰色，文字为深色，关闭按钮为灰色
  - **AC-4b**: Dark mode 下选中态与非选中态有足够对比度（灰度差 >= 25/255，即 #333333 vs #1A1A1A）
- **US-5**: As a 用户, I want 可以通过按钮收起/展开 sidebar, so that 需要更多内容空间时可以隐藏 sidebar
  - **AC-5a**: TopBar 左侧有 sidebar toggle 按钮（`sidebar.left` 图标）
  - **AC-5b**: 点击 toggle 后 sidebar 消失/恢复，宽度保持上次拖拽值
  - **AC-5c**: 快捷键 Cmd+Shift+L 可切换 sidebar

## 3. 功能描述

### 3.1 核心变更清单

| # | 区域 | 当前状态 | 目标状态 | 涉及文件 |
|---|------|---------|---------|---------|
| 1 | WebContent 背景 | 透明（导航时漏底） | 不透明背景 | `ContentAreaView.swift` |
| 2 | Sidebar 背景 | `.ultraThinMaterial`（呈现彩色渐变） | 纯色 `surfacePrimary` | `SidebarView.swift` |
| 3 | Sidebar 顶部 | 搜索框 + "+ 添加标签页" | "+ 添加标签页" + "书签" 入口（所有 sidebar 模式可见） | `SidebarView.swift` |
| 4 | Tab 选中态 | `accentPrimary`（亮蓝填充）+ 白色文字 | 浅灰高亮 + 深色文字 | `TabRowView.swift`, `PinnedTabRow.swift` |
| 5 | Sidebar 底部工具栏 | 7 个图标按钮 | 仅 "设置" 图标+文字 | `SidebarToolbar.swift` |
| 6 | 顶部工具栏 | 无 sidebar 切换 | 左侧增加 sidebar toggle 按钮 | `TopBarView.swift`, `BrowserWindow.swift` |
| 7 | Sidebar 宽度 | 140pt | 200pt（拖拽范围 160-280） | `DesignTokens.swift`, `BrowserWindow.swift`（SidebarDivider 拖拽约束） |

### 3.2 详细规则

#### 3.2.1 WebContent 透明背景修复 (P0)

**方案**：在 `ContentAreaView` 的外层 ZStack **底层** 添加 `OWL.surfacePrimary` 背景色，作为所有内容状态的兜底背景。

- 在 ZStack 底部（所有分支之前）放置 `OWL.surfacePrimary` 填充
- 这确保无论处于哪个 transition 动画阶段，底层始终有不透明背景
- **不修改 RemoteLayerView 的 NSView/CALayerHost**，避免与 Chromium compositor 的 layer 管理冲突
- `OWL.surfacePrimary` 自动支持 dark mode（light: white, dark: #1A1A1A）

**为什么不在 RemoteLayerView 层设置背景**：`OWLRemoteLayerView` 内部使用 CALayerHost 接入 Chromium compositor，其 layer 由 GPU 进程管理。在 NSView 层设置 `layer.backgroundColor` 可能被 compositor 下一帧覆盖，且修改 bridge 层代码需重建 framework。在 SwiftUI 层解决更安全。

#### 3.2.2 Sidebar 背景 (P0)

- 将 `SidebarView` 的 `.background(.ultraThinMaterial)` 改为 `.background(OWL.surfacePrimary)`
- `OWL.surfacePrimary` 已定义 light/dark 变体（light: white, dark: #1A1A1A）

#### 3.2.3 Sidebar 顶部重构 (P0)

**关键设计**：顶部区域（+ 添加标签页、书签入口）在**所有 sidebar 模式**下始终可见，不受 `sidebarMode` 切换影响。

实现方式：
- 将 `SidebarView.body` 重构为三层结构：
  1. **顶部固定区域**：`NewTabButton` + `BookmarkButton`（始终可见，不在 `if/else` 分支内）
  2. **中间内容区域**：根据 `sidebarMode` 显示 tabs/bookmarks/history/downloads
  3. **底部工具栏**：仅 "设置"
- 移除 `TabSearchField` 组件的显示（删除相关 UI 代码和 `searchText` state，过滤逻辑一并清理——此为**有意的功能移除**，搜索标签页功能本期下线，后续如需恢复可通过 Cmd+Shift+A 全局搜索实现）
- `BookmarkButton` 样式与行为：
  - 图标：`bookmark`（SF Symbols），与文字 "书签" 并排，样式同 `NewTabButton`
  - **激活态**：当 `sidebarMode == .bookmarks` 时，图标颜色为 `OWL.accentPrimary`，文字加粗；非激活时颜色同 `NewTabButton` hover 态
  - 当前为 `.tabs` 模式 → 点击切换到 `.bookmarks`
  - 当前为 `.bookmarks` 模式 → 点击切换回 `.tabs`（toggle 语义，与现有 `toggleSidebarMode` 逻辑一致）
  - 当前为其他模式（`.history`/`.downloads`）→ 点击切换到 `.bookmarks`
- `accessibilityIdentifier`: `"sidebarTopBookmarkButton"`（与原底部的 `"sidebarBookmarkButton"` 区分）
- Compact 模式（`isCompact == true`）下顶部区域隐藏（与现有行为一致，compact sidebar 仅 36pt 宽显示图标。书签/新标签页功能在 compact 下通过 Cmd+T 和菜单栏访问，此为已知体验限制）

#### 3.2.4 Tab 选中态 (P1)

**TabRowView 和 PinnedTabRow 遵循相同规则**：

- Active tab 背景：`OWL.surfaceSecondary`（light: #F5F5F5, dark: #2A2A2A）
- Active tab 文字：`OWL.textPrimary`（不再用白色）
- Active tab favicon 占位符：`OWL.textTertiary`（不再用 `.white.opacity(0.3)`）
- Active tab 关闭按钮（TabRowView hover 时）：`OWL.textSecondary`（不再用 `.white.opacity(0.7)`）
- PinnedTabRow 的 pin 图标颜色同步调整：active 时用 `OWL.textPrimary` 替代 `.white.opacity(0.8)`
- Hover 非选中 tab：`OWL.surfaceSecondary.opacity(0.5)`
- Dark mode 对比度：默认 `surfaceSecondary`(#2A2A2A) vs `surfacePrimary`(#1A1A1A) 差值偏弱。**决定**：active tab dark mode 背景使用 `Color(hex: 0x333333)` 而非 `surfaceSecondary`，确保灰度差 >= 25/255。在 `TabRowView`/`PinnedTabRow` 中直接使用该色值，不修改全局 `surfaceSecondary` token。

#### 3.2.5 Sidebar 底部工具栏精简 (P0)

- 仅保留 "设置" 按钮（`gearshape` 图标 + "设置" 文字标签），左对齐
- 设置按钮点击以 `.sheet` 方式打开 `SettingsView`（当前代码中 action 为空，需实现。使用 sheet 与 Atlas 一致，避免 sidebar 内嵌导航复杂度）
- 移除书签、历史、下载、AI、Agent、Console 图标按钮

**功能入口迁移方案**：
| 功能 | 原入口 | 新入口 | 状态 |
|------|--------|--------|------|
| 书签 | 底部工具栏 | Sidebar 顶部 BookmarkButton | 本期实现 |
| 历史 | 底部工具栏 | macOS 菜单栏 View > 历史 | 本期不实现，已知降级 |
| 下载 | 底部工具栏（含 badge） | macOS 菜单栏 View > 下载 | 本期不实现，已知降级 |
| AI/Agent/Console | 底部工具栏 | 右键菜单或快捷键 | 本期不实现，已知降级 |

**已知降级**：下载进度 badge（显示活跃下载数）在本期移除后暂无替代可见性方案。后续迭代将在 TopBar 或 StatusBar 增加下载进度指示器。

#### 3.2.6 Sidebar Toggle 按钮 (P1)

**状态管理设计**：

新增 `@AppStorage("owl.sidebar.manuallyVisible") var isSidebarManuallyVisible: Bool = true`，与现有 `LayoutMode` 合并规则：
- Sidebar 实际显示 = `layoutMode.sidebarVisible && isSidebarManuallyVisible`
- `minimal` 模式（< 600px）：sidebar 强制隐藏，`isSidebarManuallyVisible` 值保持不变
- `compact` 模式（600-999px）：sidebar toggle 按钮**可见**，可手动隐藏
- `full` 模式（>= 1000px）：sidebar toggle 按钮可见，可手动隐藏
- 窗口从 minimal 放大到 compact/full 时，恢复 `isSidebarManuallyVisible` 的值（即用户之前的选择被保留）

**TopBarView 修改**：
- Toggle 按钮在**顶层 HStack** 中插入，位于 72pt spacer 之后、`ActiveTabTopBar`/`NavigationButtons` 分支之前（即不在 `if let tab` 分支内部，而是外层的独立元素）
- 图标：`sidebar.left`（SF Symbols）
- `accessibilityIdentifier`: `"sidebarToggleButton"`
- action 传递：通过 `onToggleSidebar: (() -> Void)?` 回调闭包传入（与现有 `onTogglePanel` 模式一致），由 `BrowserWindow` 提供闭包写入 `isSidebarManuallyVisible`
- `TopBarView` 需要接收 `layoutMode` 参数来控制按钮在 minimal 模式下隐藏
- Sidebar 隐藏后 TopBar toggle 按钮**始终可见**（只要不在 minimal 模式），用户可随时点击恢复 sidebar
- 键盘快捷键：`Cmd+Shift+L`（在 BrowserWindow.swift 的 hidden button 区域添加）

#### 3.2.7 Sidebar 宽度调整 (P1)

- `DesignTokens.swift`: `OWL.sidebarWidth` 从 140 改为 200
- `BrowserWindow.swift` `SidebarDivider` 的 `dragGesture`: `max(120, min(240, ...))` 改为 `max(160, min(280, ...))`
- 窗口最小宽度 480pt，sidebar max 280pt + divider 1pt + ContentArea 至少需要 ~200pt → 合理

### 3.3 异常/边界处理

- Sidebar 隐藏时（toggle 或 minimal 模式）快捷键 Cmd+T/W/数字键等仍正常工作
- Sidebar toggle 按钮：
  - `minimal` 模式：隐藏（sidebar 强制不可见，无需切换）
  - `compact` 模式：可见，点击切换 sidebar（36pt icon-only sidebar 也可隐藏）。隐藏后 toggle 按钮仍可见，可点击恢复
  - `full` 模式：可见，点击切换 sidebar。隐藏后 toggle 按钮仍可见
- Dark mode：所有变更使用 `OWL.*` design tokens（已有 light/dark 变体），active tab dark mode 使用 `#333333` 而非全局 `surfaceSecondary`
- `ContentAreaView` 背景色跟随系统 light/dark 自动切换（`OWL.surfacePrimary` 内建）
- RightPanel（360pt）与 sidebar 同时打开时：窗口最小宽度 480pt 无法同时容纳 sidebar max(280) + RightPanel(360)。由现有布局的 `frame(minWidth: 480)` 约束保护，拖拽 sidebar 宽度时不会超出可用空间（系统级约束）

## 4. 非功能需求

- **性能**：主要为 SwiftUI 视图层变更。Sidebar 宽度调整会触发 `ContentAreaView.onGeometryChange` → `tab.updateViewport`（Host 层调用），但这与窗口 resize 是相同路径，无额外性能风险
- **兼容性**：macOS 14+ SwiftUI 兼容
- **可访问性**：
  - 新增按钮需有 accessibility identifier 和 label
  - `sidebarToggleButton` — sidebar 切换按钮
  - `sidebarTopBookmarkButton` — 侧栏顶部书签按钮

## 5. 数据模型变更

无数据模型变更。仅涉及 UI 层状态：
- `BrowserWindow` 新增 `@AppStorage("owl.sidebar.manuallyVisible") var isSidebarManuallyVisible: Bool = true`

## 6. 影响范围

| 模块 | 文件 | 影响 |
|------|------|------|
| `Views/Sidebar/` | `SidebarView.swift` | 背景色、顶部重构（去搜索框、加书签入口、模式切换） |
| `Views/Sidebar/` | `SidebarToolbar.swift` | 精简为仅设置按钮 |
| `Views/Sidebar/` | `TabRowView.swift` | 选中态颜色（背景、文字、关闭按钮） |
| `Views/Sidebar/` | `PinnedTabRow.swift` | 选中态颜色（背景、pin 图标） |
| `Views/Content/` | `ContentAreaView.swift` | ZStack 底层添加不透明背景 |
| `Views/TopBar/` | `TopBarView.swift` | 新增 sidebar toggle 按钮 |
| `Views/` | `BrowserWindow.swift` | `isSidebarManuallyVisible` 状态、sidebar 可见性逻辑、拖拽范围更新、toggle 快捷键 |
| `Views/Shared/` | `DesignTokens.swift` | `sidebarWidth` 常量调整 |

**注意**：历史/下载/AI/Agent/Console 的入口移除是**有意的功能降级**，非"无破坏性影响"。这些功能的代码和视图（HistorySidebarView、DownloadSidebarView 等）保留不变，仅移除触发入口。

## 7. 里程碑 & 优先级

**P0（必须）**:
1. WebContent 透明背景修复
2. Sidebar 背景改为纯色
3. Sidebar 顶部重构（去搜索框，加书签入口，所有模式可见）
4. Sidebar 底部工具栏精简（含设置按钮导航实现）

**P1（重要）**:
5. Tab 选中态柔和化（TabRowView + PinnedTabRow）
6. Sidebar toggle 按钮（含状态管理 + 快捷键）
7. Sidebar 宽度调整（含拖拽范围更新）

## 8. 开放问题（已关闭）

| 问题 | 决策 | 理由 |
|------|------|------|
| 搜索框移除是否为功能降级？ | 是，本期有意下线 | 与 Atlas 对齐优先，后续通过全局搜索补齐 |
| 历史/下载入口移除后如何访问？ | 本期降级，后续通过菜单栏补齐 | P0 范围控制，先视觉对齐 |
| 下载 badge 消失如何感知进度？ | 已知降级，后续在 TopBar 补充 | 与历史/下载入口统一规划 |
| isSidebarVisible 与 LayoutMode 优先级？ | 合并：实际显示 = layoutMode.sidebarVisible && isSidebarManuallyVisible | 两者独立控制，minimal 强制隐藏 |
| 书签入口点击后如何返回标签页？ | Toggle 语义，再次点击返回 tabs | 复用现有 toggleSidebarMode 逻辑 |
