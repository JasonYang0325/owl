# Module C: 权限与安全体系

| 属性 | 值 |
|------|-----|
| 优先级 | P1 |
| 依赖 | 无 |
| 预估规模 | ~800 行 |
| 状态 | pending |

## 目标

实现网站权限管理（相机、麦克风、定位、通知等）和 SSL 安全状态显示。当前所有权限请求被静默拒绝，本模块使其可交互。

## 用户故事

As a 浏览器用户, I want 控制网站的权限请求, so that 我可以安全地授权可信站点访问我的设备资源。

## 验收标准

- AC-001: 网站请求权限时弹出原生风格的提示框（允许/拒绝）
- AC-002: 权限决定可持久化（按站点记忆）
- AC-003: 地址栏显示安全锁图标（HTTPS 绿锁 / HTTP 灰色 / 证书错误红色）
- AC-004: 点击锁图标查看站点权限和证书信息
- AC-005: 设置页可管理所有站点权限（查看/撤销）
- AC-006: SSL 证书错误时显示警告页（可选择继续访问）
- AC-007: 支持至少 4 种权限类型：camera、microphone、geolocation、notifications

## 技术方案

### 层级分解

#### 1. Host C++

**`host/owl_permission_manager.h/.cc`**:
- 实现 `content::PermissionControllerDelegate`
- `RequestPermissions()`: 通过 Mojo 回调到客户端显示弹窗
- 权限持久化：JSON 文件 (`user_data_dir/permissions.json`)
- 权限模型：`{origin: {permission_type: GRANTED|DENIED|ASK}}`

**`host/owl_ssl_host_state_delegate.h/.cc`**:
- 实现 `content::SSLHostStateDelegate`
- 记录用户对证书错误的 "继续访问" 决定（会话级或持久化）

#### 2. Mojom (`mojom/permissions.mojom`)

```
enum PermissionType {
  kCamera,
  kMicrophone,
  kGeolocation,
  kNotifications,
};

enum PermissionStatus {
  kGranted,
  kDenied,
  kAsk,  // 默认，未决定
};

interface PermissionService {
  GetPermission(string origin, PermissionType type) => (PermissionStatus status);
  SetPermission(string origin, PermissionType type, PermissionStatus status);
  GetAllPermissions() => (array<SitePermission> permissions);
  ResetPermission(string origin, PermissionType type);
  ResetAll();
};

struct SitePermission {
  string origin;
  PermissionType type;
  PermissionStatus status;
};
```

Observer 扩展（`WebViewObserver`）:
```
OnPermissionRequest(string origin, PermissionType type, uint64 request_id);
OnSSLError(string url, string cert_subject, string error_description, uint64 error_id);
```

Host 端新增：
```
interface WebViewHost {
  // ... existing ...
  RespondToPermissionRequest(uint64 request_id, PermissionStatus status);
  RespondToSSLError(uint64 error_id, bool proceed);
};
```

#### 3. Bridge C-ABI

```c
// 权限请求回调（弹窗触发）
typedef void (*OWLBridge_PermissionRequestCallback)(
    const char* origin, int permission_type, uint64_t request_id, void* ctx);
OWL_EXPORT void OWLBridge_SetPermissionRequestCallback(
    OWLBridge_PermissionRequestCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_RespondToPermission(uint64_t request_id, int status);

// SSL 错误回调
typedef void (*OWLBridge_SSLErrorCallback)(
    const char* url, const char* error, uint64_t error_id, void* ctx);
OWL_EXPORT void OWLBridge_SetSSLErrorCallback(OWLBridge_SSLErrorCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_RespondToSSLError(uint64_t error_id, bool proceed);

// 权限管理
OWL_EXPORT void OWLBridge_PermissionGetAll(OWLBridge_PermissionListCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_PermissionReset(const char* origin, int type);
```

#### 4. Swift ViewModel

- `PermissionViewModel`: 权限弹窗状态、站点权限列表管理
- `SecurityViewModel`: 当前页安全状态（锁图标、证书信息）

#### 5. SwiftUI Views

- `PermissionAlertView`: 权限请求弹窗（.sheet 或 NSAlert）
- `SecurityIndicator`: 地址栏锁图标
- `SecurityPopover`: 点击锁图标的详情弹窗
- `SSLErrorPage`: 证书错误警告全屏页
- 设置页权限管理面板

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | PermissionManager 持久化、默认策略、重置 |
| C++ GTest | SSLHostStateDelegate 证书错误记忆 |
| Swift ViewModel | 弹窗状态机、安全等级计算 |
| E2E Pipeline | 请求权限 → 授予 → 查询状态 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 新增 | `mojom/permissions.mojom` |
| 新增 | `host/owl_permission_manager.h/.cc` |
| 新增 | `host/owl_ssl_host_state_delegate.h/.cc` |
| 修改 | `host/owl_content_browser_context.h/.cc`（返回 delegate） |
| 修改 | `mojom/web_view.mojom`（Observer + Host 扩展） |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 新增 | `owl-client-app/ViewModels/PermissionViewModel.swift` |
| 新增 | `owl-client-app/Views/TopBar/SecurityIndicator.swift` |
| 新增 | `owl-client-app/Views/Alert/PermissionAlertView.swift` |
| 新增 | `owl-client-app/Views/ErrorPage/SSLErrorPage.swift` |
