# Phase 3: History 推送管线

## 目标
- History 侧边栏在打开状态下实时刷新（导航新页面后 < 1s 自动更新）
- 侧边栏关闭时忽略推送信号，打开时主动 pull 最新数据
- 全栈推送管线：Host `AddVisit` 成功 → `HistoryChangeCallback` → Mojo Observer → Bridge C-ABI → Swift 信号驱动增量查询

## 范围

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/history.mojom` | 修改 | 新增 `HistoryObserver` 接口 + `HistoryService.SetObserver` 方法 |
| `host/owl_history_service.h` | 修改 | 新增 `HistoryChangeCallback` 类型 + `SetChangeCallback` 方法 |
| `host/owl_history_service.cc` | 修改 | AddVisit 成功后在 UI 线程调用 `change_callback_` |
| `host/owl_browser_context.cc` | 修改 | `HistoryServiceMojoAdapter` 新增 `SetObserver` + 构造时注入 `HistoryChangeCallback` |
| `bridge/owl_bridge_api.h` | 修改 | 新增 `OWLBridge_SetHistoryChangedCallback` 类型和函数 |
| `bridge/owl_bridge_api.cc` | 修改 | 新增 `HistoryObserverImpl` + `SetHistoryChangedCallback` C-ABI；`CreateBrowserContext` 后绑定 observer |
| `owl-client-app/Services/HistoryBridge.swift` | **新增** | 封装 `SetHistoryChangedCallback` 注册 + 信号转发到 HistoryViewModel |
| `owl-client-app/ViewModels/HistoryViewModel.swift` | 修改 | 新增 `onHistoryChanged(url:)` 信号驱动刷新 + 100ms debounce |
| `owl-client-app/Views/Sidebar/HistorySidebarView.swift` | 修改 | `onAppear` 时主动 pull；非可见状态忽略信号 |

## 依赖
- 无前置依赖（独立链路）

## 技术要点

### 关键路径说明
`RealWebContents::DidFinishNavigation` 直接调用 `g_owl_history_service->AddVisit`（非 Mojo 路径）。因此 `HistoryServiceMojoAdapter` 的 Mojo response 不会触发通知。解决方案：`OWLHistoryService` 新增 `SetChangeCallback`，由 `HistoryServiceMojoAdapter` 在构造时注入。任何路径的 AddVisit 成功都会触发 callback。

### Observer 注册时序
`HistoryService::SetObserver` 必须在 `CreateBrowserContext` 成功后立即注册（在 Bridge 层 `OWLBridge_CreateBrowserContext` 获取 HistoryService remote 时同步绑定），早于任何 `AddVisit` 调用。

### 信号与数据分离
`OnHistoryChanged(url)` 只携带 URL 信号。Swift 侧通过 `QueryByTime` 获取权威数据，不直接构造 `HistoryEntry`。

### 线程职责
Host `ChangeCallback` 在 UI 线程触发 → Mojo IPC → Bridge IO 线程 → `dispatch_async(main)` → Swift main thread

### Debounce
100ms Task cancel/replace，连续导航只触发一次查询

## 验收标准
- [ ] `history.mojom` 包含 `HistoryObserver` 接口和 `HistoryService.SetObserver` 方法
- [ ] `OWLHistoryService::AddVisit` 成功后调用 `change_callback_`
- [ ] `HistoryServiceMojoAdapter` 构造时注入 callback 并实现 `SetObserver`
- [ ] Bridge `HistoryObserverImpl::OnHistoryChanged` 正确转发到 C-ABI callback
- [ ] `HistoryBridge.swift` 存在并正确注册 callback + 转发信号
- [ ] `HistoryViewModel.onHistoryChanged(url:)` 触发增量 `QueryByTime`
- [ ] 100ms 内连续 3 次信号只触发 1 次查询（debounce 测试）
- [ ] 侧边栏关闭时不触发查询；重新打开时看到最新数据
- [ ] 所有现有 unit/cpp 测试通过
- [ ] `FakeWebViewObserver` 不受影响（`WebViewObserver` 接口未变）

## 技术方案

> 父方案: `docs/phases/observer-lifecycle/unified-observer-lifecycle.md` §4.2

### 1. 架构设计

全栈推送管线，6 层变更：

```
Host: OWLHistoryService.AddVisit 成功
  → change_callback_(url)                          [UI thread]
  → HistoryServiceMojoAdapter.OnHistoryChanged(url) [UI thread]
  → history_observer_->OnHistoryChanged(url)        [Mojo IPC]
Bridge: HistoryObserverImpl::OnHistoryChanged(url)  [IO thread]
  → dispatch_async(main)
  → g_history_changed_cb(url)                       [main thread]
Swift: HistoryBridge → HistoryViewModel.onHistoryChanged(url)
  → 100ms debounce → QueryByTime() → entries 更新
```

### 2. 接口设计

**Mojom（history.mojom）**：
```mojom
interface HistoryObserver {
  OnHistoryChanged(string url);
};

interface HistoryService {
  // ... existing methods ...
  SetObserver(pending_remote<HistoryObserver> observer);
};
```

**C++ Host（owl_history_service.h）**：
```cpp
using HistoryChangeCallback = base::RepeatingCallback<void(const std::string& url)>;
void SetChangeCallback(HistoryChangeCallback callback);
```

**C-ABI（owl_bridge_api.h）**：
```c
typedef void (*OWLBridge_HistoryChangedCallback)(const char* url, void* context);
OWL_EXPORT void OWLBridge_SetHistoryChangedCallback(
    OWLBridge_HistoryChangedCallback callback, void* callback_context);
```

### 3. 核心逻辑

**3.1 Host: OWLHistoryService 新增 ChangeCallback**

```cpp
// owl_history_service.h 新增成员:
HistoryChangeCallback change_callback_;

// owl_history_service.cc:
void OWLHistoryService::SetChangeCallback(HistoryChangeCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  change_callback_ = std::move(callback);
}

// AddVisitOnDbThread 的 callback 回到 UI 线程后:
// (在现有 PostTask 回 UI 线程的 callback 中)
if (success && change_callback_) {
  change_callback_.Run(url);
}
```

**3.2 Host: ChangeCallback 在 OWLBrowserContext 首次创建 HistoryService 时注入（不在 adapter 中）**

关键设计：`SetChangeCallback` 在 `GetHistoryServiceRaw()` 中首次创建 `OWLHistoryService` 时一次性注入，而非在每个 `HistoryServiceMojoAdapter` 构造函数中。这避免了 `GetHistoryService` 创建新 adapter 时覆写 callback 的问题。

```cpp
// owl_browser_context.cc — GetHistoryServiceRaw() 修改:
OWLHistoryService* OWLBrowserContext::GetHistoryServiceRaw() {
  if (!history_service_) {
    // ... 创建 history_service_ ...
    g_owl_history_service = history_service_.get();
    
    // 一次性注入 ChangeCallback（由 BrowserContext 持有的 history_observer_ 转发）
    history_service_->SetChangeCallback(base::BindRepeating(
        &OWLBrowserContext::OnHistoryChanged,
        weak_factory_.GetWeakPtr()));
  }
  return history_service_.get();
}

// OWLBrowserContext 新增:
void OWLBrowserContext::OnHistoryChanged(const std::string& url) {
  if (history_observer_.is_bound()) {
    history_observer_->OnHistoryChanged(url);
  }
}
```

```cpp
// owl_browser_context.h — OWLBrowserContext 新增成员:
mojo::Remote<owl::mojom::HistoryObserver> history_observer_;
// weak_factory_ 已存在（或新增）
```

```cpp
// HistoryServiceMojoAdapter 保持简单 — 不注入 callback:
// 新增 SetObserver 只是将 observer remote 转发到 OWLBrowserContext
void SetObserver(mojo::PendingRemote<owl::mojom::HistoryObserver> observer) override {
  // 将 observer 存储到 BrowserContext（非 adapter）
  context_->history_observer_.Bind(std::move(observer));
}
```

**为什么 callback 在 BrowserContext 而非 adapter**：
- `GetHistoryService` 每次被调用都创建新 adapter（重新绑定 Mojo pipe），但 `OWLHistoryService` 是唯一实例
- 如果在 adapter 构造时注入 callback，新 adapter 会覆写旧 callback，旧 adapter 的 observer 被孤立
- 将 callback 和 observer remote 都放在 `OWLBrowserContext`（生命周期覆盖整个 session），确保不会被覆写

**3.3 Bridge: HistoryObserverImpl + C-ABI**

```cpp
// owl_bridge_api.cc 新增:

// 全局 callback 存储
static OWLBridge_HistoryChangedCallback g_history_changed_cb = nullptr;
static void* g_history_changed_ctx = nullptr;

void OWLBridge_SetHistoryChangedCallback(
    OWLBridge_HistoryChangedCallback callback, void* ctx) {
  g_history_changed_cb = callback;
  g_history_changed_ctx = ctx;
}

// HistoryObserverImpl (与 WebViewObserverImpl 平行)
class HistoryObserverImpl : public owl::mojom::HistoryObserver {
 public:
  explicit HistoryObserverImpl(
      mojo::PendingReceiver<owl::mojom::HistoryObserver> receiver)
      : receiver_(this, std::move(receiver)) {}

  void OnHistoryChanged(const std::string& url) override {
    if (!g_history_changed_cb) return;
    // ObjC block 值捕获 std::string（block copy 会调 C++ copy constructor），
    // 保证 dispatch 异步执行时 c_str() 指向有效内存。
    // 与现有 SSL error callback 模式一致（owl_bridge_api.cc:542）。
    std::string url_copy = url;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (g_history_changed_cb) {
        g_history_changed_cb(url_copy.c_str(), g_history_changed_ctx);
      }
    });
  }

 private:
  mojo::Receiver<owl::mojom::HistoryObserver> receiver_;
};

// 在 OWLBridge_CreateBrowserContext 获取 HistoryService 后:
// 1. 创建 HistoryObserverImpl
// 2. 调用 history_service_remote->SetObserver(observer.BindNewPipeAndPassRemote())
```

**3.4 Swift: HistoryBridge.swift（新增）**

```swift
import Foundation
#if canImport(OWLBridge)
import OWLBridge
#endif

@MainActor
final class HistoryBridge {
    static let shared = HistoryBridge()
    private weak var historyVM: HistoryViewModel?

    func register(historyVM: HistoryViewModel) {
        self.historyVM = historyVM
        #if canImport(OWLBridge)
        OWLBridge_SetHistoryChangedCallback(historyChangedCallback, nil)
        #endif
    }

    fileprivate func forward(url: String) {
        historyVM?.onHistoryChanged(url: url)
    }
}

#if canImport(OWLBridge)
private func historyChangedCallback(url: UnsafePointer<CChar>?, ctx: UnsafeMutableRawPointer?) {
    let urlStr = url.map { String(cString: $0) } ?? ""
    Task { @MainActor in
        HistoryBridge.shared.forward(url: urlStr)
    }
}
#endif
```

**3.5 Swift: HistoryViewModel.onHistoryChanged（修改）**

```swift
// HistoryViewModel.swift 新增:
private var refreshTask: Task<Void, Never>?
package var isVisible: Bool = false  // 由 HistorySidebarView 设置

func onHistoryChanged(url: String) {
    guard isVisible else { return }  // 侧边栏关闭时忽略
    
    // Debounce: 取消上一个未完成的查询
    refreshTask?.cancel()
    refreshTask = Task {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        await loadInitial()  // 重新查询第一页
    }
}
```

**3.6 Swift: HistorySidebarView.swift（修改）**

```swift
// onAppear 时设置 isVisible + 主动 pull:
.onAppear {
    historyVM.isVisible = true
    Task { await historyVM.loadInitial() }
}
.onDisappear {
    historyVM.isVisible = false
}
```

**3.7 BrowserViewModel.swift — 注册 HistoryBridge**

在 `registerAllCallbacks` 末尾或 CreateWebView 回调内:
```swift
HistoryBridge.shared.register(historyVM: historyVM)
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/history.mojom` | 修改 | 新增 `HistoryObserver` 接口 + `HistoryService.SetObserver` |
| `host/owl_history_service.h` | 修改 | 新增 `HistoryChangeCallback` + `SetChangeCallback` + `change_callback_` 成员 |
| `host/owl_history_service.cc` | 修改 | `SetChangeCallback` 实现；AddVisit 成功后调用 callback |
| `host/owl_browser_context.h` | 修改 | `OWLBrowserContext` 新增 `history_observer_` remote + `OnHistoryChanged` 方法 |
| `host/owl_browser_context.cc` | 修改 | `GetHistoryServiceRaw()` 首次创建时注入 `SetChangeCallback`；`OnHistoryChanged` 实现；`HistoryServiceMojoAdapter::SetObserver` 转发到 BrowserContext |
| `bridge/owl_bridge_api.h` | 修改 | 新增 `OWLBridge_SetHistoryChangedCallback` 声明 |
| `bridge/owl_bridge_api.cc` | 修改 | `HistoryObserverImpl` + `SetHistoryChangedCallback`；CreateBrowserContext 后绑定 observer |
| `owl-client-app/Services/HistoryBridge.swift` | **新增** | C-ABI callback 注册 + 转发 |
| `owl-client-app/ViewModels/HistoryViewModel.swift` | 修改 | `onHistoryChanged` + `refreshTask` + `isVisible` |
| `owl-client-app/Views/Sidebar/HistorySidebarView.swift` | 修改 | `onAppear`/`onDisappear` 设置 `isVisible` |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | `registerAllCallbacks` 中注册 `HistoryBridge` |

### 5. 测试策略

| 测试 | 类型 | 覆盖点 |
|------|------|--------|
| `owl_history_service_unittest.cc` | C++ Unit | `SetChangeCallback` → `AddVisit` 成功后 callback 被调用 |
| `HistoryViewModelTests.swift` | Swift Unit | `onHistoryChanged` 触发 loadInitial；debounce 100ms 内多次只查一次；isVisible=false 时不查询 |
| `owl_bridge_web_view_unittest.mm` | C++ Unit | `HistoryObserverImpl::OnHistoryChanged` 转发到 C-ABI callback |

### 6. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| Mojom 接口变更导致 GN 生成新文件，BUILD.gn 需更新 | history.mojom 的 `HistoryObserver` 在同一 mojom target 内，GN 自动处理 |
| `HistoryServiceMojoAdapter` 的 `weak_factory_` 必须是最后一个成员 | C++ 惯例，放在 private 最后 |
| `HistoryBridge.register` 在 CreateWebView 回调后调用，但 HistoryService Mojo pipe 在 CreateBrowserContext 时绑定 | `SetObserver` 是 Mojo 调用，只要 pipe 存在就能接收；Bridge 侧在获取 HistoryService remote 时同步创建 HistoryObserverImpl |
| 快速连续导航导致 debounce 延迟用户体验 | 100ms 延迟几乎不可感知；首次打开侧边栏时 loadInitial 立即执行（无 debounce） |

## 状态
- [x] 技术方案评审（继承父方案 3 轮评审 + 模块级细化）
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
