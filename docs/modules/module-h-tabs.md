# Module H: 多标签增强

| 属性 | 值 |
|------|-----|
| 优先级 | P2 |
| 依赖 | Module A（标签恢复需历史） |
| 预估规模 | ~600 行 |
| 状态 | pending |

## 目标

当前 C-ABI 只管理单个 WebView（全局 `g_webview`）。本模块实现真正的多 WebView 实例，并增加标签固定、会话恢复等能力。

## 用户故事

As a 浏览器用户, I want 每个标签页有独立的 WebView, so that 多个页面可以真正并行加载而不互相影响。

## 验收标准

- AC-001: 每个标签页对应独立的 WebView 实例（独立渲染、独立历史栈）
- AC-002: 切换标签页时切换渲染表面（CALayerHost contextId）
- AC-003: 关闭标签页时正确释放 WebView 资源
- AC-004: 退出浏览器时保存当前标签列表，重启时恢复
- AC-005: 支持固定标签页（Pin Tab），固定标签不可关闭
- AC-006: 支持"撤销关闭标签"（Cmd+Shift+T）
- AC-007: 新标签页打开 target="_blank" 链接（而非当前标签页重定向）

## 技术方案

### 层级分解

#### 1. Bridge C-ABI 重构

当前 `g_webview` 是单实例。需要改为 `webview_id` 映射：

```c
// 所有 WebView 操作函数增加 webview_id 参数
OWL_EXPORT void OWLBridge_Navigate(uint64_t webview_id, const char* url, ...);
OWL_EXPORT void OWLBridge_SendKeyEvent(uint64_t webview_id, ...);
// ... 等等

// 新增
OWL_EXPORT void OWLBridge_DestroyWebView(uint64_t webview_id);
OWL_EXPORT void OWLBridge_SetActiveWebView(uint64_t webview_id);
```

内部：`std::unordered_map<uint64_t, std::unique_ptr<WebViewState>> g_webviews;`

**⚠️ 这是破坏性重构**，需要同步更新所有调用方。建议先做兼容层（0 = 默认单实例）。

#### 2. Host C++

- `OWLBrowserContext::CreateWebView()` 已返回独立 pipe
- 需确保每个 WebView 独立的 observer 管道

#### 3. Swift ViewModel

- `BrowserViewModel` 中 `TabViewModel` 与 `webview_id` 关联
- 标签切换时调用 `OWLBridge_SetActiveWebView`
- 会话持久化：保存 `[(url, title, isPinned)]` 到 JSON

#### 4. SwiftUI

- `TabRowView` 增加固定标签样式
- "撤销关闭" 快捷键处理
- 新标签页处理（target="_blank"）

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | 多 WebView 创建/销毁/隔离 |
| Swift ViewModel | 标签恢复、固定标签不可关闭 |
| E2E Pipeline | 创建多标签 → 各自导航 → 切换 → 关闭验证 |

## 风险

- C-ABI `webview_id` 重构影响面大，需谨慎迁移
- 多 WebView 内存占用需监控
- 渲染表面切换可能有闪烁

## 文件清单

| 操作 | 文件 |
|------|------|
| 修改 | `bridge/owl_bridge_api.h/.cc`（webview_id 参数化） |
| 修改 | `host/owl_web_contents.h/.cc`（多实例管理） |
| 修改 | `owl-client-app/ViewModels/BrowserViewModel.swift`（webview_id 映射） |
| 修改 | `owl-client-app/ViewModels/TabViewModel.swift`（独立 WebView） |
| 修改 | `owl-client-app/Services/OWLBridgeSwift.swift`（webview_id 参数） |
| 新增 | `owl-client-app/Services/SessionRestoreService.swift` |
| 修改 | `owl-client-app/Views/Sidebar/TabRowView.swift`（固定标签） |
