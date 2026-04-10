# Phase 4: SSL 安全状态 + 错误页

## 目标
实现地址栏安全指示器和 SSL 证书错误警告页。
完成后，用户能看到页面安全状态，遇到证书错误能选择返回或继续。

## 范围
- 新增: `host/owl_ssl_host_state_delegate.h/.cc`
- 修改: `host/owl_content_browser_context.h/.cc`（返回 SSLHostStateDelegate）
- 修改: `host/owl_web_contents.cc`（CertificateError 拦截）
- 修改: `mojom/web_view.mojom`（OnSSLError + RespondToSSLError）
- 修改: `bridge/owl_bridge_api.h`（SSL C-ABI 函数）
- 新增: `owl-client-app/App/ViewModels/SecurityViewModel.swift`
- 新增: `owl-client-app/App/Views/TopBar/SecurityIndicator.swift`
- 新增: `owl-client-app/App/Views/ErrorPage/SSLErrorPage.swift`

## 依赖
- Phase 1（BrowserContext 修改已完成）

## 技术要点
- SSLHostStateDelegate: 会话级记忆（重启后重置）
- SSL 错误触发点: `WebContentsDelegate::CertificateError()` 拦截导航
- SecurityViewModel: 从导航事件获取安全等级 (Secure/Info/Warning/Dangerous)
- SecurityIndicator: SF Symbol 锁图标，20x20pt，地址栏左侧
- SSLErrorPage: ZStack 全屏覆盖 WebView，"继续"需二次确认

## 验收标准
- [ ] AC-P4-1: HTTPS 页面显示绿色锁图标
- [ ] AC-P4-2: HTTP 页面显示灰色开锁图标
- [ ] AC-P4-3: 证书错误时显示全屏警告页
- [ ] AC-P4-4: "返回安全页面"按钮正常工作（有历史 goBack / 无历史 about:blank）
- [ ] AC-P4-5: "继续访问"二次确认后加载页面，地址栏显示 Warning(黄色)
- [ ] AC-P4-6: SSLHostStateDelegate 会话级：重启后继续访问决定重置

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过

---

## 技术方案

### 1. OWLSSLHostStateDelegate

**文件**: `host/owl_ssl_host_state_delegate.h/.cc`

实现 `content::SSLHostStateDelegate`，为 Chromium content layer 提供会话级证书例外记忆。当用户在 `SSLErrorPage` 点击"继续访问（已确认）"时，Host 调用 `AllowCert()`，后续同站点导航 Chromium 会先调 `QueryPolicy()` 检查是否已允许，若已允许则绕过错误拦截。

**数据结构**：

```cpp
// host/owl_ssl_host_state_delegate.h
class OWLSSLHostStateDelegate : public content::SSLHostStateDelegate {
 public:
  OWLSSLHostStateDelegate();
  ~OWLSSLHostStateDelegate() override;

  // content::SSLHostStateDelegate:
  void AllowCert(const std::string& host,
                 const net::X509Certificate& cert,
                 int error,
                 content::StoragePartition* storage_partition) override;

  void Clear(base::RepeatingCallback<bool(const std::string&)> host_filter) override;

  CertJudgment QueryPolicy(const std::string& host,
                           const net::X509Certificate& cert,
                           int error,
                           content::StoragePartition* storage_partition) override;

  void HostRanInsecureContent(const std::string& host,
                              InsecureContentType content_type) override;
  bool DidHostRunInsecureContent(const std::string& host,
                                 InsecureContentType content_type) override;

  void AllowHttpForHost(const std::string& host,
                        content::StoragePartition* storage_partition) override;
  bool IsHttpAllowedForHost(const std::string& host,
                            content::StoragePartition* storage_partition) override;
  void RevokeUserAllowExceptions(const std::string& host) override;
  void SetHttpsEnforcementForHost(const std::string& host, bool enforce,
                                  content::StoragePartition* storage_partition) override;
  bool IsHttpsEnforcedForUrl(const GURL& url,
                             content::StoragePartition* storage_partition) override;
  bool HasAllowException(const std::string& host,
                         content::StoragePartition* storage_partition) override;
  bool HasAllowExceptionForAnyHost(
      content::StoragePartition* storage_partition) override;

 private:
  // Key: (host, cert_fingerprint_sha256, net_error)
  // Value: true = ALLOWED
  // 会话级：不持久化，进程重启后重置（满足 AC-P4-6）
  struct AllowKey {
    std::string host;
    std::string cert_fingerprint;  // base::Base64Encode(cert->CalculateChainFingerprint256())
    int error;
    bool operator<(const AllowKey&) const;
  };
  std::set<AllowKey> allowed_certs_;
  std::set<std::string> ran_mixed_content_;
  std::set<std::string> ran_cert_error_content_;
};
```

**关键实现说明**：
- `AllowCert()`: 将 `(host, cert->CalculateChainFingerprint256(), error)` 插入 `allowed_certs_`
- `QueryPolicy()`: 在 `allowed_certs_` 中查找，命中返回 `ALLOWED`，否则返回 `DENIED`（默认严格）
- `Clear(host_filter)`: 若 filter 为空，清空整个集合；否则按 host 过滤删除
- `HasAllowException()`: 按 host 前缀查找任一条目

**集成到 BrowserContext**（`host/owl_content_browser_context.h/.cc`）：

```cpp
// owl_content_browser_context.h（修改）
#include "third_party/owl/host/owl_ssl_host_state_delegate.h"

class OWLContentBrowserContext : public content::BrowserContext {
  // ...
  content::SSLHostStateDelegate* GetSSLHostStateDelegate() override;
 private:
  std::unique_ptr<OWLSSLHostStateDelegate> ssl_host_state_delegate_;
};

// owl_content_browser_context.cc（修改）
OWLContentBrowserContext::OWLContentBrowserContext(bool off_the_record) {
  // ...
  ssl_host_state_delegate_ = std::make_unique<OWLSSLHostStateDelegate>();
}

content::SSLHostStateDelegate*
OWLContentBrowserContext::GetSSLHostStateDelegate() {
  return ssl_host_state_delegate_.get();  // 替换原有 return nullptr
}
```

---

### 2. SSL 错误拦截 — WebContentsObserver::DidFinishNavigation

**拦截策略**：使用 `WebContentsObserver::DidFinishNavigation()` + `NavigationHandle::GetSSLInfo()` 检测证书错误，比 `NavigationThrottle` 更简洁且与现有 `RealWebContents` 架构一致。

**判断逻辑**：

```cpp
// 在 RealWebContents::DidFinishNavigation() 中添加
void DidFinishNavigation(content::NavigationHandle* handle) override {
  NotifyPageInfo();

  if (handle->IsInPrimaryMainFrame() && handle->HasCommitted()) {
    // 重置渲染表面轮询...

    // Phase 4: SSL 错误检测
    const auto& ssl_info = handle->GetSSLInfo();
    if (ssl_info.has_value() && net::IsCertStatusError(ssl_info->cert_status)) {
      // 有证书错误 — 根据 IsErrorPage 区分两种场景
      if (handle->IsErrorPage()) {
        // Chromium 在 SSLHostStateDelegate 无允许记录时生成错误页
        // IsErrorPage=true 表示首次遇到证书错误，需触发 OnSSLError
        NotifySecurityStateChanged(handle->GetURL(),
                                   SecurityLevel::kDangerous,
                                   ssl_info->cert.get(),
                                   ssl_info->cert_status);

        uint64_t error_id = next_ssl_error_id_++;
        std::string cert_subject = ssl_info->cert
            ? ssl_info->cert->subject().GetDisplayName()
            : "";
        std::string error_desc = net::ErrorToString(
            net::MapCertStatusToNetError(ssl_info->cert_status));
        PendSSLError(error_id, handle->GetURL(), *ssl_info);

        if (observer_ && observer_->is_connected()) {
          (*observer_)->OnSSLError(handle->GetURL().spec(), cert_subject,
                                   error_desc, error_id);
        }
      } else {
        // IsErrorPage=false 且 cert_status 有错误位：
        // 用户已通过 SSLHostStateDelegate 允许继续，Chromium 直接提交页面
        // 推送 kWarning 安全等级（黄色警告）
        NotifySecurityStateChanged(handle->GetURL(),
                                   SecurityLevel::kWarning,
                                   ssl_info->cert.get(),
                                   ssl_info->cert_status);
      }
    } else {
      // 正常页面：计算安全等级
      SecurityLevel level = ComputeSecurityLevel(handle->GetURL(), ssl_info);
      NotifySecurityStateChanged(handle->GetURL(), level,
                                 ssl_info.has_value() ? ssl_info->cert.get() : nullptr,
                                 ssl_info.has_value() ? ssl_info->cert_status : 0);
    }
  }
}
```

**安全等级计算辅助函数**：

```cpp
SecurityLevel ComputeSecurityLevel(
    const GURL& url,
    const std::optional<net::SSLInfo>& ssl_info) {
  if (!url.SchemeIs("https") && !url.SchemeIs("wss")) {
    // HTTP 或非网络协议
    return (url.host() == "localhost" || url.host() == "127.0.0.1")
        ? SecurityLevel::kSecure  // localhost/127.0.0.1 视为可信来源
        : SecurityLevel::kInfo;   // HTTP = kInfo（无锁）
  }
  if (!ssl_info.has_value() || !ssl_info->is_valid()) {
    return SecurityLevel::kInfo;
  }
  if (net::IsCertStatusError(ssl_info->cert_status)) {
    return SecurityLevel::kDangerous;
  }
  return SecurityLevel::kSecure;
}
```

**RespondToSSLError 处理**（`OWLWebContents` 已有 `g_real_respond_to_permission_func` 模式，SSL 复用相同注入模式）：

```cpp
// owl_web_contents.h 新增函数指针
using RealRespondToSSLErrorFunc = void (*)(uint64_t error_id, bool proceed);
inline RealRespondToSSLErrorFunc g_real_respond_to_ssl_error_func = nullptr;

// owl_real_web_contents.mm 新增
void RealRespondToSSLError(uint64_t error_id, bool proceed) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!g_real_web_contents) return;
  g_real_web_contents->RespondToSSLError(error_id, proceed);
}
```

`RealWebContents::RespondToSSLError(error_id, proceed)` 实现：
1. 从 `pending_ssl_errors_` 中查找 `error_id`
2. 若 `proceed=true`：调用 `BrowserContext()->GetSSLHostStateDelegate()->AllowCert(...)` 记录例外，然后 `web_contents_->GetController().Reload()`
3. 若 `proceed=false`：清除 pending，无需额外操作（页面停在错误状态）
4. 从 `pending_ssl_errors_` 中移除该 ID

---

### 3. SecurityViewModel — 安全等级状态机

**文件**: `owl-client-app/App/ViewModels/SecurityViewModel.swift`

```swift
// SecurityViewModel.swift
import Foundation

public enum SecurityLevel: Equatable {
    case loading     // 导航进行中，图标置灰
    case secure      // 有效 HTTPS
    case info        // HTTP / localhost
    case warning     // 证书错误但用户选择继续（已允许）
    case dangerous   // 证书错误未处理（正在显示 SSLErrorPage）
}

@MainActor
public class SecurityViewModel: ObservableObject {
    @Published public var level: SecurityLevel = .info
    @Published public var certSubject: String = ""
    @Published public var errorDescription: String = ""

    // SSL 错误状态（显示 SSLErrorPage 时非 nil）
    @Published public var pendingSSLError: SSLErrorInfo? = nil

    public struct SSLErrorInfo: Equatable {
        public let url: String
        public let certSubject: String
        public let errorDescription: String
        public let errorId: UInt64
    }

    // 从 BrowserViewModel/OWLBridgeSwift 注入的回调
    public var onRespondToSSLError: ((UInt64, Bool) -> Void)?

    // 状态转换入口（由 PageInfoCallback 调用）
    public func onNavigationStarted() {
        level = .loading
        pendingSSLError = nil
    }

    // 由 OnPageInfoChanged 推断（HTTPS URL + 非 loading = Secure；HTTP = Info）
    // 精细等级由 OnSecurityStateChanged 更新
    public func updateFromPageInfo(url: String, isLoading: Bool) {
        if isLoading {
            level = .loading
            return
        }
        guard !url.isEmpty else { return }
        // 粗粒度：根据 URL scheme 推断（精细状态由 OnSecurityStateChanged 覆盖）
        if url.hasPrefix("https://") || url.hasPrefix("wss://") {
            if level == .loading { level = .secure }
        } else {
            if level == .loading { level = .info }
        }
    }

    // 精细安全状态（来自 OnSecurityStateChanged C-ABI 回调）
    public func updateSecurityState(rawLevel: Int32, certSubject: String, errorDesc: String) {
        self.certSubject = certSubject
        self.errorDescription = errorDesc
        switch rawLevel {
        case 0: level = .secure
        case 1: level = .info
        case 2: level = .warning
        case 3: level = .dangerous
        default: level = .info
        }
    }

    // SSL 错误到达（来自 OnSSLError C-ABI 回调）
    public func onSSLError(url: String, certSubject: String, errorDesc: String, errorId: UInt64) {
        level = .dangerous
        pendingSSLError = SSLErrorInfo(url: url, certSubject: certSubject,
                                       errorDescription: errorDesc, errorId: errorId)
    }

    // 用户决定：返回安全页面
    public func goBackToSafety() {
        guard let err = pendingSSLError else { return }
        onRespondToSSLError?(err.errorId, false)
        pendingSSLError = nil
    }

    // 用户决定：继续访问（已在 SSLErrorPage 做过二次确认）
    public func proceedAnyway() {
        guard let err = pendingSSLError else { return }
        onRespondToSSLError?(err.errorId, true)
        pendingSSLError = nil
        level = .warning  // 加载完成前先置为 Warning
    }
}
```

**状态机转换图**：

```
导航开始         ─→ loading
  ↓ OnPageInfoChanged(isLoading=false, url=https://)
secure / info / warning / dangerous
  ↓ OnSSLError 回调
dangerous + pendingSSLError != nil  (SSLErrorPage 可见)
  ↓ goBackToSafety()
pendingSSLError = nil, level 由下一次导航 PageInfo 决定
  ↓ proceedAnyway()
warning + pendingSSLError = nil, reload 后由 OnSecurityStateChanged 更新
```

---

### 4. SecurityIndicator — 地址栏锁图标

**文件**: `owl-client-app/App/Views/TopBar/SecurityIndicator.swift`

```swift
// SecurityIndicator.swift
import SwiftUI

struct SecurityIndicator: View {
    let level: SecurityLevel

    private var symbolName: String {
        switch level {
        case .loading:    return "lock.open"
        case .secure:     return "lock.fill"
        case .info:       return "lock.open"
        case .warning:    return "exclamationmark.triangle.fill"
        case .dangerous:  return "xmark.shield.fill"
        }
    }

    private var symbolColor: Color {
        switch level {
        case .loading:    return .secondary
        case .secure:     return .green
        case .info:       return .secondary
        case .warning:    return .yellow
        case .dangerous:  return .red
        }
    }

    private var accessibilityLabel: String {
        switch level {
        case .loading:    return "正在加载"
        case .secure:     return "安全连接"
        case .info:       return "不安全连接"
        case .warning:    return "证书异常（已允许继续）"
        case .dangerous:  return "证书错误，连接不安全"
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(symbolColor)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            // 导航中图标淡入淡出过渡
            .animation(.easeInOut(duration: 0.15), value: level)
            .accessibilityLabel(accessibilityLabel)
            // P1 降级：悬停 tooltip，点击事件预留接口
            .help(accessibilityLabel)
    }
}
```

**集成到 TopBar**（修改 `TopBarView.swift`）：

```swift
// TopBarView.swift 地址栏左侧插入
HStack(spacing: 4) {
    SecurityIndicator(level: browserVM.securityViewModel.level)
        .padding(.leading, 6)
    // ... 现有 URL 文本框 ...
}
```

---

### 5. SSLErrorPage — 全屏证书错误警告页

**文件**: `owl-client-app/App/Views/ErrorPage/SSLErrorPage.swift`

```swift
// SSLErrorPage.swift
import SwiftUI

struct SSLErrorPage: View {
    let errorInfo: SecurityViewModel.SSLErrorInfo
    let canGoBack: Bool
    let onGoBack: () -> Void
    let onProceed: () -> Void  // 调用前已完成二次确认

    @State private var showConfirmAlert = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // 警告图标
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                // 标题
                Text("你的连接不是私密连接")
                    .font(.title)
                    .bold()

                // 说明文字
                VStack(spacing: 8) {
                    Text("攻击者可能正在试图从 \(host(from: errorInfo.url)) 窃取你的信息（例如密码、消息或信用卡）。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)

                    // 错误代码
                    Text(errorInfo.errorDescription)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }

                // 返回安全页面（主按钮）
                Button(action: onGoBack) {
                    Text(canGoBack ? "返回安全页面" : "打开空白页")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityAddTraits(.isButton)

                // 继续访问（次级文字按钮，二次确认）
                Button("继续访问（不安全） →") {
                    showConfirmAlert = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.subheadline)

                Spacer()
            }
            .padding(40)
        }
        .alert("确定要继续访问吗？", isPresented: $showConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("继续访问", role: .destructive) {
                onProceed()
            }
        } message: {
            Text("此站点的证书无效。继续访问可能使你的信息面临风险。")
        }
    }

    private func host(from url: String) -> String {
        URL(string: url)?.host ?? url
    }
}
```

**集成到主视图**（修改 `BrowserView.swift` 或 `ContentView.swift`）：

```swift
// 在 WebView ZStack 上层叠加 SSLErrorPage
ZStack {
    WebView(...)  // 现有 Chromium 渲染层

    if let sslError = browserVM.securityViewModel.pendingSSLError {
        SSLErrorPage(
            errorInfo: sslError,
            canGoBack: browserVM.canGoBack,
            onGoBack: {
                browserVM.securityViewModel.goBackToSafety()
                if browserVM.canGoBack {
                    browserVM.goBack()
                } else {
                    browserVM.navigate(to: "about:blank")
                }
            },
            onProceed: {
                browserVM.securityViewModel.proceedAnyway()
            }
        )
        .transition(.opacity)
    }
}
.animation(.easeInOut(duration: 0.2), value: browserVM.securityViewModel.pendingSSLError != nil)
```

---

### 6. Mojom + C-ABI 扩展

#### 6.1 Mojom 扩展（`mojom/web_view.mojom`）

在 `WebViewObserver` 中新增 `OnSSLError` 和 `OnSecurityStateChanged`，在 `WebViewHost` 中新增 `RespondToSSLError`：

```mojom
// WebViewObserver 新增（追加在 OnPermissionRequest 之后）

// SSL 证书错误通知。Host 检测到证书错误时发送。
// Client 必须调用 WebViewHost.RespondToSSLError 响应。
// 如果 Client 超时或管道断开，Host 不自动处理（错误页保留）。
OnSSLError(string url,
           string cert_subject,
           string error_description,
           uint64 error_id);

// 安全状态变化通知（每次导航完成后推送）。
// level: 0=Secure, 1=Info, 2=Warning, 3=Dangerous
// cert_subject: 证书 CN，无证书时为空字符串
// error_description: net 错误字符串，无错误时为空字符串
OnSecurityStateChanged(int32 level,
                       string cert_subject,
                       string error_description);
```

```mojom
// WebViewHost 新增（追加在 RespondToPermissionRequest 之后）

// 响应 SSL 证书错误。error_id 对应 OnSSLError 中的值。
// proceed=true: 记录证书例外并重新加载页面。
// proceed=false: 不加载，保留错误状态。
// 无效 error_id 静默忽略（WARNING log）。
RespondToSSLError(uint64 error_id, bool proceed);
```

#### 6.2 OWLWebContents 新增方法（`host/owl_web_contents.h/.cc`）

```cpp
// owl_web_contents.h — WebViewHost 新增方法声明
void RespondToSSLError(uint64_t error_id, bool proceed) override;
```

```cpp
// owl_web_contents.cc
void OWLWebContents::RespondToSSLError(uint64_t error_id, bool proceed) {
  if (g_real_respond_to_ssl_error_func) {
    g_real_respond_to_ssl_error_func(error_id, proceed);
  }
}
```

#### 6.3 C-ABI 扩展（`bridge/owl_bridge_api.h`）

```c
// === SSL Security (Phase 4) ===

// SSL 错误回调（触发时显示 SSLErrorPage）。
// url: 发生错误的 URL（UTF-8）。
// cert_subject: 证书主体名（UTF-8）。
// error_description: net 错误字符串，如 "net::ERR_CERT_DATE_INVALID"。
// error_id: 唯一 ID，传给 OWLBridge_RespondToSSLError。
// 回调保证在主线程触发。
typedef void (*OWLBridge_SSLErrorCallback)(
    const char* url,
    const char* cert_subject,
    const char* error_description,
    uint64_t error_id,
    void* context);

// 注册 SSL 错误回调（全局，非 per-webview）。设 NULL 取消注册。
OWL_EXPORT void OWLBridge_SetSSLErrorCallback(
    OWLBridge_SSLErrorCallback callback,
    void* callback_context);

// 响应 SSL 错误。error_id 对应 SSLErrorCallback 中的值。
// proceed=true: 记录证书例外，重新加载页面。
// proceed=false: 不加载，保留错误状态（返回安全页面）。
// 无效 error_id 静默忽略。
OWL_EXPORT void OWLBridge_RespondToSSLError(uint64_t error_id, int proceed);

// 安全状态变化回调（每次导航完成后推送）。
// level: 0=Secure, 1=Info, 2=Warning, 3=Dangerous
// cert_subject: 证书 CN（无证书时为空字符串）。
// error_description: 错误描述（无错误时为空字符串）。
typedef void (*OWLBridge_SecurityStateCallback)(
    int32_t level,
    const char* cert_subject,
    const char* error_description,
    void* context);

// 注册安全状态变化回调（per-webview）。
OWL_EXPORT void OWLBridge_SetSecurityStateCallback(
    uint64_t webview_id,
    OWLBridge_SecurityStateCallback callback,
    void* callback_context);
```

#### 6.4 Swift 桥接（`OWLBridgeSwift.swift`）

```swift
// OWLBridgeSwift.swift 新增 SSL 相关注册
public static func setSSLErrorCallback(
    _ handler: @escaping (String, String, String, UInt64) -> Void
) {
    // 存储 Swift 闭包到静态 holder（同 permission callback 模式）
    SSLErrorCallbackHolder.shared.handler = handler
    OWLBridge_SetSSLErrorCallback({ url, certSubject, errorDesc, errorId, _ in
        let urlStr = url.map { String(cString: $0) } ?? ""
        let subject = certSubject.map { String(cString: $0) } ?? ""
        let desc = errorDesc.map { String(cString: $0) } ?? ""
        Task { @MainActor in
            SSLErrorCallbackHolder.shared.handler?(urlStr, subject, desc, errorId)
        }
    }, nil)
}

public static func respondToSSLError(errorId: UInt64, proceed: Bool) {
    OWLBridge_RespondToSSLError(errorId, proceed ? 1 : 0)
}
```

---

### 7. 文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| 新增 | `host/owl_ssl_host_state_delegate.h` | SSLHostStateDelegate 实现声明 |
| 新增 | `host/owl_ssl_host_state_delegate.cc` | 会话级证书例外存储（std::set，不持久化） |
| 修改 | `host/owl_content_browser_context.h` | 添加 `ssl_host_state_delegate_` 成员 |
| 修改 | `host/owl_content_browser_context.cc` | 构造函数初始化，`GetSSLHostStateDelegate()` 返回非 nullptr |
| 修改 | `host/owl_real_web_contents.mm` | `DidFinishNavigation` 添加 SSL 检测 + `OnSSLError`/`OnSecurityStateChanged` 推送；新增 `pending_ssl_errors_` map 和 `RealRespondToSSLError` |
| 修改 | `host/owl_web_contents.h` | 添加 `g_real_respond_to_ssl_error_func` 函数指针；`RespondToSSLError` 声明 |
| 修改 | `host/owl_web_contents.cc` | `RespondToSSLError` 实现（转发到 g_real 函数指针） |
| 修改 | `mojom/web_view.mojom` | `WebViewObserver` 添加 `OnSSLError`、`OnSecurityStateChanged`；`WebViewHost` 添加 `RespondToSSLError` |
| 修改 | `bridge/owl_bridge_api.h` | 新增 SSL C-ABI 函数声明和回调类型 |
| 修改 | `bridge/OWLBridgeSession.mm` | 实现新 C-ABI 函数，转发 Mojo 事件到 Swift 回调 |
| 新增 | `owl-client-app/App/ViewModels/SecurityViewModel.swift` | 安全状态机（SecurityLevel 枚举 + 状态更新方法） |
| 新增 | `owl-client-app/App/Views/TopBar/SecurityIndicator.swift` | SF Symbol 锁图标（20x20pt，动画过渡） |
| 新增 | `owl-client-app/App/Views/ErrorPage/SSLErrorPage.swift` | 全屏证书错误页（ZStack 覆盖，二次确认 Alert） |
| 修改 | `owl-client-app/App/Views/TopBar/TopBarView.swift` | 地址栏左侧插入 SecurityIndicator |
| 修改 | `owl-client-app/App/ContentView.swift` (或 BrowserView) | WebView ZStack 叠加 SSLErrorPage |
| 修改 | `owl-client-app/Services/OWLBridgeSwift.swift` | 注册 SSL 错误回调和安全状态回调 |
| 修改 | `BUILD.gn` | host_content target 添加 `owl_ssl_host_state_delegate.cc` |

---

### 8. 测试策略

#### 8.1 C++ GTest（`host/owl_ssl_host_state_delegate_unittest.cc`）

| 测试用例 | 验收标准 |
|----------|---------|
| `AllowCertAndQueryPolicy` | AllowCert 后 QueryPolicy 返回 ALLOWED（同 host+cert+error） |
| `DifferentErrorNotAllowed` | AllowCert(err=A) 后，QueryPolicy(err=B) 返回 DENIED |
| `DifferentHostNotAllowed` | AllowCert(host=a.com) 后，QueryPolicy(host=b.com) 返回 DENIED |
| `ClearAll` | Clear(null filter) 后所有 QueryPolicy 返回 DENIED |
| `ClearHostFilter` | Clear(host=a.com filter) 只清除 a.com 例外，b.com 不变 |
| `SessionReset` | 新建 OWLSSLHostStateDelegate 实例，QueryPolicy 返回 DENIED（满足 AC-P4-6） |
| `HasAllowException` | AllowCert 后 HasAllowException 返回 true；Clear 后返回 false |

#### 8.1b C++ GTest — DidFinishNavigation SSL 拦截（`host/owl_real_web_contents_ssl_unittest.cc`）

| 测试用例 | 验收标准 |
|----------|---------|
| `IsErrorPage_TriggersOnSSLError` | DidFinishNavigation 时 IsErrorPage()=true 且 cert_status 有错误位 → 触发 OnSSLError 回调，安全等级为 kDangerous |
| `NotErrorPage_AlreadyAllowed_PushesWarning` | DidFinishNavigation 时 IsErrorPage()=false 且 cert_status 有错误位（用户已 AllowCert） → 不触发 OnSSLError，推送 kWarning 安全等级 |
| `NoCertError_NormalNavigation` | DidFinishNavigation 时 cert_status 无错误位 → 不触发 OnSSLError，安全等级由 ComputeSecurityLevel 决定 |
| `PendingSSLError_WebContentsDestroyed` | WebContents 销毁时 pending_ssl_errors_ 被清空，不触发 UAF |

#### 8.1c C++ GTest — ComputeSecurityLevel（`host/owl_real_web_contents_ssl_unittest.cc`）

| 测试用例 | 验收标准 |
|----------|---------|
| `Localhost_ReturnsSecure` | ComputeSecurityLevel(http://localhost/...) → kSecure |
| `Loopback_ReturnsSecure` | ComputeSecurityLevel(http://127.0.0.1/...) → kSecure |
| `HTTP_ReturnsInfo` | ComputeSecurityLevel(http://example.com/) → kInfo |
| `HTTPS_ValidCert_ReturnsSecure` | ComputeSecurityLevel(https://example.com/, valid SSLInfo) → kSecure |
| `HTTPS_CertError_ReturnsDangerous` | ComputeSecurityLevel(https://example.com/, cert_status has error) → kDangerous |
| `HTTPS_NoSSLInfo_ReturnsInfo` | ComputeSecurityLevel(https://example.com/, std::nullopt) → kInfo |
| `AboutBlank_ReturnsInfo` | ComputeSecurityLevel(about:blank, std::nullopt) → kInfo |

#### 8.2 Swift ViewModel 单元测试（`OWLUnitTests`）

| 测试用例 | 验收标准 |
|----------|---------|
| `testSecurityLevelHTTPS` | updateFromPageInfo(url="https://...") → level == .secure |
| `testSecurityLevelHTTP` | updateFromPageInfo(url="http://...") → level == .info |
| `testSSLErrorSetsLevelDangerous` | onSSLError(...) → level == .dangerous，pendingSSLError != nil |
| `testGoBackToClearsPending` | goBackToSafety() → pendingSSLError == nil，onRespondToSSLError 以 false 调用 |
| `testProceedAnywaySetWarning` | proceedAnyway() → level == .warning，pendingSSLError == nil，onRespondToSSLError 以 true 调用 |
| `testLoadingStateTransition` | onNavigationStarted() → level == .loading |

#### 8.3 Pipeline E2E 测试（`OWLBrowserTests`）

| 测试用例 | 验收标准 |
|----------|---------|
| `testHTTPSShowsSecureIndicator` | 导航到 https://example.com → SecurityViewModel.level == .secure（AC-P4-1） |
| `testHTTPShowsInfoIndicator` | 导航到 http://example.com → SecurityViewModel.level == .info（AC-P4-2） |

> Pipeline 测试无法访问真实的自签名证书站点，SSL 错误路径（AC-P4-3 到 AC-P4-6）通过 Mock Bridge 回调注入测试。

#### 8.4 Mock Bridge 注入测试（`OWLUnitTests` / MockConfig 模式）

```swift
// 在 MockConfig 中注入 SSL 错误回调
browserVM.securityViewModel.onSSLError(
    url: "https://expired.badssl.com",
    certSubject: "*.badssl.com",
    errorDesc: "net::ERR_CERT_DATE_INVALID",
    errorId: 42
)
// 验证 SSLErrorPage 可见
// 点击"返回安全页面" → 验证 goBackToSafety() 调用
// 点击"继续访问"（确认 Alert）→ 验证 proceedAnyway() 调用
```

#### 8.5 关键 Pitfall 预防

1. **`DidFinishNavigation` 中的 `GetSSLInfo()` 可能为 `std::nullopt`**：非 HTTPS URL 时返回空，需 `has_value()` 检查
2. **`already_allowed` 判断防止无限触发 `OnSSLError`**：用户 proceed 后再次导航同站点，cert_status 仍有错误位，需通过 `QueryPolicy` 区分
3. **`pending_ssl_errors_` 内存管理**：SSL error_id 生命周期绑定到 WebContents；WebContents 销毁时调用 `pending_ssl_errors_.clear()`，避免客户端发来 stale error_id
4. **Mojo Observer 线程安全**：`OnSSLError` 只能在 UI thread 调用 `observer_->is_connected()`，与现有 `OnPermissionRequest` 模式一致
5. **`RespondToSSLError` 的 `Reload()` 时序**：`AllowCert()` 必须在 `Reload()` 之前调用，否则新的导航仍会触发错误
