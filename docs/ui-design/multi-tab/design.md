# 多标签管理 — UI 设计稿

## 1. 设计概述

### 设计目标
- 在现有垂直侧边栏中实现完整的多标签管理体验
- 固定标签以紧凑图标形式置顶，与普通标签在视觉上明确区分
- 延迟加载标签（deferred）有轻微视觉提示，避免用户困惑
- 所有交互对齐 macOS 浏览器惯例（Safari/Chrome 快捷键和行为）

### 设计原则
- **复用现有组件**: 基于 `TabRowView`、`SidebarView`、`ObservedTabRow` 扩展，不造新轮子
- **渐进增强**: 固定标签和撤销关闭是在现有标签行为上的增量，不改变基础交互模式
- **状态可见**: 活跃/非活跃/固定/延迟加载/加载中/错误 六种状态视觉上可区分
- **上下文菜单**: macOS 原生右键菜单，固定/取消固定/关闭等操作

## 2. 信息架构

```
SidebarView (sidebarMode == .tabs)
  ├── TabSearchField            — 搜索标签（已有）
  ├── NewTabButton              — "+ 添加标签页"（已有）
  ├── Divider
  ├── [固定标签区]              — 新增，置顶
  │     ├── PinnedTabRow (固定标签 1)
  │     ├── PinnedTabRow (固定标签 2)
  │     └── Divider（仅当有固定标签时显示）
  └── [普通标签区]              — ScrollView 内
        ├── ObservedTabRow (标签 A) — 活跃
        ├── ObservedTabRow (标签 B) — 非活跃
        └── ObservedTabRow (标签 C) — deferred（浅色）
```

**导航路径**:
- 创建标签: Cmd+T / 点击 "+" → 新标签出现在列表末尾
- 切换标签: 点击标签行 / Cmd+1~9 / Cmd+Option+↑↓
- 关闭标签: 悬停显示 X 按钮 / Cmd+W
- 固定标签: 右键 → "固定标签"
- 撤销关闭: Cmd+Shift+T

## 3. 页面/组件设计

### 3.1 固定标签行 (PinnedTabRow)

#### 布局
```
┌────────────────────────────┐
│  [■] ← favicon placeholder │  ← 36px 高，紧凑模式
│  固定标签 1                 │     完整模式时显示短标题
└────────────────────────────┘
```

紧凑侧边栏（isCompact=true）时：仅显示 favicon 方块，居中。
完整侧边栏时：favicon + 截断标题（最多显示侧边栏宽度内），**无关闭按钮**。

#### 视觉规范
- **背景**: 透明（默认），`OWL.surfaceSecondary.opacity(0.3)`（悬停），`OWL.accentPrimary.opacity(0.15)`（活跃）
- **Favicon 占位**: 16x16，`cornerRadius: 4`
- **标题字体**: `OWL.tabFont`（13pt），`OWL.textSecondary`
- **活跃状态**: 左侧 3px 竖线指示条，颜色 `OWL.accentPrimary`
- **固定图标**: 小图钉 SF Symbol `pin.fill`（8pt），叠加在 favicon 右下角，颜色 `OWL.textTertiary`
- **间距**: `padding(.horizontal, 10)`, `padding(.vertical, 6)`
- **高度**: `OWL.tabItemHeight`（36px）

#### 交互设计
| 状态 | 视觉表现 |
|------|---------|
| 默认 | 透明背景，标题 `OWL.textSecondary` |
| 悬停 | 浅灰背景，标题变为 `OWL.textPrimary`，**不显示关闭按钮** |
| 活跃 | 左侧蓝色指示条，背景 `OWL.accentPrimary.opacity(0.15)`，标题 `OWL.accentPrimary` |
| 右键 | 弹出上下文菜单（见 3.5） |

### 3.2 普通标签行 (TabRowView 扩展)

#### 布局（与现有一致，增加状态）
```
┌─────────────────────────────────────────┐
│  [■]  标签标题 ···················· [✕]  │  ← 36px
└─────────────────────────────────────────┘
     16px  OWL.tabFont                  悬停显示
```

#### 视觉规范
沿用现有 `TabRowView` 设计，新增以下状态：

**活跃标签**: 保持现有设计
- 背景: `OWL.accentPrimary` 蓝色填充
- 标题: `.white`
- 关闭按钮: `.white.opacity(0.7)`
- 圆角: `OWL.radiusMedium`（8px）

**非活跃标签**: 保持现有设计
- 背景: 透明 → 悬停 `OWL.surfaceSecondary.opacity(0.3)`
- 标题: `OWL.textPrimary`
- 关闭按钮: 悬停时显示

**延迟加载标签 (deferred)**:（新增状态）
- 背景: 同非活跃
- 标题: `OWL.textTertiary`（比普通标签更浅，暗示"尚未加载"）
- Favicon 占位: `OWL.textTertiary.opacity(0.5)`
- 关闭按钮: 悬停时显示（可以关闭 deferred 标签）
- 点击后: 创建 WebView → 标题颜色恢复正常 → 显示加载指示

**加载中标签**:（新增状态）
- 标题左侧 favicon 位置替换为旋转加载指示器
- 使用 `ProgressView()` 尺寸 14x14，样式 `.circular`（或 `controlSize(.mini)`）
- 标题显示 URL host（如 "google.com"），等 PageInfo 回调后替换为页面标题
- 加载指示器在 `OnNavigationStarted` 时开始，`OnNavigationFinished`/`OnPageInfoChanged(title)` 时结束

**错误标签**:（新增状态）
- Favicon 位置显示 SF Symbol `exclamationmark.triangle.fill`（14pt），颜色 `OWL.warning`
- 标题显示错误描述（如 "无法连接到服务器"），颜色 `OWL.textSecondary`
- 点击标签可激活，渲染区域显示错误页面（Chromium 内置的 error page）
- 右键菜单包含"重新加载"选项

#### 交互设计
| 事件 | 行为 |
|------|------|
| 单击 | 激活标签，切换渲染表面 |
| 悬停 | 显示关闭按钮 |
| 右键 | 弹出上下文菜单（见 3.5） |
| Cmd+W（活跃时） | 关闭标签 |

### 3.3 侧边栏标签列表 (SidebarView 变更)

#### 布局
```
┌──────────────────────────────┐
│  🔍 搜索标签页               │  ← TabSearchField
│  ＋ 添加标签页               │  ← NewTabButton
│  ─────────────────────────── │
│  📌 固定标签 A  ←活跃 ●      │  ← PinnedTabRow（固定区）
│  📌 固定标签 B               │
│  ─────────────────────────── │  ← 固定/普通分隔线
│  标签 C          [✕]        │  ← 普通 TabRowView（ScrollView）
│  标签 D（浅色）   [✕]        │  ← deferred 标签
│  ● 加载中...      [✕]        │  ← 加载中标签
│                              │
│                              │
│  ─────────────────────────── │
│  📑  🕐  ⬇️  💬  🤖  ⚙️    │  ← SidebarToolbar
└──────────────────────────────┘
```

**侧边栏宽度**: 140px（`OWL.sidebarWidth`，与现有设计一致）。可用内容宽度 120px（10px horizontal padding），标签标题严重截断是预期行为，通过 `.lineLimit(1)` + text ellipsis 处理。

#### 变更点
1. 固定标签从 `viewModel.tabs` 中分离出来，在 ScrollView 之前渲染
2. 固定标签之间用 `spacing: 2` 排列，固定区底部有 `Divider`
3. 搜索同时过滤固定和非固定标签
4. 空状态: 无标签时（理论上不会发生，至少有一个标签）

### 3.4 标签切换动画

#### 渲染区域切换
- 切换标签时，`RemoteLayerView` 更新 `CALayerHost.contextId`
- 无需额外过渡动画（CALayerHost 切换本身是即时的）
- 如果目标标签正在加载（deferred 刚激活），渲染区域先显示空白/加载状态，随后页面内容逐步呈现

#### 标签列表动画
- 新标签创建: `.transition(.opacity.combined(with: .move(edge: .bottom)))` 配合 `withAnimation(.easeOut(duration: 0.2))`
- 标签关闭: `.transition(.opacity.combined(with: .move(edge: .trailing)))` 配合 `withAnimation(.easeIn(duration: 0.15))`
- 撤销恢复: `.transition(.opacity.combined(with: .scale(scale: 0.95)))` 配合 `withAnimation(.easeOut(duration: 0.2))`，标签出现在 originalIndex 位置
- 标签固定/取消固定: 使用 `.id(tab.id)` + 统一 `VStack` 排序（而非跨容器移动），让 SwiftUI 自动产生移动动画。如果固定/非固定区分别在不同容器，需使用 `matchedGeometryEffect` 实现跨容器平滑过渡

### 3.5 上下文菜单 (Tab Context Menu)

右键标签行弹出 macOS 原生上下文菜单:

#### 普通标签的菜单
```
┌─────────────────────────┐
│ 固定标签                 │
│ ─────────────────────── │
│ 重新加载            ⌘R  │
│ ─────────────────────── │
│ 关闭标签            ⌘W  │
│ 关闭其他标签             │
│ 关闭下方所有标签          │
│ ─────────────────────── │
│ 复制链接地址             │
└─────────────────────────┘
```

#### 固定标签的菜单
```
┌─────────────────────────┐
│ 取消固定                 │
│ ─────────────────────── │
│ 重新加载            ⌘R  │
│ ─────────────────────── │
│ 关闭标签            ⌘W  │
│ 关闭其他标签             │
│ ─────────────────────── │
│ 复制链接地址             │
└─────────────────────────┘
```

注意: deferred 标签的右键菜单中"重新加载"替换为"加载此标签"（触发 WebView 创建+导航），"复制链接地址"仍可用（从 SessionTab.url 读取）。

#### 实现方式
使用 SwiftUI `.contextMenu { }` modifier，附加在 `ObservedTabRow` 上。

### 3.6 键盘快捷键 UI 反馈

| 快捷键 | UI 反馈 |
|--------|---------|
| Cmd+T | 新标签出现在列表末尾，自动激活（蓝色高亮），侧边栏自动滚动到新标签 |
| Cmd+W | 当前标签淡出消失，相邻标签（下方优先）自动激活 |
| Cmd+Shift+T | 恢复的标签出现在原始位置，带淡入动画 |
| Cmd+1~8 | 目标标签高亮，渲染区域切换 |
| Cmd+9 | 切换到最后一个标签 |
| Cmd+Option+↓ | 下一个标签高亮 |
| Cmd+Option+↑ | 上一个标签高亮 |

## 4. 状态流转

### 标签生命周期状态机

```
                 ┌──────────────────────────┐
                 │                          │
[Session Restore] ──→ deferred ──(首次激活)──→ loading ──→ ready
                           │                     │          │    │
                           │                     │          │    └──(加载失败)──→ error
                      (关闭)↓                (关闭)↓    (关闭)↓            │      │
                        closed               closed    closed        (重新加载) (关闭)
                           │                     │          │            ↓      ↓
                      (Cmd+Shift+T)          (Cmd+Shift+T)          loading  closed
                           ↓                     ↓
                       loading ──────────────→ ready
```

注意: deferred → loading 的过渡是即时的（点击后立即显示加载指示器，不等 CreateWebView 完成）。

### 标签 UI 状态

| 状态 | Favicon | 标题颜色 | 背景 | 关闭按钮 |
|------|---------|---------|------|---------|
| deferred | 灰色占位 | `textTertiary` | 透明 | 悬停显示 |
| loading | 旋转指示器 | `textPrimary` | 活跃蓝/透明 | 悬停显示 |
| ready (活跃) | 正常 | `.white` | `accentPrimary` | 悬停显示 |
| ready (非活跃) | 正常 | `textPrimary` | 透明 | 悬停显示 |
| error (活跃) | ⚠️ warning 图标 | `.white` | `accentPrimary` | 悬停显示 |
| error (非活跃) | ⚠️ warning 图标 | `textSecondary` | 透明 | 悬停显示 |
| pinned (活跃) | 正常+图钉 | `accentPrimary` | 淡蓝 | 不显示 |
| pinned (非活跃) | 正常+图钉 | `textSecondary` | 透明 | 不显示 |
| pinned+deferred | 灰色占位+图钉 | `textTertiary` | 透明 | 不显示 |
| pinned+loading | 旋转指示器+图钉 | `textSecondary` | 透明 | 不显示 |

## 5. 设计决策记录

| # | 决策 | 原因 | 替代方案 |
|---|------|------|---------|
| 1 | 固定标签不单独用紧凑行，保持与普通标签相同高度 | 侧边栏宽度有限（140px），紧凑图标行过小难以辨认；且固定标签数量通常 < 5 | 另做 32px 紧凑行 |
| 2 | 活跃标签继续使用蓝色填充背景（现有设计） | 用户已经习惯，且视觉层次最清晰 | 左侧指示条（只用于固定标签活跃态） |
| 3 | Deferred 标签用浅色标题而非单独图标提示 | 避免视觉噪音，用户通常不关心标签是否已加载 | 单独的"未加载"图标 |
| 4 | 上下文菜单使用 SwiftUI `.contextMenu` | 原生 macOS 体验，无需自定义弹窗组件 | 自定义 popover 菜单 |
| 5 | 固定标签在活跃时用左侧指示条而非蓝色填充 | 与普通活跃标签区分，避免混淆"固定"和"活跃"两个概念 | 统一用蓝色填充 |
| 6 | PinnedTabRow 作为独立组件而非扩展 TabRowView | 固定标签的活跃态（指示条+淡蓝背景）与普通标签（蓝色填充）完全不同，合并会导致条件分支膨胀 | 扩展 TabRowView 加 isPinned flag |
| 7 | Cmd+1~9 计入固定标签（全局第 N 个标签） | 对齐 Safari/Chrome 行为，固定+普通按显示顺序统一计数 | 仅计数普通标签 |
| 8 | 不实现"静音标签"菜单项 | 当前无音频管理需求，后续 Module L（全屏与媒体控制）时统一处理 | 预留菜单项 |
| 9 | 固定标签区最多 8 个，超过时固定区也变为可滚动 | 避免窗口较矮时普通标签区被完全挤占 | 不设上限 |

## 6. 无障碍考量

- **VoiceOver**: 每个标签行添加 `accessibilityLabel`（含标题、固定状态、加载状态、deferred 标注"未加载"）
- **焦点管理**:
  - Cmd+1~9/Cmd+Option+↑↓ 切换标签时同步移动 VoiceOver 焦点
  - **关闭标签后**: VoiceOver 焦点移到新激活的标签（下方优先，其次上方）
  - 状态变化（deferred→loading→ready）时发送 `UIAccessibility.post(notification: .layoutChanged)`
- **对比度**: 所有文本颜色与背景对比度 >= 4.5:1（WCAG AA）
  - `textPrimary` (black/white) on surface: 通过
  - `textSecondary` (#8E8E93) on surface: 临界，dark mode 通过
  - `textTertiary` (deferred 标签): 对比度不达 4.5:1，通过 accessibilityLabel 补充"(未加载)"标注，确保 VoiceOver 用户不依赖视觉色差
- **关闭按钮**: 最小点击区域 20x20（macOS 桌面端 20pt 足够）
- **键盘越界**: Cmd+N 超出标签数量时忽略，无额外反馈；Cmd+Option+↑↓ 到达首尾时停留不循环（对齐 Chrome）

## 7. 组件树

```
SidebarView (修改)
├── TabSearchField (现有)
├── NewTabButton (现有)
├── PinnedTabSection (新增)
│   ├── ForEach(pinnedTabs)
│   │   └── PinnedTabRow (新增)
│   │       ├── Favicon + pin badge overlay
│   │       ├── Title (truncated)
│   │       └── Active indicator bar
│   └── Divider (条件显示)
├── ScrollView
│   └── LazyVStack
│       └── ForEach(unpinnedTabs)
│           └── ObservedTabRow (修改: 增加 deferred/loading 状态)
│               └── TabRowView (修改: 增加 isPinned, isDeferred, isLoading props)
│                   ├── Favicon / ProgressView (loading)
│                   ├── Title
│                   └── Close button (hover)
└── SidebarToolbar (现有)

TabRowView props 变更:
  + isPinned: Bool      — 影响样式和关闭按钮可见性
  + isDeferred: Bool    — 标题颜色变浅
  + isLoading: Bool     — favicon 替换为 ProgressView
  (保留: title, isActive, isCompact, onClose, onSelect)

新增组件:
  PinnedTabRow        — 固定标签行（继承 TabRowView 或独立组件）
  PinnedTabSection    — 固定标签区域容器
  TabContextMenu      — 上下文菜单内容（作为 ViewModifier）
```
