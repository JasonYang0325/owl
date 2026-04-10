# Console 与 JS 错误捕获 — UI 设计稿

## 1. 设计概述

### 设计目标
在现有右侧面板系统中添加 Console Tab，展示网页 console 输出，提供级别过滤、文本搜索、复制和清除功能。

### 设计原则
- **复用优先**: 融入现有 RightPanel 架构（RightPanel enum + RightPanelContainer）
- **开发者友好**: 沿用 Chrome DevTools Console 的视觉语言和交互惯例
- **信息密度**: 紧凑布局，单条消息最小高度，最大化可见消息数

## 2. 信息架构

```
RightPanelContainer (已有, 360pt)
├── AIChatView (已有)
├── AgentPanelView (已有)
├── MemoryPanelView (已有)
└── 🆕 ConsolePanelView
    ├── ConsoleToolbar (过滤+搜索+清除+保留日志)
    ├── ConsoleMessageList (LazyVStack, 消息列表)
    │   ├── NavigationSeparator (保留日志模式下的分割线)
    │   └── ConsoleRow × N
    └── NewMessagesBanner (底部浮动按钮)
```

RightPanel enum 新增 `.console` case。

## 3. 组件设计

### 3.1 ConsolePanelView（主面板）

#### 布局
```
┌──────────────────────────────────┐ 360pt
│  Console              [清除] [×] │ ← Header (36pt)
├──────────────────────────────────┤
│ [All▼] [🔴3] [🟡5] [ℹ12] [🔍___]│ ← Toolbar (32pt)
│ [☐ 保留日志]                      │
├──────────────────────────────────┤
│ ℹ 10:23:45.123 page loaded      │ ← ConsoleRow
│                    app.js:12     │
│ ⚠ 10:23:45.456 deprecated API   │
│                    lib.js:89     │
│ 🔴 10:23:46.789 TypeError: ...  │
│                    main.js:42    │
│ ...                              │
│                                  │
│         [↓ 3 条新消息]            │ ← NewMessagesBanner
└──────────────────────────────────┘
```

#### 视觉规范
- 背景: `OWL.surfacePrimary`
- Header: "Console" 标题 (`OWL.buttonFont`, `OWL.textPrimary`) + 清除按钮 + 关闭按钮
- 宽度: `OWL.rightPanelWidth` (360pt)，与其他面板一致
- 过渡动画: `.move(edge: .trailing)`，与现有面板一致

### 3.2 ConsoleToolbar（工具栏）

#### 布局
```
┌────────────────────────────────────┐
│ [All▼] [🔴 3] [🟡 5] [ℹ 12] [V 0] │ ← 级别过滤按钮
│ [🔍 搜索消息...______] [☐保留日志]  │ ← 搜索框 + 保留日志
└────────────────────────────────────┘
```

#### 视觉规范
- 高度: 两行，各 28pt（总 56pt + 间距）
- 过滤按钮: Pill 形状，选中时背景对应颜色 opacity(0.15)
  - All: `OWL.textPrimary` 背景
  - Error(🔴): `OWL.error` 背景
  - Warning(🟡): `OWL.warning` 背景
  - Info(ℹ): `OWL.accentPrimary` 背景
  - Verbose(V): `OWL.textTertiary` 背景
- 计数 badge: 每个按钮右上角小数字
- 搜索框: `OWL.surfaceSecondary` 背景, `OWL.radiusSmall` 圆角, 带 magnifyingglass 图标
- "保留日志" checkbox: `OWL.captionFont`, 默认 off

### 3.3 ConsoleRow（消息行）

#### 布局
```
┌──────────────────────────────────┐
│ ⚠ 10:23:45.456 deprecated API   │
│                   lib.js:89      │
└──────────────────────────────────┘
```

#### 视觉规范
- 最小高度: 自适应（单行消息 ~24pt，多行扩展）
- 左侧: 级别图标 (12pt SF Symbol) + 8pt 间距
  - verbose: `text.alignleft`, `OWL.textTertiary`
  - info: `info.circle`, `OWL.textSecondary`
  - warning: `exclamationmark.triangle.fill`, `OWL.warning`
  - error: `xmark.circle.fill`, `OWL.error`
- 时间戳: `OWL.codeFont` (13pt mono), `OWL.textTertiary`, 格式 HH:mm:ss.SSS
- 消息文本: `OWL.codeFont`, 颜色按级别（verbose=textTertiary, info=textPrimary, warning=warning, error=error）
- Source:line: 右对齐/第二行, `OWL.captionFont`, `OWL.textTertiary`
- 分隔线: 底部 0.5pt `OWL.border`
- 截断标记: 红色 `... (已截断至 10KB)`, `OWL.error`, `OWL.captionFont`
- hover: 背景 `OWL.surfaceSecondary.opacity(0.5)`
- 选中: 背景 `OWL.accentPrimary.opacity(0.1)`

#### 交互
- 单击选中（高亮）
- Cmd+C 复制选中行（格式: `[level] HH:mm:ss.SSS message\nsource:line`）
- 右键菜单: "复制消息" / "复制全部"

### 3.4 NavigationSeparator（导航分割线）

仅在"保留日志"开关开启时显示。

```
┌──────────────────────────────────┐
│ ── Navigated to example.com ──── │
└──────────────────────────────────┘
```

- 高度: 20pt
- 文字: `OWL.captionFont`, `OWL.textTertiary`, 居中
- 分割线: `OWL.border`, 两侧延伸

### 3.5 NewMessagesBanner（新消息按钮）

用户手动滚动到上方时显示。

```
         [↓ 3 条新消息]
```

- 位置: 列表底部浮动，居中
- 样式: Pill 形状, `OWL.accentPrimary` 背景, 白色文字, `OWL.radiusPill`
- 点击: 滚动到底部
- 自动消失: 用户滚动到底部时

## 4. 状态流转

### 数据模型

```swift
// ConsoleItem: 联合类型，消息行 vs 导航分割线
enum ConsoleItem: Identifiable {
    case message(ConsoleMessageItem)
    case separator(url: String, id: UUID = UUID())

    var id: String { ... }  // 唯一标识，LazyVStack 需要
}

struct ConsoleMessageItem: Identifiable {
    let id = UUID()
    let level: ConsoleLevel
    let message: String
    let source: String
    let line: Int
    let timestamp: Date
    let isTruncated: Bool
}
```

### ConsoleViewModel 状态
```swift
@MainActor class ConsoleViewModel: ObservableObject {
    // 数据层: 环形缓冲区 (容量 1000，PRD 定义)
    private var buffer: [ConsoleItem] = []
    private let capacity = 1000
    private var needsRefresh = false
    private var refreshTask: Task<Void, Never>? = nil

    // UI 层: @Published 驱动视图
    @Published var displayItems: [ConsoleItem] = []       // 节流后的快照
    @Published var filteredItems: [ConsoleItem] = []       // 🆕 @Published 而非 computed
    @Published var filter: ConsoleLevel? = nil
    @Published var searchText: String = ""
    @Published var preserveLog: Bool = false
    @Published var counts: [ConsoleLevel: Int] = [:]       // 合并计数，减少重绘
    @Published var isAtBottom: Bool = true                 // 自动滚动状态

    func addMessage(...)  // 写入 buffer + 标记 needsRefresh
    func clear()          // 清空 buffer + 重置 counts
    func onNavigation(url:)  // preserveLog=off→清空, =on→插入 .separator

    // 初始化时启动刷新 Task
    init() { startRefreshLoop() }
    deinit { refreshTask?.cancel() }
}
```

### UI 刷新节流（Task 而非 Timer，自动随 ViewModel 释放）
```
Bridge callback (任意频率)
  → ConsoleViewModel.addMessage() — 立即写入 buffer + needsRefresh=true

refreshTask = Task { @MainActor in
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        if needsRefresh {
            displayItems = buffer  // O(1) 数组赋值（CoW）
            // filteredItems 异步计算避免阻塞
            filteredItems = displayItems.filter { item in
                matchesFilter(item) && matchesSearch(item)
            }
            needsRefresh = false
        }
    }
}
```
生命周期: `refreshTask` 在 `deinit` 中 cancel，无 Timer 泄漏风险。

### 自动滚动检测
```swift
// ConsolePanelView 中使用 ScrollViewReader:
ScrollViewReader { proxy in
    ScrollView {
        LazyVStack { ... }
            .onChange(of: viewModel.filteredItems.count) { _, _ in
                if viewModel.isAtBottom {
                    // 延迟一帧确保 LazyVStack 更新完成
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo("bottom") }
                    }
                }
            }
    }
    // 检测滚动位置: onScrollGeometryChange (macOS 14+) 或
    // GeometryReader 在列表底部放一个 anchor view 检测可见性
}
```

## 5. 设计决策记录

| 决策 | 选择 | 替代方案 | 理由 |
|------|------|---------|------|
| 面板位置 | 右侧面板 Tab | 底部 Panel | 复用现有 RightPanel 架构，无需新布局 |
| 消息字体 | monospace (OWL.codeFont) | 等比例字体 | Console 内容是代码，mono 更易读 |
| 过滤 UI | Pill 按钮 + 搜索框 | 下拉菜单 | Pill 一目了然，搜索框常驻 |
| 自动滚动 | 底部跟随 + 手动中断 | 始终跟随 | 开发者需要回看历史 |
| 节流策略 | 200ms Timer batch | Combine debounce | Timer 更可控，与伪进度 Task 模式一致 |

## 6. 无障碍考量

- **VoiceOver**: 每条消息 `accessibilityLabel("级别 时间 消息内容")`
- **键盘**: Tab 切换过滤按钮，Cmd+C 复制
- **颜色对比**: error 红色/warning 橙色在深浅背景上对比度 > 4.5:1
