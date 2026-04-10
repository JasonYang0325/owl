# Phase 2: Permission Host→Observer 打通

## 目标
- Host `RequestPermissions()` 通过 RFH 寻址通知 `RealWebContents`，触发 `observer_->OnPermissionRequest`
- 权限弹窗正确弹出，用户 Allow/Deny 响应正确回传 Host
- 30s 超时自动 deny

## 范围

| 文件 | 操作 | 说明 |
|------|------|------|
| `host/owl_web_contents.h` | 修改 | 新增 `g_real_notify_permission_func` 函数指针声明 |
| `host/owl_permission_manager.cc` | 修改 | `RequestPermissions()` 中调用 `g_real_notify_permission_func` 通知 observer |
| `host/owl_real_web_contents.mm` | 修改 | `OWLRealWebContents_Init` 中注入 `g_real_notify_permission_func` 实现 |

## 依赖
- 无前置依赖（独立链路）
- Permission 的 C-ABI callback (`SetPermissionRequestCallback`) 和 Swift 层 (`PermissionBridge`, `PermissionViewModel`, `PermissionAlertView`) 已实现

## 技术要点
- `FromWebContents` 当前通过 `g_real_web_contents` 全局指针实现 + DCHECK 验证 `wc` 匹配
- release build 中 `wc` 不匹配返回 `nullptr`（非错误实例）
- `NotifyPermissionRequest` 内部调用 `(*observer_)->OnPermissionRequest(origin, type, request_id)`
- 多类型并发权限请求：每个 permission type 独立 `request_id`，`PermissionViewModel` 队列管理串行弹窗

## 验收标准
- [ ] `RequestPermissions()` 内部通过 `g_real_notify_permission_func` 调用通知
- [ ] `g_real_notify_permission_func` 在 `OWLRealWebContents_Init` 中正确注入
- [ ] 注入实现正确调用 `observer_->OnPermissionRequest`
- [ ] C++ unit test: `RequestPermissions` → `g_real_notify_permission_func` 被调用（mock 函数指针）
- [ ] C++ unit test: `RespondToPermission(.denied)` → callback 收到 `.denied`
- [ ] 所有现有 unit/cpp 测试通过

## 技术方案

> 父方案: `docs/phases/observer-lifecycle/unified-observer-lifecycle.md` §4.1

### 1. 架构设计

当前断点：`OWLPermissionManager::RequestPermissions()` 存储 PendingRequest 后只打 log + 30s 超时，不通知 Observer。

```
Before:
  RequestPermissions(rfh, ...) → pending_requests_[id] = {...} → LOG → 30s auto-deny
  
After:
  RequestPermissions(rfh, ...) → pending_requests_[id] = {...}
    → WebContents::FromRenderFrameHost(rfh)
    → RealWebContents::FromWebContents(wc)
    → NotifyPermissionRequest(origin, type, request_id)
    → observer_->OnPermissionRequest(...)
    → 30s auto-deny (保留作为兜底)
```

### 2. 接口设计

**`owl_web_contents.h` — 新增函数指针（遵循现有 15+ 个全局函数指针模式）**：

```cpp
// Notify the observer about a pending permission request.
// Injected by OWLRealWebContents_Init (same pattern as g_real_respond_to_permission_func).
// Parameters: origin, permission_type (PermissionType enum int), request_id.
using RealNotifyPermissionFunc = void (*)(const std::string& origin,
    int permission_type, uint64_t request_id);
inline RealNotifyPermissionFunc g_real_notify_permission_func = nullptr;
```

注：不接受 `WebContents*` 参数——单 WebView 架构下只有一个 `g_real_web_contents`，无需路由。与 `g_real_respond_to_permission_func` 签名风格一致。

**`owl_real_web_contents.mm` — 注入实现**：

在 `OWLRealWebContents_Init` 中注入（与 `g_real_respond_to_permission_func` 在同一位置）：
```cpp
g_real_notify_permission_func = [](const std::string& origin,
    int type, uint64_t id) {
  if (g_real_web_contents && g_real_web_contents->observer_ &&
      g_real_web_contents->observer_->is_connected()) {
    (*g_real_web_contents->observer_)->OnPermissionRequest(
        origin, static_cast<owl::mojom::PermissionType>(type), id);
  }
};
```

### 3. 核心逻辑

**`owl_permission_manager.cc` — RequestPermissions 修改**：

在 `pending_requests_[request_id] = {...}` 之后、LOG 之前插入：

```cpp
// Notify observer via global function pointer (injected by RealWebContents).
if (g_real_notify_permission_func) {
  // Find the first ASK permission type for this request.
  for (const auto& descriptor : request_description.permissions) {
    auto maybe_type =
        blink::MaybePermissionDescriptorToPermissionType(descriptor);
    if (!maybe_type.has_value()) continue;
    PermissionStatus status = LookupPermission(origin_str, *maybe_type);
    if (status == PermissionStatus::ASK) {
      g_real_notify_permission_func(
          origin_str, static_cast<int>(*maybe_type), request_id);
      break;  // Phase 2 限制: 只通知第一个 ASK 类型
    }
  }
}
```

**Phase 2 已知简化（批量权限）**：

当一次 `RequestPermissions` 包含多个 ASK 类型（如 camera + microphone）时：
- 只向 observer 通知**第一个** ASK 类型（用户看到一个弹窗）
- 用户响应后，`ResolvePendingRequest` 将该决策应用到全部 permissions
- 这意味着**其余 ASK 类型未经用户逐个确认**

这与现有代码的 `// Phase 2: only prompt for first ASK permission` 注释一致。后续 Phase 扩展为逐个弹窗（修改 `PendingRequest` 结构记录每个 descriptor 的独立决策）。

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `host/owl_web_contents.h` | 修改 | 新增 `g_real_notify_permission_func` 函数指针声明 |
| `host/owl_real_web_contents.mm` | 修改 | `NotifyPermissionRequest()` 实例方法；`OWLRealWebContents_Init` 中注入函数指针 |
| `host/owl_permission_manager.cc` | 修改 | `RequestPermissions()` 中通过 `g_real_notify_permission_func` 调用通知 |

### 5. 测试策略

| 测试 | 类型 | 覆盖点 |
|------|------|--------|
| `owl_permission_manager_unittest.cc` | C++ Unit | `RequestPermissions` 时 `g_real_notify_permission_func` 被调用（mock 函数指针） |
| `owl_permission_manager_unittest.cc` | C++ Unit | `ResolvePendingRequest(.denied)` 后 callback 收到 denied |
| `owl_bridge_permission_unittest.mm` | C++ Unit | `WebViewObserverImpl::OnPermissionRequest` 正确转发到 C-ABI callback |

### 6. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| `g_real_notify_permission_func` 在 RealWebContents 初始化前为 nullptr | 注入位置：`OWLRealWebContents_Init`（与 `g_real_respond_to_permission_func` 在 `OWLPermissionManager` 构造函数中注入的时机不同，但 notify 方向的首次调用必然晚于 `OWLRealWebContents_Init`，因为权限请求需要 RFH 存在）。nullptr 时不通知，30s 超时兜底 |
| 批量权限中多个 ASK 只通知第一个 | Phase 2 已知简化，文档已明确标注。后续 Phase 扩展为逐个弹窗 |
| `render_frame_host` 为 nullptr | Chromium 保证 `RequestPermissions` 传入有效 RFH；加 nullptr 检查 |
| 多 permission batch 只通知第一个 ASK | 与现有 Phase 2 设计一致（注释明确） |

## 状态
- [x] 技术方案评审（继承父方案 3 轮评审 + 模块级细化）
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
