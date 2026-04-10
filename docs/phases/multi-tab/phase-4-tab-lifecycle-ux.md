# Phase 4: 标签生命周期 UX（固定标签 + 撤销关闭 + 快捷键）

## 目标
- 支持固定标签（Pin Tab）：置顶、图标样式、关闭保护
- 支持撤销关闭（Cmd+Shift+T）：恢复 URL + isPinned + 位置
- 完整的键盘快捷键支持
- 上下文菜单（右键）

## 范围

### 修改文件
| 文件 | 变更 |
|------|------|
| `owl-client-app/ViewModels/BrowserViewModel.swift` | closedTabsStack + pinTab/unpinTab + 撤销关闭逻辑 |
| `owl-client-app/ViewModels/TabViewModel.swift` | isPinned 属性持久化 |
| `owl-client-app/Views/Sidebar/SidebarView.swift` | 固定标签区 PinnedTabSection + 分隔线 |
| `owl-client-app/Views/Sidebar/TabRowView.swift` | deferred/loading/error 状态视觉 |

### 新增文件
| 文件 | 内容 |
|------|------|
| `owl-client-app/Views/Sidebar/PinnedTabRow.swift` | 固定标签独立组件 |
| `owl-client-app/Views/Sidebar/TabContextMenu.swift` | 上下文菜单 ViewModifier |

## 依赖
- Phase 2（BrowserViewModel.createTab/closeTab/activateTab）

## 技术要点

### 固定标签
- isPinned 是纯 UI 层概念（Host 不感知）
- 固定标签侧边栏置顶，显示为 PinnedTabRow（图标样式、无关闭按钮）
- Cmd+W 在活跃固定标签上仍可关闭（对齐 Safari/Chrome）
- 取消固定：右键 → "取消固定"，移到固定区之后第一个位置
- 固定标签区最多 8 个，超过时变为可滚动

### 撤销关闭栈
- `closedTabsStack: [ClosedTabRecord]`，最多 20 条
- ClosedTabRecord: url, title, isPinned, originalIndex
- Cmd+Shift+T 弹出最近记录 → createTab(url) → 恢复 isPinned → 插入 originalIndex

### 键盘快捷键
- Cmd+T: 新建空白标签（末尾）
- Cmd+W: 关闭活跃标签
- Cmd+Shift+T: 撤销关闭
- Cmd+1~8: 第 N 个标签（固定+普通统一计数）
- Cmd+9: 最后一个标签
- Cmd+Option+↓/↑: 切换到下/上方标签（不循环）

### 上下文菜单
- 使用 SwiftUI `.contextMenu { }` modifier
- 普通标签: 固定/重新加载/关闭/关闭其他/关闭下方/复制链接
- 固定标签: 取消固定/重新加载/关闭/关闭其他/复制链接
- Deferred 标签: "加载此标签" 替代 "重新加载"

## 验收标准
- [ ] 固定标签置顶显示，无关闭按钮（AC-005）
- [ ] Cmd+W 关闭活跃固定标签
- [ ] 撤销关闭恢复 URL + isPinned + 位置（AC-006）
- [ ] 所有键盘快捷键正常工作
- [ ] 上下文菜单功能完整
- [ ] 标签列表动画（创建/关闭/恢复/固定移动）

## 技术方案

### 1. 架构设计

Phase 4 完全在 Swift/SwiftUI 层，无 Host/Bridge 变更。

```
BrowserViewModel (数据层)
  ├── tabs: [TabViewModel]          — 现有，Phase 2 已支持多标签
  ├── pinnedTabs: [TabViewModel]    — 新增计算属性（tabs.filter { $0.isPinned }）
  ├── unpinnedTabs: [TabViewModel]  — 新增计算属性
  ├── closedTabsStack: [ClosedTabRecord]  — 新增，最多 20 条
  └── pinTab/unpinTab/undoCloseTab  — 新增方法

SidebarView (UI 层)
  ├── PinnedTabSection              — 新增组件（固定标签区）
  │     └── PinnedTabRow × N        — 新增组件
  ├── Divider（条件显示）
  └── ScrollView > LazyVStack       — 现有，显示 unpinnedTabs
        └── ObservedTabRow × N      — 现有 + 状态扩展 + contextMenu

ContentAreaView → 键盘快捷键绑定（.keyboardShortcut modifier）
```

### 2. 数据模型

#### ClosedTabRecord（新增）
```swift
struct ClosedTabRecord {
    let url: String
    let title: String
    let isPinned: Bool
    let originalIndex: Int  // 在 tabs 数组中的位置
}
```

#### BrowserViewModel 新增
```swift
// 撤销关闭栈
private var closedTabsStack: [ClosedTabRecord] = []
private let maxClosedTabs = 20

// 计算属性（基于 tabs 数组 + isPinned）
var pinnedTabs: [TabViewModel] { tabs.filter { $0.isPinned } }
var unpinnedTabs: [TabViewModel] { tabs.filter { !$0.isPinned } }
```

### 3. 核心逻辑

#### pinTab / unpinTab
```swift
func pinTab(_ tab: TabViewModel) {
    tab.isPinned = true
    // 移动到固定区末尾：从当前位置移除，插入到最后一个固定标签之后
    if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
        tabs.remove(at: idx)
        let insertIdx = pinnedTabs.count  // 新的固定区末尾
        tabs.insert(tab, at: insertIdx)
    }
}

func unpinTab(_ tab: TabViewModel) {
    tab.isPinned = false
    // 移动到非固定区开头：从当前位置移除，插入到固定区之后第一个位置
    if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
        tabs.remove(at: idx)
        let insertIdx = tabs.filter { $0.isPinned }.count
        tabs.insert(tab, at: insertIdx)
    }
}
```

#### closeTab 修改（增加入栈逻辑）
```swift
func closeTab(_ tab: TabViewModel) {
    // 记录关闭信息
    if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
        let record = ClosedTabRecord(
            url: tab.url ?? "", title: tab.title,
            isPinned: tab.isPinned, originalIndex: idx)
        closedTabsStack.append(record)
        if closedTabsStack.count > maxClosedTabs {
            closedTabsStack.removeFirst()
        }
    }
    // 现有关闭逻辑（clearCallbacks + removeFromMap + DestroyWebView）
    // ...
}
```

#### undoCloseTab (Cmd+Shift+T)
```swift
func undoCloseTab() {
    guard let record = closedTabsStack.popLast() else { return }
    let insertIndex = min(record.originalIndex, tabs.count)
    createTabAtIndex(url: record.url, index: insertIndex, foreground: true)
    // 恢复 isPinned（在 createTab 回调中设置）
    // 使用 pendingPinAfterCreate flag
}
```

#### 键盘快捷键
```swift
// 在 ContentAreaView 或顶层 View 中：
.keyboardShortcut("t", modifiers: .command)           // Cmd+T: 新标签
.keyboardShortcut("w", modifiers: .command)           // Cmd+W: 关闭标签
.keyboardShortcut("t", modifiers: [.command, .shift]) // Cmd+Shift+T: 撤销关闭
.keyboardShortcut("1"..."8", modifiers: .command)     // Cmd+1~8: 切换标签
.keyboardShortcut("9", modifiers: .command)           // Cmd+9: 最后标签
// Cmd+Option+↓/↑ 用 onKeyPress 或 NSEvent.addLocalMonitorForEvents
```

### 4. UI 组件设计

#### PinnedTabRow（新增独立组件）
```swift
struct PinnedTabRow: View {
    @ObservedObject var tab: TabViewModel
    let isActive: Bool
    var onSelect: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            // Favicon + pin badge overlay
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? OWL.accentPrimary.opacity(0.3) : OWL.textTertiary)
                    .frame(width: 16, height: 16)
                Image(systemName: "pin.fill")
                    .font(.system(size: 7))
                    .foregroundColor(OWL.textTertiary)
            }
            Text(tab.displayTitle)
                .font(OWL.tabFont)
                .lineLimit(1)
                .foregroundColor(isActive ? OWL.accentPrimary : OWL.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: OWL.tabItemHeight)
        .background(
            RoundedRectangle(cornerRadius: OWL.radiusMedium)
                .fill(isActive ? OWL.accentPrimary.opacity(0.15) : .clear)
        )
        // 活跃指示条
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(OWL.accentPrimary)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
    }
}
```

#### TabContextMenu（ViewModifier）
```swift
struct TabContextMenu: ViewModifier {
    let tab: TabViewModel
    let onPin: () -> Void
    let onUnpin: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseBelow: () -> Void
    let onReload: () -> Void
    let onCopyURL: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            if tab.isPinned {
                Button("取消固定") { onUnpin() }
            } else {
                Button("固定标签") { onPin() }
            }
            Divider()
            if tab.isDeferred {
                Button("加载此标签") { onReload() }
            } else {
                Button("重新加载") { onReload() }
            }
            Divider()
            Button("关闭标签") { onClose() }
            if !tab.isPinned {
                Button("关闭其他标签") { onCloseOthers() }
                Button("关闭下方所有标签") { onCloseBelow() }
            }
            Divider()
            Button("复制链接地址") { onCopyURL() }
        }
    }
}
```

#### SidebarView 修改
```swift
// 固定标签区（ScrollView 之前）
if !pinnedTabs.isEmpty {
    ForEach(pinnedTabs) { tab in
        PinnedTabRow(tab: tab, isActive: tab.id == viewModel.activeTab?.id)
            .modifier(TabContextMenu(...))
    }
    Divider()
}
// 非固定标签区（现有 ScrollView 内）
ForEach(unpinnedTabs) { tab in
    ObservedTabRow(tab: tab, ...)
        .modifier(TabContextMenu(...))
}
```

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | closedTabsStack + pinTab/unpinTab/undoCloseTab + closeOthers/closeBelow |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | isPinned 已有（Phase 2），无需变更 |
| `owl-client-app/Views/Sidebar/PinnedTabRow.swift` | 新增 | 固定标签独立组件 |
| `owl-client-app/Views/Sidebar/TabContextMenu.swift` | 新增 | 右键菜单 ViewModifier |
| `owl-client-app/Views/Sidebar/SidebarView.swift` | 修改 | PinnedTabSection + Divider + contextMenu |
| `owl-client-app/Views/Content/ContentAreaView.swift` | 修改 | 键盘快捷键绑定 |

### 6. 测试策略

Phase 4 是纯 Swift UI 层，GTest 无法覆盖。测试通过 Swift 单元测试 + XCUITest：

| 测试 | 类型 | 验证点 |
|------|------|--------|
| PinTab_MovesToTop | Swift Unit | 固定后移到 tabs 数组前部 |
| UnpinTab_MovesToUnpinnedStart | Swift Unit | 取消固定后移到固定区之后 |
| CloseTab_PushesToStack | Swift Unit | 关闭记录入栈 |
| UndoClose_RestoresPosition | Swift Unit | 恢复到 originalIndex |
| UndoClose_RestoresPinned | Swift Unit | 恢复 isPinned 状态 |
| ClosedTabsStack_MaxSize | Swift Unit | 超过 20 条时自动淘汰最旧 |
| KeyboardShortcut_CmdT | XCUITest | 新建标签 |
| KeyboardShortcut_CmdW | XCUITest | 关闭标签 |
| ContextMenu_Pin | XCUITest | 右键固定标签 |

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| SwiftUI .contextMenu 在 macOS 上可能有 bug | 编译时验证，运行时 XCUITest |
| Cmd+1~9 与系统快捷键冲突 | macOS 允许 app 覆盖，SwiftUI .keyboardShortcut 优先 |
| pinTab/unpinTab 动画跨区域 | 使用 tabs 数组排序 + .animation(.easeInOut) |
| undoCloseTab 的 pendingPinAfterCreate | 在 createTab 回调中检查并设置 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
