# Phase 3: 新标签打开

## 目标
- target="_blank" 链接在新标签打开（前台）
- window.open() 在新标签打开（有 user_gesture 时）
- Cmd+Click 在后台新标签打开（不切换焦点）
- window.close() 正确触发标签关闭

## 范围

### 修改文件
| 文件 | 变更 |
|------|------|
| `host/owl_real_web_contents.mm` | OpenURLFromTab() 创建新 WebView; AddNewContents() 处理 window.open; CloseContents() 上报关闭 |
| `bridge/owl_bridge_api.h/cc` | 新增 onNewTabRequested 回调; onWebViewCloseRequested 回调 |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 处理新标签请求（foreground/background, 插入位置） |

## 依赖
- Phase 2（Swift 回调路由 + createTab 方法）

## 技术要点

### Host 端两个拦截点
1. `OpenURLFromTab()` — target="_blank" / Cmd+Click
   - 检查 disposition（NEW_FOREGROUND_TAB / NEW_BACKGROUND_TAB）
   - 创建新 OWLRealWebContents，分配 webview_id
2. `AddNewContents()` — window.open() / JS 弹窗
   - 接收 Chromium 已创建的 new_contents
   - 无 user_gesture 的 window.open → 触发弹窗拦截（已有逻辑）

### 标签插入位置
- 页面派生新标签 → 插入到当前活跃标签的紧邻下方（侧边栏垂直布局）
- foreground=true → 自动激活; foreground=false → 不切换焦点

### window.close() 流程
- Host CloseContents() → Bridge onWebViewCloseRequested(webview_id) → Swift 执行关闭流程

## 验收标准
- [ ] 点击 target="_blank" 链接在新标签打开并自动激活（AC-007①）
- [ ] Cmd+Click 普通链接在后台新标签打开，不切换焦点（AC-007②）
- [ ] window.open() 有 user_gesture 时创建新标签
- [ ] window.open() 无 user_gesture 时被弹窗拦截
- [ ] window.close() 正确关闭对应标签，无僵尸标签残留
- [ ] 新标签插入到当前活跃标签的紧邻下方

## 技术方案

### 1. 架构设计

Host 端 WebContentsDelegate 拦截新窗口请求 → 创建新 WebView → 通过 Bridge 回调通知 Swift → Swift 创建 Tab 并插入正确位置。

```
Chromium Renderer → WebContentsDelegate::OpenURLFromTab(disposition)
                  → WebContentsDelegate::AddNewContents(new_contents)
                  → WebContentsDelegate::CloseContents()
  ↓
Host: 创建新 OWLRealWebContents / 通知 observer
  ↓
Bridge: C-ABI callback → Swift BrowserViewModel
  ↓
Swift: createTab(插入到 activeTab 下方, foreground/background)
```

### 2. Host 层变更

#### OpenURLFromTab（target="_blank" / Cmd+Click）

**当前实现**（line 481-493）：将 URL 加载到当前 tab（same-tab redirect）。

**修改为**：
```objc
WebContents* RealWebContents::OpenURLFromTab(
    WebContents* source, const OpenURLParams& params) {
  if (params.disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB ||
      params.disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB) {
    // 通知 Bridge 创建新标签
    bool foreground = (params.disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB);
    NotifyNewTabRequested(params.url, foreground);
    return nullptr;  // 不在当前 tab 加载
  }
  // 其他 disposition → 同当前 tab 加载（现有逻辑）
  NavigationController::LoadURLParams load_params(params.url);
  source->GetController().LoadURLWithParams(load_params);
  return source;
}
```

#### AddNewContents（window.open / JS 弹窗）

**当前实现**（line 500-522）：用户手势的 popup 重定向到当前 tab。

**修改为**：
```objc
void RealWebContents::AddNewContents(
    WebContents* source, std::unique_ptr<WebContents> new_contents,
    const GURL& target_url, WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture, bool* was_blocked) {
  if (!user_gesture || target_url.is_empty() || !target_url.SchemeIsHTTPOrHTTPS()) {
    *was_blocked = true;  // 拦截非用户手势/空/非 HTTP(S) 弹窗
    return;
  }
  // 有 user_gesture → 通知 Bridge 创建新标签
  bool foreground = (disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB);
  NotifyNewTabRequested(target_url, foreground);
  // new_contents 不使用（Bridge 会通过 CreateWebView 创建独立实例）
}
```

#### CloseContents（window.close）

**新增**：
```objc
void RealWebContents::CloseContents(WebContents* source) {
  if (observer_) {
    observer_->OnWebViewCloseRequested();
  }
}
```

#### NotifyNewTabRequested（辅助方法）

```objc
void RealWebContents::NotifyNewTabRequested(const GURL& url, bool foreground) {
  if (observer_) {
    observer_->OnNewTabRequested(url.spec(), foreground);
  }
}
```

### 3. Mojom 变更

在 `WebViewObserver` 接口追加：
```mojom
interface WebViewObserver {
  // 现有回调...
  OnWebViewCloseRequested();       // 已在 Phase 1 定义
  OnNewTabRequested(string url, bool foreground);  // 新增
};
```

### 4. Bridge 层变更

#### 新增 C-ABI callback typedef + 注册函数

```c
// owl_bridge_api.h
typedef void (*OWLBridge_NewTabRequestedCallback)(
    uint64_t source_webview_id,  // 发起请求的源标签
    const char* url,
    int foreground,              // 1=前台激活, 0=后台
    void* context);
OWL_EXPORT void OWLBridge_SetNewTabRequestedCallback(
    uint64_t webview_id,
    OWLBridge_NewTabRequestedCallback callback,
    void* callback_context);

typedef void (*OWLBridge_CloseRequestedCallback)(
    uint64_t webview_id,
    void* context);
OWL_EXPORT void OWLBridge_SetCloseRequestedCallback(
    uint64_t webview_id,
    OWLBridge_CloseRequestedCallback callback,
    void* callback_context);
```

#### WebViewObserverImpl 新增方法

```cpp
void OnNewTabRequested(const std::string& url, bool foreground) override {
  auto* e = entry();
  if (!e || !e->new_tab_requested_cb) return;
  auto cb = e->new_tab_requested_cb;
  auto ctx = e->new_tab_requested_ctx;
  auto id = webview_id_;
  std::string url_copy = url;
  dispatch_async(dispatch_get_main_queue(), ^{
    cb(id, url_copy.c_str(), foreground ? 1 : 0, ctx);
  });
}

void OnWebViewCloseRequested() override {
  auto* e = entry();
  if (!e || !e->close_requested_cb) return;
  auto cb = e->close_requested_cb;
  auto ctx = e->close_requested_ctx;
  auto id = webview_id_;
  dispatch_async(dispatch_get_main_queue(), ^{
    cb(id, ctx);
  });
}
```

#### WebViewEntry 新增字段

```cpp
OWLBridge_NewTabRequestedCallback new_tab_requested_cb = nullptr;
void* new_tab_requested_ctx = nullptr;
OWLBridge_CloseRequestedCallback close_requested_cb = nullptr;
void* close_requested_ctx = nullptr;
```

### 5. Swift 层变更

#### BrowserViewModel — 新标签请求处理

```swift
// 在 registerAllCallbacks(wvId) 中新增:
OWLBridge_SetNewTabRequestedCallback(wvId, { sourceWvId, url, foreground, ctx in
    let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
    let urlStr = url.map { String(cString: $0) }
    Task { @MainActor in
        guard let urlStr else { return }
        // 找到源标签的位置
        let insertIndex: Int
        if let sourceTab = vm.webviewIdMap[sourceWvId],
           let idx = vm.tabs.firstIndex(where: { $0.id == sourceTab.id }) {
            insertIndex = idx + 1  // 紧邻源标签下方
        } else {
            insertIndex = vm.tabs.count  // 末尾
        }
        // 创建新标签
        vm.createTabAtIndex(url: urlStr, index: insertIndex, foreground: foreground != 0)
    }
}, Unmanaged.passUnretained(self).toOpaque())

// 关闭请求处理:
OWLBridge_SetCloseRequestedCallback(wvId, { wvId, ctx in
    let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
    Task { @MainActor in
        guard let tab = vm.webviewIdMap[wvId] else { return }
        vm.closeTab(tab)
    }
}, Unmanaged.passUnretained(self).toOpaque())
```

#### BrowserViewModel — createTabAtIndex

```swift
func createTabAtIndex(url: String, index: Int, foreground: Bool) {
    #if canImport(OWLBridge)
    pendingURLQueue.append(url)
    pendingInsertIndex = index
    pendingForeground = foreground
    OWLBridge_CreateWebView(browserContextId, { wvId, errMsg, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeRetainedValue()
        Task { @MainActor in
            // ... 同 createTab，但用 pendingInsertIndex 插入位置
            // foreground=true → activateTab; foreground=false → 不切换
        }
    }, Unmanaged.passRetained(self).toOpaque())
    #endif
}
```

### 6. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/web_view.mojom` | 修改 | WebViewObserver 新增 OnNewTabRequested(string, bool) |
| `host/owl_real_web_contents.mm` | 修改 | OpenURLFromTab/AddNewContents 改为创建新标签; 新增 CloseContents |
| `bridge/owl_bridge_api.h` | 修改 | 新增 NewTabRequestedCallback + CloseRequestedCallback typedef 和注册函数 |
| `bridge/owl_bridge_api.cc` | 修改 | WebViewEntry 新增字段; WebViewObserverImpl 新增 dispatch; Set*Callback 实现 |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | 新增 createTabAtIndex + 回调注册 |

### 7. 测试策略

| 测试 | 验证点 |
|------|--------|
| OpenURLFromTab_NewForegroundTab | disposition=NEW_FOREGROUND_TAB → observer 收到 OnNewTabRequested(url, true) |
| OpenURLFromTab_NewBackgroundTab | disposition=NEW_BACKGROUND_TAB → observer 收到 OnNewTabRequested(url, false) |
| AddNewContents_UserGesture | user_gesture=true + HTTP URL → OnNewTabRequested |
| AddNewContents_NoUserGesture | user_gesture=false → was_blocked=true, 无回调 |
| CloseContents_NotifiesObserver | CloseContents → observer 收到 OnWebViewCloseRequested |
| InsertPosition_AfterSourceTab | 新标签插入到源标签的紧邻下方 |

### 8. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| AddNewContents 的 new_contents 被丢弃，浪费渲染器资源 | Chromium 内部处理释放；我们通过 CreateWebView 创建独立实例 |
| window.open 返回值（opener 引用）丢失 | 已知限制，v1 不支持 opener；后续可通过 WebContents::SetOpener 处理 |
| pendingInsertIndex/pendingForeground 同样有 race | 与 pendingURLQueue 一起改为队列化管理 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
