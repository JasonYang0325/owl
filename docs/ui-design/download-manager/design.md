# 下载管理系统 — UI 设计稿

## 1. 设计概述

### 设计目标
- 在不打断用户浏览流的前提下，提供清晰的下载状态感知
- 与现有 sidebar 面板（书签、历史）保持视觉一致
- 5 种下载状态（进行中/已暂停/已完成/已取消/失败）各有明确的视觉区分

### 设计原则
- **克制反馈**: 新下载不自动弹出面板，仅通过工具栏图标提示
- **复用现有组件**: 沿用 sidebar 面板结构、DesignTokens、ToolbarIconButton 模式
- **状态即颜色**: 通过颜色和图标直观区分下载状态，无需阅读文字

## 2. 信息架构

```
SidebarToolbar
  └── 下载图标 (arrow.down.circle) + badge
        └── SidebarMode.downloads
              └── DownloadSidebarView
                    ├── Header (清除所有记录 按钮)
                    └── 下载列表 (LazyVStack)
                          ├── DownloadRow (进行中)
                          ├── DownloadRow (已暂停)
                          ├── DownloadRow (已完成)
                          ├── DownloadRow (已取消)
                          └── DownloadRow (失败)
```

**导航路径**: 工具栏下载图标 → 切换 sidebar 到下载面板 → 查看/操作下载项

## 3. 页面/组件设计

### 3.1 工具栏下载图标

#### 布局
在 SidebarToolbar 中新增下载图标按钮，位于历史图标之后：

```
┌─────────────────────────────────────────┐
│  📑 书签  │  🕐 历史  │  ⬇️ 下载  │  💬 AI  │
└─────────────────────────────────────────┘
```

#### 视觉规范
- **SF Symbol**: `arrow.down.circle`（默认）/ `arrow.down.circle.fill`（有活跃下载时）
- **图标大小**: 15pt（与现有工具栏图标一致）
- **颜色**: 
  - 默认: `OWL.textSecondary`
  - 悬停: `OWL.textPrimary`  
  - 选中（面板展开）: `OWL.accentPrimary`
- **Badge**: 右上角红色小圆点 + 数字（活跃下载数量，IN_PROGRESS 且未暂停）
  - 圆点直径: 14pt
  - 字体: 9pt bold, 白色
  - 背景: `OWL.error`（#FF3B30）
  - 定位: `.offset(x: 8, y: -6)` 相对于图标中心
  - 仅当 activeCount > 0 时显示
  - 实现: 扩展 `ToolbarIconButton`，新增 `badgeCount: Int?` 可选参数，用 `ZStack + overlay` 实现。`.zIndex(1)` 确保不被相邻按钮裁切
- **完成动画**: 最后一个下载完成时，使用 `symbolEffect(.bounce)` (macOS 14+)，fallback 为 `.scaleEffect` 弹跳（1.0 → 1.15 → 1.0，持续 0.3s）

#### 交互设计
- 点击: 切换 SidebarMode 到 `.downloads`（再次点击切回 `.tabs`）
- 与书签/历史互斥（同一时间只有一个面板展开）

### 3.2 DownloadSidebarView（下载面板）

#### 布局
```
┌──────────────────────────────────┐ ← sidebar 宽度 (140pt+)
│ Header                     [清除] │ ← 36pt
├──────────────────────────────────┤
│ ┌──────────────────────────────┐ │
│ │ 📄 big-file.zip             │ │ ← DownloadRow 进行中
│ │ ████████░░░ 45% · 2.3 MB/s  │ │
│ │              [⏸] [✕]        │ │
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ 📄 document.pdf             │ │ ← DownloadRow 已完成
│ │ 1.2 MB        [打开] [📂]   │ │
│ └──────────────────────────────┘ │
│         ...                      │
│                                  │
│ ┌──────────────────────────────┐ │
│ │     ⬇️ 暂无下载记录          │ │ ← 空状态
│ └──────────────────────────────┘ │
└──────────────────────────────────┘
```

#### 视觉规范
- **背景**: `.ultraThinMaterial`（与 sidebar 一致）
- **Header**:
  - 高度: 36pt
  - 左侧: "下载" 标题，`OWL.buttonFont` (13pt medium)，`OWL.textPrimary`（与书签面板标题风格一致）
  - 右侧: `trash.circle` 图标按钮（13pt，`OWL.textSecondary`，hover 时 `OWL.textPrimary`）
  - 清除按钮仅当有可清除记录时显示（已完成/已取消/已失败）
  - Padding: horizontal 12pt, vertical 4pt
- **列表**: `ScrollView` + `LazyVStack(spacing: 0)`
- **排序**: 按创建时间倒序（最新在上）
- **Divider**: 行间 0.5pt `OWL.border` 分割线
- **Compact 模式** (36pt sidebar): 面板内容隐藏，仅显示工具栏图标 + badge
- **最小宽度约束**: DownloadSidebarView 要求 sidebar 宽度 ≥ 200pt。当 sidebar 处于 140pt 默认宽度时，展示降级布局：速度文字隐藏，仅显示 "23/52 MB"；进度百分比隐藏；操作按钮缩小为 20pt

#### 空状态
- 图标: `arrow.down.circle`，40pt，`OWL.textTertiary`
- 文字: "暂无下载记录"，`OWL.captionFont`，`OWL.textTertiary`
- 垂直居中

### 3.3 DownloadRow（下载行）

#### 布局 — 进行中

```
┌────────────────────────────────────────────┐
│ 📄  big-file.zip                    [⏸][✕] │  ← 行高 64pt
│     ████████░░░░░░░░░  45%                 │
│     23.5 MB / 52.1 MB  ·  2.3 MB/s        │
└────────────────────────────────────────────┘
```

#### 布局 — 已暂停

```
┌────────────────────────────────────────────┐
│ 📄  big-file.zip                    [▶][✕] │  ← 行高 64pt
│     ████████░░░░░░░░░  45%                 │
│     已暂停  ·  23.5 MB / 52.1 MB           │
└────────────────────────────────────────────┘
```

#### 布局 — 已完成

```
┌────────────────────────────────────────────┐
│ 📄  document.pdf                           │  ← 行高 52pt
│     1.2 MB              [打开] [📂]        │
└────────────────────────────────────────────┘
```

#### 布局 — 已取消

```
┌────────────────────────────────────────────┐
│ 📄  cancelled-file.zip                     │  ← 行高 44pt
│     已取消                                 │
└────────────────────────────────────────────┘
```

#### 布局 — 失败

```
┌────────────────────────────────────────────┐
│ 📄  failed-file.zip               [重新下载]│  ← 行高 52pt
│     ⚠️ 网络连接中断                         │
└────────────────────────────────────────────┘
```

#### 视觉规范

**文件图标** (左侧):
- 使用 `NSWorkspace.shared.icon(for: UTType)` 获取系统图标（macOS 12+，需 `import UniformTypeIdentifiers`）
- 大小: 28x28pt
- 圆角: `OWL.radiusSmall` (6pt)
- Fallback: `doc.fill` SF Symbol + `OWL.surfaceSecondary` 背景

**文件名** (第一行):
- 字体: `OWL.tabFont` (13pt regular)
- 颜色: `OWL.textPrimary`
- 已取消/已失败: `OWL.textSecondary`（灰色减弱）
- 截断: `.tail`，单行
- 超长文件名: 中间省略号保留扩展名（如 `very_long_...v2.pdf`）

**进度条**:
- 高度: 4pt
- 圆角: 2pt
- 背景: `OWL.surfaceSecondary`
- 填充: `OWL.accentPrimary`（进行中）/ `OWL.warning`（已暂停，静止）
- 不确定进度（Content-Length 未知）: 从左到右循环滑动动画

**状态文字** (第二行):
- 字体: `OWL.captionFont` (12pt)
- 颜色: `OWL.textSecondary`
- 进行中: "23.5 MB / 52.1 MB · 2.3 MB/s"
- 已暂停: "已暂停 · 23.5 MB / 52.1 MB"（`OWL.warning` 色）
- 已完成: "1.2 MB"
- 已取消: "已取消"（`OWL.textTertiary`）
- 失败: 错误信息（`OWL.error` 色），带 ⚠️ 前缀图标

**操作按钮**:
- 大小: 24x24pt
- 圆角: 4pt
- 字体: 11pt SF Symbol
- 默认色: `OWL.textSecondary`
- Hover 色: `OWL.textPrimary`

| 状态 | 左按钮 | 右按钮 |
|------|--------|--------|
| 进行中 | ⏸ `pause.fill` (暂停) | ✕ `xmark` (取消) |
| 已暂停 | ▶ `play.fill` (恢复) | ✕ `xmark` (取消) |
| 已完成 | "打开" 文字按钮 | 📂 `folder` (在 Finder 中显示) |
| 已取消 | — | — |
| 失败 (CanResume) | "恢复" 文字按钮 | — |
| 失败 (!CanResume) | "重新下载" 文字按钮 | — |

**文字按钮样式**:
- 字体: `OWL.captionFont` (12pt)
- 颜色: `OWL.accentPrimary`
- Hover: 带下划线
- 无背景

**行交互**:
- Hover: 背景 `OWL.surfaceSecondary.opacity(0.3)`
- 双击已完成项: 打开文件（等同于点击"打开"按钮）
- 右键菜单:
  - 进行中: "暂停下载" / "取消下载"
  - 已暂停: "恢复下载" / "取消下载"
  - 已完成: "打开" / "在 Finder 中显示" / "从列表中移除"
  - 已取消: "重新下载" / "从列表中移除"
  - 失败 (CanResume): "恢复下载" / "从列表中移除"
  - 失败 (!CanResume): "重新下载" / "从列表中移除"

**行高**:
- 进行中/已暂停: 64pt（3 行：文件名 + 进度条 + 状态文字）
- 已完成/失败: 52pt（2 行：文件名 + 状态/操作）
- 已取消: 44pt（2 行：文件名 + 状态）

**Padding**:
- Leading: 12pt
- Trailing: 8pt
- Vertical: 8pt

#### 组件树

```
DownloadRow (状态驱动布局)
├── HStack(spacing: 8)
│   ├── FileIconView (28x28pt, UTType icon + optional completion badge)
│   └── VStack(spacing: 3)  — row-content
│       ├── [进行中/已暂停/失败/已取消]
│       │   ├── HStack: filename + icon-action-buttons (暂停/恢复/取消)
│       │   ├── ProgressRow: progress-bar + percentage (进行中/已暂停 only)
│       │   └── HStack: status-text
│       └── [已完成]
│           ├── HStack: filename (无操作按钮)
│           └── HStack: status-text (左) + text-action-buttons (右: 打开/Finder)
```

**ViewModel 架构** (性能优化):
```
DownloadViewModel: ObservableObject
  @Published items: [DownloadItemVM]

DownloadItemVM: ObservableObject, Identifiable
  @Published progress: Double
  @Published state: DownloadState
  @Published speed: String
  @Published receivedBytes: Int64
  @Published totalBytes: Int64
```
每个下载项为独立 `ObservableObject`，进度变化只触发对应行的重绘。

### 3.4 批量下载拦截提示

#### 布局
面板顶部，Header 下方的横幅：
```
┌──────────────────────────────────────────┐
│ ⚠️ 此网页试图下载多个文件 (已拦截 5 个)    │
│                           [全部允许]       │
└──────────────────────────────────────────┘
```

#### 视觉规范
- 背景: `OWL.warning.opacity(0.1)`
- 边框: 无
- 图标: `exclamationmark.triangle.fill`，`OWL.warning` 色
- 文字: `OWL.captionFont`，`OWL.textPrimary`
- 按钮: "全部允许"，`OWL.accentPrimary` 色文字按钮
- 高度: 自适应（约 36pt）
- 动画: `.move(edge: .top)` 进入
- 自动消失: 用户处理后 3 秒淡出

## 4. 状态流转

```
用户视角状态:
                                  ┌─── 暂停 ──→ 已暂停 (黄色进度条)
                                  │                │
                                  │                └── 恢复 ──→ 进行中
  开始下载 ──→ 进行中 (蓝色进度条) ─┤
                                  ├─── 完成 ──→ 已完成 (绿色完成标记)
                                  │
                                  ├─── 取消 ──→ 已取消 (灰色)
                                  │
                                  └─── 错误 ──→ 失败 (红色错误信息)
                                                    │
                                                    ├── 恢复 ──→ 进行中
                                                    └── 重新下载 ──→ 新的进行中
```

## 5. 设计决策记录

| 决策 | 选择 | 原因 |
|------|------|------|
| 面板位置 | Sidebar（非 Right Panel） | 下载列表是全局功能，sidebar 更符合使用频率和心理模型；与书签/历史并列更自然 |
| 不自动弹出面板 | 仅工具栏图标提示 | 避免打断浏览流；用户在看视频/阅读时不应被强制切换面板 |
| 行高分级 | 64pt/52pt/44pt | 进行中需要展示进度条和速度，需要最大空间；已完成次之；已取消最简 |
| 进度条颜色 | 蓝色(进行中)/黄色(暂停) | 与 macOS 系统风格一致，蓝色=活跃，黄色=等待 |
| 操作按钮为小图标 | 24pt 圆形 | sidebar 宽度有限(140pt)，文字按钮太占空间；图标更紧凑 |
| 已完成用文字按钮 | "打开"/"Finder" | 已完成状态空间充裕，文字按钮更明确操作意图 |

## 6. 无障碍考量

- **进度条**: 添加 `accessibilityValue("45%")` 和 `accessibilityLabel("下载进度")`
- **操作按钮**: 每个按钮有明确的 `accessibilityLabel`（"暂停下载"/"恢复下载"/"取消下载"）
- **状态变化**: 下载完成时通过 `AccessibilityNotification.Announcement` 播报
- **颜色对比度**: 所有文字色与背景色对比度 ≥ 4.5:1（WCAG AA）
- **键盘导航**: 支持 Tab 键在下载项之间移动，Space 键触发默认操作
