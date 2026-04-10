# Phase 1: WebView 路由重构 (BH-001)

## Goal
消除 `g_real_web_contents` 全局单例，所有 WebView 操作通过 `webview_id` 路由。

## Scope
- **Modified**: `host/owl_web_contents.h`, `host/owl_web_contents.cc`, `host/owl_real_web_contents.mm`, `host/owl_web_contents_unittest.cc`
- **Layers**: Host

## Dependencies
- None (foundational change)

## Key Technical Points
1. 重新键控 `g_real_web_contents_map`: `Remote*` → `uint64_t webview_id`，使用 `base::flat_map`
2. 修改 14+ 个 `g_real_*` 函数指针签名添加 `uint64_t webview_id`
3. `OWLWebContents` 构造时注入 `webview_id_` 成员
4. 删除 `g_real_web_contents` 裸指针
5. Cursor swizzle 保留 `g_active_webview_id`（已知限制）
6. `owl_web_contents_unittest.cc` 有 3500+ 行需更新

## Acceptance Criteria
- [ ] `g_real_web_contents` 裸指针已删除
- [ ] 所有函数指针签名包含 `webview_id` 参数
- [ ] GTest: GoBack on WebView A 不影响 WebView B
- [ ] GTest: Resize on WebView A 不影响 WebView B
- [ ] 现有测试全部通过（更新签名后）
- [ ] 新增测试 ≥ 5

## 技术方案（Round 2 — 采纳 AutoReset 模式）

### 1. 架构设计

**核心洞察**: 所有 `g_real_*` 函数调用都在 UI thread 同步完成。利用 Chromium 经典的 `base::AutoReset` 模式，在调用前临时设置 `g_active_webview_id`，底层通过该 ID 从 registry 查找 `RealWebContents`。**函数指针签名不变，测试不需要大规模修改**。

```
OWLWebContents (owns webview_id_)
  ↓ base::AutoReset(&g_active_webview_id, webview_id_)
  ↓ calls g_real_go_back_func()  // 签名不变
RealGoBack()
  ↓ reads g_active_webview_id → looks up base::IDMap
RealWebContents instance
```

### 2. 数据模型变更

**删除**:
- `g_real_web_contents`（裸指针单例）
- `g_real_web_contents_map`（`Remote*`-keyed map）

**新增/修改**:
- `base::IDMap<RealWebContents*> g_webview_registry` — webview_id 到实例的映射（使用 Chromium 标准 IDMap，提供 O(1) 查找、自动 ID 分配、防 ID 复用）
- `OWLWebContents::webview_id_`（`uint64_t`，**构造函数参数**，非 setter 注入，消除 Bind 后竞态）
- `RealWebContents::wid_`（`uint64_t`，构造时注入，供 Chromium 内部回调使用）
- `g_active_webview_id` — 从 `std::atomic<uint64_t>` 改为普通 `uint64_t`（整个设计已声明仅 UI thread 访问，atomic 无必要），语义从"单例活跃 ID"变为"当前调用上下文的 ID"。`base::AutoReset<uint64_t>` 要求普通赋值语义，不兼容 `std::atomic`

**线程约束**: `g_webview_registry` 仅在 UI thread 访问，添加 `SEQUENCE_CHECKER(ui_sequence_checker_)` 保护

### 3. 接口设计 — 函数指针签名不变

**所有全局函数指针签名保持不变**。路由通过 `g_active_webview_id` + `g_webview_registry` 间接完成。

### 4. 核心逻辑

**OWLWebContents 构造注入 webview_id + AutoReset**:
```cpp
class OWLWebContents {
  const uint64_t webview_id_;  // 构造时注入，不可变
public:
  OWLWebContents(uint64_t webview_id, ClosedCallback closed_callback);
  
  void GoBack(GoBackCallback cb) override {
    base::AutoReset<uint64_t> scoped(&g_active_webview_id, webview_id_);
    if (g_real_go_back_func) g_real_go_back_func();
    std::move(cb).Run();
  }
  // Navigate, Resize, Mouse/Key/Wheel, Find, Zoom 等同理
};
```

**RealNavigate 注册到 IDMap**:
```cpp
void RealNavigate(const GURL& url, Remote* observer) {
  uint64_t wid = g_active_webview_id;  // AutoReset 已设置
  auto* existing = g_webview_registry.Lookup(wid);
  if (existing) {
    existing->Navigate(url);
  } else {
    auto* rwc = new RealWebContents(wid, url, observer);
    g_webview_registry.AddWithID(rwc, wid);
  }
}
```

**RealGoBack 读取 g_active_webview_id**:
```cpp
void RealGoBack() {  // 签名不变
  auto* rwc = g_webview_registry.Lookup(g_active_webview_id);
  if (rwc) rwc->web_contents()->GetController().GoBack();
}
```

**RealDetachObserver 清理**:
```cpp
void RealDetachObserver() {  // 签名不变
  uint64_t wid = g_active_webview_id;
  auto* rwc = g_webview_registry.Lookup(wid);
  if (rwc) {
    rwc->DetachObserver();
    g_webview_registry.Remove(wid);
    delete rwc;
  }
}
```

**RealWebContents 存储 wid_ 供 Chromium 回调**:
```cpp
class RealWebContents : public WebContentsDelegate, ... {
  uint64_t wid_;
public:
  RealWebContents(uint64_t wid, const GURL& url, Remote* observer)
    : wid_(wid), ... {}
  
  void DidFinishNavigation(NavigationHandle* handle) override {
    // 使用存储的 wid_ 查找 observer，而非依赖全局单例
    // history_service_ 通过构造注入（Phase 2 BH-016）
  }
};
```

**webview_id 注入时机**: `OWLBrowserContext::CreateWebView()` 中通过构造函数参数注入（非 setter），保证 `Bind()` 前 ID 已确定。

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `host/owl_web_contents.h` | 修改 | OWLWebContents 构造函数添加 webview_id，添加 webview_id_ 成员 |
| `host/owl_web_contents.cc` | 修改 | 每个方法添加 `base::AutoReset` |
| `host/owl_real_web_contents.mm` | 修改 | 重新键控为 IDMap，RealWebContents 存储 wid_，Real* 函数读 g_active_webview_id 查找 |
| `host/owl_web_contents_unittest.cc` | 修改 | 仅更新 OWLWebContents 构造（添加 webview_id 参数），函数指针 lambda **不需要改** |
| `host/owl_browser_context.cc` | 修改 | CreateWebView 传入递增 ID |

**预估测试变更量**: ~50 行（构造函数参数变更），而非 3500 行

### 6. 测试策略

**新增 GTest**:
1. `MultiWebViewGoBackTest`: 2 个 WebView，GoBack on A 不影响 B（通过 AutoReset 验证）
2. `MultiWebViewResizeTest`: Resize on A 不影响 B
3. `MultiWebViewFindTest`: Find on A 不影响 B
4. `WebViewRegistryCleanupTest`: Close 后 IDMap 中移除，再调用 GoBack 不 crash
5. `WebViewIdConstructorTest`: webview_id 在构造后正确设置
6. `CloseAndOperateTest`: Close WebView 后再调用 GoBack 防御（dangling pointer 测试）
7. `WebViewIdZeroTest`: webview_id=0 时的防御行为

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| AutoReset 仅保护同步调用栈 | 所有 g_real_* 调用在 UI thread 同步完成，AutoReset scope 覆盖整个调用 |
| IDMap 在 Chromium 回调中不可用 | RealWebContents 存储 wid_，回调中直接使用 |
| Cursor swizzle 无 AutoReset scope | 保留 g_active_webview_id 的 tab 切换更新机制（SetActive 时设置） |
| base::IDMap ID 空间冲突 | 始终使用 `AddWithID()`（不混用 `Add()`），ID 由 `OWLBrowserContext` 递增分配（从 1 开始），IDMap 内部自增不被使用 |
| RealNavigate 重复调用 observer 更新 | 同一 wid 二次 Navigate 时 observer 指针不变（Mojo Remote 地址不变，只是内容更新），无需额外处理 |

## Status
- [ ] Tech design review
- [ ] Development
- [ ] Code review
- [ ] Tests pass
