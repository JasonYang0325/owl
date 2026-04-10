# Module K: 网络请求监控

| 属性 | 值 |
|------|-----|
| 优先级 | P2 |
| 依赖 | 无 |
| 预估规模 | ~600 行 |
| 状态 | pending |

## 目标

捕获页面的所有网络请求/响应，在右侧面板展示。这是 AI 浏览器的差异化能力——让 AI 理解页面的 API 调用和资源加载。

## 用户故事

As a 开发者/AI 用户, I want 查看页面的网络请求和响应, so that 我可以分析 API 调用、排查加载问题或让 AI 理解页面数据流。

## 验收标准

- AC-001: 实时显示页面所有网络请求（URL、方法、状态码、耗时、大小）
- AC-002: 可按类型过滤（All/XHR/JS/CSS/Img/Doc）
- AC-003: 点击请求查看详情（请求头/响应头/timing）
- AC-004: 显示请求总数和总传输量
- AC-005: 可清除请求列表
- AC-006: 失败请求高亮显示

## 技术方案

### 层级分解

#### 1. Host C++

使用 DevTools Protocol 的 Network domain（通过 `content::DevToolsAgentHost`）：
- 附加到 WebContents 的 DevTools agent
- 监听 `Network.requestWillBeSent`、`Network.responseReceived`、`Network.loadingFinished`/`loadingFailed`

或者使用 `content::WebContentsObserver::ResourceLoadComplete()`（更轻量）：
- 提供 URL、状态码、MIME 类型、传输大小、加载时间
- 缺点：没有请求头/响应头详情

推荐 MVP 用 `ResourceLoadComplete`，后续再用 DevTools Protocol 增强。

#### 2. Mojom（扩展 `web_view.mojom`）

```
enum ResourceType {
  kDocument,
  kScript,
  kStylesheet,
  kImage,
  kFont,
  kXHR,
  kFetch,
  kMedia,
  kOther,
};

struct NetworkRequest {
  string url;
  string method;
  ResourceType type;
  int32 status_code;
  int64 transfer_size;
  int64 encoded_body_size;
  float duration_ms;
  bool from_cache;
  string mime_type;
};

// WebViewObserver 新增:
OnResourceLoaded(NetworkRequest request);
```

#### 3. Bridge C-ABI

```c
typedef void (*OWLBridge_NetworkRequestCallback)(
    const char* url, const char* method, int type, int status_code,
    int64_t transfer_size, float duration_ms, bool from_cache,
    const char* mime_type, void* ctx);
OWL_EXPORT void OWLBridge_SetNetworkRequestCallback(OWLBridge_NetworkRequestCallback cb, void* ctx);
```

#### 4. Swift ViewModel (`ViewModels/NetworkViewModel.swift`)

- 环形缓冲区（最近 500 条请求）
- `@Published var requests: [NetworkRequest]`
- `@Published var filter: ResourceType?`
- 统计：总请求数、总传输量、失败数

#### 5. SwiftUI Views

- `NetworkPanelView`: 右侧面板 Network Tab
- `NetworkRow`: 单条请求（状态色块 + URL + 类型 + 大小 + 耗时）
- `NetworkDetailView`: 请求详情（Sheet）
- 过滤工具栏 + 统计摘要

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | ResourceLoadComplete 参数提取 |
| Swift ViewModel | 过滤、统计计算、缓冲区溢出 |
| E2E Pipeline | 导航 → 验证资源加载回调 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 修改 | `mojom/web_view.mojom`（NetworkRequest + Observer） |
| 修改 | `host/owl_real_web_contents.mm`（ResourceLoadComplete） |
| 修改 | `host/owl_web_contents.h/.cc` |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 新增 | `owl-client-app/ViewModels/NetworkViewModel.swift` |
| 新增 | `owl-client-app/Views/RightPanel/NetworkPanelView.swift` |
| 新增 | `owl-client-app/Views/RightPanel/NetworkRow.swift` |
| 修改 | `owl-client-app/Views/RightPanel/RightPanelContainer.swift`（添加 Network Tab） |
