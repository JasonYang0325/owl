# Phase 1: Host 多 WebView 基础设施

## 目标
- Host 端支持同时管理多个 WebView 实例（创建/销毁/切换活跃）
- Bridge C-ABI 实现按 webview_id 路由（修复当前忽略 webview_id 的问题）
- Mojom 接口扩展生命周期管理

## 范围

### 修改文件
| 文件 | 变更 |
|------|------|
| `mojom/browser_context.mojom` | 新增 DestroyWebView, SetActiveWebView 方法 |
| `mojom/web_view.mojom` | 新增 OnWebViewReady, OnWebViewCloseRequested 回调 |
| `host/owl_browser_context.h/cc` | 多 WebView 管理 map（webview_id → OWLRealWebContents） |
| `host/owl_content_browser_client.h/cc` | 适配多 WebView 创建流程 |
| `bridge/owl_bridge_api.cc` | 修复 per-webview 函数路由：g_session 单例 → webview_map[webview_id] |
| `bridge/OWLBridgeWebView.mm` | 适配多实例管理 |
| `mojom/BUILD.gn` | Mojom 编译配置更新 |

### 不修改
- Swift 层（Phase 2 处理）
- UI 层（Phase 4 处理）

## 依赖
- 无前置 Phase
- 依赖 Chromium content layer API（已有）

## 技术要点

### Host 层 RealWebContents 单例问题（关键）
- **当前**: `owl_real_web_contents.mm` 中 `g_real_web_contents` 是全局单例，所有 `RealNavigate/RealGoBack/...` 操作路由到同一个 `content::WebContents`
- **修复**: 每个 `OWLWebContents` 必须持有自己的 `RealWebContents` 实例，`g_real_web_contents` 全局指针改为 per-instance 成员
- 光标 swizzle (`g_real_web_contents->NotifyCursorChanged`) 需改为查找活跃 WebView 的实例

### webview_id 分配
- Host 端 `OWLBrowserContext` 使用 `next_webview_id_++`（uint64_t, 从 1 开始）
- webview_id 在进程生命周期内唯一，不回收
- 通过修改后的 CreateWebView Mojom 回调直接返回

### Bridge 路由修复
- 当前: 所有 per-webview 函数忽略 webview_id，路由到 g_session 单例
- 目标: `std::map<uint64_t, WebViewEntry> g_webviews`
- 兼容层: webview_id=0 路由到活跃 WebView，debug build 打 DLOG(WARNING)

### 已知陷阱
- 修改 bridge/*.h 后需重建 framework（build_all.sh 自动处理）
- Mojo observer 管道是 per-WebView 绑定的，不需要在每个回调中加 webview_id
- OWLBridge_Initialize() 只能调一次，多 WebView 通过现有 session 创建
- Permission/SSL/Auth 回调保持全局（Phase 2 由 Swift 按 webview_id 路由）
- OWLRemoteLayerView 硬编码 webview_id=1 的输入路由（Phase 2 修复）
- C-ABI header 已有 webview_id 参数（签名不变），仅新增 3 个函数

## 验收标准
- [ ] Host 端可创建多个 OWLRealWebContents 实例（各自独立渲染）
- [ ] DestroyWebView 正确释放 WebContents 资源
- [ ] SetActiveWebView 切换活跃 WebContents
- [ ] Bridge C-ABI 按 webview_id 正确路由（不同 webview_id 的操作互不干扰）
- [ ] webview_id=0 兼容层正常工作（路由到活跃 WebView + WARNING 日志）
- [ ] GTest 覆盖: 创建/销毁/切换多个 WebView 实例

## 技术方案

### 1. 架构设计

核心变更：将 Bridge 的全局单例 `g_webview` 替换为 `g_webviews` map，所有 per-webview 操作按 webview_id 路由。

```
              CreateWebView(observer) => (webview_id, web_view_host)
Swift/ObjC ──────────────────→ Bridge (owl_bridge_api.cc)
                                │  g_webviews[id] = WebViewEntry{state, observer, receiver}
                                ↓
                            Host (OWLBrowserContext)
                                │  web_view_map_[id] = OWLRealWebContents
                                ↓
                            Chromium Content Layer
```

**关键设计决策**:
- **webview_id 单一真相源**: Host 端分配（`next_webview_id_++`），通过修改后的 `CreateWebView` Mojom 签名直接返回
- **无 DestroyWebView Mojom**: Bridge 从 map erase → Mojo pipe 断开 → Host `OnDisconnect` 自动清理
- **SetActive 在 per-WebView 接口**: `WebViewHost::SetActive(bool)` 而非全局 SetActiveWebView
- **线程所有权**: `g_webviews` map 仅在 IO thread 访问。所有 C-ABI 函数 PostTask 到 IO thread 执行
- **Bridge 不自动选活跃标签**: active 切换仅由 Swift 显式调用

数据流：
- **创建**: Swift → OWLTabManager → Bridge → Host CreateWebView → Host 分配 webview_id → 返回 (webview_id, web_view_host) → Bridge 存入 g_webviews → 回调 Swift
- **操作**: Swift → C-ABI(webview_id) → PostTask IO thread → g_webviews[id].remote → Host
- **回调**: Host → observer pipe → IO thread WebViewObserverImpl → 提取 callback+data → PostToMain(callback, data)
- **销毁**: Swift → C-ABI DestroyWebView → IO thread erase g_webviews[id] → pipe 断开 → Host OnDisconnect 自动清理

### 2. 数据模型变更

#### Mojom (browser_context.mojom)

修改 `CreateWebView` 签名，新增 `webview_id` 返回值：
```mojom
interface BrowserContextHost {
  // 修改（新增 webview_id 返回值）
  CreateWebView(pending_remote<WebViewObserver> observer)
      => (uint64 webview_id, pending_remote<WebViewHost> web_view);
  // 不需要 DestroyWebView — Mojo pipe 断开自动触发 Host 清理
};
```

#### Mojom (web_view.mojom)

在 `WebViewHost` 接口追加 SetActive；在 `WebViewObserver` 追加 window.close 回调：
```mojom
interface WebViewHost {
  // 现有方法保持不变
  // 新增
  SetActive(bool active);  // 通知 Host 此 WebView 是否为活跃标签
};

interface WebViewObserver {
  // 现有回调保持不变（已通过 pipe 绑定到特定 WebView）
  // 新增
  OnWebViewCloseRequested();  // window.close() 触发（无需 webview_id，pipe 已绑定）
};
```

#### Host (owl_browser_context.h)

```cpp
class OWLBrowserContext {
 private:
  // 替换现有 std::vector<std::unique_ptr<OWLWebContents>> web_views_;
  std::map<uint64_t, std::unique_ptr<OWLWebContents>> web_view_map_;
  uint64_t next_webview_id_ = 1;  // 单一真相源

 public:
  // CreateWebView 内部分配 webview_id，通过回调返回
};
```

#### Bridge (owl_bridge_api.cc)

```cpp
// 合并为单一 map（消除同步风险）
struct WebViewEntry {
  std::unique_ptr<WebViewState> state;
  std::unique_ptr<WebViewObserverImpl> observer;
  std::unique_ptr<mojo::Receiver<owl::mojom::WebViewObserver>> receiver;
};

// 仅在 IO thread 访问（无需 mutex）
std::map<uint64_t, std::unique_ptr<WebViewEntry>> g_webviews;
std::atomic<uint64_t> g_active_webview_id{0};  // atomic: IO thread 写, GetActiveWebViewId 可 main thread 读
// 删除: g_next_bridge_webview_id（Host 分配 ID）
```

### 3. 接口设计

#### 新增 C-ABI 函数

```c
OWL_EXPORT void OWLBridge_DestroyWebView(uint64_t webview_id);
OWL_EXPORT void OWLBridge_SetActiveWebView(uint64_t webview_id);
OWL_EXPORT uint64_t OWLBridge_GetActiveWebViewId(void);
```

#### C-ABI 函数线程模型

**所有 per-webview C-ABI 函数**统一 PostTask 到 IO thread 执行：

```cpp
// 示例：OWLBridge_Navigate
void OWLBridge_Navigate(uint64_t webview_id, const char* url_cstr, ...) {
  std::string url(url_cstr);  // 在 main thread 复制参数
  (*g_io_thread)->task_runner()->PostTask(FROM_HERE,
      base::BindOnce([](uint64_t id, std::string url) {
        auto* entry = GetWebViewEntry(id);  // IO thread 安全查找
        if (!entry) return;
        entry->state->remote->Navigate(GURL(url));
      }, webview_id, std::move(url)));
}
```

#### GetWebViewEntry (IO thread only)

```cpp
// 仅在 IO thread 调用
WebViewEntry* GetWebViewEntry(uint64_t webview_id) {
  if (webview_id == 0) {
    uint64_t active = g_active_webview_id.load();
    if (active == 0) return nullptr;  // 无活跃 WebView
    DLOG(WARNING) << "webview_id=0 used, routing to active: " << active;
    webview_id = active;
  }
  auto it = g_webviews.find(webview_id);
  if (it == g_webviews.end()) {
    LOG(ERROR) << "WebView " << webview_id << " not found";
    return nullptr;
  }
  return it->second.get();
}
```

#### 回调分发模型（消除 dangling pointer）

```cpp
class WebViewObserverImpl : public owl::mojom::WebViewObserver {
 public:
  explicit WebViewObserverImpl(uint64_t webview_id)
      : webview_id_(webview_id) {}
  // 不持有 WebViewState* 裸指针

  void OnPageInfoChanged(owl::mojom::PageInfoPtr info) override {
    // IO thread: 查表提取 callback + context
    auto* entry = GetWebViewEntry(webview_id_);
    if (!entry || !entry->state->page_info_cb) return;
    auto cb = entry->state->page_info_cb;
    auto ctx = entry->state->page_info_ctx;
    auto id = webview_id_;
    // 转换数据...
    // PostToMain 只传值，不访问 map
    PostToMain([cb, ctx, id, converted_info]() {
      cb(id, converted_info, ctx);
    });
  }
};
```

#### 错误处理
- `GetWebViewEntry` 返回 nullptr 时静默返回（不 crash）
- 有回调的函数回调 error_msg
- webview_id=0: debug `DLOG(WARNING)`, release 静默路由

### 4. 核心逻辑

#### CreateWebView 流程

```
OWLBridge_CreateWebView(context_id, callback, ctx):
  PostTask IO thread:
    1. 创建 observer pipe pair（但先不 Bind receiver — 延迟到 ID 确定后）
    2. g_context->remote->CreateWebView(observer_remote, callback):
       回调（IO thread）:
         - 收到 (webview_id, web_view_host) — Host 分配的 ID
         - 创建 WebViewEntry{state, observer(webview_id), receiver}
         - entry->state->remote = web_view_host
         - Bind observer receiver（此时 observer 已有正确 webview_id，不会误路由）
         - g_webviews[webview_id] = std::move(entry)
         - 不设 g_active_webview_id — Swift 层通过 SetActiveWebView 显式设置
         - PostToMain: callback(webview_id, nullptr, ctx)
```

#### DestroyWebView 流程

```
OWLBridge_DestroyWebView(webview_id):
  PostTask IO thread:
    1. auto it = g_webviews.find(webview_id)
    2. if not found → LOG(ERROR), return
    3. if (g_active_webview_id == webview_id) g_active_webview_id = 0
       (重置为 0，不自动选下一个 — Swift 层负责调 SetActiveWebView)
    4. g_webviews.erase(it)
       → WebViewEntry 析构 → state.remote 析构 → Mojo pipe 断开
       → Host OnDisconnect 回调 → Host 自动从 web_view_map_ 移除
```

#### SetActiveWebView 流程

```
OWLBridge_SetActiveWebView(webview_id):
  PostTask IO thread:
    1. auto* entry = GetWebViewEntry(webview_id)
    2. if not found → LOG(ERROR), return
    3. // 通知旧活跃 WebView 变为非活跃
       if (g_active_webview_id != 0) {
         auto* old = GetWebViewEntry(g_active_webview_id);
         if (old) old->state->remote->SetActive(false);
       }
    4. g_active_webview_id = webview_id
    5. entry->state->remote->SetActive(true)  // 通知新活跃 WebView
```

#### 线程安全（修正后）

- **g_webviews map**: 所有读写均在 IO thread（PostTask 保证）。无需 mutex。
- **C-ABI 函数**: main thread 调用 → PostTask 到 IO thread → IO thread 查表+执行
- **回调分发**: IO thread 查表提取 callback pointer + data → PostToMain 只传提取后的值（不访问 map）
- **Set*Callback 函数**: 也必须 PostTask 到 IO thread（修复现有 latent bug：当前直接在 main thread 写 callback pointer）
- **WebViewObserverImpl**: 仅持有 webview_id，不持有 WebViewState*。通过 GetWebViewEntry 在 IO thread 查表。WebView 销毁后 entry 不存在 → 安全丢弃。
- **PostToMain ctx 安全**: 回调的 `void* ctx` 指向 Swift/ObjC 对象，其生命周期由上层管理。DestroyWebView 后可能有已入队的 PostToMain 任务携带 stale ctx。**缓解**: C-ABI 契约要求上层在调用 DestroyWebView 前确保不再依赖该 WebView 的 ctx（或 ctx 本身是弱引用）。这与现有单 WebView 模式的行为一致——当前也不保证回调 ctx 的生命周期。
- **g_active_webview_id**: 使用 `std::atomic<uint64_t>` — IO thread 写，`OWLBridge_GetActiveWebViewId` 可从 main thread 安全读。

#### 全局 vs Per-WebView 回调清单

| 回调 | 归属 | 说明 |
|------|------|------|
| page_info_cb, render_surface_cb, nav_start_cb, ... | Per-WebView (WebViewState) | 随 WebViewEntry 生命周期 |
| permission_request_cb, ssl_error_cb, auth_required_cb | 全局 (g_permission_request_cb 等) | 保持全局不变，Phase 2 由 Swift 层按 webview_id 路由 |
| download_cb, history_cb, bookmark_cb | 全局 (per-context) | 标签无关，保持不变 |

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/browser_context.mojom` | 修改 | CreateWebView 返回 webview_id |
| `mojom/web_view.mojom` | 修改 | WebViewHost 新增 SetActive; WebViewObserver 新增 OnWebViewCloseRequested |
| `mojom/BUILD.gn` | 修改 | 确保编译正确 |
| `host/owl_browser_context.h` | 修改 | web_views_ → web_view_map_, next_webview_id_ |
| `host/owl_browser_context.cc` | 修改 | CreateWebView 分配 id + map, SetActive 实现 |
| `host/owl_real_web_contents.mm` | 修改 | g_real_web_contents 单例 → per-instance; 实现 SetActive; 光标 swizzle 改为查活跃实例 |
| `host/owl_web_contents.h/cc` | 修改 | OWLWebContents 持有自己的 RealWebContents 实例 |
| `bridge/owl_bridge_api.h` | 修改 | 新增 DestroyWebView, SetActiveWebView, GetActiveWebViewId |
| `bridge/owl_bridge_api.cc` | 修改 | g_webview → g_webviews map + WebViewEntry; 所有 C-ABI PostTask 到 IO thread; WebViewObserverImpl 改造 |
| `bridge/OWLBridgeBrowserContext.mm` | 修改 | 适配 CreateWebView 新返回值 (webview_id) |
| `host/owl_web_contents_unittest.cc` | 修改 | 新增多 WebView 测试 |

### 6. 测试策略

#### GTest (C++ 层)

| 测试 | 验证点 |
|------|--------|
| CreateMultipleWebViews | 创建 3 个 WebView，各自获得不同 Host 分配的 webview_id |
| DestroyWebView_PipeDisconnect | erase entry → pipe 断开 → Host OnDisconnect 自动清理 |
| SetActiveWebView | SetActive(true/false) 正确传递到 Host |
| WebViewIdZeroCompat | webview_id=0 路由到活跃 WebView + WARNING |
| RouteToCorrectWebView | 对不同 webview_id 发 Navigate，验证各自收到正确回调 |
| CallbackAfterDestroy | 销毁后回调安全丢弃，不 crash |

#### Mock 策略
- Host 层测试 mock OWLWebContents（已有 mock）
- Bridge 层通过 pipeline 测试验证端到端

### 7. 风险 & 缓解

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| per-webview 函数遗漏 PostTask 改造（~40 个） | 中 | 线程安全问题 | grep 确认所有 g_webview 引用已替换；编译后搜索 main thread 直接访问 |
| Set*Callback 函数未迁移到 IO thread | 中 | 现有 latent data race | 本 Phase 统一迁移，修复现有 bug |
| webview_id=0 兼容层静默错误 | 中 | 调用方 bug 变成误操作活跃标签 | debug DLOG(WARNING); Phase 6 移除 |
| OWLBridgeBrowserContext.createWebView 适配 | 低 | 已有 per-instance 管理 | 仅需适配新返回值 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
