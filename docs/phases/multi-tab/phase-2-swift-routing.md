# Phase 2: Swift 回调路由 + 渲染表面切换

## 目标
- Swift 层建立 per-webview 回调路由表，每个标签的回调精确分发到对应 TabViewModel
- 标签切换时正确切换 CALayerHost 渲染表面
- OWLTabManager 作为 tab 生命周期单一真相源

## 范围

### 修改文件
| 文件 | 变更 |
|------|------|
| `owl-client-app/ViewModels/BrowserViewModel.swift` | webviewIdMap 路由表 + per-webview 回调分发 + createTab/closeTab/activateTab 重构 |
| `owl-client-app/ViewModels/TabViewModel.swift` | 新增 isPinned, isDeferred, isLoading 属性 |
| `owl-client-app/Views/Content/RemoteLayerView.swift` | 按 activeTab.caContextId 切换 CALayerHost |
| `owl-client-app/Views/Sidebar/SidebarView.swift` | 基础多标签列表更新（搜索过滤适配） |
| `bridge/OWLBridgeSession.mm` | 适配多 WebView 回调路由 |
| `client/OWLTabManager.mm` | 确保 createTab/closeTab 正确管理多实例 |

## 依赖
- Phase 1（Host 多 WebView 基础设施）

## 技术要点

### 回调路由架构
```
Host/Bridge 回调 → 携带 webview_id
  → BrowserViewModel.webviewIdMap[webview_id] → TabViewModel
  → 若找到 → 分发到该 TabViewModel
  → 若未找到 → 丢弃 + LOG warning
  → 禁止直接写入 activeTab
```

### ObjC/Swift 数据边界
- OWLTabManager (ObjC): 持有 Host 层状态（webviewId, url, title, isLoading）
- TabViewModel (Swift): 额外持有 UI 状态（isPinned, isDeferred）
- 同步方式: OWLTabManager delegate → BrowserViewModel

### 渲染表面切换
- activateTab() → OWLBridge_SetActiveWebView(webview_id) → Host 推送 ca_context_id
- RemoteLayerView 监听 activeTab.caContextId 变化 → 更新 CALayerHost

### 已知陷阱
- 关闭标签后可能仍收到该 webview_id 的回调 → webviewIdMap 在 DestroyWebView 后立即移除
- C-ABI 回调在 main thread，Swift 侧用 `Task { @MainActor in }` 桥接
- 现有 Find-in-Page/Zoom 等功能需验证在多标签下正确路由到活跃标签

## 验收标准
- [ ] 创建多个标签，各自独立导航，后台标签回调不污染前台标签
- [ ] 切换标签时渲染区域立即显示目标标签页面（AC-002）
- [ ] 关闭标签后资源释放，不再收到该 webview_id 回调（AC-003）
- [ ] 已有功能（Find-in-Page, Zoom, Bookmarks, Downloads, History, Context Menu, Permissions）无回归（AC-009）
- [ ] GTest + 单元测试覆盖回调路由正确性

## 技术方案

### 1. 架构设计

核心变更：修复回调路由，从"所有回调 → activeTab"改为"回调携带 webview_id → webviewIdMap 查表 → 对应 TabViewModel"。

```
Bridge WebViewObserverImpl (IO thread, 知道 webview_id)
  ↓ PostToMain
C-ABI 回调 (main thread, webview_id 作为首参数)
  ↓
BrowserViewModel callback handler
  ↓ webviewIdMap[webview_id]
TabViewModel (直接更新 title/url/caContextId/nav state)
  ↓
SwiftUI 响应式更新 (RemoteLayerView 切换 contextId)
```

**关键设计决策**：
- **统一走 C-ABI 路径**: WebView 创建/销毁/激活全部通过 C-ABI（`OWLBridge_CreateWebView` 等），确保 `g_webviews` map 和 `WebViewObserverImpl` 正确注册。不走 OWLTabManager 的 ObjC Mojo 路径（两套 Observer 冲突）
- **Per-webview 回调注册**: 每个新 WebView 创建后，用 BrowserViewModel 作为 context（`Unmanaged.passUnretained`）注册同一组 callback 函数。无需 CallbackContext 类
- **C-ABI 回调签名扩展**: 所有 per-webview callback typedef 新增 `uint64_t webview_id` 首参数（Bridge 在 dispatch 时传入）
- **Bridge g_compat_webview 全面消除**: 所有 `Set*Callback` 和命令函数（Navigate/Find/Zoom/IME 等）统一按 webview_id 路由到 `WebViewEntry`
- **Tab 列表管理在 Swift**: BrowserViewModel 维护 `tabs` + `webviewIdMap`，不依赖 OWLTabManager（避免 ObjC/C-ABI 双轨冲突）
- **渲染表面切换**: SwiftUI 已支持（RemoteLayerView 绑定 activeTab.caContextId），无需额外代码

### 2. 数据模型变更

#### C-ABI 回调签名扩展（Bridge 层）

所有 per-webview callback typedef 新增 `uint64_t webview_id` 首参数：

```c
// bridge/owl_bridge_api.h — 修改现有 typedef
typedef void (*OWLBridge_PageInfoCallback)(
    uint64_t webview_id,         // 新增：标识来源 WebView
    const char* title, const char* url,
    int is_loading, int can_go_back, int can_go_forward,
    void* context);

typedef void (*OWLBridge_RenderSurfaceCallback)(
    uint64_t webview_id,         // 新增
    uint32_t ca_context_id, uint32_t pixel_width,
    uint32_t pixel_height, float scale_factor,
    void* context);

// Navigation, Zoom, Find, Auth, Console, SecurityState 等同理
```

#### Bridge Set*Callback 修复

```cpp
// bridge/owl_bridge_api.cc — 修复 Set*Callback 路由
void OWLBridge_SetPageInfoCallback(uint64_t webview_id, 
    OWLBridge_PageInfoCallback cb, void* ctx) {
  PostTask IO thread:
    auto* entry = GetWebViewEntry(webview_id);  // 按 ID 查表
    if (!entry) return;
    entry->state->page_info_cb = cb;
    entry->state->page_info_ctx = ctx;
}
// 所有 Set*Callback 同理，替换现有 g_compat_webview 写入
```

#### TabViewModel 新增属性

```swift
@MainActor
package class TabViewModel: ObservableObject, Identifiable {
    // 现有属性保持不变
    // 新增 Phase 2
    @Published var isPinned: Bool = false        // Phase 4 预留
    @Published var isDeferred: Bool = false       // Phase 5 预留
    // 删除: callbackContext（不再需要 per-tab context）
}
```

#### BrowserViewModel 新增结构

```swift
@MainActor
package class BrowserViewModel: NSObject, ObservableObject {
    // 现有
    @Published package var tabs: [TabViewModel] = []
    @Published package var activeTab: TabViewModel?
    
    // 新增
    private var webviewIdMap: [UInt64: TabViewModel] = [:]  // webview_id → TabViewModel 路由表
    
    // 保留: package var webviewId: UInt64  （用于 CLI IPC activeWebviewId）
}
```

### 3. 接口设计

#### 回调注册改造

**现有问题**: `registerAllCallbacks(_ wvId:)` 注册回调用 `vm.activeTab` 路由 → 后台标签丢失回调。

**新设计**: 每个新 WebView 创建后，为其注册同一组 callback 函数（BrowserViewModel 作为 context）。回调通过 `webview_id` 首参数查 `webviewIdMap` 路由：

```swift
/// 为每个新 WebView 注册回调（同一 callback 函数，不同 webview_id）
private func registerCallbacks(forWebViewId wvId: UInt64) {
    let rawSelf = Unmanaged.passUnretained(self).toOpaque()
    
    // PageInfo — 通过 webview_id 查 webviewIdMap
    OWLBridge_SetPageInfoCallback(wvId, { wvId, title, url, loading, back, fwd, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
        Task { @MainActor in
            guard let tab = vm.webviewIdMap[wvId] else { return }
            if let title = title.map({ String(cString: $0) }) { tab.title = title }
            if let url = url.map({ String(cString: $0) }), url.hasPrefix("http") { tab.url = url }
            tab.isLoading = loading != 0
            tab.canGoBack = back != 0
            tab.canGoForward = fwd != 0
            if loading == 0 { tab.completeNavigation(success: true) }
        }
    }, rawSelf)
    
    // RenderSurface — 同理
    OWLBridge_SetRenderSurfaceCallback(wvId, { wvId, caId, w, h, s, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
        Task { @MainActor in
            guard let tab = vm.webviewIdMap[wvId] else { return }
            tab.caContextId = caId
            tab.renderPixelWidth = w
            tab.renderPixelHeight = h
            tab.renderScaleFactor = s
        }
    }, rawSelf)
    
    // Navigation Started/Committed/Failed, Zoom, Find, Auth, SecurityState,
    // ContextMenu, Console, CursorChange, CaretRect, UnhandledKey, CopyImageResult
    // — 全部用同样模式：wvId → webviewIdMap[wvId] → TabViewModel
}
```

**关键区别 vs Round 1**：
- 无 `CallbackContext` 类，无 retain/release → 零 UAF 风险
- 每个 WebView 各自注册到 `g_webviews[wvId]` 的 entry → Bridge 按 entry 分发
- callback 函数体相同，但 Bridge 层存储在不同的 `WebViewEntry` → 正确路由

#### 回调清理

```swift
private func clearCallbacks(forWebViewId wvId: UInt64) {
    // Set nil callback — Bridge 清除该 entry 的回调
    OWLBridge_SetPageInfoCallback(wvId, nil, nil)
    OWLBridge_SetRenderSurfaceCallback(wvId, nil, nil)
    // ... 所有 per-webview 回调
}
```

- closeTab 时先 `clearCallbacks` + `webviewIdMap.removeValue` → 双重保障
- BrowserViewModel deinit 时遍历所有 webviewId 清理

#### 回调分类（完整）

| 回调 | 路由方式 | 说明 |
|------|---------|------|
| PageInfo, RenderSurface | `webviewIdMap[wvId]` → TabViewModel | per-webview 核心状态 |
| NavigationStarted/Committed/Failed | `webviewIdMap[wvId]` → TabViewModel | per-webview 导航状态 |
| Zoom, Find, Auth, SecurityState | `webviewIdMap[wvId]` → TabViewModel | per-webview 功能 |
| ContextMenu | `webviewIdMap[wvId]` → TabViewModel | per-webview，菜单 + ExecuteAction 都需正确 wvId |
| CopyImageResult | `webviewIdMap[wvId]` → TabViewModel | per-webview |
| Console | `webviewIdMap[wvId]` → tab + 全局 consoleVM | per-webview 但同时写全局（标注来源 tab） |
| CursorChange, CaretRect, UnhandledKey | guard `wvId == activeTab?.webviewId` | 仅活跃标签有意义 |
| History, Download, Bookmark, Permission, SSL Error | 全局注册（独立 typedef，不含 webview_id） | 标签无关，保持现状 |

### 4. 核心逻辑

#### createTab 流程（C-ABI 路径）

```
BrowserViewModel.createTab(url:):
  1. OWLBridge_CreateWebView(contextId, callback, ctx)
  2. 回调收到 (webview_id, web_view_host):
     a. 创建 TabViewModel(webviewId: webview_id)
     b. webviewIdMap[webview_id] = tabVM
     c. tabs.append(tabVM)
     d. registerCallbacks(forWebViewId: webview_id)  // 注册 per-webview 回调
     e. OWLBridge_SetActiveWebView(webview_id)
     f. activeTab = tabVM
     g. 如有 url → tabVM.navigate(to: url)
```

#### closeTab 流程

```
BrowserViewModel.closeTab(_ tabVM:):
  1. let wvId = tabVM.webviewId
  2. clearCallbacks(forWebViewId: wvId)    // 清除 Bridge 回调
  3. webviewIdMap.removeValue(forKey: wvId) // 断路由
  4. tabs.removeAll { $0.id == tabVM.id }
  5. OWLBridge_DestroyWebView(wvId)        // pipe 断开 → Host 清理
  6. 如果关闭的是 activeTab:
     - 激活相邻标签（下方优先，其次上方）
     - 如果是最后一个标签 → createTab()
```

#### activateTab 流程

```
BrowserViewModel.activateTab(_ tabVM:):
  1. guard tabVM.id != activeTab?.id else { return }
  2. activeTab = tabVM
  3. OWLBridge_SetActiveWebView(tabVM.webviewId)
  4. SwiftUI 自动响应:
     - RemoteLayerView 绑定 activeTab.caContextId → 切换 CALayerHost
```

#### 渲染表面切换

SwiftUI 已正确工作：`RemoteLayerView(contextId: activeTab.caContextId, ...)` 绑定到 activeTab。当 `activeTab` 变化或其 `caContextId` 变化时，`updateNSView` 自动切换 CALayerHost。

#### 回调安全性（简化后）

- **无 CallbackContext 类**: 无 retain/release，无 use-after-free 风险
- **webviewIdMap 先移除**: closeTab 先 `removeValue` → 后续回调查不到 tab → 安全丢弃
- **Unmanaged.passUnretained(self)**: BrowserViewModel 的生命周期 ≥ 回调生命周期（app 级别），不会 dangle
- **main thread 安全**: C-ABI 回调在 main thread，Swift `@MainActor` 保证一致

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `bridge/owl_bridge_api.h` | 修改 | 所有 per-webview callback typedef 新增 `uint64_t webview_id` 首参数 |
| `bridge/owl_bridge_api.cc` | 修改 | **全面消除 g_compat_webview**：所有 Set*Callback + Navigate/Find/Zoom/IME/Mouse/Key 等命令函数统一路由到 GetWebViewEntry(webview_id)；WebViewObserverImpl dispatch 传 webview_id |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | webviewIdMap + per-webview registerCallbacks + createTab/closeTab/activateTab 走 C-ABI |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | 新增 isPinned, isDeferred 属性 |

**不修改**:
- `RemoteLayerView.swift` — 已正确工作
- `OWLBridgeSwift.swift` — 薄封装无需变更
- `OWLTabManager.mm` — 本 Phase 不使用 OWLTabManager（避免双路径 Observer 冲突）。后续可考虑统一

### 6. 测试策略

#### Swift 单元测试（mock 模式）

| 测试 | 验证点 |
|------|--------|
| CreateMultipleTabs | 创建 3 个标签，webviewIdMap 有 3 个条目 |
| CloseTab_RemovesFromMap | 关闭标签后 webviewIdMap 移除对应条目 |
| ActivateTab_SwitchesActive | 切换 activeTab，验证 activeTab 正确 |
| CallbackRouting_UpdatesCorrectTab | 模拟 per-tab 回调，验证只更新目标 tab |
| CloseActiveTab_ActivatesNeighbor | 关闭活跃标签后自动激活下方标签 |
| CloseLastTab_CreatesNew | 关闭最后一个标签后自动创建新标签 |

#### Pipeline 测试（real 模式）

| 测试 | 验证点 |
|------|--------|
| MultiTab_IndependentNavigation | 两个标签各自导航不同 URL，验证 title 独立 |
| MultiTab_RenderSurfaceSwitch | 切换标签验证 caContextId 变化 |
| MultiTab_BackgroundTabCallback | 后台标签导航完成，验证其 title 更新（非 activeTab） |
| MultiTab_ExistingFeatureRegression | Find-in-Page/Zoom 在活跃标签正常工作 |

### 7. 风险 & 缓解

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| C-ABI callback typedef 变更（+webview_id 首参） | 确定 | Swift 编译失败 | 同一 PR 中同步修改所有 Swift callback lambda 签名 |
| 回调在 tab close 后到达 | 高 | webviewIdMap 查不到 → 丢弃 | clearCallbacks + removeValue 双重保障 |
| g_compat_webview 全面消除 scope 大 | 中 | ~40 函数需改 | grep 确认所有引用；编译+测试验证 |
| BrowserViewModel deinit 后悬垂 | 低 | 单窗口 app 级别生命周期 | deinit 中遍历 clearCallbacks；后续多窗口时改 passRetained |
| 不用 OWLTabManager 的 Mojo 路径 | 低 | 两套 Observer 不冲突 | 统一走 C-ABI，后续可考虑融合 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
