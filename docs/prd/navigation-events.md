# 导航事件与错误处理 — PRD

## 1. 背景与目标

OWL Browser 当前仅有粗粒度的导航通知：`OnPageInfoChanged`（标题/URL 变化）和 `OnLoadFinished`（加载成功/失败布尔值）。用户无法了解页面加载进度，导航失败时只看到空白页，遇到 HTTP 401/407 认证时无法输入凭证。这些是浏览器基础体验的缺失。

**目标**: 实现完整的导航生命周期事件传递、友好的错误页面、HTTP 认证对话框、进度条 UI（含停止加载交互）、CLI 导航状态命令，以及 XCUITest 端到端验收。

**成功指标**:
- 8 个 AC 全部通过自动化测试（GTest + XCUITest）
- 错误页面覆盖 Chromium net::ERR_* 中最常见的 10 种错误类型
- Auth 对话框支持 HTTP 401 和 407（Proxy-Authenticate）两种挑战
- 导航事件状态机正确性：GTest 验证事件序列（Started → Committed/Failed）无乱序、无丢失
- UI 响应性：进度条和错误页面在用户感知范围内无明显延迟（定性指标，不设硬性 ms 阈值）

## 2. 用户故事

- **US-001**: As a 浏览器用户, I want 在地址栏看到加载进度条, so that 我知道页面是否在加载、加载到了哪一步。
- **US-002**: As a 浏览器用户, I want 导航失败时看到友好的错误页面（而不是空白页）, so that 我知道发生了什么并可以采取行动（重试/检查网络）。
- **US-003**: As a 浏览器用户, I want 在网站要求 HTTP 认证时看到用户名/密码弹窗, so that 我可以登录受保护的资源。
- **US-004**: As a 开发者/高级用户, I want 通过 CLI 查询当前导航状态和事件历史, so that 我可以在自动化脚本中监控浏览器行为。
- **US-005**: As a 浏览器用户, I want 在页面加载超过 5 秒时看到提示, so that 我知道页面加载较慢，可以选择等待或停止。
- **US-006**: As a 浏览器用户, I want 在页面加载时能停止加载, so that 我不必等待不需要的页面加载完成。

## 验收标准（完整定义）

| AC | 描述 | 输入 | 操作 | 预期输出 |
|----|------|------|------|---------|
| AC-001 | 进度条显示 | 访问任意 HTTPS 页面 | 输入 URL 并导航 | 地址栏底部出现进度条：started→缓慢爬升→committed→继续爬升→finished→渐隐消失（300ms） |
| AC-002 | 错误页面 | 访问不存在的域名（如 `https://this-domain-does-not-exist-12345.com`） | 输入 URL 并导航 | 显示友好错误页面：标题"无法访问此网站"、描述"无法找到该网站的服务器地址"、"重试"按钮 |
| AC-003 | HTTP 认证 | 访问需要 HTTP Basic Auth 的页面 | 导航到 401 页面 | 弹出 AuthAlertView：显示 realm、用户名输入框、密码输入框（SecureField）、确定/取消按钮。输入正确凭证后页面正常加载。 |
| AC-004 | 重定向追踪 | 访问会 301 重定向的 URL | 导航 | CLI `owl nav events` 显示完整事件链：Started(original_url, is_redirect=false) → Redirected(new_url) → Committed(final_url) |
| AC-005 | 慢加载提示 | 访问响应很慢的页面 | 等待 5 秒以上 | 进度条旁显示"加载较慢..."文案 + 明确的"停止"按钮。加载完成或用户停止后提示消失。 |
| AC-006 | CLI nav status | OWL Browser 正在加载页面 | 执行 `owl nav status` | 返回 JSON: `{ "state": "loading", "progress": 0.6, "url": "...", "navigation_id": 123 }` |
| AC-007 | CLI nav events | 有多次导航历史 | 执行 `owl nav events --limit 5` | 返回最近 5 条导航事件（JSON 数组），每条含 navigation_id、event_type、url、timestamp |
| AC-008 | XCUITest E2E | 构建完成的 OWL Browser | 运行 XCUITest suite | 覆盖场景：(a) 正常导航进度条可见性 (b) 导航到无效域名显示错误页 (c) 停止加载按钮可点击 (d) Auth 对话框弹出和提交 |

## 3. 功能描述

### 3.1 核心流程

#### 导航事件传递流程
```
用户输入 URL / 点击链接
  → Chromium DidStartNavigation(NavigationHandle*)
  → Host OWLRealWebContents::DidStartNavigation()
    过滤: 仅 IsInPrimaryMainFrame() 的导航
    提取: navigation_id = handle->GetNavigationId()
  → Mojo WebViewObserver::OnNavigationStarted(NavigationEvent)
  → Bridge C-ABI navigation_started_callback(nav_id, url, ...)
  → Swift TabViewModel: loadingProgress = 0.1, 启动伪进度动画（缓慢爬向 0.5）

  → Chromium DidFinishNavigation(NavigationHandle*) (commit 成功, !IsErrorPage())
  → Host → Mojo OnNavigationCommitted(NavigationEvent with http_status)
  → Bridge → Swift TabViewModel: loadingProgress = 0.6, 伪进度切换（缓慢爬向 0.9）
  → 地址栏保持"停止"图标（仍在加载资源）

  → Chromium DidFinishLoad() (主帧)
  → Host → Mojo OnLoadFinished(true) [已有]
  → Bridge → Swift TabViewModel: loadingProgress = 1.0 → 300ms 后渐隐消失
```

#### 导航失败流程
```
DNS 解析失败 / 连接超时 / SSL 握手失败 / 服务器无响应
  → Chromium DidFinishNavigation(NavigationHandle*) with IsErrorPage()==true 或 !HasCommitted()
  → Host 检查: handle->IsErrorPage() || !handle->HasCommitted()
    提取: net_error = handle->GetNetErrorCode()
  → Mojo OnNavigationFailed(navigation_id, url, error_code, error_description)
  → Bridge → Swift TabViewModel.navigationError = NavigationError(...)
  → SwiftUI:
    - 进度条重置为 0.0 并隐藏
    - 慢加载提示（如有）消失
    - 显示 NavigationErrorPage

注意: 与现有 OnSSLError 的关系:
  - SSL 证书错误 → 走 OnSSLError（已有），不走 OnNavigationFailed
  - SSL 协议错误（如 ERR_SSL_PROTOCOL_ERROR）→ 走 OnNavigationFailed
  - Swift 侧优先级: OnSSLError > OnNavigationFailed（SSL 错误页面优先于通用错误页面）
```

#### 用户停止加载流程
```
用户点击"停止"按钮（加载中时地址栏刷新图标变为 X）
  → Swift 调用 WebViewHost.Stop()（已有）
  → Chromium 中止导航 → 触发 DidFinishNavigation(ERR_ABORTED) 或不触发
  → Swift 侧: 收到 Stop() 响应后直接重置进度条为 0.0
  → 地址栏恢复为"刷新"图标
  → 不显示错误页面（ERR_ABORTED 是用户主动行为）
```

#### HTTP 认证流程
```
网站返回 401 Unauthorized / 407 Proxy Authentication Required
  → Chromium ContentBrowserClient::CreateLoginDelegate()
  → Host OWLContentBrowserClient::CreateLoginDelegate() 创建 OWLLoginDelegate
    生成 auth_id，存入 pending_auth_requests_ map（key=auth_id, value=LoginDelegate weak_ptr）
  → Mojo OnAuthRequired(url, realm, scheme, auth_id, is_proxy)
  → Bridge → Swift 弹出 AuthAlertView:
    - 显示 realm 和来源 URL
    - 407 时额外显示"代理认证"标识
    - 第 2/3 次弹出时显示"用户名或密码错误，请重试"红色提示
  → 用户提交 → Swift → Bridge → Mojo RespondToAuthChallenge(auth_id, username, password)
  → Host → 查找 pending_auth_requests_[auth_id]:
    - 找到 → LoginDelegate->SetAuth(credentials)，从 map 移除
    - 未找到（过期/已取消）→ WARNING log，忽略
  → 用户取消 → RespondToAuthChallenge(auth_id, null, null)
  → Host → LoginDelegate->CancelAuth()，从 map 移除

Auth 生命周期管理:
  - LoginDelegate 绑定到具体导航，导航结束时 Chromium 自动销毁
  - Host 通过 weak_ptr 持有，销毁后自动失效
  - 同一 realm 认证失败计数器在 Host 层维护（key=origin+realm），跨导航共享
  - 计数器达到 3 次 → 不再触发 OnAuthRequired，直接 CancelAuth，页面显示错误
  - 认证成功 → 重置该 realm 计数器
  - 新 tab 访问同一 realm → 独立计数器（不共享）
```

#### 慢加载提示流程
```
导航开始 → Swift 层启动 5 秒计时器（绑定 navigation_id）
  → 5 秒后检查: 该 navigation_id 仍在加载中？
    → 是 → 在进度条旁显示"加载较慢..."提示 + 突出显示"停止"按钮
    → 否（已完成/已失败/已被新导航覆盖）→ 不显示

提示消失条件（任���满足）:
  - OnLoadFinished（加载完成）
  - OnNavigationFailed（加��失败）
  - 用户点击停止
  - 新导航开始（进度条重置）
注意: OnNavigationCommitted 不清除提示（commit 后资源加载可能仍很慢）
```

### 3.2 详细规则

**进度估算规则**:
- `DidStartNavigation`（`is_redirect=false`）→ progress = 0.1，启动伪进度动画
- `DidStartNavigation`（`is_redirect=true`，即重定向）→ progress 不重置，保持当前值继续爬升
- `DidFinishNavigation`（commit 成功，非 error page）→ progress 跳至 0.6，伪进度继续
- `OnLoadFinished(true)` → progress = 1.0（全部完成）→ 300ms 后渐隐消失
- `OnNavigationFailed` → progress = 0.0（重置，显示错误页面）
- `OnLoadFinished(false)` → progress = 0.0（兼容性重置；错误页面由 OnNavigationFailed 驱动，OnLoadFinished(false) 仅重置进度条）
- 用户主动 `Stop()` → progress = 0.0（重置，不显示错误页面）
- 仅主帧（`IsInPrimaryMainFrame()`）导航影响进度条
- Same-document 导航（hash change / pushState）不触发进度条
- `about:blank` / `data:` URL 不显示进度条（瞬时完成）

**伪进度动画**（Swift 层实现）:
- Started 阶段: 每 500ms 增加 0.02，从 0.1 缓慢爬向 0.5（最多持续 20 秒）
- Committed 阶段: 每 300ms 增加 0.03，从 0.6 缓慢爬向 0.9（最多持续 10 秒）
- 收到真实事件时，直接跳到目标值（0.6 或 1.0），取消伪动画
- 使用 SwiftUI `.animation(.easeInOut(duration: 0.3))` 做值变化的平滑过渡

**地址栏按钮状态**:
- 空闲 (loadingProgress == 0) → 显示"刷新"图标 (arrow.clockwise)
- 加载中 (0 < loadingProgress < 1.0) → 显示"停止"图标 (xmark)，点击调用 `Stop()`
- 加载完成 (loadingProgress == 1.0) → 等渐隐后恢复"刷新"图标

**错误页面映射**（net::ERR_* → 友好描述）:

| 错误码 | 描述 | 建议操作 |
|--------|------|---------|
| ERR_NAME_NOT_RESOLVED (-105) | 无法找到该网站的服务器地址 | 请检查网址是否正确 |
| ERR_CONNECTION_REFUSED (-102) | 该网站拒绝了连接 | 重试 |
| ERR_CONNECTION_TIMED_OUT (-118) | 连接超时 | 重试 |
| ERR_INTERNET_DISCONNECTED (-106) | 没有网络连接 | 请检查网络连接 |
| ERR_SSL_PROTOCOL_ERROR (-107) | 安全连接失败 | 重试 |
| ERR_CONNECTION_RESET (-101) | 连接被重置 | 重试 |
| ERR_NETWORK_CHANGED (-21) | 网络已更改 | 重试 |
| ERR_TOO_MANY_REDIRECTS (-310) | 重定向次数过多 | 请清除 Cookie 后重试 |
| 其他 | 页面加载失败（错误码: {code}） | 重试 |

注意: SSL 证书错误（ERR_CERT_DATE_INVALID、ERR_CERT_AUTHORITY_INVALID 等）走现有 OnSSLError 流程，不经 OnNavigationFailed，不在此表中。

错误页面操作按钮:
- 所有类型: "重试"按钮（调用 Reload）
- ERR_INTERNET_DISCONNECTED: 额外显示"请检查网络连接后重试"文案
- ERR_TOO_MANY_REDIRECTS: 不显示"重试"按钮（会再次死循环），改为"返回"按钮
- ERR_ABORTED: 不显示错误页面（用户主动停止）

**HTTP Auth 规则**:
- 同一 origin+realm 最多弹 3 次（Host 层计数），超过后自动 CancelAuth
- 对话框显示 realm 和请求来源 URL
- 401 和 407 共用 AuthAlertView，407 额外显示"代理认证"标识
- 第 2/3 次弹出时显示红色错误提示"用户名或密码错误，请重试"
- 取消认证 = CancelAuth()，页面显示 401 原始响应
- 认证成功 → 重置计数器
- 页面刷新 → 不重置计数器（防止密码暴力尝试）
- LoginDelegate 生命周期由 Chromium 管理，Host 通过 weak_ptr 引用

**重定向追踪规则**:
- Server redirect (301/302/307/308): 由 Chromium 内部处理，触发 `DidRedirectNavigation`
  - Host ��发为 `OnNavigationStarted(event)` 其中 `is_redirect=true`
  - 同一 `navigation_id`，URL 更���为重定向目标
  - Swift/CLI 层将 `is_redirect=true` 的 Started 事件序列化为 `event_type: "redirected"`
- Client redirect (meta refresh / JS location): 触发新的 `DidStartNavigation`，新 navigation_id，视为独立导航
- CLI 事件历史通过 navigation_id 关联同一导航的所有事件（server redirect 同 ID，client redirect 不同 ID）

### 3.3 异常/边界处理

- **多个并发导航**: 新导航自动取消前一个未完成的导航（Chromium 行为），Swift 通过 navigation_id 丢弃旧导航的迟到事件
- **快速连续导航**: 不做额外防抖（Chromium 已处理取消逻辑），Swift 仅需根据最新 navigation_id 更新 UI
- **Auth 弹窗期间导航**: Chromium 销毁 LoginDelegate → Host weak_ptr 失效 → 新 Auth 不会发给已关闭的弹窗。Swift 收到新 Started 事件时关闭 Auth 弹窗
- **子帧导航**: Host 层过滤 `IsInPrimaryMainFrame()`，子帧事件不通过 Mojo 传递
- **about:blank / data: URL**: 不触发 OnNavigationStarted（Chromium 行为），不影响进度条
- **Mojom 接口扩展**: 新增 Observer 方法会导致现有实现编译失败，需同步更新 `OWLBridgeWebView.mm`、`owl_bridge_api.cc`、所有 test double（空实现 stub）

## 4. 非功能需求

- **性能**: 导航事件状态机正确性优先于极致延迟；实际延迟由 Mojo IPC + C-ABI + MainActor 三次跨界决定，预期在 10-50ms 范围内
- **安全**: Auth 对话框中的密码字段使用 SecureField，不在日志中打印凭证，auth_id 使用 random uint64 防止猜测
- **兼容性**: `OnPageInfoChanged` / `OnLoadFinished` 保持不变。新事件是补充，不是替代。长期规划：新事件稳定后考虑废弃 `OnLoadFinished`，但不在本模块范围内
- **编译影响**: Mojom WebViewObserver 新增方法会导致所有现有实现编译失败，影响范围见第 6 节，需在开发时一次性全部更新

## 5. 数据模型变更

### Mojom 新增

```
// WebViewObserver 新增方法:
OnNavigationStarted(NavigationEvent event);
OnNavigationCommitted(NavigationEvent event);
OnNavigationFailed(int64 navigation_id, string url, int32 error_code, string error_description);
OnAuthRequired(string url, string realm, string scheme, uint64 auth_id, bool is_proxy);

struct NavigationEvent {
  int64 navigation_id;   // Chromium NavigationHandle::GetNavigationId()
  string url;
  bool is_main_frame;    // Always true (Host filters sub-frame)
  bool is_user_initiated;
  bool is_redirect;
  int32 http_status_code; // 0 if not yet committed
  bool is_ssl;
};

// WebViewHost 新增方法:
RespondToAuthChallenge(uint64 auth_id, string? username, string? password);
```

### Bridge C-ABI 新增

```c
// 两个独立 callback: Started 和 Committed
typedef void (*OWLBridge_NavigationStartedCallback)(
    int64_t nav_id, const char* url, bool is_user_initiated,
    bool is_redirect, bool is_ssl, void* ctx);
typedef void (*OWLBridge_NavigationCommittedCallback)(
    int64_t nav_id, const char* url, int http_status,
    bool is_ssl, void* ctx);
typedef void (*OWLBridge_NavigationErrorCallback)(
    int64_t nav_id, const char* url, int error_code,
    const char* error_desc, void* ctx);
typedef void (*OWLBridge_AuthRequiredCallback)(
    const char* url, const char* realm, const char* scheme,
    uint64_t auth_id, bool is_proxy, void* ctx);

OWL_EXPORT void OWLBridge_SetNavigationStartedCallback(OWLBridge_NavigationStartedCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetNavigationCommittedCallback(OWLBridge_NavigationCommittedCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetNavigationErrorCallback(OWLBridge_NavigationErrorCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetAuthRequiredCallback(OWLBridge_AuthRequiredCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_RespondToAuth(uint64_t auth_id, const char* username, const char* password);
```

### CLI 新增命令

```
owl nav status          → { "state": "loading"|"error"|"idle", "progress": 0.6, "url": "...", "navigation_id": 123 }
owl nav events [--limit N]  → 最近 N 条导航事件（默认 20，最大 100）
```

Socket 消息类型: `nav.status`, `nav.events`

**CLI 事件存储**:
- Swift 层维护环形缓冲区（NavigationEventRing），容量 100 条，FIFO 淘汰
- 全局共享（不区分 tab，当前单 tab 架构）
- 每条记录包含: navigation_id, event_type (started/committed/failed/redirected), url, timestamp, http_status (可选), error_code (可选)
- 仅存在内存中，不持久化
- timestamp 由 Swift 层在收到事件时生成（Date()），精度 ms 级，不代表 Host 层精确时间
- SSL 证书错误（走 OnSSLError）不记入 nav events（属于独立的安全事件流，非导航状态机）
- CLI 路由: `CLICommandRouter` 新增 `nav.status` / `nav.events` 路由 → `BrowserControl` 协议新增 `navStatus()` / `navEvents(limit:)` 方法

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| `mojom/web_view.mojom` | 新增 4 个 Observer 方法 + 1 个 Host 方法 + 1 个结构体 |
| `host/owl_real_web_contents.mm` | 新增 DidStartNavigation/DidRedirectNavigation/DidFinishNavigation(error) 回调 |
| `host/owl_content_browser_client.h/.mm` | 新增 `CreateLoginDelegate()` 覆写 |
| `host/owl_login_delegate.h/.cc` | **新文件**: OWLLoginDelegate 实现 |
| `host/owl_web_contents.h/.cc` | 扩展接口支持新事件 |
| `bridge/owl_bridge_api.h/.cc` | 新增 4 个回调注册 + 1 个动作函数 |
| `bridge/OWLBridgeWebView.mm` | 新增 4 个 Observer 方法实现（stub） |
| `host/owl_web_contents_unittest.cc` | 更新 MockObserver 补全新方法（空实现） |
| `host/owl_browser_context_unittest.cc` | 更新 MockObserver 补全新方法（空实现） |
| `owl-client-app/ViewModels/TabViewModel.swift` | 新增 loadingProgress/navigationError/authChallenge/伪进度 Timer |
| `owl-client-app/Views/TopBar/AddressBarView.swift` | 添加进度条 + 停止/刷新按钮切换 |
| `owl-client-app/Views/Content/` | 新增 NavigationErrorPage.swift, AuthAlertView.swift |
| `owl-client-app/Models/NavigationEvent.swift` | **新文件**: 事件模型 + 环形缓冲区 |
| `owl-client-app/CLI/Commands/NavStatusCommand.swift` | **新文件**: CLI 命令 |
| `owl-client-app/Services/CLICommandRouter.swift` | 新增 nav.status / nav.events 路由 |
| `owl-client-app/Services/BrowserControl.swift` | 协议扩展 navStatus() / navEvents() |
| `owl-client-app/UITests/OWLNavigationUITests.swift` | **新文件**: XCUITest |

**编译影响**: Mojom WebViewObserver 新增 4 个方法 → 所有实现（OWLBridgeWebView.mm、owl_bridge_api.cc、test doubles）必须同步补全，否则编译失败。建议开发顺序：Mojom → 所有实现 stub → 逐个填充真实逻辑。

## 7. 里程碑 & 优先级

本模块属于项目整体的 P1（质量）优先级。内部功能按相对重要性排序：

| 相对优先级 | 功能 | AC |
|-----------|------|----|
| P1-Critical | 导航事件全栈传递 + navigation_id（其他功能的基础） | AC-004 |
| P1-Critical | 进度条 UI + 停止加载按钮 | AC-001, AC-005 |
| P1-Critical | 错误页面 | AC-002 |
| P1-High | HTTP 认证对话框 | AC-003 |
| P1-High | CLI 导航状态命令 | AC-006, AC-007 |
| P1-Normal | XCUITest 端到端验收 | AC-008 |

## 8. 已决策事项

以下问题在需求澄清阶段已达成共识：

1. **HTTP 407 代理认证**: 支持，401/407 共用 AuthAlertView，407 额外显示"代理认证"标识
2. **错误页面模板**: 统一模板，根据错误码显示不同文案和操作建议
3. **进度条动画**: 伪进度动画（缓慢爬升）+ SwiftUI `.animation(.easeInOut)` 平滑值变化过渡
4. **停止加载**: 加载中时地址栏刷新图标切换为停止图标（X），点击调用 Stop()
5. **SSL 错误分流**: SSL 证书错误走现有 OnSSLError，SSL 协议错误走 OnNavigationFailed
6. **5 秒慢加载阈值**: 参考主流浏览器用户感知研究，5 秒为可接受等待上限。后续可通过 A/B 测试或设置系统（Module I）调整
