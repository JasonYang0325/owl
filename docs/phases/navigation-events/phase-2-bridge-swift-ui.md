# Phase 2: Bridge + Swift + 进度条/错误页 UI

## 目标
- 将 Host 导航事件通过 Bridge C-ABI 传递到 Swift
- TabViewModel 实现导航状态机（进度、错误、慢加载）
- SwiftUI 实现 ProgressBar、ErrorPageView 扩展、SlowLoadingBanner

## 范围

### 修改文件
| 文件 | 变更 |
|------|------|
| `bridge/owl_bridge_api.h` | 新增 3 个 callback typedef + setter + 注释 |
| `bridge/owl_bridge_api.cc` | Observer 实现 OnNavigationStarted/Committed/Failed → C-ABI 回调 |
| `bridge/OWLBridgeWebView.mm` | Observer stub 补全 4 个新方法 |
| `owl-client-app/ViewModels/TabViewModel.swift` | 新增 loadingProgress/navigationError/isSlowLoading + 伪进度 Task |
| `owl-client-app/Views/TopBar/AddressBarView.swift` | 添加 ProgressBar overlay |
| `owl-client-app/Views/Content/ErrorPageView.swift` | 扩展参数支持导航错误 |
| `owl-client-app/Views/Content/ContentAreaView.swift` | ErrorPageView 显示条件 + SlowLoadingBanner overlay |
| `owl-client-app/Models/NavigationEvent.swift` | 🆕 NavigationError model（NavigationEventRing 推迟到 Phase 4） |
| `owl-client-app/Views/Shared/ProgressBar.swift` | 🆕 ProgressBar 组件 |
| `owl-client-app/Views/Content/SlowLoadingBanner.swift` | 🆕 SlowLoadingBanner 组件 |

### 不涉及
- Host C++ 逻辑（Phase 1）
- HTTP Auth（Phase 3）
- CLI（Phase 4）

## 依赖
- Phase 1（Mojom 接口 + Host 回调已实现）

## 技术要点

### Bridge C-ABI 回调（与 Phase 1 Mojom 对齐，已删除 is_ssl）
```c
typedef void (*OWLBridge_NavigationStartedCallback)(
    int64_t nav_id, const char* url, int is_user_initiated,
    int is_redirect, void* ctx);
typedef void (*OWLBridge_NavigationCommittedCallback)(
    int64_t nav_id, const char* url, int http_status, void* ctx);
typedef void (*OWLBridge_NavigationErrorCallback)(
    int64_t nav_id, const char* url, int error_code,
    const char* error_desc, void* ctx);
```
注意: bool 在 C-ABI 中用 int 传递（0/1），与项目现有模式一致。

### TabViewModel 新增属性
```swift
@Published var loadingProgress: Double = 0.0
@Published var navigationError: NavigationError? = nil
@Published var isSlowLoading: Bool = false
private var currentNavigationId: Int64 = 0
private var fakeProgressTask: Task<Void, Never>? = nil
private var slowLoadingTask: Task<Void, Never>? = nil
```

### ProgressBar modifier 链位置
```swift
// AddressBarView body 中：
.clipShape(...)           // ① 圆角裁切
.overlay(ProgressBar(...), alignment: .bottom)  // ② 进度条（被裁切）
.overlay(focus stroke)    // ③ 聚焦边框
```

### ErrorPageView 扩展（非新建）
复用现有 ErrorPageView，增加可选参数：errorCode, suggestion, onGoBack, showRetry

### 已知陷阱
- C-ABI 回调在 main thread，Swift 侧用 `Task { @MainActor in }` 桥接
- 修改 `bridge/*.h` 后必须重建 framework
- 伪进度 Task 用 `Task.isCancelled` 检查，避免 tab 销毁后继续执行
- `navigationError` 在 `completeNavigation(success:false)` 之前由调用方设置

## 验收标准
- [ ] 导航时地址栏显示蓝色进度条（0.1→缓慢爬升→0.6→继续→1.0→渐隐）
- [ ] 导航到不存在域名时显示友好错误页面（标题+描述+重试按钮）
- [ ] 重试按钮点击后重新加载
- [ ] ERR_TOO_MANY_REDIRECTS 显示"返回"而非"重试"
- [ ] 加载超过 5 秒显示"加载较慢..."提示
- [ ] 停止加载后进度条消失，不显示错误页面
- [ ] 现有功能不回归（导航、查找、缩放等）
- [ ] build_all.sh 编译通过

## 技术方案

### 1. 架构设计

```
Mojo WebViewObserver (Phase 1 已实现)
    │  OnNavigationStarted / Committed / Failed
    ▼
owl_bridge_api.cc::WebViewObserverImpl
    │  提取字段 → dispatch_async(main_queue)
    ▼
C-ABI Callback (OWLBridge_NavigationStartedCallback etc.)
    │  Swift closure capture
    ▼
BrowserViewModel.registerAllCallbacks()
    │  Task { @MainActor in }
    ▼
TabViewModel (loadingProgress / navigationError / isSlowLoading)
    │  @Published → SwiftUI binding
    ▼
UI Components (ProgressBar / ErrorPageView / SlowLoadingBanner)
```

### 2. Bridge C-ABI 实现

#### owl_bridge_api.h 新增
```c
// Navigation lifecycle callbacks (per-webview, registered via OWLBridge_Set*)
typedef void (*OWLBridge_NavigationStartedCallback)(
    int64_t nav_id, const char* url, int is_user_initiated,
    int is_redirect, void* ctx);
typedef void (*OWLBridge_NavigationCommittedCallback)(
    int64_t nav_id, const char* url, int http_status, void* ctx);
typedef void (*OWLBridge_NavigationErrorCallback)(
    int64_t nav_id, const char* url, int error_code,
    const char* error_desc, void* ctx);

OWL_EXPORT void OWLBridge_SetNavigationStartedCallback(
    uint64_t webview_id, OWLBridge_NavigationStartedCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetNavigationCommittedCallback(
    uint64_t webview_id, OWLBridge_NavigationCommittedCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetNavigationErrorCallback(
    uint64_t webview_id, OWLBridge_NavigationErrorCallback cb, void* ctx);
```

#### owl_bridge_api.cc WebViewObserverImpl 扩展
```cpp
// 替换 Phase 1 的空 stub:
void OnNavigationStarted(owl::mojom::NavigationEventPtr event) override {
    if (!state_->nav_started_cb) return;
    int64_t nav_id = event->navigation_id;
    std::string url = event->url;  // Block 值捕获 std::string，保证生命周期
    int user_init = event->is_user_initiated ? 1 : 0;
    int redirect = event->is_redirect ? 1 : 0;
    auto cb = state_->nav_started_cb;
    auto ctx = state_->nav_started_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        cb(nav_id, url.c_str(), user_init, redirect, ctx);
    });
}

// OnNavigationCommitted 同理（NavigationEventPtr → 提取字段）
void OnNavigationCommitted(owl::mojom::NavigationEventPtr event) override {
    if (!state_->nav_committed_cb) return;
    int64_t nav_id = event->navigation_id;
    std::string url = event->url;
    int status = event->http_status_code;
    auto cb = state_->nav_committed_cb;
    auto ctx = state_->nav_committed_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        cb(nav_id, url.c_str(), status, ctx);
    });
}

// ⚠️ OnNavigationFailed 签名不同：4 个散参，非 NavigationEventPtr
void OnNavigationFailed(int64_t navigation_id,
                        const std::string& url,
                        int32_t error_code,
                        const std::string& error_description) override {
    if (!state_->nav_error_cb) return;
    int64_t nav_id = navigation_id;
    std::string u = url;
    std::string desc = error_description;
    auto cb = state_->nav_error_cb;
    auto ctx = state_->nav_error_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        cb(nav_id, u.c_str(), error_code, desc.c_str(), ctx);
    });
}
```

### 3. Swift 层实现

#### NavigationError model (新文件)
```swift
struct NavigationError: Identifiable {
    let id = UUID()
    let navigationId: Int64
    let url: String
    let errorCode: Int32
    let errorDescription: String

    var localizedTitle: String { ... }  // 根据 errorCode 返回友好标题
    var localizedMessage: String { ... }  // 友好描述
    var suggestion: String? { ... }  // 操作建议
    var requiresGoBack: Bool { errorCode == -310 }  // ERR_TOO_MANY_REDIRECTS
    var isAborted: Bool { errorCode == -3 }  // ERR_ABORTED
}
```

#### NavigationEventRing
**推迟到 Phase 4**。Phase 2 不引入环形缓冲区（YAGNI）。

#### TabViewModel 扩展

导航状态机完整转移表:

| 事件 | loadingProgress | navigationError | isSlowLoading |
|------|----------------|----------------|---------------|
| onNavigationStarted (redirect=false) | → 0.1, 启动伪进度 Task | → nil（清除旧错误） | → false, 启动 5s Timer |
| onNavigationStarted (redirect=true) | 保持当前值（不重置） | 不变 | 不变 |
| onNavigationCommitted | → 0.6, 切换伪进度阶段 | 不变 | 不变（commit 不清除慢加载提示） |
| onLoadFinished(true) | → 1.0（300ms 后渐隐→0） | → nil | → false |
| onNavigationFailed (ERR_ABORTED) | → 0.0 | 不设置（不显示错误页） | → false |
| onNavigationFailed (其他) | → 0.0 | → NavigationError(...) | → false |
| pageInfo.isLoading=false | isLoading = false | 不变 | 不变 |

**关键: 每次 await Task.sleep 后校验 navigationId**:
```swift
func startFakeProgress(navigationId: Int64) {
    fakeProgressTask?.cancel()
    slowLoadingTask?.cancel()
    currentNavigationId = navigationId
    navigationError = nil  // 清除旧错误
    loadingProgress = 0.1
    isSlowLoading = false

    fakeProgressTask = Task { @MainActor in
        while !Task.isCancelled && loadingProgress < 0.5 {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, currentNavigationId == navigationId else { return }
            loadingProgress += 0.02
        }
    }
    slowLoadingTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, currentNavigationId == navigationId else { return }
        if isLoading { isSlowLoading = true }
    }
}
```

#### BrowserViewModel.registerAllCallbacks 扩展

**Tab 路由说明**: 当前 OWL 是单 tab 架构（`tabs` 数组始终只有 1 个元素），`activeTab` 即唯一 tab。所有回调均使用 `vm.activeTab`，与现有 PageInfo/RenderSurface/Zoom 回调一致。若未来支持多 tab，需改为按 webview_id 路由。

```swift
// 在 registerAllCallbacks(_:) 中追加:
OWLBridge_SetNavigationStartedCallback(wvId, { navId, url, userInit, redirect, ctx in
    let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
    let urlStr = String(cString: url!)
    Task { @MainActor in
        guard let tab = vm.activeTab else { return }
        if redirect != 0 {
            tab.onNavigationRedirected(navigationId: navId, url: urlStr)
        } else {
            tab.onNavigationStarted(navigationId: navId, url: urlStr,
                                    isUserInitiated: userInit != 0)
        }
    }
}, Unmanaged.passUnretained(self).toOpaque())

OWLBridge_SetNavigationCommittedCallback(wvId, { navId, url, status, ctx in
    let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
    let urlStr = String(cString: url!)
    Task { @MainActor in
        guard let tab = vm.activeTab else { return }
        tab.onNavigationCommitted(navigationId: navId, url: urlStr, httpStatus: status)
    }
}, Unmanaged.passUnretained(self).toOpaque())

OWLBridge_SetNavigationErrorCallback(wvId, { navId, url, code, desc, ctx in
    let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
    let urlStr = String(cString: url!)
    let descStr = String(cString: desc!)
    Task { @MainActor in
        guard let tab = vm.activeTab else { return }
        tab.onNavigationFailed(navigationId: navId, url: urlStr,
                               errorCode: code, errorDescription: descStr)
    }
}, Unmanaged.passUnretained(self).toOpaque())
```

**Callback unregister**: 在 `BrowserViewModel.disconnect()` 中，对应 `OWLBridge_SetNavigation*Callback(wvId, nil, nil)` 将 callback 置空。这与现有 PageInfo/RenderSurface 的 teardown 模式一致（setter(nil) = unregister）。

### 4. SwiftUI 组件

#### ProgressBar (新文件)
```swift
struct ProgressBar: View {
    let progress: Double
    @State private var fadeOpacity: Double = 1.0
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(OWL.accentPrimary)
                .frame(width: geo.size.width * progress, height: 2)
                .opacity(fadeOpacity)
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(height: 2)
        .onChange(of: progress) { _, newValue in
            if newValue >= 1.0 {
                withAnimation(.easeOut(duration: 0.3)) { fadeOpacity = 0 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { fadeOpacity = 1.0 }
                }
            } else if newValue > 0 {
                fadeOpacity = 1.0
            }
        }
        .accessibilityLabel("页面加载进度")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}
```

#### AddressBarView 修改
```swift
// 在 .clipShape() 之后、focus .overlay() 之前插入:
.overlay(alignment: .bottom) {
    if let tab = activeTab, tab.loadingProgress > 0 {
        ProgressBar(progress: tab.loadingProgress)
    }
}
```

#### ErrorPageView 扩展
```swift
struct ErrorPageView: View {
    var title: String = "无法连接到浏览器引擎"
    var message: String
    var onRetry: (() -> Void)? = nil
    // 🆕 新增参数
    var errorCode: Int? = nil
    var suggestion: String? = nil
    var onGoBack: (() -> Void)? = nil
    var showRetry: Bool = true
    // body 中根据 showRetry/onGoBack 条件渲染按钮
}
```

#### SlowLoadingBanner (新文件)
```swift
struct SlowLoadingBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill").font(.system(size: 12))
            Text("加载较慢...").font(OWL.captionFont)
        }
        .foregroundColor(OWL.warning)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .background(OWL.warning.opacity(0.15))
    }
}
```

#### ContentAreaView 修改
```swift
// 替换现有 TabContentView 的条件分支:
// 错误页面显示条件: navigationError 非空、非 ERR_ABORTED、且 navigationId 匹配当前导航
if let error = tab.navigationError,
   !error.isAborted,
   error.navigationId == tab.currentNavigationId {
    ErrorPageView(title: error.localizedTitle,
                  message: error.localizedMessage,
                  onRetry: { tab.reload() },
                  errorCode: Int(error.errorCode),
                  suggestion: error.suggestion,
                  onGoBack: { if tab.canGoBack { tab.goBack() } else { tab.navigate(to: "about:blank") } },
                  showRetry: !error.requiresGoBack)
} else if tab.isWelcomePage { ... }
else if tab.hasRenderSurface { ... }
// navigationError 清除时机: onNavigationStarted(redirect=false) 设 nil → ErrorPageView 自动消失

// overlay 替换现有 FindBarView 位置:
.overlay(alignment: .top) {
    VStack(spacing: 0) {
        if tab.isFindBarVisible { FindBarView(...) }
        if tab.isSlowLoading {
            SlowLoadingBanner()
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
```

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `bridge/owl_bridge_api.h` | 修改 | 3 个 callback typedef + 3 个 setter |
| `bridge/owl_bridge_api.cc` | 修改 | 3 个 Observer 方法实现（替换 Phase 1 stub）+ state 字段 |
| `owl-client-app/Models/NavigationEvent.swift` | 新增 | NavigationError model（NavigationEventRing 推迟到 Phase 4） |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | loadingProgress + navigationError + isSlowLoading + 伪进度 Task + 状态转移 |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | registerAllCallbacks 扩展 3 个新回调 + disconnect unregister |
| `owl-client-app/Views/Shared/ProgressBar.swift` | 新增 | 进度条组件 |
| `owl-client-app/Views/TopBar/AddressBarView.swift` | 修改 | ProgressBar overlay |
| `owl-client-app/Views/Content/ErrorPageView.swift` | 修改 | 扩展参数（errorCode, suggestion, onGoBack, showRetry） |
| `owl-client-app/Views/Content/ContentAreaView.swift` | 修改 | ErrorPageView 条件 + SlowLoadingBanner overlay VStack |
| `owl-client-app/Views/Content/SlowLoadingBanner.swift` | 新增 | 慢加载提示组件 |

### 6. 测试策略

Phase 2 主要是 UI 层，测试重点:
- **Swift ViewModel 单元测试**: NavigationError model 的 localizedTitle/requiresGoBack 逻辑
- **NavigationEventRing**: 环形缓冲区的 append/recent/overflow
- **Pipeline test**: 启动 OWL → 导航 → 验证进度条出现/消失、错误页面显示
- **编译验证**: build_all.sh 全量构建通过

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| ProgressBar overlay 位置错误（被 clipShape 裁切或被 focus stroke 遮挡） | 严格按 modifier 链顺序：clipShape → progress overlay → focus overlay |
| 伪进度 Task 泄漏（tab 销毁后 Task 仍运行） | Task.isCancelled 检查 + 每次 await 后校验 navigationId + deinit cancel |
| C-ABI 回调中字符串 lifetime | Block 值捕获 std::string（Clang Blocks 扩展保证 copy-construct） |
| ErrorPageView 参数扩展破坏现有使用方 | 所有新参数带默认值（nil/true），现有调用站点无需修改 |
| Callback ctx 悬空（BrowserViewModel 已释放但 dispatch block 仍引用） | disconnect() 中 setter(nil) unregister，与现有模式一致 |
| 旧 navigationError 残留覆盖新导航 | onNavigationStarted(redirect=false) 清 nil + ErrorPageView 绑定 navigationId |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
