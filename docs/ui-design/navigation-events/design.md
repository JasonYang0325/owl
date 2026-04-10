# 导航事件与错误处理 — UI 设计稿

## 1. 设计概述

### 设计目标
为导航生命周期的三种关键状态提供清晰的视觉反馈：加载中（进度条）、失败（错误页面）、认证（Auth 对话框）。

### 设计原则
- **最小侵入**: 进度条是地址栏底部的 2pt 细线，不占额外空间
- **状态明确**: 每个导航状态都有唯一的视觉表达，不依赖颜色 alone
- **复用优先**: 复用 `OWL` Design Tokens 和现有组件（扩展 ErrorPageView 而非新建）
- **macOS 原生风格**: Auth 对话框用 `.sheet`，保持系统 vibrancy

## 2. 信息架构

```
TopBarView (48pt)
├── NavigationButtons (已有: back/forward/reload-stop)
├── AddressBarView (已有)
│   ├── SecurityIndicator
│   ├── AddressTextField
│   ├── ZoomIndicator
│   ├── StarButton
│   └── 🆕 ProgressBar (2pt, 地址栏底部内嵌)
└── ...

ContentAreaView
├── TabContentView (已有)
│   ├── WelcomeView
│   ├── RemoteLayerView (web content)
│   └── 🆕 ErrorPageView 扩展（导航错误 + Auth 失败错误）
├── SSLErrorOverlay (已有)
├── 🆕 TopOverlayStack (.overlay(alignment: .top))
│   ├── FindBarView (已有，移入此 VStack)
│   └── SlowLoadingBanner (条件显示)
└── ...

BrowserWindow Level
└── 🆕 AuthAlertView (.sheet on BrowserWindow body)
```

## 3. 页面/组件设计

### 3.1 ProgressBar（进度条）

#### 布局
```
┌─────────────────────────────────────┐
│ 🔒  example.com           ⊕  ★    │ ← AddressBarView (32pt)
├─────────────────────────────────────┤
│████████████░░░░░░░░░░░░░░░░░░░░░░░░│ ← ProgressBar (2pt, 内嵌在地址栏底部)
└─────────────────────────────────────┘
```
- 位置: AddressBarView 的 `.overlay(alignment: .bottom)`
- 高度: 2pt
- 宽度: 与地址栏等宽（含圆角内区域）

#### Modifier 链位置（关键实现细节）

AddressBarView 当前 modifier 链（简化）:
```swift
HStack { ... }                    // 地址栏内容
  .background(OWL.surfaceSecondary)
  .clipShape(RoundedRectangle(...))  // ① 圆角裁切
  .overlay(ProgressBar(...),         // ② 🆕 进度条（被①裁切，贴合圆角）
           alignment: .bottom)
  .overlay(                          // ③ 聚焦边框（在进度条之上）
    RoundedRectangle(...)
      .stroke(isFocused ? OWL.accentPrimary : .clear)
  )
```

**要点**: ProgressBar overlay 插入在 `.clipShape()` 之后、focus stroke `.overlay()` 之前。这样：
- ProgressBar 被圆角裁切（左右两端贴合地址栏弧形）
- 聚焦边框在进度条之上（2pt stroke 不遮挡 2pt 进度条，因为 stroke 是空心的）

#### 视觉规范
- 填充色: `OWL.accentPrimary` (#0A84FF)
- 背景轨道: 不显示（透明），填充部分直接画在地址栏底部
- 完成渐隐: `opacity` 从 1.0 → 0.0，duration 300ms，easeOut

#### 交互设计
| 状态 | 表现 |
|------|------|
| 空闲 (progress == 0) | 不可见 |
| 加载开始 (0.1) | 从左侧出现，缓慢爬升 |
| 加载中 (0.1-0.9) | 伪进度平滑前进 |
| 加载完成 (1.0) | 满条 → 300ms 渐隐 |
| 加载失败 | 立即隐藏（不渐隐） |

#### 动画
- 值变化: `.animation(.easeInOut(duration: 0.3), value: progress)`
- 完成渐隐: `.animation(.easeOut(duration: 0.3), value: opacity)`
- Reduce Motion: 检查 `@Environment(\.accessibilityReduceMotion)`，若开启则显示 indeterminate 细线（无动画，仅出现/消失），不使用伪进度

#### 数据源与伪进度 Timer

**TabViewModel 新增属性**:
```swift
@Published var loadingProgress: Double = 0.0  // 0.0-1.0, 驱动 ProgressBar
@Published var navigationError: NavigationError? = nil  // 驱动 ErrorPageView
@Published var authChallenge: AuthChallenge? = nil  // 驱动 AuthAlertView
@Published var isSlowLoading: Bool = false  // 驱动 SlowLoadingBanner

// 内部状态（不 @Published）
private var currentNavigationId: Int64 = 0
private var fakeProgressTask: Task<Void, Never>? = nil
private var slowLoadingTask: Task<Void, Never>? = nil
```

**伪进度 Timer 实现**（用 `Task` + `Task.sleep`，非 `Timer.publish`）:
```swift
// OnNavigationStarted 时启动
func startFakeProgress(navigationId: Int64) {
    fakeProgressTask?.cancel()
    currentNavigationId = navigationId
    loadingProgress = 0.1
    isSlowLoading = false

    fakeProgressTask = Task { @MainActor in
        // Started 阶段: 每 500ms +0.02, 0.1 → 0.5
        while !Task.isCancelled && loadingProgress < 0.5 {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { loadingProgress += 0.02 }
        }
    }

    // 5 秒慢加载检测
    slowLoadingTask?.cancel()
    slowLoadingTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled && isLoading {
            isSlowLoading = true
        }
    }
}

// OnNavigationCommitted 时切换
func onCommitted(navigationId: Int64) {
    guard navigationId == currentNavigationId else { return }  // 丢弃旧导航事件
    fakeProgressTask?.cancel()
    loadingProgress = 0.6

    fakeProgressTask = Task { @MainActor in
        // Committed 阶段: 每 300ms +0.03, 0.6 → 0.9
        while !Task.isCancelled && loadingProgress < 0.9 {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { loadingProgress += 0.03 }
        }
    }
}

// OnLoadFinished / OnNavigationFailed / Stop 时完成
func completeNavigation(success: Bool) {
    fakeProgressTask?.cancel()
    slowLoadingTask?.cancel()
    isSlowLoading = false

    if success {
        loadingProgress = 1.0  // → 300ms 后 ProgressBar 内部渐隐
    } else {
        loadingProgress = 0.0  // 立即隐藏
    }
}
```

**多 Tab 场景**: 每个 TabViewModel 实例有自己的 `fakeProgressTask`。Tab 切换时不取消 Task（后台 tab 继续加载），仅 UI 绑定活跃 tab 的 `loadingProgress`。

#### 组件树
```swift
struct ProgressBar: View {
    let progress: Double  // 0.0 - 1.0, 来自 TabViewModel.loadingProgress
    @State private var fadeOpacity: Double = 1.0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
}
```

### 3.2 NavigationButtons 更新（停止/刷新切换）

NavigationButtons 已有 reload/stop 切换逻辑（`isLoading` 驱动）。**无需修改现有组件**，只需确保 `TabViewModel.isLoading` 在新的导航事件中正确更新。

现有行为确认：
- 加载中: 显示 `xmark` 图标（停止），点击调用 `stop()`
- 空闲: 显示 `arrow.clockwise` 图标（刷新），点击调用 `reload()`

### 3.3 ErrorPageView 扩展（导航错误页面）

**复用现有 `ErrorPageView`**，不新建组件。扩展其参数以支持导航错误：

#### 布局（与现有 ErrorPageView 一致）
```
┌─────────────────────────────────────────┐
│                                         │
│            ⚠ (48pt icon)                │
│                                         │
│         无法访问此网站                    │  ← 标题
│                                         │
│    无法找到该网站的服务器地址              │  ← 描述
│    请检查网址是否正确                     │  ← 建议
│                                         │
│         ┌──────────┐                    │
│         │   重试    │                    │  ← Primary Button
│         └──────────┘                    │
│                                         │
│    错误码: ERR_NAME_NOT_RESOLVED (-105) │  ← 错误码 (mono)
│                                         │
└─────────────────────────────────────────┘
```

#### 视觉规范
- 背景: `OWL.surfaceSecondary`
- 图标: `exclamationmark.triangle.fill` (SF Symbol), 48pt, `OWL.warning` (#FF9500)
- 标题: `OWL.titleFont` (20pt semibold), `OWL.textPrimary`
- 描述: `OWL.bodyFont` (14pt), `OWL.textSecondary`, maxWidth 400pt, multilineTextAlignment(.center)
- 建议: `OWL.captionFont` (12pt), `OWL.textTertiary`
- 重试按钮: `OWL.accentPrimary` 背景, 白色文字, `OWL.radiusMedium` 圆角, `OWL.buttonFont`
- 错误码: `OWL.codeFont` (13pt mono), `OWL.textTertiary`
- 整体垂直居中，元素间距 12pt

#### 特殊错误类型处理
| 错误类型 | 按钮 | 备注 |
|---------|------|------|
| 通用错误 | "重试" (Primary, 调用 reload()) | 默认行为 |
| ERR_INTERNET_DISCONNECTED | "重试" + 额外文案"请检查网络连接" | 重试仍可能失败 |
| ERR_TOO_MANY_REDIRECTS | "返回" (Primary, 调用 goBack()) | 不提供重试（会死循环）|
| Auth 失败 (3次上限) | "返回" (Primary) | 标题: "认证失败"，描述: "请联系网站管理员" |

**`canGoBack==false` 处理**: 如果 `goBack()` 不可用（新标签页首次导航失败），"返回"按钮改为"返回主页"（导航到 `about:blank` 显示 WelcomeView）。

#### 在 ContentAreaView 中的显示条件

```swift
// TabContentView 中的条件分支:
if let error = tab.navigationError {
    ErrorPageView(
        errorCode: error.code,
        errorDescription: error.localizedDescription,
        suggestion: error.suggestion,
        primaryAction: error.requiresGoBack ? .goBack : .retry,
        canGoBack: tab.canGoBack
    )
} else if tab.isWelcomePage {
    WelcomeView()
} else if tab.hasRenderSurface {
    RemoteLayerView(...)
}
```

#### 扩展后的组件接口
```swift
struct ErrorPageView: View {
    // 现有参数保留
    var title: String = "无法连接到浏览器引擎"
    var message: String = "..."
    var onRetry: (() -> Void)? = nil

    // 🆕 新增可选参数（导航错误扩展）
    var errorCode: Int? = nil               // 显示 mono 错误码
    var suggestion: String? = nil            // 建议文案
    var onGoBack: (() -> Void)? = nil        // 返回按钮（可选）
    var showRetry: Bool = true               // ERR_TOO_MANY_REDIRECTS 时隐藏
}
```

### 3.4 AuthAlertView（HTTP 认证对话框）

#### 布局
使用 `.sheet` modifier 呈现，**挂载在 BrowserWindow body 上**（与 PermissionAlertView 同级）。

```
┌──────────────────────────────────┐
│  🔒  认证请求                     │
│                                  │
│  example.com 要求输入凭证         │
│  Realm: "Admin Panel"            │
│                                  │
│  ⚠ 用户名或密码错误，请重试       │  ← 仅第 2/3 次显示 (OWL.error)
│                                  │
│  用户名: [________________]      │
│  密  码: [________________]      │  ← SecureField
│                                  │
│       [取消]        [登录]       │
│                                  │
│  🔄 代理认证                     │  ← 仅 407 时显示
└──────────────────────────────────┘
```

#### 视觉规范
- 呈现方式: `.sheet` modifier 在 BrowserWindow body 上
- 窗口尺寸: 宽 360pt, 高度自适应
- 背景: 系统 sheet 背景（自动 vibrancy — macOS `.sheet` 默认行为）
- 图标: `lock.fill` (SF Symbol), 32pt, `OWL.accentPrimary`
- 标题: "认证请求", `OWL.titleFont`
- 来源说明: "{domain} 要求输入凭证", `OWL.bodyFont`, `OWL.textSecondary`
- Realm: `OWL.captionFont`, `OWL.textTertiary`
- 错误提示: `OWL.captionFont`, `OWL.error` (#FF3B30), 仅 failureCount > 0 时显示
- 输入框: 标准 TextField / SecureField, 高 28pt
- 按钮: "取消" (Secondary, `.keyboardShortcut(.escape)`) + "登录" (Primary, `.keyboardShortcut(.defaultAction)`)
- 代理标签: `OWL.captionFont`, `OWL.textTertiary`, 带 `arrow.triangle.2.circlepath` 小图标
- 内边距: 20pt
- 元素间距: 12pt

#### 交互设计
| 状态 | 表现 |
|------|------|
| 首次弹出 | 无错误提示, 用户名输入框获得焦点 |
| 第 2/3 次弹出 | 显示红色错误提示"用户名或密码错误，请重试"，VoiceOver 自动播报错误 |
| 登录按钮禁用 | **仅当用户名为空时** disabled（密码允许为空，支持空密码 Auth 场景） |
| 提交中 | 按钮显示 ProgressView spinner (可选) |
| 取消 | 关闭 sheet, 调用 CancelAuth |
| 导航中断 | sheet 自动关闭（TabViewModel.authChallenge = nil） |

#### 与 PermissionAlertView 的优先级
- Auth sheet 和 Permission overlay **互斥**：Auth 挑战发生在导航阶段（页面未加载完），Permission 发生在页面加载后
- 极端情况（理论上不会同时触发）：Auth sheet 优先（阻塞导航），Permission 排队等 Auth 完成
- 实现: `BrowserWindow` 通过 `activeTab?.authChallenge != nil` 控制 `.sheet`

#### 组件树
```swift
struct AuthAlertView: View {
    let url: String
    let realm: String
    let isProxy: Bool
    let failureCount: Int  // 0=首次, 1=第2次, 2=第3次
    let onSubmit: (String, String) -> Void  // (username, password)
    let onCancel: () -> Void
}
```

### 3.5 SlowLoadingBanner（慢加载提示）

#### 布局

**与 FindBarView 共存**: 放入同一个 `.overlay(alignment: .top)` VStack 中。

```
┌─────────────────────────────────────┐  ← TopBar
│ FindBarView (如果可见)               │  ← 在上
│ SlowLoadingBanner (如果慢加载)       │  ← 在下
├─────────────────────────────────────┤
│            (web content)            │
```

实现方式:
```swift
// ContentAreaView 中
.overlay(alignment: .top) {
    VStack(spacing: 0) {
        if tab.isFindBarVisible {
            FindBarView(...)
        }
        if tab.isSlowLoading {
            SlowLoadingBanner()
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
```

#### 视觉规范
- 背景: `OWL.warning.opacity(0.15)` 浅橙色（Dark mode 下 0.15 保证可见性）
- 文字: "加载较慢...", `OWL.captionFont`, `OWL.warning`
- 图标: `clock.fill` (SF Symbol), 12pt, `OWL.warning`
- 水平排列: icon + text，左对齐，左边距 12pt
- 高度: 28pt
- 无按钮（停止操作通过导航栏的停止图标触发）

#### 交互设计
| 状态 | 表现 |
|------|------|
| 出现 | 导航 5 秒后仍在加载 → slide in from top |
| 消失 | 加载完成/失败/停止/新导航 → slide out |

#### 组件树
```swift
struct SlowLoadingBanner: View {
    // 无需 props，仅作为条件渲染组件
}
```

## 4. 状态流转

### TabViewModel 导航状态机

```
                         navigate(to:)
                              │
                    ┌─────────▼─────────┐
                    │   idle            │
                    │ progress=0        │◄────────────────┐
                    │ error=nil         │                  │
                    └─────────┬─────────┘                  │
                              │ OnNavigationStarted        │
                    ┌─────────▼─────────┐                  │
                    │   loading_started │                  │
              ┌────►│ progress=0.1→0.5  │                  │
              │     │ isLoading=true    │                  │
              │     └───┬─────────┬─────┘                  │
              │         │         │                        │
      redirect│  commit │   fail/stop │                    │
      (same   │         │         │                        │
       nav_id)│ ┌───────▼──────┐  │                        │
              │ │  loading_    │  │  OnNavigationFailed    │
              └─┤  committed   │  ├───────────────────────►│
                │ progress=    │  │                        │
                │  0.6→0.9     │  │  Stop() → ERR_ABORTED │
                │ isLoading=   │  ├───────────────────────►│
                │  true        │  │  (no error page)       │
                └──────┬───────┘  │                        │
                       │          │                        │
            OnLoad     │          │                        │
            Finished   │          │                        │
                ┌──────▼──────┐   │  ┌──────────────┐     │
                │  completing │   └─►│  error       │     │
                │ progress=1.0│      │ progress=0   │     │
                │ 300ms fade  │      │ show error   │─────┘
                └──────┬──────┘      │ page         │ retry/
                       │             └──────────────┘ navigate
                       │
                       └──────────────────────────────────┘
```

### Auth 状态机（TabViewModel.authChallenge）

```
nil ──OnAuthRequired──► AuthChallenge(attempt=1)
                              │
                    ┌─────────┤
                    │ submit   │ cancel
                    │         │
                    ▼         ▼
              [wait for    nil (CancelAuth)
               server]
                    │
            ┌───────┤
        401 again   │ 200 OK
            │       │
            ▼       ▼
    AuthChallenge  nil (success,
    (attempt=2)     reset counter)
            │
        ... (max attempt=3)
            │
            ▼
    nil + ErrorPageView
    (title: "认证失败",
     action: "返回")
```

### 地址栏 URL 更新规则

| 事件 | 地址栏内容 |
|------|-----------|
| navigate(to:) | 立即显示新 URL（`pendingURL`） |
| redirect (server) | 不更新（等 committed） |
| committed | 更新为 committed URL |
| failed | 保留失败的 URL（用户可修改后重试） |
| Stop() 且未 commit | 恢复为前一个 committed URL（或空） |

## 5. 设计决策记录

| 决策 | 选择 | 替代方案 | 理由 |
|------|------|---------|------|
| 进度条位置 | 地址栏底部内嵌 2pt | 独立条在顶栏下方 | Safari/Chrome 风格，不占额外空间 |
| Auth 对话框 | `.sheet` on BrowserWindow | `.alert` / NSAlert | `.alert` 不支持自定义 TextField；`.sheet` 保持 SwiftUI 原生 vibrancy |
| 错误页面 | 扩展现有 ErrorPageView | 新建 NavigationErrorPage | 复用现有组件，统一错误页面风格，减少维护成本 |
| 慢加载提示 | 顶部 Banner in overlay VStack | Toast / 进度条变色 | 与 FindBar 共存于同一 overlay，清晰不遮挡 |
| 伪进度 Timer | `Task` + `Task.sleep` | `Timer.publish` (Combine) | 与项目 Swift Concurrency 模式一致，可精确 cancel |
| Auth 登录按钮 | 仅用户名为空时 disabled | 用户名或密码为空 disabled | 支持空密码 Auth 场景（路由器等） |
| Reduce Motion | 显示 indeterminate 细线 | 跳变 0.1→1.0 | 跳变比静态出现/消失更令人困惑 |

## 6. 无障碍考量

- **颜色对比**: 进度条 `#0A84FF` 在白色/深色地址栏上对比度 > 4.5:1 (WCAG AA)
- **VoiceOver 静态**:
  - 进度条: `accessibilityLabel("页面加载进度")` + `accessibilityValue("\(Int(progress*100))%")`
  - 错误页面: VoiceOver 朗读完整错误描述 + 重试按钮
- **VoiceOver 动态播报**:
  - SlowLoadingBanner 出现时: `AccessibilityNotification.Announcement("页面加载较慢").post()`
  - Auth 错误提示出现时: 错误文本自动获得 VoiceOver 焦点（`.accessibilityFocused`）
  - NavigationErrorPage 出现时: 标题自动获得 VoiceOver 焦点
- **键盘**: Auth 对话框支持 Tab 切换焦点，Escape 取消，Return 提交
- **Reduce Motion**: 进度条显示 indeterminate 样式（静态细线出现/消失），伪进度禁用，SlowLoadingBanner 无滑入动画直接显示
- **Dark Mode**: SlowLoadingBanner 背景 `OWL.warning.opacity(0.15)` 在深色模式下保证可见性
