# Unified Observer Lifecycle — PRD

## 1. 背景与目标

OWL Browser 的 Host→Swift 推送管线存在系统性断裂，导致三个已实现功能无法正常工作：

| 功能 | 现象 | 根因 |
|------|------|------|
| SSL SecurityIndicator | HTTPS 页面无锁图标或颜色错误 | callback 在 WebView 创建前注册，被 null 守卫静默丢弃 |
| Permission UI | 权限请求弹窗永远不出现，30s 后自动 deny | Host `RequestPermissions()` 不调 Observer 通知 |
| History 侧边栏 | 导航新页面后列表不更新 | 全链路缺失：无 Mojo Observer、无 C-ABI callback、无响应式绑定 |

**技术目标**：统一 Observer 推送管线，修复三个功能的数据流断裂。

**成功指标**（每条附自动化验证方式）：
- SSL 锁图标：HTTPS 页面显示绿色锁，HTTP 显示灰色，证书错误显示红色，混合内容显示灰色（降级）
  - 验证：Pipeline test — 导航到 HTTPS/HTTP 页面后断言 `SecurityViewModel.level`
- Permission 弹窗：网站请求权限时弹窗出现，用户可 Allow/Deny，响应正确回传 Host；Deny 后 Chromium 收到 `.denied` callback
  - 验证：C++ unit test — `RequestPermissions` → `NotifyPermissionRequest` → `RespondToPermission(.denied)` → callback 被调用
- History 实时更新：侧边栏打开时导航新页面，列表在 1s 内自动刷新
  - 验证：Swift unit test — `onHistoryChanged` → `entries` 更新；debounce 100ms 内多次信号只触发一次查询
- 回归安全：所有现有 cpp/unit 测试通过 + 新增针对性测试全部通过

## 2. 用户故事

**SSL**：
- As a 用户, I want 在访问 HTTPS 网站时看到绿色锁图标, so that 我能确认连接安全
- As a 用户, I want 在访问 HTTP 网站时看到灰色图标, so that 我知道连接不加密

**Permission**：
- As a 用户, I want 当网站请求摄像头/麦克风/位置/通知权限时看到弹窗提示, so that 我能控制隐私授权
- As a 用户, I want 点击 Deny 后页面功能被正确拒绝, so that 我的隐私决策被执行
- As a 用户, I want 如果我未响应弹窗，30s 后弹窗自动消失并视为拒绝, so that 页面不会永久阻塞

**History**：
- As a 用户, I want 浏览历史记录在侧边栏打开时实时更新, so that 我能随时查看刚访问的页面
- As a 用户, I want 打开侧边栏时看到最新的历史记录, so that 即使之前侧边栏关闭也能看到完整历史

## 3. 功能描述

### 3.1 核心流程

**统一注册时序**：所有 per-webview callback 在 `CreateWebView` 成功回调后一次性注册，而非在每次 `navigate()` 时重复注册。WebView 销毁时（`Close` 回调），所有 callback 通过设置为 `nil` 解绑。

**三条推送管线**：

1. **SSL SecurityIndicator**（修复时序）：
   - Host `DidFinishNavigation` → `NotifySecurityStateChanged` → `observer_->OnSecurityStateChanged` → Bridge → Swift `SecurityViewModel`
   - 修复：callback 注册移到 WebView Ready 后，Bridge 用 DCHECK 断言时序

2. **Permission UI**（打通通知）：
   - Host `RequestPermissions(rfh)` → `WebContents::FromRenderFrameHost(rfh)` → `RealWebContents::NotifyPermissionRequest()` → `observer_->OnPermissionRequest` → Bridge → Swift `PermissionViewModel`
   - 新增：RFH 寻址 + `NotifyPermissionRequest` 实例方法
   - 响应路径：Swift → `OWLBridge_RespondToPermission(request_id, status)` → Host `ResolvePendingRequest`

3. **History 侧边栏**（新建管线）：
   - **关键路径说明**：`RealWebContents::DidFinishNavigation` 直接调用 `g_owl_history_service->AddVisit`（非 Mojo 路径），因此通知不能依赖 `HistoryServiceMojoAdapter` 的 Mojo response。解决方案：`OWLHistoryService` 新增 `SetChangeCallback`，由 `HistoryServiceMojoAdapter` 在构造时注入 callback。任何路径的 `AddVisit` 成功都会触发 callback → `history_observer_->OnHistoryChanged(url)` → Bridge `HistoryObserverImpl` → C-ABI → Swift `HistoryViewModel` → 增量 `QueryByTime`

### 3.2 详细规则

- **信号与数据分离**：History 推送只发 `url` 信号，Swift 侧通过 `QueryByTime` pull 权威数据
- **Debounce**：连续导航时 100ms debounce 聚合，避免冗余查询
- **侧边栏关闭时的行为**：`onHistoryChanged` 信号被忽略（不触发查询）；侧边栏 `onAppear` 时主动 pull 最新数据
- **DCHECK 契约**：`SetSecurityStateCallback` 在 debug build 中 DCHECK webview 已就绪，release 有 `if (!*g_webview) return;` 安全网
- **RFH 寻址**：Permission 通过 `WebContents::FromRenderFrameHost(rfh)` 路由到 `RealWebContents`。当前通过 `g_real_web_contents` 全局指针实现 `FromWebContents`（单 WebView 阶段，release build 中 `wc` 不匹配返回 `nullptr`）
- **SSL 触发语义**：每次 `DidFinishNavigation` 独立触发（每个页面有自己的 SSL 状态）
- **Permission 触发语义**：由页面 JS 请求驱动（`navigator.permissions.request` 等），与导航无关
- **Observer 注册时序**：`HistoryService::SetObserver` 必须在 `CreateBrowserContext` 成功后立即注册，早于任何 `AddVisit` 调用
- **线程职责边界**：Host `OWLHistoryService` 的 `ChangeCallback` 在 UI 线程触发（由 AddVisit 的 PostTask 保证）→ Mojo IPC → Bridge IO 线程 → `dispatch_async(main)` → Swift main thread

### 3.3 异常/边界处理

- **WebView 创建失败**：callback 不注册，connectionState 保持 `.failed`
- **WebView 销毁/重建**：销毁时所有 per-webview callback 设为 nil；重建时在新的 `CreateWebView` 回调中重新注册
- **Permission Deny**：用户点 Deny → `OWLBridge_RespondToPermission(id, .denied)` → Host `ResolvePendingRequest` 调用 Chromium callback(`.denied`) → 页面 JS 收到拒绝
- **Permission 超时**：30s 未响应 → 弹窗自动消失 → auto deny（与用户点 Deny 相同路径）
- **多类型并发权限请求**：每个 permission type 独立一个 `request_id`，独立 30s 超时。`PermissionViewModel` 队列管理（`processQueue`），串行显示弹窗，先完成一个再显示下一个
- **Permission 请求在 WebView 销毁后到达**：RFH 寻址返回 null（release 安全网），30s 超时自动 deny
- **History DB 写入失败**：`HistoryChangeCallback` 不触发，UI 不更新（静默降级）
- **混合内容 SSL**：Chromium `SecurityLevel::NONE` 映射到灰色图标（与 HTTP 相同），本 phase 不区分混合内容和纯 HTTP

### 3.4 Permission 类型枚举

本 phase 支持的 `PermissionType`（与 `mojom/permissions.mojom` 对齐）：

| 值 | 类型 | 弹窗文案 |
|----|------|---------|
| 0 | Camera | "请求使用摄像头" |
| 1 | Microphone | "请求使用麦克风" |
| 2 | Geolocation | "请求获取位置信息" |
| 3 | Notifications | "请求发送通知" |

不支持的类型（如 MIDI、Clipboard 等）→ 静默 deny，不弹窗。

## 4. 非功能需求

- **性能**：History 推送 + 增量查询延迟 < 200ms（100ms debounce + DB 查询）
- **安全**：DCHECK 不引入 release build 崩溃风险（有安全网兜底）；`FromWebContents` 在 release 中不匹配返回 `nullptr`（非错误实例）
- **兼容性**：`WebViewObserver` Mojom 接口不变，`FakeWebViewObserver` 不受影响
- **线程安全**：所有 C-ABI callback 在 main thread（`dispatch_get_main_queue`）。线程切换在 Bridge 层完成，Swift 不感知

## 5. 数据模型变更

**`history.mojom` 新增**：
```mojom
interface HistoryObserver {
  OnHistoryChanged(string url);
};
// HistoryService 新增：
SetObserver(pending_remote<HistoryObserver> observer);
```

**`owl_history_service.h` 新增**：
```cpp
using HistoryChangeCallback = base::RepeatingCallback<void(const std::string& url)>;
void SetChangeCallback(HistoryChangeCallback callback);
```

**`owl_bridge_api.h` 新增**：
```c
typedef void (*OWLBridge_HistoryChangedCallback)(const char* url, void* context);
OWL_EXPORT void OWLBridge_SetHistoryChangedCallback(
    OWLBridge_HistoryChangedCallback callback, void* callback_context);
```

## 6. 影响范围

| 层 | 涉及文件 | 变更类型 |
|----|---------|---------|
| Host C++ | `owl_permission_manager.cc`, `owl_real_web_contents.mm`, `owl_browser_context.cc`, `owl_history_service.h/cc` | 修改 |
| Mojom | `history.mojom` | 修改 |
| Bridge C++ | `owl_bridge_api.h/cc` | 修改 |
| Swift | `BrowserViewModel.swift`, `TabViewModel.swift`, `SSLBridge.swift`, `HistoryViewModel.swift` | 修改 |
| Swift | `HistoryBridge.swift` | **新增** |

**对现有功能的影响**：
- `TabViewModel.navigate()` 精简（去掉重复 callback 注册）— 行为不变，只是注册位置前移
- `web_view.mojom` 的 `WebViewObserver` 接口**不变**，不影响 `FakeWebViewObserver`

## 7. 里程碑 & 优先级

| Sprint | 优先级 | 任务 | 验收标准 | 依赖 |
|--------|--------|------|---------|------|
| 1 | P0 | 统一 callback 注册时序 | WebView Ready 后一次注册，navigate() 不重复注册 | 无 |
| 1 | P0 | SSL callback 时序修复 | HTTPS 页面锁图标正确显示（绿/灰/红） | 统一注册 |
| 2 | P0 | Permission Host→Observer 打通 | 权限弹窗正确弹出，Allow/Deny 响应回传 Host | 无（独立链路） |
| 2 | P0 | History 推送管线 | 侧边栏打开时实时刷新 | 无（独立链路） |

**并行策略**：Sprint 1 和 Sprint 2 的两组任务可以并行开发（Sprint 2 不依赖 Sprint 1）。

## 8. 实现状态与开放问题

**实现状态**：技术方案已经过 3 轮全盲评审（Claude + Codex + Gemini）收敛。代码实现待执行——当前代码中 `BrowserViewModel.swift` 的 `CreateWebView` 回调内尚未有 callback 注册逻辑，`HistoryBridge.swift` 尚未创建，Host 侧 RFH 寻址和 `HistoryChangeCallback` 均待实现。

**已决策事项**（经评审确认）：
- `FromWebContents` 当前阶段通过 `g_real_web_contents` 全局指针实现，Module H 迁移到 `WebContentsUserData`
- `HistoryObserver` 放在 `HistoryService` 接口内（非 `BrowserContextHost`）
- History 推送通过 `OWLHistoryService::SetChangeCallback` 而非 Mojo response 路径触发
- `webview_id` 参数在 `SetSecurityStateCallback` 等函数中当前被忽略（单 WebView 架构）

**开放问题**：无。

详细技术方案见 `docs/phases/observer-lifecycle/unified-observer-lifecycle.md`
