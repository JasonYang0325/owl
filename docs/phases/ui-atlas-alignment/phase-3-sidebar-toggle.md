# Phase 3: Sidebar Toggle + 宽度调整

## 目标
添加 Sidebar 切换按钮，用户可手动收起/展开侧栏。调整拖拽范围匹配新宽度。

## 范围
- 修改：
  - `owl-client-app/Views/TopBar/TopBarView.swift` — 新增 toggle 按钮
  - `owl-client-app/Views/BrowserWindow.swift` — `isSidebarManuallyVisible` 状态 + sidebar 可见性逻辑 + 拖拽范围 + 快捷键
  - `owl-client-app/Views/Shared/DesignTokens.swift` — （如 Phase 2 未更新拖拽范围相关）

## 依赖
- Phase 2（Sidebar 重构完成后再添加 toggle）

## 技术要点

### 3.1 状态管理
- `BrowserWindow` 新增 `@AppStorage("owl.sidebar.manuallyVisible") var isSidebarManuallyVisible: Bool = true`
- Sidebar 实际显示 = `layoutMode.sidebarVisible && isSidebarManuallyVisible`
- `minimal` 模式强制隐藏，`isSidebarManuallyVisible` 值保持不变

### 3.2 TopBarView 修改
- Toggle 按钮在**顶层 HStack**（72pt spacer 之后，`ActiveTabTopBar`/`NavigationButtons` 分支之前）
- 图标：`sidebar.left`（SF Symbols），14pt
- 按钮尺寸：28x28pt，圆角 6pt
- 颜色：默认 `textSecondary`，hover `textPrimary` + `surfaceSecondary` 背景
- `accessibilityIdentifier`: `"sidebarToggleButton"`
- `accessibilityValue`: sidebar 展开 "expanded" / 收起 "collapsed"
- Action 通过 `onToggleSidebar: (() -> Void)?` 回调传入
- `minimal` 模式下隐藏（需接收 `layoutMode` 参数）

### 3.3 BrowserWindow 修改
- `if layoutMode.sidebarVisible` → `if layoutMode.sidebarVisible && isSidebarManuallyVisible`
- 提供 `onToggleSidebar` 闭包给 TopBarView
- `SidebarDivider.dragGesture`: `max(120, min(240, ...))` → `max(160, min(280, ...))`
- 新增 Cmd+Shift+L hidden button 快捷键

### 3.4 动画
- Sidebar 展开/收起：`withAnimation(.easeInOut(duration: 0.2))`

## 验收标准
- [ ] TopBar 左侧有 sidebar toggle 按钮（sidebar.left 图标）
- [ ] 点击 toggle 后 sidebar 消失，再次点击恢复
- [ ] Sidebar 隐藏后 toggle 按钮仍可见
- [ ] Cmd+Shift+L 可切换 sidebar
- [ ] Sidebar 隐藏时 Cmd+T/W 等快捷键仍正常
- [ ] `isSidebarManuallyVisible` 跨 session 持久化
- [ ] minimal 模式下 toggle 按钮隐藏
- [ ] compact 模式下 toggle 可用（隐藏/恢复 36pt sidebar）
- [ ] 拖拽范围为 160-280pt
- [ ] 展开/收起有平滑动画

## 技术方案

### 1. 架构设计

2 个文件修改，无新增文件。涉及状态管理（`@AppStorage`）和视图层修改。

```
BrowserWindow.swift  — isSidebarManuallyVisible 状态 + sidebar 可见性 + 拖拽范围 + 快捷键 + onToggleSidebar 回调
TopBarView.swift     — 新增 sidebar toggle 按钮 + onToggleSidebar 参数 + layoutMode 参数
```

### 2. 核心逻辑

#### 2.1 BrowserWindow.swift

**新增状态**：
```swift
@AppStorage("owl.sidebar.manuallyVisible") private var isSidebarManuallyVisible: Bool = true

// 计算实际 sidebar 可见性（供 TopBarView AX value 使用）
private var isSidebarActuallyVisible: Bool {
    layoutMode.sidebarVisible && isSidebarManuallyVisible
}
```

**修改 sidebar 可见性条件 + 添加 transition**（第 35 行）：
```swift
// 原: if layoutMode.sidebarVisible {
// 改:
if isSidebarActuallyVisible {
    SidebarView(...)
    SidebarDivider(...)
}
```
**注意**：需在包含 sidebar 的 Group/VStack 上添加显式 transition，否则 sidebar 收起时仅淡出不折叠：
```swift
// 在 SidebarView 外层包裹，或用 Group
Group {
    SidebarView(...)
    SidebarDivider(...)
}
.transition(.move(edge: .leading))
```

**修改 TopBarView 调用**（第 30-33 行）：
```swift
TopBarView(
    layoutMode: layoutMode,
    onTogglePanel: { panel in viewModel.togglePanel(panel) },
    onToggleSidebar: {                    // ← 新增
        withAnimation(.easeInOut(duration: 0.25)) {  // 与 layout 动画时长对齐
            isSidebarManuallyVisible.toggle()
        }
    },
    isSidebarVisible: isSidebarActuallyVisible  // ← 实际显示状态，非用户意图
)
```

**修复 SidebarDivider 拖拽**（累积 translation bug）：
```swift
// 原（有 bug）: width = max(120, min(240, width + value.translation.width))
// 修复：使用 @GestureState 记录起始宽度
@GestureState private var dragStartWidth: CGFloat? = nil

private var dragGesture: some Gesture {
    DragGesture()
        .updating($dragStartWidth) { _, state, _ in
            if state == nil { state = width }
        }
        .onChanged { value in
            let start = dragStartWidth ?? width
            width = max(160, min(280, start + value.translation.width))
        }
}
```

**新增快捷键**（hidden button 区域）：
```swift
// Cmd+Shift+L: toggle sidebar
Button("") {
    withAnimation(.easeInOut(duration: 0.25)) {
        isSidebarManuallyVisible.toggle()
    }
}
.keyboardShortcut("l", modifiers: [.command, .shift])
.hidden()
```

#### 2.2 TopBarView.swift

**新增参数**：
```swift
struct TopBarView: View {
    @EnvironmentObject var viewModel: BrowserViewModel
    let layoutMode: LayoutMode
    var onTogglePanel: ((RightPanel) -> Void)? = nil
    var onToggleSidebar: (() -> Void)? = nil      // ← 新增
    var isSidebarVisible: Bool = true              // ← 实际显示状态（由 BrowserWindow 计算传入）
```

**在 body HStack 中内联 toggle 按钮**（72pt spacer 之后，if/else 分支之前，不抽 struct）：
```swift
var body: some View {
    HStack(spacing: 0) {
        Spacer().frame(width: 72)

        // Sidebar toggle — 内联，minimal 模式隐藏
        if layoutMode != .minimal {
            Button(action: { onToggleSidebar?() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundColor(OWL.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebarToggleButton")
            .accessibilityValue(isSidebarVisible ? "expanded" : "collapsed")
            .padding(.trailing, 4)
        }

        if let tab = viewModel.activeTab {
            ActiveTabTopBar(...)
        } else {
            NavigationButtons()
            ...
        }

        if layoutMode == .minimal {
            CompactTabSwitcher()  // 现有，不与 toggle 冲突（minimal 下 toggle 隐藏）
        }
    }
}
```

**设计简化说明**：
- Toggle 按钮内联到 TopBarView.body，不抽独立 struct（仅 ~10 行，无复用需求）
- hover 效果可选加（与 NavButton 一致的 `.onHover` pattern），非必需
- `isSidebarVisible` 由 BrowserWindow 传入 `isSidebarActuallyVisible`（`layoutMode.sidebarVisible && isSidebarManuallyVisible`），确保 AX value 反映实际状态

### 3. 文件变更清单

| 文件 | 操作 | 改动量 |
|------|------|--------|
| `BrowserWindow.swift` | 修改 | ~20 行（状态 + 可见性条件 + 拖拽范围 + 快捷键 + 回调传递） |
| `TopBarView.swift` | 修改 | ~40 行（新参数 + SidebarToggleButton 组件） |

### 4. 测试策略

- **编译验证**：`run_tests.sh cpp` 确认无编译错误
- **手动验证**：
  - 点击 toggle 按钮 sidebar 消失/恢复
  - Cmd+Shift+L 快捷键
  - 窗口缩到 minimal 后 toggle 隐藏
  - 拖拽 sidebar 宽度在 160-280 范围内
  - 退出重启后 sidebar 状态保持
- **XCUITest**：`sidebarToggleButton` accessibility identifier 可用于自动化测试

### 5. 风险 & 缓解

| 风险 | 概率 | 缓解 |
|------|------|------|
| @AppStorage key 冲突 | 极低 | 使用 namespaced key `owl.sidebar.manuallyVisible` |
| Toggle 动画与 layout resize 冲突 | 低 | withAnimation 包裹，SwiftUI 自动处理布局变化 |
| minimal→compact 模式切换时状态恢复 | 低 | isSidebarManuallyVisible 值不随 layoutMode 变化 |
| Cmd+Shift+L 与系统快捷键冲突 | 低 | macOS 无默认 Cmd+Shift+L 绑定 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
