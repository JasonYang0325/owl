# Phase 1: 统一 Callback 注册 + SSL 时序修复

## 目标
- 所有 per-webview callback 在 `CreateWebView` 成功回调后一次性注册
- `TabViewModel.navigate()` 不再重复注册 PageInfo/RenderSurface callback
- SSL SecurityIndicator 锁图标正确显示（HTTPS 绿色、HTTP 灰色、证书错误红色）
- Bridge 层 `SetSecurityStateCallback` 改用 DCHECK + release 安全网

## 范围

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | `CreateWebView` 回调内统一注册所有 per-webview callback |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | `navigate()` 去掉 PageInfo/RenderSurface callback 注册 |
| `owl-client-app/Services/SSLBridge.swift` | 修改 | `register()` 接受 `webviewId` 参数；从 `initializeAndLaunch` 移到 WebView Ready |
| `bridge/owl_bridge_api.cc` | 修改 | `SetSecurityStateCallback` 改用 DCHECK + release 安全网 |

## 依赖
- 无前置依赖

## 技术要点
- `Task { @MainActor in }` 块内串行保证：callback 注册在 `navigate()` 之前
- DCHECK 在 debug build 中断言 `g_webview` 已就绪，release 有 `if (!*g_webview) return;`
- `SSLBridge.register(webviewId:securityVM:)` 新签名，去掉硬编码 `1`
- `TabViewModel` 需要接收 `webviewId` 属性（由 `BrowserViewModel` 注入）

## 验收标准
- [ ] `BrowserViewModel.handleHostLaunched` 的 `CreateWebView` 回调内包含所有 callback 注册
- [ ] `TabViewModel.navigate()` 中不再有 `SetPageInfoCallback` / `SetRenderSurfaceCallback` 调用
- [ ] 导航到 HTTPS 页面后 `SecurityViewModel.level == .secure`
- [ ] 导航到 HTTP 页面后 `SecurityViewModel.level == .info`
- [ ] debug build 中在 WebView 未创建时调用 `SetSecurityStateCallback` 触发 DCHECK
- [ ] 所有现有 unit/cpp 测试通过

## 技术方案

> 父方案: `docs/phases/observer-lifecycle/unified-observer-lifecycle.md` §4.3, §4.4, §4.6

### 1. 架构设计

当前问题：callback 注册分散在多个位置，时序不可控。

```
Before:
  initializeAndLaunch()  → SSLBridge.register()     ← g_webview 未创建，被丢弃
  TabVM.navigate()       → SetPageInfoCallback()    ← 每次导航重复注册
                         → SetRenderSurfaceCallback() ← 每次导航重复注册
  
After:
  CreateWebView callback → 统一注册所有 callbacks   ← g_webview 已就绪
  TabVM.navigate()       → 只负责导航              ← 无 callback 注册
```

### 2. 接口设计

**SSLBridge.swift — 签名变更**：
```swift
// Before:
func register(securityVM: SecurityViewModel)

// After:
func register(webviewId: UInt64, securityVM: SecurityViewModel)
```

**owl_bridge_api.cc — DCHECK 契约**：
```cpp
void OWLBridge_SetSecurityStateCallback(...) {
    DCHECK(*g_webview) << "Called before webview ready";
    if (!*g_webview) return;  // release 安全网
    (*g_webview)->security_state_cb = callback;
    (*g_webview)->security_state_ctx = callback_context;
}
```

### 3. 核心逻辑

**BrowserViewModel.swift — CreateWebView 回调内统一注册**：

关键设计：callback 的 context 指针用 `BrowserViewModel` 自身（非 `activeTab`），回调内通过 `vm.activeTab` 间接访问。这避免了 `activeTab` 在注册时可能为 nil 的 crash 问题，且 tab 切换时 callback 自动路由到当前活跃 tab。

```swift
OWLBridge_CreateWebView(ctxId, { wvId, errMsg, ctx in
    let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeRetainedValue()
    Task { @MainActor in
        guard errMsg == nil else { /* error handling */ return }
        
        vm.webviewId = wvId  // 新增属性，存储 webview ID
        
        // ⚠️ 先创建 tab，注入 webviewId，再注册 callback
        vm.reconnectAttempt = 0
        vm.createMockTab(title: "新标签页", url: nil)
        vm.activeTab?.webviewId = wvId  // 注入 webviewId 到 TabVM
        
        // === 统一注册所有 per-webview callbacks ===
        // context 指针用 BrowserViewModel，回调内通过 vm.activeTab 间接访问
        vm.registerAllCallbacks(wvId)
        
        vm.connectionState = .connected
    }
}, Unmanaged.passRetained(vm).toOpaque())
```

```swift
// BrowserViewModel — 新增私有方法
private func registerAllCallbacks(_ wvId: UInt64) {
    // 1. PageInfo callback（从 TabVM.navigate 移来）
    // context 用 BrowserViewModel 自身，回调内通过 activeTab 间接访问
    OWLBridge_SetPageInfoCallback(wvId, { title, url, loading, back, fwd, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
        let titleStr = title.map { String(cString: $0) }
        let urlStr = url.map { String(cString: $0) }
        let isLoading = loading != 0
        let canBack = back != 0
        let canFwd = fwd != 0
        Task { @MainActor in
            guard let tab = vm.activeTab else { return }
            if let titleStr { tab.title = titleStr }
            if let urlStr, urlStr.hasPrefix("http") { tab.url = urlStr }
            tab.isLoading = isLoading
            tab.canGoBack = canBack
            tab.canGoForward = canFwd
            tab.updateCachedHost()
        }
    }, Unmanaged.passUnretained(self).toOpaque())
    
    // 2. RenderSurface callback
    OWLBridge_SetRenderSurfaceCallback(wvId, { ctxId, pw, ph, scale, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
        Task { @MainActor in
            guard let tab = vm.activeTab else { return }
            tab.caContextId = ctxId
            tab.renderPixelWidth = pw
            tab.renderPixelHeight = ph
            tab.renderScaleFactor = scale
        }
    }, Unmanaged.passUnretained(self).toOpaque())
    
    // 3. SecurityState callback（per-webview，依赖 g_webview）
    SSLBridge.shared.registerSecurityState(webviewId: wvId)
    
    // 4. ZoomChanged callback（从 TabVM.setupZoomCallbackIfNeeded 移来）
    OWLBridge_SetZoomChangedCallback(wvId, { newLevel, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
        Task { @MainActor in
            vm.activeTab?.zoomLevel = newLevel
        }
    }, Unmanaged.passUnretained(self).toOpaque())
    
    // 5. FindResult callback（从 TabVM.setupFindResultCallbackIfNeeded 移来）
    OWLBridge_SetFindResultCallback(wvId, { reqId, matches, active, final, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
        Task { @MainActor in
            vm.activeTab?.handleFindResult(requestId: reqId, matches: matches,
                                           activeOrdinal: active, isFinal: final != 0)
        }
    }, Unmanaged.passUnretained(self).toOpaque())
    
    // 6. UnhandledKey / Cursor / Caret callbacks（保持现有模式）
    // ... 注册逻辑同上
}
```

**TabViewModel.navigate() — 精简**：

```swift
func navigate(to input: String) {
    #if canImport(OWLBridge)
    let urlStr = /* ... URL 处理逻辑不变 ... */
    isLoading = true
    pendingURL = urlStr
    url = urlStr
    updateCachedHost()
    
    // ⚠️ 去掉 SetPageInfoCallback 和 SetRenderSurfaceCallback
    // callback 已在 WebView Ready 时通过 BrowserVM.registerAllCallbacks 注册
    
    // ⚠️ 使用 BrowserViewModel 注入的 webviewId，不再硬编码 1
    urlStr.withCString { cStr in
        OWLBridge_Navigate(webviewId, cStr, { success, status, errMsg, ctx in
            if success == 0 {
                let err = errMsg.map { String(cString: $0) } ?? "Navigation failed"
                NSLog("[OWL] Navigate failed: \(err)")
            }
        }, nil)
    }
    #else
    // mock mode unchanged
    #endif
}
```

**TabViewModel — 新增/修改**：
```swift
// 由 BrowserViewModel 在 createMockTab 后注入
package var webviewId: UInt64 = 1

// 新增：Find 结果处理方法（从 setupFindResultCallbackIfNeeded 内联逻辑提取）
func handleFindResult(requestId: Int32, matches: Int32,
                      activeOrdinal: Int32, isFinal: Bool) {
    guard requestId == activeFindRequestId else { return }  // 过滤过时请求
    findResultCount = Int(matches)
    findActiveIndex = Int(activeOrdinal)
    if isFinal {
        isFindComplete = true
    }
}
```

**TabViewModel — 所有 C-ABI 调用统一使用 webviewId**：
以下方法中的硬编码 `1` 全部改为 `webviewId`：
- `navigate()`: `OWLBridge_Navigate(webviewId, ...)`
- `setZoom()`: `OWLBridge_SetZoomLevel(webviewId, ...)`
- `find()`: `OWLBridge_Find(webviewId, ...)`
- `stopFinding()`: `OWLBridge_StopFinding(webviewId, ...)`
- `updateViewport()`: `OWLBridge_UpdateViewGeometry(webviewId, ...)`
- `goBack/goForward/reload/stop`: 如使用 C-ABI 路径，同样改用 `webviewId`

**TabViewModel — 删除独立注册方法**：
删除 `setupZoomCallbackIfNeeded()` 和 `setupFindResultCallbackIfNeeded()` 方法及其 guard flags（`zoomCallbackRegistered`、`findResultCallbackRegistered`），已移至 `BrowserVM.registerAllCallbacks`。

**SSLBridge.swift — 拆分全局/per-webview 注册**：

```swift
/// 注册全局 SSL error callback（不依赖 webview，在 initializeAndLaunch 中调用）
func registerGlobal(securityVM: SecurityViewModel) {
    self.securityVM = securityVM
    securityVM.onRespondToSSLError = { errorId, proceed in
        #if canImport(OWLBridge)
        OWLBridge_RespondToSSLError(errorId, proceed ? 1 : 0)
        #endif
    }
    #if canImport(OWLBridge)
    OWLBridge_SetSSLErrorCallback(sslErrorCallback, nil)
    #endif
}

/// 注册 per-webview SecurityState callback（依赖 webview，在 WebView Ready 后调用）
/// 前置条件：registerGlobal 已调用（securityVM 已注入）
func registerSecurityState(webviewId: UInt64) {
    #if canImport(OWLBridge)
    OWLBridge_SetSecurityStateCallback(webviewId, securityStateCallback, nil)
    #endif
}
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | 新增 `webviewId` 属性 + `registerAllCallbacks(_:)` 私有方法；`CreateWebView` 回调内先 `createMockTab` 再注册 callback；`initializeAndLaunch` 中 `SSLBridge.registerGlobal` 保留（全局），`registerSecurityState` 移到 callback 注册 |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | `navigate()` 去掉 `SetPageInfoCallback` + `SetRenderSurfaceCallback`；`OWLBridge_Navigate` 改用 `webviewId` 属性；删除 `setupZoomCallbackIfNeeded` + `setupFindResultCallbackIfNeeded`；新增 `package var webviewId: UInt64` |
| `owl-client-app/Services/SSLBridge.swift` | 修改 | 拆分为 `registerGlobal(securityVM:)` + `registerSecurityState(webviewId:securityVM:)` |
| `bridge/owl_bridge_api.cc` | 修改 | `SetSecurityStateCallback` 添加 DCHECK + release 安全网 |

### 5. 测试策略

| 测试 | 类型 | 覆盖点 |
|------|------|--------|
| `SecurityViewModelTests.swift` | Unit | `updateSecurityState` 正确映射 rawLevel → SecurityLevel（直接调用，不依赖 bridge） |
| `BrowserViewModelTests.swift` | Unit | mock 模式下 connectionState 正确转换；callback 注册后 activeTab 非 nil |
| Pipeline test | Integration | 导航 HTTPS 页面 → `SecurityViewModel.level == .secure` |
| `owl_bridge_web_view_unittest.mm` | C++ Unit | `SetSecurityStateCallback` 在 webview null 时不崩溃（release 安全网验证） |
| `TabViewModelTests.swift` | Unit | `navigate()` 不再包含 `SetPageInfoCallback` 调用（通过 mock 验证无副作用） |

注：DCHECK 验证在 debug build 的 C++ 单元测试中自动覆盖（DCHECK 失败 = test crash = 测试不通过）。

### 6. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| callback context 用 BrowserVM 而非 TabVM 后，回调内需 `guard let tab = vm.activeTab` | 已在伪代码中加 `guard`，activeTab 为 nil 时安全跳过 |
| `createMockTab` 在 callback 注册前调用，注册的 callback 能否立即工作 | 是的，注册只是存储函数指针，首次导航时才会触发回调 |
| 删除 TabVM 的 `setupZoomCallbackIfNeeded` 后，现有调用方是否编译失败 | 需检查所有调用方并移除调用 |
| `webviewId` 从 BrowserVM 注入到 TabVM，依赖注入时序 | `createMockTab` 创建 tab 后立即设置 `tab.webviewId = wvId`，在 `registerAllCallbacks` 之前 |
| mock 模式测试不受影响 | mock 模式走 `#else` 分支，不涉及 callback 注册或 webviewId |

## 状态
- [x] 技术方案评审（继承父方案 3 轮评审结果）
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
