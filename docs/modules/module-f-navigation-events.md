# Module F: 导航事件与错误处理

| 属性 | 值 |
|------|-----|
| 优先级 | P1 |
| 依赖 | 无 |
| 预估规模 | ~450 行 |
| 状态 | pending |

## 目标

当前仅有粗粒度的 `OnPageInfoChanged` 和 `OnLoadFinished`。本模块添加详细导航生命周期事件和 HTTP 认证支持。

## 用户故事

As a 浏览器用户, I want 看到页面加载进度并在需要时输入认证信息, so that 我可以更好地了解加载状态并访问受保护的资源。

## 验收标准

- AC-001: 地址栏显示加载进度条（基于导航阶段估算）
- AC-002: 导航失败时显示友好的错误页面（网络错误/DNS 失败/超时）
- AC-003: HTTP 401/407 认证挑战时弹出用户名/密码对话框
- AC-004: 重定向链可追踪（通过 Observer 事件）
- AC-005: 慢加载（>5s）显示提示

## 技术方案

### 层级分解

#### 1. Host C++

扩展 `WebContentsObserver` 回调：
- `DidStartNavigation()` → 导航开始（URL、是否用户发起、是否重定向）
- `DidFinishNavigation()` → 导航完成（HTTP 状态码、SSL 信息）
- `DidFailLoad()` → 加载失败（错误码、描述）
- `LoginDialogOpened()` → HTTP Auth 挑战

#### 2. Mojom（扩展 `web_view.mojom`）

```
// WebViewObserver 新增:
OnNavigationStarted(NavigationEvent event);
OnNavigationCommitted(NavigationEvent event);
OnNavigationFailed(string url, int32 error_code, string error_description);
OnAuthRequired(string url, string realm, string scheme, uint64 auth_id);

struct NavigationEvent {
  string url;
  bool is_user_initiated;
  bool is_redirect;
  int32 http_status_code;
  bool is_ssl;
};

// WebViewHost 新增:
RespondToAuthChallenge(uint64 auth_id, string? username, string? password);
```

#### 3. Bridge C-ABI

```c
typedef void (*OWLBridge_NavigationEventCallback)(
    const char* url, bool is_user_initiated, int http_status, bool is_ssl, void* ctx);
typedef void (*OWLBridge_NavigationErrorCallback)(
    const char* url, int error_code, const char* error_desc, void* ctx);
typedef void (*OWLBridge_AuthRequiredCallback)(
    const char* url, const char* realm, uint64_t auth_id, void* ctx);

OWL_EXPORT void OWLBridge_SetNavigationEventCallback(OWLBridge_NavigationEventCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetNavigationErrorCallback(OWLBridge_NavigationErrorCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetAuthRequiredCallback(OWLBridge_AuthRequiredCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_RespondToAuth(uint64_t auth_id, const char* username, const char* password);
```

#### 4. Swift ViewModel

- `TabViewModel` 扩展：`loadingProgress`（0.0-1.0）、`navigationError`、`authChallenge`
- 进度估算：started=0.1, committed=0.6, finished=1.0

#### 5. SwiftUI Views

- 地址栏底部进度条（细线动画）
- `AuthAlertView`: HTTP 认证对话框
- `NavigationErrorPage`: 友好错误页（替换当前 ErrorPageView）

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | 导航事件序列正确性、Auth 回调 |
| Swift ViewModel | 进度估算、错误状态机 |
| E2E Pipeline | 导航 → 事件序列验证、401 → Auth 响应 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 修改 | `mojom/web_view.mojom`（Observer + Host 扩展） |
| 修改 | `host/owl_real_web_contents.mm`（WebContentsObserver 回调） |
| 修改 | `host/owl_web_contents.h/.cc` |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 修改 | `owl-client-app/ViewModels/TabViewModel.swift`（进度 + 错误） |
| 新增 | `owl-client-app/Views/Alert/AuthAlertView.swift` |
| 修改 | `owl-client-app/Views/TopBar/AddressBarView.swift`（进度条） |
| 修改 | `owl-client-app/Views/Content/ErrorPageView.swift`（增强） |
