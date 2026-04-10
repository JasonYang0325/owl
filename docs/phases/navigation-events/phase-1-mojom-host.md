# Phase 1: Mojom + Host 导航事件

## 目标
- 在 Host C++ 层捕获 Chromium 导航生命周期事件（Started/Committed/Failed/Redirect）
- 通过 Mojom 接口将事件传递给客户端
- GTest 验证事件序列正确性

## 范围

### 修改文件
| 文件 | 变更 |
|------|------|
| `mojom/web_view.mojom` | 新增 NavigationEvent struct + 3 个 Observer 方法（Started/Committed/Failed） |
| `host/owl_real_web_contents.mm` | 扩展 DidStartNavigation + 新增 DidRedirectNavigation + 扩展 DidFinishNavigation + 加 DidFinishLoad/DidFailLoad 主帧过滤 |
| `host/owl_web_contents_unittest.cc` | MockObserver 补全新方法 + 事件序列测试 |
| `host/owl_browser_context_unittest.cc` | MockObserver 补全新方法（空实现） |

### 编译适配（非功能变更）
Mojom Observer 新增方法导致所有实现编译失败，需同步补全空 stub：
| 文件 | 变更 |
|------|------|
| `bridge/OWLBridgeWebView.mm` | 3 个 Observer 空 stub |
| `bridge/owl_bridge_api.cc` | 3 个 Observer 空 stub |

### 不涉及
- Bridge C-ABI 功能逻辑（Phase 2）
- Swift/SwiftUI（Phase 2）
- HTTP Auth（OnAuthRequired/RespondToAuthChallenge 推迟到 Phase 3 Mojom 变更）
- CLI（Phase 4）

## 依赖
- 无前置依赖

## 技术要点

### NavigationEvent Mojom 定义（精简版）
```mojom
struct NavigationEvent {
  int64 navigation_id;     // Chromium NavigationHandle::GetNavigationId()
  string url;              // 截断至 2KB（data: URL 安全）
  bool is_user_initiated;  // !IsRendererInitiated()
  bool is_redirect;        // DidRedirectNavigation 触发时为 true
  int32 http_status_code;  // 0 for Started/Redirect, real code for Committed
};
```

**已删除字段**:
- `is_main_frame`: Host 已过滤子帧，恒为 true，无信息量
- `is_ssl`: 客户端可从 URL scheme 推导（`url.hasPrefix("https://")`)

### Host 回调映射
| Chromium 回调 | OWL 处理 |
|--------------|----------|
| `DidStartNavigation(handle)` | 过滤主帧 + 过滤 same-document → `OnNavigationStarted(event)` |
| `DidRedirectNavigation(handle)` | 同上，`is_redirect=true` |
| `DidFinishNavigation(handle)` commit 成功 | 过滤 same-document → `OnNavigationCommitted(event)` |
| `DidFinishNavigation(handle)` 错误 | `IsErrorPage()` 或 `!HasCommitted()` → `OnNavigationFailed(nav_id, url, error, desc)` |
| `DidFinishLoad(rfh, url)` | 🆕 加主帧过滤（已有但缺失） |
| `DidFailLoad(rfh, url, code)` | 🆕 加主帧过滤（已有但缺失） |

### 已知陷阱
- `DidFinishNavigation` 对 error page 和正常 commit 都会触发，必须检查 `IsErrorPage()` 和 `HasCommitted()`
- **Same-document 导航**（hash change / pushState）也触发 `DidStartNavigation` + `DidFinishNavigation`，必须用 `IsSameDocument()` 过滤
- 子帧导航也会触发回调，必须用 `IsInPrimaryMainFrame()` 过滤
- Mojom 新增 Observer 方法会导致所有现有实现编译失败，需同步更新所有 stub
- `navigation_id` 来自 `NavigationHandle::GetNavigationId()`，是 int64
- **URL 安全**: `data:` URL 可能很大（2MB），必须截断 `url` 字段至 2KB 以防 IPC 膨胀

### 与 OnSSLError 分流
- SSL 证书错误（ERR_CERT_*）走现有 `OnSSLError` 流程
- SSL 协议错误（ERR_SSL_PROTOCOL_ERROR）走 `OnNavigationFailed`
- 判断方法：`net::IsCertificateError(handle->GetNetErrorCode())`

### 与 OnLoadFinished 并存
- 现有 `DidFinishLoad` / `DidFailLoad` **不过滤主帧**，任意子帧失败都会触发 `OnLoadFinished(false)`
- Phase 1 修复：为 `DidFinishLoad` 和 `DidFailLoad` 添加 `rfh->IsInPrimaryMainFrame()` 检查
- 新旧事件关系：`OnNavigationFailed` 驱动错误页面，`OnLoadFinished(false)` 仅做进度条兼容性重置

## 验收标准
- [ ] Mojom 编译通过，NavigationEvent struct 可序列化
- [ ] `DidStartNavigation` 触发 `OnNavigationStarted`（仅主帧，非 same-document）
- [ ] `DidRedirectNavigation` 触发 `OnNavigationStarted(is_redirect=true)`
- [ ] `DidFinishNavigation` commit 成功触发 `OnNavigationCommitted`（非 same-document）
- [ ] `DidFinishNavigation` 错误触发 `OnNavigationFailed`
- [ ] Same-document 导航不触发任何新事件
- [ ] GTest: 事件序列验证
- [ ] 现有测试不回归

## 技术方案

### 1. 架构设计

```
Chromium WebContentsObserver 回调
    │
    ▼
RealWebContents (owl_real_web_contents.mm)
    │  过滤: IsInPrimaryMainFrame() + !IsSameDocument()
    │  提取: navigation_id, url (截断), is_user_initiated
    │  截断: URL > 2KB 时截断并追加 "...[truncated]"
    ▼
Mojo WebViewObserver (web_view.mojom)
    │  OnNavigationStarted / OnNavigationCommitted / OnNavigationFailed
    ▼
Bridge / Swift（Phase 2 接收）
```

数据流：单向推送，Host → Client。

### 2. 数据模型

#### Mojom 新增（web_view.mojom）

```mojom
// NavigationEvent 结构体（新增，放在 WebViewObserver 之前）
struct NavigationEvent {
  int64 navigation_id;
  string url;               // 截断至 2KB
  bool is_user_initiated;
  bool is_redirect;
  int32 http_status_code;   // 0 for Started/Redirect
};

// WebViewObserver 新增方法（在 OnLoadFinished 之后）:
OnNavigationStarted(NavigationEvent event);
OnNavigationCommitted(NavigationEvent event);
OnNavigationFailed(int64 navigation_id, string url,
                   int32 error_code, string error_description);
```

**注意**: Auth 接口（OnAuthRequired / RespondToAuthChallenge）推迟到 Phase 3 再添加到 Mojom。

### 3. 接口设计

#### RealWebContents 扩展

```cpp
// owl_real_web_contents.mm

// URL 截断工具（私有方法）
// 保证返回值总长度 <= 2048 字节（含 truncation marker）
static constexpr size_t kMaxNavigationUrlLength = 2048;
static constexpr char kTruncationMarker[] = "...[truncated]";
std::string TruncateUrl(const GURL& url) {
    std::string spec = url.spec();
    if (spec.size() > kMaxNavigationUrlLength) {
        spec.resize(kMaxNavigationUrlLength - strlen(kTruncationMarker));
        spec += kTruncationMarker;
    }
    return spec;
}

// NavigationEvent 构建工厂（消除 Started/Committed 重复赋值）
owl::mojom::NavigationEventPtr BuildNavigationEvent(
    content::NavigationHandle* handle,
    bool is_redirect = false) {
    auto event = owl::mojom::NavigationEvent::New();
    event->navigation_id = handle->GetNavigationId();
    event->url = TruncateUrl(handle->GetURL());
    event->is_user_initiated = !handle->IsRendererInitiated();
    event->is_redirect = is_redirect;
    event->http_status_code =
        handle->GetResponseHeaders()
            ? handle->GetResponseHeaders()->response_code() : 0;
    return event;
}

// 内部分发方法（消除 Started/Redirect 重复）
void DispatchNavigationStarted(content::NavigationHandle* handle,
                                bool is_redirect) {
    if (observer_ && observer_->is_connected()) {
        (*observer_)->OnNavigationStarted(
            BuildNavigationEvent(handle, is_redirect));
    }
}

// 修改: DidStartNavigation（已有，扩展导航事件通知）
void DidStartNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInPrimaryMainFrame()) return;
    ++current_menu_id_;  // existing: context menu stale guard

    // 🆕 过滤 same-document 导航（hash change / pushState）
    if (handle->IsSameDocument()) return;

    DispatchNavigationStarted(handle, /*is_redirect=*/false);
}

// 🆕 DidRedirectNavigation
void DidRedirectNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInPrimaryMainFrame()) return;
    DispatchNavigationStarted(handle, /*is_redirect=*/true);
}

// 修改: DidFinishNavigation（已有，扩展错误检测）
void DidFinishNavigation(content::NavigationHandle* handle) override {
    NotifyPageInfo();  // existing

    if (!handle->IsInPrimaryMainFrame()) return;

    if (handle->HasCommitted() && !handle->IsErrorPage()) {
        // existing: 渲染表面轮询重启 + 历史记录写入
        // ...existing code unchanged...

        // 🆕 过滤 same-document，仅跨文档 commit 触发
        if (!handle->IsSameDocument()) {
            if (observer_ && observer_->is_connected()) {
                (*observer_)->OnNavigationCommitted(
                    BuildNavigationEvent(handle, /*is_redirect=*/false));
            }
        }
    } else if (handle->IsErrorPage() || !handle->HasCommitted()) {
        // 🆕 导航失败事件
        int net_error = handle->GetNetErrorCode();

        // SSL 证书错误走 OnSSLError，不重复通知
        if (net::IsCertificateError(net_error)) return;

        // 所有失败都通知（含 ERR_ABORTED），客户端按 error_code 区分行为:
        // - ERR_ABORTED (-3): 用户主动 Stop 或被新导航覆盖 → 不显示错误页
        // - 其他: 显示友好错误页
        if (observer_ && observer_->is_connected()) {
            (*observer_)->OnNavigationFailed(
                handle->GetNavigationId(),
                TruncateUrl(handle->GetURL()),
                net_error,
                net::ErrorToString(net_error));
        }
    }
}

// 修改: DidFinishLoad（已有，🆕 加主帧过滤）
void DidFinishLoad(content::RenderFrameHost* rfh,
                   const GURL& validated_url) override {
    if (!rfh->IsInPrimaryMainFrame()) return;  // 🆕
    if (observer_ && observer_->is_connected()) {
        (*observer_)->OnLoadFinished(true);
    }
    NotifyPageInfo();
}

// 修改: DidFailLoad（已有，🆕 加主帧过滤）
void DidFailLoad(content::RenderFrameHost* rfh,
                 const GURL& validated_url,
                 int error_code) override {
    if (!rfh->IsInPrimaryMainFrame()) return;  // 🆕
    if (observer_ && observer_->is_connected()) {
        (*observer_)->OnLoadFinished(false);
    }
}
```

### 4. 核心逻辑

#### 事件序列保证

```
正常导航:     Started(X) → Committed(X)
重定向导航:   Started(X, redirect=false) → Started(X, redirect=true) → Committed(X)
失败导航:     Started(X) → Failed(X, error_code)
用户取消:     Started(X) → Failed(X, ERR_ABORTED=-3)
新导航覆盖:   Started(X) → Started(Y), X 被 Chromium 取消
              可能收到 Failed(X, ERR_ABORTED) 也可能不收到（取决于导航阶段）
Same-doc:     不触发任何新事件（Hash change / pushState 被过滤）
SSL 证书错误: Started(X) → [OnSSLError, 无 Committed/Failed]
              客户端通过下一个 Started(Y) 或 OnSSLError 判断旧导航结束
```

**客户端状态机指导**（给 Phase 2 的约定）:
- 收到 `Started(nav_id=Y)` 时，丢弃所有 `nav_id != Y` 的后续事件
- `ERR_ABORTED` (-3) = 用户主动取消或被覆盖 → 不显示错误页
- 其他 error_code → 显示错误页

#### DidFinishNavigation 分支逻辑

```
DidFinishNavigation(handle)
  ├── !IsInPrimaryMainFrame() → return
  ├── HasCommitted() && !IsErrorPage()
  │   ├── [已有] 渲染表面轮询重启
  │   ├── [已有] 历史记录写入
  │   └── !IsSameDocument()
  │       └── [新增] OnNavigationCommitted(event)
  └── IsErrorPage() || !HasCommitted()
      ├── IsCertificateError(net_error) → return (走 OnSSLError)
      └── [新增] OnNavigationFailed(nav_id, url, error, desc)
          客户端根据 error_code 区分:
          - ERR_ABORTED: 静默处理
          - 其他: 显示错误页
```

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/web_view.mojom` | 修改 | NavigationEvent struct + 3 个 Observer 方法 |
| `host/owl_real_web_contents.mm` | 修改 | 扩展 3 个回调 + 新增 1 个回调 + DidFinishLoad/DidFailLoad 主帧过滤 |
| `host/owl_web_contents_unittest.cc` | 修改 | MockObserver 补全 + 事件序列 GTest |
| `host/owl_browser_context_unittest.cc` | 修改 | MockObserver 补全空实现 |
| `bridge/OWLBridgeWebView.mm` | 修改 | 3 个 Observer 空 stub（编译适配） |
| `bridge/owl_bridge_api.cc` | 修改 | 3 个 Observer 空 stub（编译适配） |

### 6. 测试策略

#### GTest 用例（Mirror test 级别）

```cpp
// owl_web_contents_unittest.cc — MockObserver 扩展

// MockObserver 新增记录:
struct RecordedNavEvent {
    int64_t navigation_id;
    std::string url;
    bool is_redirect;
    int http_status;
};
std::vector<RecordedNavEvent> nav_started_events_;
std::vector<RecordedNavEvent> nav_committed_events_;
struct RecordedNavError {
    int64_t navigation_id;
    int error_code;
};
std::vector<RecordedNavError> nav_failed_events_;

// Test cases:
// 1. 基本事件记录（Started → Committed 序列）
// 2. Same-document 过滤验证（hash change 不触发事件）
// 3. 子帧过滤验证（子帧 Started 不触发）
// 4. URL 截断验证（>2KB 的 data: URL，总长度 <= 2048）
// 5. DidFinishNavigation 分支覆盖:
//    a. HasCommitted && !IsErrorPage → OnNavigationCommitted
//    b. IsErrorPage → OnNavigationFailed
//    c. !HasCommitted → OnNavigationFailed
//    d. ERR_ABORTED → OnNavigationFailed(error_code=-3)
//    e. IsCertificateError → 不触发 OnNavigationFailed（走 OnSSLError）
// 6. DidFinishLoad/DidFailLoad 主帧过滤（子帧不触发 OnLoadFinished）
```

**注意**: Mirror test 验证 Mock 调用，非端到端。Pipeline test 在 Phase 2 后补充。

### 7. 风险 & 缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| Mojom 新增方法导致全量编译失败 | 所有 Observer 实现需同步更新 | 同一 commit 更新所有 stub |
| Same-document 过滤遗漏 | 进度条/错误页误触发 | `IsSameDocument()` 在 Started + Committed 两处都检查 |
| data: URL 膨胀 IPC | 性能/内存 | TruncateUrl 截断至 2KB |
| DidFinishLoad 子帧 → OnLoadFinished(false) 误触 | 进度条闪烁 | 本 phase 修复主帧过滤 |
| ERR_ABORTED 多义（stop/覆盖/下载） | 客户端误判 | 统一通知，客户端按 error_code 区分 |
| DidFinishNavigation 对同一导航多次触发 | 事件重复 | 客户端用 navigation_id 去重 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
