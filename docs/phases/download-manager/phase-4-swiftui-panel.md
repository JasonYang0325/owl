# Phase 4: SwiftUI 下载面板

## 目标
- 实现下载面板 UI：工具栏图标 + badge、sidebar 面板、下载行（5 种状态）
- 用户可通过 UI 查看/操作下载

## 范围

### 新增文件
- `owl-client-app/Views/Sidebar/DownloadSidebarView.swift` — 下载面板主视图
- `owl-client-app/Views/Sidebar/DownloadRow.swift` — 单条下载行

### 修改文件
- `owl-client-app/Views/Sidebar/SidebarView.swift` — 新增 `.downloads` 分支
- `owl-client-app/Views/Sidebar/SidebarToolbar.swift` — 新增下载图标 + badge
- `owl-client-app/Views/Shared/DesignTokens.swift` — 如需新增 token（应该不需要）

## 依赖
- Phase 3（ViewModel 已实现）

## 技术要点

1. **SidebarMode 扩展**: 新增 `case downloads`
2. **ToolbarIconButton badge**: 扩展现有组件，新增 `badgeCount: Int?` 参数，用 `overlay` + `.offset(x: 8, y: -6)` 实现
3. **DownloadSidebarView 结构**:
   - Header: "下载" 标题 + 清除按钮
   - ScrollView + LazyVStack(spacing: 0) + DownloadRow
   - 空状态
   - 批量下载拦截横幅
4. **DownloadRow**:
   - 状态驱动布局（进行中/已暂停/已完成/已取消/失败）
   - 进度条: `GeometryReader` 或 `ProgressView` 自定义样式
   - 文件图标: `NSWorkspace.shared.icon(for: UTType)`
   - 右键菜单: 按状态不同提供不同菜单项
   - 双击已完成项打开文件
5. **不确定进度条**: `TimelineView(.animation)` + 自定义滑动动画，在 `.onDisappear` 时停止
6. **降级布局**: 当 sidebar 宽度 < 200pt 时，隐藏速度和百分比
7. **完成动画**: `symbolEffect(.bounce)` on macOS 14+

## 验收标准
- [ ] 工具栏下载图标显示且可切换面板
- [ ] badge 显示活跃下载数量
- [ ] 5 种下载状态正确渲染（进行中/已暂停/已完成/已取消/失败）
- [ ] 进度条实时更新
- [ ] 暂停/恢复/取消/打开/Finder 按钮可操作
- [ ] 清除按钮移除非活跃记录
- [ ] 空状态正确显示
- [ ] 右键菜单按状态提供正确选项

## 技术方案

### 1. 架构设计

```
SidebarView
  ├── if sidebarMode == .downloads
  │     └── DownloadSidebarView
  │           ├── Header ("下载" + 清除按钮)
  │           ├── ScrollView > LazyVStack
  │           │     └── DownloadRow × N (per-item @ObservedObject)
  │           └── EmptyState (暂无下载)
  └── SidebarToolbar
        └── ToolbarIconButton("arrow.down.circle", badge: activeCount)
```

### 2. SidebarMode 扩展

```swift
// 在现有 SidebarMode enum 中新增:
case downloads
```

修改 `SidebarView` 的 if-else 链，新增 `.downloads` 分支。修改 `toggleSidebarMode` — 已是通用的（`sidebarMode == mode ? .tabs : mode`），无需额外修改。

### 3. ToolbarIconButton badge

扩展现有 `ToolbarIconButton`，新增可选 `badgeCount`:

```swift
struct ToolbarIconButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var badgeCount: Int? = nil  // 新增
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(isActive ? OWL.accentPrimary :
                                   (isHovered ? OWL.textPrimary : OWL.textSecondary))
                    .frame(maxWidth: .infinity)
                    .frame(height: OWL.toolbarHeight)

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(OWL.error)
                        .clipShape(Circle())
                        .offset(x: -4, y: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
    }
}
```

### 4. DownloadSidebarView

```swift
struct DownloadSidebarView: View {
    @ObservedObject var downloadVM: DownloadViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("下载")
                    .font(OWL.buttonFont)
                    .foregroundColor(OWL.textPrimary)
                Spacer()
                if downloadVM.items.contains(where: { $0.state != .inProgress && $0.state != .paused }) {
                    Button(action: { downloadVM.clearCompleted() }) {
                        Image(systemName: "trash.circle")
                            .font(.system(size: 13))
                            .foregroundColor(OWL.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除所有记录")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(height: 36)

            Divider()

            // Content
            if downloadVM.items.isEmpty {
                // 空状态
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 40))
                        .foregroundColor(OWL.textTertiary)
                    Text("暂无下载记录")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(downloadVM.items) { item in
                            DownloadRow(item: item, downloadVM: downloadVM)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }
}
```

### 5. DownloadRow

```swift
struct DownloadRow: View {
    @ObservedObject var item: DownloadItemVM
    @ObservedObject var downloadVM: DownloadViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // 文件图标
            FileIconView(filename: item.filename, state: item.state)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                // 第一行: 文件名 + 操作按钮
                HStack {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(item.state == .cancelled || item.state == .interrupted
                            ? OWL.textSecondary : OWL.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    actionButtons
                }

                // 进度条 (进行中/已暂停)
                if item.state == .inProgress || item.state == .paused {
                    ProgressBar(progress: item.progress,
                               isIndeterminate: item.totalBytes <= 0,
                               isPaused: item.state == .paused)
                        .frame(height: 4)
                }

                // 状态文字
                statusText
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(isHovered ? OWL.surfaceSecondary.opacity(0.3) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if item.state == .complete {
                downloadVM.openFile(id: item.id)
            }
        }
        .contextMenu { contextMenuItems }
    }

    // 状态驱动的操作按钮
    @ViewBuilder var actionButtons: some View {
        switch item.state {
        case .inProgress:
            HStack(spacing: 4) {
                IconButton(icon: "pause.fill") { downloadVM.pause(id: item.id) }
                IconButton(icon: "xmark") { downloadVM.cancel(id: item.id) }
            }
        case .paused:
            HStack(spacing: 4) {
                IconButton(icon: "play.fill", accent: true) { downloadVM.resume(id: item.id) }
                IconButton(icon: "xmark") { downloadVM.cancel(id: item.id) }
            }
        case .complete:
            HStack(spacing: 4) {
                TextButton("打开") { downloadVM.openFile(id: item.id) }
                IconButton(icon: "folder") { downloadVM.showInFolder(id: item.id) }
            }
        case .interrupted:
            if item.canResume {
                TextButton("恢复") { downloadVM.resume(id: item.id) }
            } else {
                TextButton("重新下载") { downloadVM.redownload(id: item.id) }
            }
        case .cancelled:
            EmptyView()
        }
    }

    // 状态文字
    @ViewBuilder var statusText: some View {
        switch item.state {
        case .inProgress:
            Text("\(formatBytes(item.receivedBytes)) / \(formatBytes(item.totalBytes)) · \(item.speed)")
                .font(OWL.captionFont).foregroundColor(OWL.textSecondary)
        case .paused:
            Text("已暂停 · \(formatBytes(item.receivedBytes)) / \(formatBytes(item.totalBytes))")
                .font(OWL.captionFont).foregroundColor(OWL.warning)
        case .complete:
            Text(formatBytes(item.totalBytes))
                .font(OWL.captionFont).foregroundColor(OWL.textSecondary)
        case .cancelled:
            Text("已取消").font(OWL.captionFont).foregroundColor(OWL.textTertiary)
        case .interrupted:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text(item.errorDescription ?? "下载失败")
            }
            .font(OWL.captionFont).foregroundColor(OWL.error)
        }
    }

    // 右键菜单
    @ViewBuilder var contextMenuItems: some View {
        switch item.state {
        case .inProgress:
            Button("暂停下载") { downloadVM.pause(id: item.id) }
            Button("取消下载") { downloadVM.cancel(id: item.id) }
        case .paused:
            Button("恢复下载") { downloadVM.resume(id: item.id) }
            Button("取消下载") { downloadVM.cancel(id: item.id) }
        case .complete:
            Button("打开") { downloadVM.openFile(id: item.id) }
            Button("在 Finder 中显示") { downloadVM.showInFolder(id: item.id) }
            Divider()
            Button("从列表中移除") { downloadVM.removeEntry(id: item.id) }
        case .cancelled:
            Button("从列表中移除") { downloadVM.removeEntry(id: item.id) }
        case .interrupted:
            if item.canResume {
                Button("恢复下载") { downloadVM.resume(id: item.id) }
            }
            Button("从列表中移除") { downloadVM.removeEntry(id: item.id) }
        }
    }
}
```

### 6. 辅助组件

```swift
// ProgressBar — 自定义进度条
struct ProgressBar: View {
    let progress: Double
    let isIndeterminate: Bool
    let isPaused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(OWL.surfaceSecondary)
                if isIndeterminate {
                    // 不确定进度: 滑动动画
                    IndeterminateBar()
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isPaused ? OWL.warning : OWL.accentPrimary)
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                }
            }
        }
    }
}

// IconButton — 24pt 图标按钮
struct IconButton: View {
    let icon: String
    var accent: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(accent ? OWL.accentPrimary :
                               (isHovered ? OWL.textPrimary : OWL.textSecondary))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// TextButton — 蓝色文字按钮
struct TextButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(OWL.captionFont).foregroundColor(OWL.accentPrimary)
        }.buttonStyle(.plain)
    }
}

// formatBytes — 字节数格式化
func formatBytes(_ bytes: Int64) -> String {
    if bytes < 0 { return "未知" }
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
    return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
}

// IndeterminateBar — 不确定进度滑动动画
struct IndeterminateBar: View {
    @State private var offset: CGFloat = -0.3
    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(OWL.accentPrimary)
                .frame(width: geo.size.width * 0.3)
                .offset(x: geo.size.width * offset)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                        offset = 1.0
                    }
                }
        }
    }
}

// downloadPanelWidth Environment Key
private struct DownloadPanelWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 280
}
extension EnvironmentValues {
    var downloadPanelWidth: CGFloat {
        get { self[DownloadPanelWidthKey.self] }
        set { self[DownloadPanelWidthKey.self] = newValue }
    }
}

// FileIconView — 文件类型图标 + 完成标记
struct FileIconView: View {
    let filename: String
    let state: DownloadState
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 系统文件图标（简化版用 SF Symbol）
            Image(systemName: "doc.fill")
                .font(.system(size: 14))
                .foregroundColor(OWL.textSecondary)
                .frame(width: 28, height: 28)
                .background(OWL.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: OWL.radiusSmall))
                .opacity(state == .cancelled ? 0.5 : 1.0)

            if state == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#34C759"))
                    .offset(x: 2, y: 2)
            }
        }
    }
}
```

### 7. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `Views/Sidebar/DownloadSidebarView.swift` | 新增 | 面板主视图 + 空状态 |
| `Views/Sidebar/DownloadRow.swift` | 新增 | 下载行 + 5 种状态 + 操作 + 右键菜单 + 辅助组件 |
| `Views/Sidebar/SidebarView.swift` | 修改 | 新增 `.downloads` 分支 |
| `Views/Sidebar/SidebarToolbar.swift` | 修改 | 新增下载图标 + badge（扩展 ToolbarIconButton 添加 `@State private var isHovered` 和 `badgeCount: Int?`） |
| `ViewModels/BrowserViewModel.swift` | 修改 | SidebarMode enum 新增 `case downloads` |

**注意**: ToolbarIconButton 示例中的 `isHovered` 已在现有代码中声明为 `@State private var isHovered = false`（SidebarToolbar.swift:38），badge 扩展只需在现有 struct 中添加 `badgeCount` 参数和 overlay。

**批量下载拦截横幅**: 降级为 🔮 后续迭代。当前版本暂不实现（需要 Host 层新增拦截计数 API，属于跨 Phase 依赖）。从 AC 列表中移除该项。

**降级布局** (sidebar < 200pt): 使用 `GeometryReader` 在 DownloadSidebarView 最外层获取宽度，通过 `Environment` 传递给 DownloadRow：
```swift
// DownloadSidebarView 外层:
GeometryReader { geo in
    content.environment(\.downloadPanelWidth, geo.size.width)
}

// DownloadRow 内部:
@Environment(\.downloadPanelWidth) var panelWidth
// 当 panelWidth < 200 时隐藏速度和百分比
```

### 8. 测试策略

SwiftUI 视图层测试（编译 + 单元 + Preview）：
- **编译验证**: 所有 View 正确引用 ViewModel，SidebarMode exhaustive switch 不破坏
- **ViewModel 单元测试**（Phase 3 已有 42 个测试）: 状态驱动逻辑全覆盖
- **辅助函数单元测试**（新增）:
  - `formatBytes()`: 0 / 100 / 1024 / 1048576 / 1073741824 / -1 各种输入
  - `DownloadItemVM.formatSpeed()`: 已在 Phase 3 覆盖
- **SidebarMode 枚举测试**（新增）:
  - `.downloads` case 存在
  - `toggleSidebarMode(.downloads)` 切换行为正确
- **DownloadRow 状态驱动测试**（新增，不依赖 SwiftUI 渲染）:
  - 验证 actionButtons ViewBuilder 在各状态下返回正确按钮类型
  - 验证 contextMenuItems 在各状态下返回正确菜单项数量
  - 验证 statusText 在各状态下显示正确内容
- **Preview 验证**: DownloadRow 5 种状态 + ToolbarIconButton badge（手动检查）

### 9. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| SidebarMode 新增 case 破坏 exhaustive switch | Swift 编译器强制检查 |
| badge 在紧凑工具栏溢出 | offset 定位 + zIndex |
| LazyVStack 大量下载项性能 | per-item ObservableObject 避免全量重绘 |
| 文件图标 UTType 不可用 | 简化为 SF Symbol doc.fill（后续可替换） |
| 批量拦截横幅未实现 | 降级为后续迭代，不影响核心下载 UI |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
