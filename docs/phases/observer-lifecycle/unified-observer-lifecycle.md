# Unified Observer Lifecycle — 统一 Observer 推送管线

## 背景

当前三个功能（SSL SecurityIndicator、Permission UI、History 侧边栏）的 Host→Swift 推送管线存在系统性断裂。根因是 **没有统一的 callback 注册生命周期**，也没有强制 "Host 状态变更 → Observer 通知" 的架构约束。

### 现状诊断

| 功能 | Host 产生信号 | Mojo Observer 接口 | C-ABI Callback | Swift 响应式 | 断点 |
|------|:---:|:---:|:---:|:---:|------|
| PageInfo | OK | `OnPageInfoChanged` | `SetPageInfoCallback` | `@Published` | 全通（但每次 navigate 重复注册） |
| SSL | OK | `OnSecurityStateChanged` | `SetSecurityStateCallback` | `@Published` | callback 在 webview 创建前注册，被 null 守卫丢弃 |
| Permission | 缺失 | `OnPermissionRequest` | `SetPermissionRequestCallback` | `@Published` | Host `RequestPermissions()` 不调 observer |
| History | 缺失 | 无 | 无 | 仅 pull | 全链路缺失 |

### 第一性原则

1. **推送优于轮询** — 状态变更必须主动推送到 UI，不依赖 UI 侧定时拉取
2. **注册一次，全程有效** — callback 注册应与 webview 生命周期绑定，不随导航重复注册
3. **Host 是唯一真相源** — 所有状态变更从 Host 发起，经 Observer 单向流动到 Swift
4. **实例级绑定** — 通知通过 Chromium 原生寻址（`WebContents::FromRenderFrameHost`）路由到实例，禁止新增全局函数指针或全局 delegate
5. **信号与数据分离** — 推送通知仅作为"数据已变更"信号，UI 侧通过增量 pull 获取真实数据
6. **严格时序契约** — Swift 侧保证 WebView Ready 后才注册 callback；Bridge 层用 `DCHECK` 断言而非 pending 机制，倒逼时序正确

## 技术方案

### 1. 架构设计

#### 核心变更：WebView Ready 统一注册点 + Chromium 原生寻址

```
OWLBridge_CreateWebView 成功
  → WebView Ready callback
    → 统一注册所有 per-webview Observer callbacks
    → 注册 BrowserContext 级 Observer callbacks (History)

Permission 请求
  → OWLPermissionManager::RequestPermissions(rfh, ...)
    → WebContents::FromRenderFrameHost(rfh) 寻址到 RealWebContents
    → RealWebContents::NotifyPermissionRequest()
    → observer_->OnPermissionRequest(...)
```

#### 数据流（统一后）

**per-WebView 事件（PageInfo, SSL, Permission, Zoom, Find 等）**：
```
Host 状态变更
  → RealWebContents 实例方法（直接通过 observer_ 成员调用）
    → observer_->OnXxx(...)          [Mojo IPC, UI thread]
  → WebViewObserverImpl::OnXxx()     [Bridge C++, IO thread]
    → dispatch_async(main)
      → g_xxx_cb(...)                [C-ABI callback, main thread]
      → Task { @MainActor in }       [Swift, main actor]
        → @Published var xxx         [SwiftUI reactive]
```

**BrowserContext 级事件（History）**：
```
Host: HistoryServiceMojoAdapter::AddVisit 成功
  → history_observer_->OnHistoryChanged(url)    [Mojo IPC, Host→Bridge]
  → HistoryObserverImpl::OnHistoryChanged()     [Bridge C++, IO thread]
    → dispatch_async(main)
      → g_history_changed_cb(url)               [C-ABI callback, main thread]
      → HistoryViewModel.onHistoryChanged(url)  [Swift]
        → 增量 QueryByTime()                    [pull 权威数据]
```

#### 模块划分

| 模块 | 职责 | 变更类型 |
|------|------|---------|
| `owl_real_web_contents.mm` | Permission 通知（RFH 寻址 `FromWebContents` + `NotifyPermissionRequest()`） | 修改 |
| `host/owl_browser_context.cc` | `HistoryServiceMojoAdapter` 新增 `SetObserver` + 注入 `HistoryChangeCallback` | 修改 |
| `owl_permission_manager.cc` | `RequestPermissions()` 通过 RFH 寻址调用 `RealWebContents` 通知方法 | 修改 |
| `owl_history_service.h/cc` | 新增 `SetChangeCallback(HistoryChangeCallback)`；AddVisit 成功后调用 callback | 修改 |
| `history.mojom` | 新增 `HistoryObserver` 接口 + `HistoryService.SetObserver` | 修改 |
| `owl_bridge_api.h/cc` | 新增 `SetHistoryChangedCallback`；`SetSecurityStateCallback` 改用 `DCHECK` | 修改 |
| `BrowserViewModel.swift` | 将所有 callback 注册移到 WebView Ready 回调后 | 修改 |
| `TabViewModel.swift` | `navigate()` 不再重复注册 PageInfo/RenderSurface callback | 修改 |
| `HistoryViewModel.swift` | 收到 "history changed" 信号后增量查询 | 修改 |

### 2. 数据模型

无 schema 变更。History 的 `HistoryEntry` 结构不变。推送通知只携带信号（url），UI 侧通过现有 `QueryByTime` 获取完整数据。

### 3. 接口设计

#### 3.1 Mojom 变更

**`history.mojom` — 新增 HistoryObserver 接口 + HistoryService.SetObserver：**

```mojom
// Observer for history data changes (BrowserContext-level, not per-webview).
interface HistoryObserver {
  // A visit was added or updated. url identifies the affected entry.
  // UI should re-query to get the authoritative HistoryEntry.
  OnHistoryChanged(string url);
};

interface HistoryService {
  // ... existing methods unchanged ...

  // Register a history change observer. At most one observer per service.
  // Replaces any previously registered observer.
  SetObserver(pending_remote<HistoryObserver> observer);
};
```

选择在 `HistoryService` 内而非 `BrowserContextHost` 的理由：
- Observer 订阅逻辑属于 `HistoryService` 业务领域，保持单一职责闭环
- 与 `HistoryService` 的 CRUD 方法同级，调用方通过同一个 Mojo remote 管理
- `BrowserContextHost` 只负责创建/获取 service，不应越俎代庖管理 service 内部 observer

**`browser_context.mojom` — 不变。**

**`web_view.mojom` — 不变。**

`WebViewObserver` 保持现有接口不变。Permission 通知 `OnPermissionRequest` 已定义在其中（正确：权限弹窗需要绑定到触发它的 WebView/Tab）。

#### 3.2 C-ABI 变更

**`owl_bridge_api.h` 新增：**

```c
// History changed callback (BrowserContext-level).
// url: the URL that was added/updated. UI should re-query for full data.
typedef void (*OWLBridge_HistoryChangedCallback)(
    const char* url, void* context);
OWL_EXPORT void OWLBridge_SetHistoryChangedCallback(
    OWLBridge_HistoryChangedCallback callback,
    void* callback_context);
```

**`owl_bridge_api.cc` — SecurityState DCHECK 契约：**

```cpp
void OWLBridge_SetSecurityStateCallback(uint64_t webview_id,
    OWLBridge_SecurityStateCallback callback, void* ctx) {
    DCHECK(*g_webview) << "SetSecurityStateCallback called before webview ready. "
                       << "Caller must wait for CreateWebView callback.";
    (*g_webview)->security_state_cb = callback;
    (*g_webview)->security_state_ctx = ctx;
}
```

选择 `DCHECK` 而非 pending 机制的理由：
- Swift 侧已保证在 WebView Ready 后才注册所有 callback（§4.3）
- pending 机制引入额外全局可变状态，在多标签场景下会导致数据竞争
- `DCHECK` 在 debug build 中崩溃，倒逼调用方遵守时序契约，比 pending 更安全
- 符合 Chromium 风格：前置条件用 DCHECK 断言，不用隐式容错

#### 3.3 Host 内部变更

**不新增全局函数指针，不新增 delegate 接口。** 使用 Chromium 原生寻址：

**Permission 通知 — RFH 寻址模式：**

```cpp
// owl_permission_manager.cc — RequestPermissions() 内部：
void OWLPermissionManager::RequestPermissions(
    content::RenderFrameHost* rfh,
    const content::PermissionRequestDescription& desc,
    base::OnceCallback<void(...)> callback) {
  // ... 存储 PendingRequest ...

  // 通过 Chromium 原生 API 寻址到 RealWebContents
  auto* web_contents = content::WebContents::FromRenderFrameHost(rfh);
  auto* real_wc = RealWebContents::FromWebContents(web_contents);
  if (real_wc) {
    real_wc->NotifyPermissionRequest(origin_str, type_int, request_id);
  }
}
```

```cpp
// owl_real_web_contents.mm — RealWebContents 新增：
void RealWebContents::NotifyPermissionRequest(
    const std::string& origin, int type, uint64_t request_id) {
  if (observer_) {
    (*observer_)->OnPermissionRequest(
        origin, static_cast<owl::mojom::PermissionType>(type), request_id);
  }
}

// 寻址：当前单 WebView 阶段，通过现有 g_real_web_contents 全局指针实现
static RealWebContents* FromWebContents(content::WebContents* wc) {
  DCHECK(g_real_web_contents);
  DCHECK_EQ(g_real_web_contents->web_contents(), wc);
  return g_real_web_contents;
}
```

**`FromWebContents` 实现策略**：

当前阶段（单 WebView）：通过已有的 `g_real_web_contents` 全局指针实现，加 `DCHECK` 验证 `wc` 匹配。不引入 `WebContentsUserData`，避免与现有全局指针产生双重所有权冲突。

Module H 阶段（多 WebView）：迁移到 `WebContentsUserData<RealWebContents>` 模式，`g_real_web_contents` 全局指针同步移除。此时每个 tab 的 `RealWebContents` 通过 `content::WebContents::SetUserData` 绑定，`FromWebContents` 自然路由到正确实例。

选择 RFH 寻址而非 delegate 的理由：
- `OWLPermissionManager` 在 BrowserContext 创建时构造，此时 `RealWebContents` 尚不存在 → 构造函数注入不可行
- `WebContents::FromRenderFrameHost(rfh)` 是 Chromium 标准寻址方式
- **多标签就绪**：寻址接口（`FromWebContents`）不变，只需替换内部实现
- 无需引入任何新接口，`OWLPermissionManager` 构造函数签名不变

**History 通知 — `OWLHistoryService` ChangeCallback + Bridge 侧 `HistoryObserverImpl`：**

History 推送**不经过 `RealWebContents`**。`HistoryObserver` 是 BrowserContext 级事件，与 WebView 无关。

**推送路径**：

```
OWLHistoryService::AddVisit 成功（UI 线程 callback）
  → change_callback_(url)                      [OWLHistoryService 内部]
  → HistoryServiceMojoAdapter 转发到 observer
    → history_observer_->OnHistoryChanged(url)  [Mojo IPC, Host→Bridge]
  → HistoryObserverImpl::OnHistoryChanged(url)  [Bridge C++, IO thread]
    → dispatch_async(main)
      → g_history_changed_cb(url)               [C-ABI callback, main thread]
      → Swift HistoryViewModel.onHistoryChanged  [Swift @MainActor]
```

**Host 侧变更**：

```cpp
// owl_history_service.h 新增：
using HistoryChangeCallback = base::RepeatingCallback<void(const std::string& url)>;
void SetChangeCallback(HistoryChangeCallback callback);

// owl_history_service.cc — AddVisit 成功后在 UI 线程调用：
if (success && change_callback_) {
  change_callback_.Run(url);
}
```

```cpp
// host/owl_browser_context.cc — HistoryServiceMojoAdapter：

// 构造时注入 change_callback，转发到 Mojo observer：
HistoryServiceMojoAdapter(...) {
  history_service_->SetChangeCallback(
      base::BindRepeating(&HistoryServiceMojoAdapter::OnHistoryChanged,
                          weak_factory_.GetWeakPtr()));
}

void OnHistoryChanged(const std::string& url) {
  if (history_observer_.is_bound()) {
    history_observer_->OnHistoryChanged(url);
  }
}

// SetObserver 实现：
void SetObserver(mojo::PendingRemote<owl::mojom::HistoryObserver> observer) override {
  history_observer_.Bind(std::move(observer));
}

mojo::Remote<owl::mojom::HistoryObserver> history_observer_;
```

**Bridge 侧**：

```cpp
// bridge/owl_bridge_api.cc：

// 1. C-ABI callback 存储（BrowserContext 级，非 per-webview）
static OWLBridge_HistoryChangedCallback g_history_changed_cb = nullptr;
static void* g_history_changed_ctx = nullptr;

void OWLBridge_SetHistoryChangedCallback(
    OWLBridge_HistoryChangedCallback callback, void* ctx) {
  g_history_changed_cb = callback;
  g_history_changed_ctx = ctx;
}

// 2. HistoryObserverImpl（与 WebViewObserverImpl 平行）
class HistoryObserverImpl : public owl::mojom::HistoryObserver {
  void OnHistoryChanged(const std::string& url) override {
    if (!g_history_changed_cb) return;
    std::string url_copy = url;
    dispatch_async(dispatch_get_main_queue(), ^{
      g_history_changed_cb(url_copy.c_str(), g_history_changed_ctx);
    });
  }
};

// 3. OWLBridge_CreateBrowserContext 成功后，获取 HistoryService 时：
//    history_service_remote->SetObserver(observer_impl.BindNewPipeAndPassRemote())
```

**设计要点**：
- `OWLHistoryService` 通过 `HistoryChangeCallback` 通知，不感知 Mojo/observer（保持单一职责）
- `HistoryServiceMojoAdapter` 是 callback → observer 的转接层
- 无论 `AddVisit` 来自 Mojo 路径还是 `g_owl_history_service` 直接调用，都会触发通知
- `RealWebContents` 不需要任何 history 相关成员变量

**`history_observer_` 生命周期**：
- 类型：`mojo::Remote<owl::mojom::HistoryObserver>`，存储在 `HistoryServiceMojoAdapter` 中
- 绑定方式：Bridge 调用 `HistoryService::SetObserver` → `HistoryServiceMojoAdapter::SetObserver`
- 生命周期：与 `HistoryServiceMojoAdapter` 共存亡（BrowserContext 级）
- 多标签安全：BrowserContext 级全局唯一，任何 tab 的导航都会触发通知

### 4. 核心逻辑

#### 4.1 Permission 通知

```
OWLPermissionManager::RequestPermissions(rfh, request_description, callback)
  → 检查存储状态
  → 对每个 ASK 状态的 permission:
      存储 PendingRequest(request_id, callback)
      auto* wc = WebContents::FromRenderFrameHost(rfh)
      auto* real_wc = RealWebContents::FromWebContents(wc)
      if (real_wc)
        real_wc->NotifyPermissionRequest(origin_str, type_int, request_id)
      // 启动 30s 超时自动 deny
```

**时序安全性**：
- `RequestPermissions` 由 Chromium 内容层调用，传入 `RenderFrameHost*`
- RFH 存在 → WebContents 必然存在 → RealWebContents 必然已绑定
- 无需任何注入时序管理，Chromium 原生 API 保证安全
- **多标签原生支持**：不同 tab 的 RFH 自然路由到不同 RealWebContents

#### 4.2 History 推送

History 推送路径完全在 Host（MojoAdapter）+ Bridge 层闭环，不经过 `RealWebContents`：

```
RealWebContents::DidFinishNavigation(handle)
  → g_owl_history_service->AddVisit(url, title, log_callback)
  → [RealWebContents 职责到此为止]

HistoryServiceMojoAdapter::AddVisit(url, title) [Mojo 调用]
  → OWLHistoryService::AddVisit(url, title, callback)
  → DB 线程写入 → PostTask 回 UI 线程
  → callback(success):
      if (success && history_observer_.is_bound())
        history_observer_->OnHistoryChanged(url)  [通知 Bridge]

Bridge: HistoryObserverImpl::OnHistoryChanged(url)
  → dispatch_async(main) → g_history_changed_cb(url) → Swift
```

**关键设计**：`DidFinishNavigation` 调用的 `AddVisit` 是通过全局 `g_owl_history_service` 指针直接调用 `OWLHistoryService`，而 Mojo 路径的 `HistoryServiceMojoAdapter::AddVisit` 也最终调用同一个 `OWLHistoryService`。通知由 `HistoryServiceMojoAdapter` 在 Mojo response path 触发，无论 AddVisit 的来源是什么。

**信号 vs 数据**：`OnHistoryChanged` 只携带 `url`（标识哪条记录变了），不携带完整 `HistoryEntry`。理由：
- `AddVisit` 对已有 URL 是 UPDATE（递增 visit_count），对新 URL 是 INSERT
- UI 侧无法仅凭 `url` 正确构造完整 `HistoryEntry`（缺 visitCount、lastVisitTime）
- 推送信号 + 增量 pull 保证 UI 数据始终与 DB 一致

**注意**：`RealWebContents::DidFinishNavigation` 直接调用 `g_owl_history_service->AddVisit`（非 Mojo 路径），此路径不经过 `HistoryServiceMojoAdapter`，因此 observer 不会被触发。需要修改 `DidFinishNavigation` 改为通过 Mojo pipe 调用 `HistoryService::AddVisit`，或在 `OWLHistoryService` 内部添加通知回调。推荐后者（在 `OWLHistoryService::AddVisit` 的 callback 中，由调用方 `RealWebContents` 通知 observer）——但这又需要 `RealWebContents` 持有 observer 引用。

**最终决策**：`OWLHistoryService` 新增可选的 `HistoryChangeCallback`：

```cpp
// owl_history_service.h 新增：
using HistoryChangeCallback = base::RepeatingCallback<void(const std::string& url)>;
void SetChangeCallback(HistoryChangeCallback callback);

// AddVisit 成功后在 UI 线程调用 change_callback_(url)
```

`HistoryServiceMojoAdapter` 在构造时注入 callback，callback 内部调用 `history_observer_->OnHistoryChanged(url)`。这样无论 AddVisit 来自 Mojo 还是直接调用，observer 都会被触发。`OWLHistoryService` 不感知 Mojo 或 observer——它只调一个简单的 callback。

#### 4.3 统一注册时序

```swift
// BrowserViewModel.swift — handleHostLaunched 内部

OWLBridge_CreateWebView(ctxId) { wvId, errMsg, ctx in
    Task { @MainActor in
        vm.webviewId = wvId

        // === Phase 1: 注册所有 per-webview callbacks（注册一次，全程有效） ===
        vm.registerPageInfoCallback(wvId)      // 从 TabViewModel.navigate 移来
        vm.registerRenderSurfaceCallback(wvId)  // 从 TabViewModel.navigate 移来
        SSLBridge.shared.register(webviewId: wvId, securityVM: vm.securityVM)
        vm.registerZoomChangedCallback(wvId)
        vm.registerFindResultCallback(wvId)
        vm.registerInputCallbacks(wvId)         // UnhandledKey, Cursor, Caret

        // === Phase 2: 注册 BrowserContext 级 callbacks ===
        HistoryBridge.shared.register(historyVM: vm.historyVM)
        // PermissionRequestCallback 是全局的（非 per-webview），
        // 在 initializeAndLaunch 中注册仍安全（不依赖 g_webview）

        vm.connectionState = .connected
    }
}
```

**时序保证**：`Task { @MainActor in }` 块内所有代码串行执行。callback 注册在最前，`connectionState = .connected` 在最后。首次 `navigate()` 只可能在 `.connected` 之后被 UI 触发。因此 callback 注册必然早于首次导航。

#### 4.4 TabViewModel.navigate() 精简

```swift
// Before: 每次 navigate 都注册 PageInfo + RenderSurface callback
// After: navigate 只负责导航，callback 已在 WebView Ready 时注册

func navigate(to input: String) {
    // ... URL 处理 ...
    urlStr.withCString { cStr in
        OWLBridge_Navigate(webviewId, cStr, { success, status, errMsg, ctx in
            // Navigation initiated — updates via pre-registered callbacks
        }, nil)
    }
}
```

#### 4.5 HistoryViewModel 信号驱动刷新

```swift
// HistoryViewModel.swift — 推送信号接收

private var refreshTask: Task<Void, Never>?

func onHistoryChanged(url: String) {
    // Debounce: 取消上一个未完成的查询，只保留最新的
    refreshTask?.cancel()
    refreshTask = Task {
        // 短暂延迟聚合连续信号
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }

        // 增量查询最新数据（权威数据来自 DB）
        let result = await OWLHistoryBridge.queryByTime(
            query: "", maxResults: displayPageSize, offset: 0)
        self.entries = result.entries
        self.totalCount = result.total
    }
}
```

#### 4.6 SSLBridge — DCHECK 契约

```cpp
// owl_bridge_api.cc
void OWLBridge_SetSecurityStateCallback(uint64_t webview_id,
    OWLBridge_SecurityStateCallback callback, void* ctx) {
    DCHECK(*g_webview) << "SetSecurityStateCallback called before webview ready";
    if (!*g_webview) return;  // release 安全网
    (*g_webview)->security_state_cb = callback;
    (*g_webview)->security_state_ctx = ctx;
}
```

Swift 侧对应修改：`SSLBridge.register(webviewId:securityVM:)` 只在 WebView Ready 回调内调用（§4.3），不再在 `initializeAndLaunch` 中提前注册。

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `host/owl_real_web_contents.mm` | 修改 | 新增 `NotifyPermissionRequest()` + `FromWebContents()` 静态方法（通过 `g_real_web_contents` + DCHECK 实现） |
| `host/owl_permission_manager.cc` | 修改 | `RequestPermissions()` 通过 `WebContents::FromRenderFrameHost` + `RealWebContents::FromWebContents` 寻址并调用通知 |
| `host/owl_permission_manager.h` | 不变 | 无需新增 delegate 接口，构造函数签名不变 |
| `host/owl_browser_context.cc` | 修改 | `HistoryServiceMojoAdapter` 新增 `SetObserver` + 注入 `HistoryChangeCallback` |
| `host/owl_history_service.h/cc` | 修改 | 新增 `SetChangeCallback(HistoryChangeCallback)`；AddVisit 成功后调用 callback |
| `mojom/history.mojom` | 修改 | 新增 `HistoryObserver` 接口；`HistoryService` 新增 `SetObserver` 方法 |
| `mojom/browser_context.mojom` | 不变 | `BrowserContextHost` 不介入 observer 管理 |
| `bridge/owl_bridge_api.h` | 修改 | 新增 `OWLBridge_SetHistoryChangedCallback` 类型和函数 |
| `bridge/owl_bridge_api.cc` | 修改 | 实现 `HistoryObserver` Mojo 绑定 + `SetHistoryChangedCallback` C-ABI 转发；`SetSecurityStateCallback` 改用 `DCHECK` |
| `bridge/OWLBridgeWebView.mm` | 不变 | History 走独立 observer，不经过 `WebViewObserverBridge` |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | callback 注册移到 `CreateWebView` 回调内 |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | `navigate()` 去掉 PageInfo/RenderSurface callback 注册 |
| `owl-client-app/Services/SSLBridge.swift` | 修改 | `register()` 接受 `webviewId` 参数；移除 `initializeAndLaunch` 中的提前注册 |
| `owl-client-app/Services/HistoryBridge.swift` | 新增 | 封装 `SetHistoryChangedCallback` 注册 + 信号转发到 HistoryViewModel |
| `owl-client-app/ViewModels/HistoryViewModel.swift` | 修改 | 新增 `onHistoryChanged()` 信号驱动刷新方法 + debounce |

### 6. 测试策略

#### 单元测试

| 测试 | 覆盖点 |
|------|--------|
| `owl_permission_manager_unittest.cc` | `RequestPermissions()` 通过 RFH 寻址调用 `NotifyPermissionRequest`；mock `RealWebContents::FromWebContents` 验证路由 |
| `owl_bridge_permission_unittest.mm` | `WebViewObserverImpl::OnPermissionRequest` 正确转发到 C-ABI callback |
| `owl_bridge_web_view_unittest.mm` | `SetSecurityStateCallback` 在 webview ready 后正常挂载；debug build 中 webview 未 ready 时 DCHECK 触发 |
| `HistoryViewModelTests.swift` | `onHistoryChanged()` 触发增量查询；快速连续信号 debounce 只发一次查询 |
| `SecurityViewModelTests.swift` | 注册时序正确（mock 模式验证 updateSecurityState 被调用） |
| `PermissionViewModelTests.swift` | 完整 request → alert → respond 流程 |

#### 集成测试

| 测试 | 覆盖点 |
|------|--------|
| Pipeline test | 导航到 HTTPS 页面后 SecurityViewModel.level == .secure |
| Pipeline test | 历史侧边栏打开状态下导航新页面，列表自动刷新 |

#### Mock 策略

- ViewModel 单元测试通过 `MockConfig` 注入，不依赖 Host
- Bridge 层单元测试通过 `FakeWebViewObserver` 验证 Mojo 消息
- `FakeWebViewObserver` 不受影响（`WebViewObserver` 接口未变）
- 新增 `FakeHistoryObserver` 用于 History 推送测试

### 7. 风险 & 缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| callback 注册移到 WebView Ready 后，首次导航可能在注册完成前发起 | 丢失首次 PageInfo/RenderSurface | 统一注册后再 navigate，`Task { @MainActor in }` 块内串行保证 |
| DCHECK 在 release build 中不生效 | release 中时序错误静默失败 | `DCHECK` 后紧跟 `if (!*g_webview) return;` 作为 release 安全网 |
| History 信号触发频繁查询 | 性能压力 | 100ms debounce + HistoryService 30s dedupe 窗口 |
| `RealWebContents::FromWebContents` 在 WebContents 销毁后返回 null | 权限请求被忽略 | RFH 存在 → WebContents 必然存在；30s 超时兜底 auto-deny |
| `history_observer_` remote 在 BrowserContext 销毁时断开 | History UI 停止更新 | BrowserContext 销毁时整个 app 关闭，无影响 |

### 8. 技术债声明

以下设计决策在当前单 WebView 架构下是正确的，但 Module H（多标签增强）需要重新审视：

1. **`OWLBridge_SetPermissionRequestCallback` 全局 callback（无 webview_id）** — 多 WebView 时需改为 per-webview，以便 UI 将弹窗锚定到正确 tab
2. **per-webview callback 硬编码 webview_id=1** — 多 WebView 时需要 callback 路由表
3. **History observer 通过 BrowserContext 全局注册** — 多 WebView 无影响（正确设计，History 是全局状态）
4. **Permission 通知已原生支持多标签** — `WebContents::FromRenderFrameHost` 自然路由到正确实例，Module H 无需额外改动
