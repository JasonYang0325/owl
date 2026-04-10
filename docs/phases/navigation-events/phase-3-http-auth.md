# Phase 3: HTTP Auth 全栈

## 目标
- Host 层实现 HTTP 认证拦截（CreateLoginDelegate）
- 通过 Mojom + Bridge 传递 Auth 挑战到 Swift
- SwiftUI 实现 AuthAlertView（.sheet 对话框）
- 支持 401 和 407，3 次失败上限

## 范围

### 新增文件
| 文件 | 内容 |
|------|------|
| `host/owl_login_delegate.h` | OWLLoginDelegate 声明 |
| `host/owl_login_delegate.cc` | OWLLoginDelegate 实现（weak_ptr + auth_id 映射 + 计数器） |
| `owl-client-app/Views/Alert/AuthAlertView.swift` | Auth 对话框 UI |

### 修改文件
| 文件 | 变更 |
|------|------|
| `host/owl_content_browser_client.h` | 新增 `CreateLoginDelegate()` 覆写声明 |
| `host/owl_content_browser_client.mm` | `CreateLoginDelegate()` 实现 |
| `host/BUILD.gn` | 添加 owl_login_delegate 源文件 |
| `bridge/owl_bridge_api.h` | 新增 auth callback typedef + setter + RespondToAuth |
| `bridge/owl_bridge_api.cc` | Observer OnAuthRequired → C-ABI 回调 + RespondToAuth 实现 |
| `bridge/OWLBridgeWebView.mm` | OnAuthRequired stub |
| `owl-client-app/ViewModels/TabViewModel.swift` | 新增 authChallenge 属性 + Auth 回调处理 |
| `owl-client-app/Views/BrowserWindow.swift` | 添加 .sheet(item: authChallenge) |

## 依赖
- Phase 1（Host 导航事件已实现）
- Phase 2（Bridge C-ABI 模式已建立）
- 注意: Auth Mojom 接口（OnAuthRequired/RespondToAuthChallenge）在 Phase 1 被推迟，需在本 Phase 添加

## 技术要点

### ContentBrowserClient::CreateLoginDelegate
```cpp
std::unique_ptr<content::LoginDelegate> OWLContentBrowserClient::CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* web_contents,
    content::LoginDelegate::LoginAuthRequiredCallback auth_required_callback) {
  // 生成 auth_id，创建 OWLLoginDelegate
  // 通过 Observer 发送 OnAuthRequired
}
```

### OWLLoginDelegate 生命周期
- Chromium 拥有 unique_ptr，导航结束时自动销毁
- Host 通过 WeakPtrFactory 持有 WeakPtr
- pending_auth_requests_ map: key=auth_id, value=weak_ptr
- auth_failure_counts_ map: key=origin+realm, value=count (max 3)

### Auth 计数器规则
- key = origin (scheme+host+port) + realm
- 认证失败 → count++
- 认证成功 → count = 0
- count >= 3 → 自动 CancelAuth，不发 OnAuthRequired
- 页面刷新 → 不重置
- 新 tab → 独立计数器（不同 WebContents）

### AuthAlertView .sheet 挂载
```swift
// BrowserWindow body 中
.sheet(item: $activeTab.authChallenge) { challenge in
    AuthAlertView(
        url: challenge.url,
        realm: challenge.realm,
        isProxy: challenge.isProxy,
        failureCount: challenge.failureCount,
        onSubmit: { username, password in ... },
        onCancel: { ... }
    )
}
```

### 已知陷阱
- `CreateLoginDelegate` 必须返回 non-null，否则 Chromium 会默认拒绝
- `LoginAuthRequiredCallback` 只能调用一次（SetAuth 或 CancelAuth）
- Auth 弹窗期间用户导航 → Chromium 销毁 LoginDelegate → weak_ptr 失效 → Swift 侧关闭弹窗
- 登录按钮仅当用户名为空时 disabled（密码允许空）

## 验收标准
- [ ] 访问 401 页面弹出 Auth 对话框（显示 realm + URL）
- [ ] 输入正确凭证后页面正常加载
- [ ] 取消对话框后不重试
- [ ] 错误凭证后再次弹出（显示红色错误提示）
- [ ] 3 次失败后显示"认证失败"错误页
- [ ] 407 代理认证显示"代理认证"标识
- [ ] GTest: auth challenge/respond/cancel 序列
- [ ] build_all.sh 编译通过

## 技术方案

### 1. Mojom 新增

```mojom
// WebViewObserver 新增:
OnAuthRequired(string url, string realm, string scheme,
               uint64 auth_id, bool is_proxy);

// WebViewHost 新增:
RespondToAuthChallenge(uint64 auth_id, string? username, string? password);
```

所有现有 Observer/Host 实现需同步补全 stub。

### 2. Host: OWLLoginDelegate

```cpp
// owl_login_delegate.h
class OWLLoginDelegate : public content::LoginDelegate {
 public:
  OWLLoginDelegate(
      const net::AuthChallengeInfo& auth_info,
      content::LoginDelegate::LoginAuthRequiredCallback callback,
      uint64_t auth_id,
      base::WeakPtr<RealWebContents> web_contents);
  ~OWLLoginDelegate() override;

 private:
  content::LoginDelegate::LoginAuthRequiredCallback callback_;
  uint64_t auth_id_;
  base::WeakPtrFactory<OWLLoginDelegate> weak_factory_{this};
};
```

关键实现:
- `OWLLoginDelegate` 持有 `LoginAuthRequiredCallback`（只能调用一次）
- 析构时如果 callback 未消费，自动 CancelAuth
- `RealWebContents` 持有 `pending_auth_map_<auth_id, WeakPtr<OWLLoginDelegate>>` 和 `auth_failure_counts_<origin+realm, int>`

### 3. Host: CreateLoginDelegate

```cpp
// owl_content_browser_client.cc 新增
std::unique_ptr<content::LoginDelegate>
OWLContentBrowserClient::CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* web_contents,
    content::BrowserContext* browser_context,
    const content::GlobalRequestID& request_id,
    bool is_main_frame,
    const GURL& url,
    scoped_refptr<net::HttpResponseHeaders> response_headers,
    bool first_auth_attempt,
    content::LoginDelegate::LoginAuthRequiredCallback auth_required_callback) {
  // 只处理主帧
  if (!is_main_frame) return nullptr;
  // 查找 RealWebContents → 检查失败计数 → 生成 auth_id
  // → 创建 OWLLoginDelegate → 通过 Observer 发送 OnAuthRequired
  // → 返回 delegate
}
```

### 4. Host: RespondToAuthChallenge

通过 function pointer injection 模式:
```cpp
// owl_web_contents.h 新增:
using RealRespondToAuthFunc = void (*)(uint64_t auth_id,
                                       const std::string* username,
                                       const std::string* password);
inline RealRespondToAuthFunc g_real_respond_to_auth_func = nullptr;
```

OWLWebContents::RespondToAuthChallenge → g_real_respond_to_auth_func → RealWebContents 查找 pending_auth_map_ → 调用 LoginDelegate callback。

### 5. Bridge C-ABI

```c
typedef void (*OWLBridge_AuthRequiredCallback)(
    const char* url, const char* realm, const char* scheme,
    uint64_t auth_id, int is_proxy, void* ctx);

OWL_EXPORT void OWLBridge_SetAuthRequiredCallback(
    uint64_t webview_id, OWLBridge_AuthRequiredCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_RespondToAuth(
    uint64_t auth_id, const char* username, const char* password);
```

### 6. Swift AuthAlertView

```swift
struct AuthChallenge: Identifiable {
    let id = UUID()
    let authId: UInt64
    let url: String
    let realm: String
    let isProxy: Bool
    let failureCount: Int
}

struct AuthAlertView: View {
    let challenge: AuthChallenge
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void
    @State private var username = ""
    @State private var password = ""
    // .sheet on BrowserWindow
}
```

### 7. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/web_view.mojom` | 修改 | OnAuthRequired + RespondToAuthChallenge |
| `host/owl_login_delegate.h/.cc` | 新增 | LoginDelegate 实现 |
| `host/owl_content_browser_client.h/.cc` | 修改 | CreateLoginDelegate 覆写 |
| `host/owl_real_web_contents.mm` | 修改 | pending_auth_map + auth_failure_counts + RespondToAuth |
| `host/owl_web_contents.h/.cc` | 修改 | RespondToAuthChallenge + function pointer |
| `host/BUILD.gn` | 修改 | 添加 owl_login_delegate 源文件 |
| `bridge/owl_bridge_api.h/.cc` | 修改 | Auth callback + RespondToAuth |
| `bridge/OWLBridgeWebView.mm` | 修改 | OnAuthRequired stub |
| `owl-client-app/Models/AuthChallenge.swift` | 新增 | AuthChallenge model |
| `owl-client-app/Views/Alert/AuthAlertView.swift` | 新增 | Auth 对话框 |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | authChallenge 属性 |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | Auth callback 注册 |
| `owl-client-app/Views/BrowserWindow.swift` | 修改 | .sheet 挂载 |
| 所有 Observer test doubles | 修改 | OnAuthRequired stub |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
