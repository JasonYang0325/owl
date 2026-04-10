# Phase 33: Find-in-Page

## 目标

用户可以在页面中搜索文本，高亮显示匹配项，并在匹配项间导航。

## 范围

### 新增文件
- `owl-client-app/Views/Content/FindBarView.swift` — SwiftUI 查找栏

### 修改文件

| 层级 | 文件 | 变更 |
|------|------|------|
| Mojom | `mojom/web_view.mojom` | +Find, +StopFinding, +OnFindReply |
| Mojom | `mojom/owl_types.mojom` | +FindOptions, +StopFindAction enum |
| Host stub | `host/owl_web_contents.h/.cc` | +Find/StopFinding 方法 + g_real_* |
| Host real | `host/owl_real_web_contents.h/.mm` | +FindRequestManager 集成 + FindReply delegate |
| ObjC++ Bridge | `bridge/OWLBridgeWebView.h/.mm` | +find/stopFinding ObjC 方法 |
| C-ABI | `bridge/owl_bridge_api.h/.cc` | +OWLBridge_Find, +OWLBridge_StopFinding, +SetFindResultCallback |
| Swift VM | `ViewModels/TabViewModel.swift` | +find/stopFinding/findNext 方法, +findState 属性 |
| SwiftUI | `Views/Content/ContentAreaView.swift` | FindBar overlay 集成 |
| GN | `host/BUILD.gn` | 可能需要加 find_in_page 依赖 |
| Tests | `host/owl_web_contents_unittest.cc` | +Find/StopFinding 单元测试 |
| Tests | `Tests/OWLBrowserTests.swift` | +Find E2E 测试 |

## 依赖

- 无前置 phase 依赖
- Chromium 依赖：`content::WebContents::Find()`, `WebContentsDelegate::FindReply()`

## 技术要点

### Chromium Find API

```cpp
// 发起搜索
web_contents_->Find(request_id, search_text, options);

// 结果通过 WebContentsDelegate 回调
void FindReply(WebContents* web_contents,
               int request_id,
               int number_of_matches,
               const gfx::Rect& selection_rect,
               int active_match_ordinal,
               bool final_update);

// 停止搜索
web_contents_->StopFinding(content::STOP_FIND_ACTION_CLEAR_SELECTION);
```

### Mojom 接口设计

```mojom
// WebViewHost 新增
Find(string query, bool forward, bool match_case) => (int32 request_id);
StopFinding(StopFindAction action);

// WebViewObserver 新增
OnFindReply(int32 request_id, int32 number_of_matches,
            int32 active_match_ordinal, bool final_update);

// owl_types.mojom 新增
enum StopFindAction {
  kClearSelection,
  kKeepSelection,
  kActivateSelection,
};
```

### C-ABI 设计

```c
// 发起/继续搜索（forward=1 向下，0 向上）
OWL_EXPORT void OWLBridge_Find(uint64_t webview_id, const char* query,
                                int forward, int match_case,
                                OWLBridge_FindCallback callback, void* ctx);

// 停止搜索
OWL_EXPORT void OWLBridge_StopFinding(uint64_t webview_id, int action);

// 搜索结果回调
typedef void (*OWLBridge_FindResultCallback)(
    int32_t request_id, int32_t number_of_matches,
    int32_t active_match_ordinal, int final_update, void* ctx);
OWL_EXPORT void OWLBridge_SetFindResultCallback(
    uint64_t webview_id, OWLBridge_FindResultCallback callback, void* ctx);
```

### SwiftUI FindBar

- 覆盖在 ContentAreaView 顶部（类似 Safari/Chrome 的 find bar）
- Cmd+F 打开，Escape 关闭
- 实时搜索（输入即搜）
- 显示 "X/Y" 匹配计数
- 上/下箭头按钮导航匹配项

### 已知陷阱

- `FindReply` 回调是增量的：`final_update=false` 时匹配数可能还在增加
- `request_id` 需要递增，用于区分不同搜索会话
- 空字符串查询应调用 StopFinding 而非 Find
- Chromium Find 内部会自动滚动到匹配位置

## 验收标准

- [ ] AC-001: Cmd+F 打开查找栏，光标自动聚焦到输入框
- [ ] AC-002: 输入文本后页面高亮显示所有匹配项
- [ ] AC-003: 查找栏显示匹配计数（如 "3/15"）
- [ ] AC-004: Enter 跳到下一个匹配，Shift+Enter 跳到上一个
- [ ] AC-005: Escape 或点击关闭按钮关闭查找栏并清除高亮
- [ ] AC-006: 无匹配时显示 "0/0" 或 "无匹配"
- [ ] AC-007: C++ 单元测试覆盖 Find/StopFinding stub 和 real 模式
- [ ] AC-008: E2E 集成测试通过 JS 验证 find 功能

---

## 技术方案

### 1. 架构设计

**核心思路**：贯穿全栈 6 层（Mojom → Host C++ → Host Real → C-ABI → Swift VM → SwiftUI），遵循 Phase 33+ 共享决策——新功能统一走 C-ABI 路径。

**模块划分**：

```
SwiftUI FindBarView (输入/显示)
  │
  TabViewModel.find/findNext/stopFinding
  │
  OWLBridge_Find (callback → request_id) / OWLBridge_StopFinding (C-ABI)
  │
  IO thread PostTask → Mojo WebViewHost.Find/StopFinding
  │
  OWLWebContents::Find/StopFinding (stub/real 分发)
  │
  g_real_find_func / g_real_stop_finding_func
  │
  RealWebContents::Find/StopFinding
  │
  content::WebContents::Find / StopFinding (Chromium API)
  │
  FindReply delegate callback → observer_->OnFindReply → C-ABI callback → Swift
```

**数据流（Find）**：
```
用户输入 "hello"
  │
  FindBarView TextField .onChange(of: query)
  │
  TabViewModel.find(query: "hello", forward: true)
  │
  OWLBridge_Find(1, "hello", 1, 0, callback, ctx)
  │  callback → Swift 存 activeFindRequestId（用于过滤过期 FindReply）
  │
  IO thread → remote_->Find("hello", true, false)
  │ => (int32 request_id)
  │
  OWLWebContents::Find("hello", true, false, callback)
  │  空字符串守卫 → 直接返回 request_id=0
  │  request_id = g_real_find_func("hello", true, false)
  │  callback(request_id)
  │
  RealWebContents::Find():
  │  request_id_ += 1
  │  options->new_session = (query != last_query_)
  │  web_contents_->Find(request_id_, u"hello", options)
  │  return request_id_
  │
  Chromium renderer 高亮匹配 → WebContentsDelegate::FindReply
  │
  RealWebContents::FindReply → observer_->OnFindReply(request_id, ...)
  │
  C-ABI find result callback → dispatch_async(main) → Swift callback
  │  guard requestId == vm.activeFindRequestId → 过滤过期结果
  │  guard finalUpdate → 仅最终结果更新 UI（避免闪烁）
  │
  TabViewModel.findState = FindState(active: 2, total: 15)
  │
  FindBarView: 显示 "2/15"
```

**数据流（StopFinding）**：
```
用户按 Escape 或关闭查找栏
  │
  TabViewModel.hideFindBar()
  │  activeFindRequestId = 0  (使所有 in-flight FindReply 过期)
  │  stopFinding()
  │  findState = nil
  │
  OWLBridge_StopFinding(1, kClearSelection)
  │
  IO thread → remote_->StopFinding(kClearSelection)
  │
  OWLWebContents::StopFinding(kClearSelection) → g_real_stop_finding_func
  │
  RealWebContents::StopFinding → web_contents_->StopFinding(STOP_FIND_ACTION_CLEAR_SELECTION)
  │
  渲染器清除所有高亮
  │
  残余 FindReply: requestId != activeFindRequestId(0) → 丢弃
```

### 2. 接口设计

#### 2.1 Mojom 变更

**owl_types.mojom 新增**（Round 1 P0 修复：使用 Mojom enum 保证类型安全和 IPC 校验）：
```mojom
// 停止查找后的行为
enum StopFindAction {
  kClearSelection,
  kKeepSelection,
  kActivateSelection,
};
```

**web_view.mojom WebViewHost 新增**：
```mojom
// 页面内查找。返回此次查找的 request_id，结果通过 OnFindReply 推送。
// 空 query 由 Host 拦截，返回 request_id=0。
Find(string query, bool forward, bool match_case) => (int32 request_id);

// 停止查找。fire-and-forget。
StopFinding(StopFindAction action);
```

**web_view.mojom WebViewObserver 新增**：
```mojom
// 查找结果（增量推送，final_update=false 时可能后续还有更新）。
OnFindReply(int32 request_id, int32 number_of_matches,
            int32 active_match_ordinal, bool final_update);
```

#### 2.2 函数指针（owl_web_contents.h 新增）

```cpp
// Round 1 P0 fix: 函数指针返回 int32_t（同步），OWLWebContents 包装 Mojo 回调。
// Round 1 P1 fix: std::string by value 消除生命周期歧义。
using RealFindFunc = int32_t (*)(std::string query,
                                  bool forward,
                                  bool match_case);
inline RealFindFunc g_real_find_func = nullptr;

// StopFinding: Round 1 P0 fix: 使用 Mojom enum 值（int 映射在分发层完成）。
using RealStopFindingFunc = void (*)(int32_t action);
inline RealStopFindingFunc g_real_stop_finding_func = nullptr;
```

**不新增 OnFindReply 函数指针**——FindReply 在 `RealWebContents`（WebContentsDelegate）中直接通过 `observer_->OnFindReply()` 推送，不经过 `OWLWebContents` 分发层。这与 cursor/caret/render surface 等现有 observer 回调模式一致。

**混合路径说明**：请求（Find）走 OWLWebContents 分发层 → g_real_find_func，响应（OnFindReply）直接从 RealWebContents → observer_ 推送。这与 Navigate（请求走分发层）→ OnPageInfoChanged/OnRenderSurfaceChanged（响应直接走 observer）的模式完全一致。

#### 2.3 C-ABI（owl_bridge_api.h 新增）

```c
// Round 2 fix: 恢复 one-shot callback 传回 request_id（用于精确过滤过期 FindReply）。
// Round 1 P1 fix: 空指针守卫在实现中检查 query != NULL。
typedef void (*OWLBridge_FindCallback)(int32_t request_id, void* ctx);
OWL_EXPORT void OWLBridge_Find(uint64_t webview_id,
                                const char* query,
                                int forward,
                                int match_case,
                                OWLBridge_FindCallback callback,
                                void* callback_context);

// Round 2 fix: C enum 保持与 Mojom StopFindAction 对齐，避免魔术数字。
typedef enum {
    OWLBridgeStopFindAction_ClearSelection = 0,
    OWLBridgeStopFindAction_KeepSelection = 1,
    OWLBridgeStopFindAction_ActivateSelection = 2,
} OWLBridgeStopFindAction;

// 停止搜索（fire-and-forget）
OWL_EXPORT void OWLBridge_StopFinding(uint64_t webview_id,
                                       OWLBridgeStopFindAction action);

// 搜索结果回调（增量推送，可能多次触发）
// Round 2 fix: 过期过滤由 Swift 端 activeFindRequestId 实现，
//   比较 callback 的 request_id 精确丢弃过期结果。
typedef void (*OWLBridge_FindResultCallback)(
    int32_t request_id,
    int32_t number_of_matches,
    int32_t active_match_ordinal,
    int final_update,
    void* ctx);
OWL_EXPORT void OWLBridge_SetFindResultCallback(
    uint64_t webview_id,
    OWLBridge_FindResultCallback callback,
    void* callback_context);
```

**C 字符串安全**：`OWLBridge_Find` 内部在 PostTask 前 `std::string(query)` 拷贝。`query == NULL` 时直接 return。

**webview_id 当前被忽略**：与现有 Navigate/GoBack 等 C-ABI 一致，单 tab 模式下通过 `(*g_webview)` 路由（Round 2 fix: 使用实际代码模式而非虚拟 `GetActiveWebViewState()`）。

#### 2.4 Swift ViewModel（TabViewModel 新增）

```swift
// 查找状态（Round 1 P1 fix: 字段改为 let，每次回调创建新实例）
struct FindState {
    let query: String
    let activeOrdinal: Int  // 1-based
    let totalMatches: Int
    
    init(query: String = "", activeOrdinal: Int = 0, totalMatches: Int = 0) {
        self.query = query
        self.activeOrdinal = activeOrdinal
        self.totalMatches = totalMatches
    }
}

@Published var findState: FindState?
@Published var isFindBarVisible: Bool = false

// Round 2 fix: request_id 精确过滤过期 FindReply（替代有缺陷的 findGeneration）。
// activeFindRequestId 由 OWLBridge_Find callback 设置，
// OnFindReply 中 requestId != activeFindRequestId → 丢弃。
private var activeFindRequestId: Int32 = 0
private var findResultCallbackRegistered = false

func showFindBar() { isFindBarVisible = true }

// Escape → 关闭查找栏
func hideFindBar() {
    isFindBarVisible = false
    activeFindRequestId = 0  // Invalidate all in-flight FindReply
    stopFinding()
    findState = nil
}

// 输入搜索词
func find(query: String, forward: Bool = true) {
    guard !query.isEmpty else {
        activeFindRequestId = 0
        stopFinding()
        findState = FindState()
        return
    }
    #if canImport(OWLBridge)
    setupFindResultCallbackIfNeeded()
    findState = FindState(query: query)
    
    // Round 2 fix: callback 传回 request_id，存入 activeFindRequestId。
    query.withCString { cStr in
        OWLBridge_Find(1, cStr, forward ? 1 : 0, 0, { requestId, ctx in
            let vm = Unmanaged<TabViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            Task { @MainActor in
                // Round 3 fix: 单调递增守卫（防御理论上的回调乱序）。
                guard requestId > vm.activeFindRequestId else { return }
                vm.activeFindRequestId = requestId
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    #endif
}

func findNext() { find(query: findState?.query ?? "", forward: true) }
func findPrevious() { find(query: findState?.query ?? "", forward: false) }

func stopFinding() {
    #if canImport(OWLBridge)
    OWLBridge_StopFinding(1, OWLBridgeStopFindAction_ClearSelection)
    #endif
}

// Round 1 P1 fix: 补充 setupFindResultCallbackIfNeeded 实现。
// 一次性注册，用 Unmanaged.passUnretained (ctx = self)。
// Round 2 fix: 用 activeFindRequestId 精确过滤 + finalUpdate 过滤。
private func setupFindResultCallbackIfNeeded() {
    guard !findResultCallbackRegistered else { return }
    findResultCallbackRegistered = true
    
    OWLBridge_SetFindResultCallback(1, { requestId, numMatches, activeOrdinal, finalUpdate, ctx in
        let vm = Unmanaged<TabViewModel>.fromOpaque(ctx!).takeUnretainedValue()
        Task { @MainActor in
            // Round 2 fix: 精确过滤 — request_id 必须匹配当前活跃搜索
            guard requestId == vm.activeFindRequestId else { return }
            guard vm.isFindBarVisible else { return }
            // Round 2 fix: 仅 finalUpdate 时更新 UI（避免增量回调闪烁）
            guard finalUpdate != 0 else { return }
            
            vm.findState = FindState(
                query: vm.findState?.query ?? "",
                activeOrdinal: Int(activeOrdinal),
                totalMatches: Int(numMatches)
            )
        }
    }, Unmanaged.passUnretained(self).toOpaque())
}
```

**ctx 生命周期分析**：
- `ctx` = `Unmanaged.passUnretained(self)` → TabViewModel 的裸指针。
- TabViewModel 由 BrowserViewModel 强持有，生命周期 >= OWLBridge（单 tab 模式下与 app 同生同灭）。
- 回调中 `Task { @MainActor }` 访问 `vm` 时 TabViewModel 必然存活（单 tab 架构保证）。
- 未来多 tab：改为 `passRetained` + `SetFindResultCallback(nil)` 注销时 `takeRetainedValue`。

### 3. 核心逻辑

#### 3.1 OWLWebContents 分发层（owl_web_contents.cc）

```cpp
// Round 1 P0 fix: 补充 Find/StopFinding 声明到 .h（WebViewHost override）。
// Round 1 P1 fix: 空字符串守卫在 Host 层（多层防御）。
void OWLWebContents::Find(const std::string& query,
                           bool forward,
                           bool match_case,
                           FindCallback callback) {
  // Round 1 P1 fix: 空字符串守卫（Chromium Find 不接受空串）。
  if (query.empty()) {
    std::move(callback).Run(0);
    return;
  }
  if (g_real_find_func) {
    // Round 1 P0 fix: 函数指针同步返回 request_id，
    // OWLWebContents 包装 Mojo 回调。
    int32_t request_id = g_real_find_func(std::string(query), forward, match_case);
    std::move(callback).Run(request_id);
    return;
  }
  // Stub: return request_id = 0, no real find.
  std::move(callback).Run(0);
}

// Round 1 P0 fix: 参数类型改为 StopFindAction enum。
void OWLWebContents::StopFinding(owl::mojom::StopFindAction action) {
  if (g_real_stop_finding_func) {
    g_real_stop_finding_func(static_cast<int32_t>(action));
  }
}
```

#### 3.2 RealWebContents 实现（owl_real_web_contents.mm）

```cpp
class RealWebContents : public content::WebContentsDelegate,
                        public content::WebContentsObserver {
 public:
  // ... existing ...

  int32_t Find(std::string query, bool forward, bool match_case) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return 0;

    int32_t request_id = ++find_request_id_;

    auto options = blink::mojom::FindOptions::New();
    options->forward = forward;
    options->match_case = match_case;
    // new_session = true when query changes, false for find next/prev.
    options->new_session = (query != last_find_query_);
    last_find_query_ = query;

    web_contents_->Find(request_id, base::UTF8ToUTF16(query),
                        std::move(options), /*skip_delay=*/false);
    return request_id;
  }

  void StopFinding(int32_t action) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return;

    content::StopFindAction stop_action;
    switch (action) {
      case 1: stop_action = content::STOP_FIND_ACTION_KEEP_SELECTION; break;
      case 2: stop_action = content::STOP_FIND_ACTION_ACTIVATE_SELECTION; break;
      default: stop_action = content::STOP_FIND_ACTION_CLEAR_SELECTION; break;
    }
    web_contents_->StopFinding(stop_action);
    last_find_query_.clear();
  }

  // WebContentsDelegate override:
  void FindReply(content::WebContents* web_contents,
                 int request_id,
                 int number_of_matches,
                 const gfx::Rect& selection_rect,
                 int active_match_ordinal,
                 bool final_update) override {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);  // Round 2 fix
    if (observer_ && observer_->is_connected()) {
      (*observer_)->OnFindReply(request_id, number_of_matches,
                                active_match_ordinal, final_update);
    }
  }

 private:
  int32_t find_request_id_ = 0;
  std::string last_find_query_;
  // ... existing members ...
};
```

#### 3.3 顶层自由函数（owl_real_web_contents.mm）

```cpp
// Round 1 P0 fix: 同步返回 int32_t，不再接受 OnceCallback。
int32_t RealFind(std::string query, bool forward, bool match_case) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!g_real_web_contents) return 0;
  return g_real_web_contents->Find(std::move(query), forward, match_case);
}

void RealStopFinding(int32_t action) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!g_real_web_contents) return;
  g_real_web_contents->StopFinding(action);
}
```

#### 3.4 函数指针注册（OWLRealWebContents_Init）

```cpp
// Phase 33: Find-in-Page
owl::g_real_find_func = &owl::RealFind;
owl::g_real_stop_finding_func = &owl::RealStopFinding;
```

#### 3.5 C-ABI 实现（owl_bridge_api.cc）

```cpp
// Round 2 fix: 恢复 callback 传回 request_id。
// Round 2 fix: 使用 (*g_webview) 模式（匹配现有代码，非虚拟 GetActiveWebViewState）。
void OWLBridge_Find(uint64_t webview_id,
                    const char* query,
                    int forward,
                    int match_case,
                    OWLBridge_FindCallback callback,
                    void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  if (!callback) return;
  // Round 3 fix: empty/null query 仍调用 callback(0) 保持 C-ABI 契约一致。
  if (!query || !*query) {
    dispatch_async(dispatch_get_main_queue(), ^{ callback(0, ctx); });
    return;
  }
  std::string query_str(query);  // Copy before PostTask.
  
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](std::string q, bool fwd, bool mc,
             OWLBridge_FindCallback cb, void* ctx) {
            if (!(*g_webview) || !(*g_webview)->remote.is_connected()) {
              dispatch_async(dispatch_get_main_queue(), ^{ cb(0, ctx); });
              return;
            }
            (*g_webview)->remote->Find(
                q, fwd, mc,
                base::BindOnce(
                    [](OWLBridge_FindCallback cb, void* ctx,
                       int32_t request_id) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(request_id, ctx);
                      });
                    },
                    cb, ctx));
          },
          std::move(query_str), forward != 0, match_case != 0,
          callback, ctx));
}

// Round 2 fix: bounds check before cast to Mojom enum.
void OWLBridge_StopFinding(uint64_t webview_id,
                            OWLBridgeStopFindAction action) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  int32_t act = static_cast<int32_t>(action);
  if (act < 0 || act > 2) act = 0;  // Clamp to ClearSelection
  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](int32_t act) {
            if ((*g_webview) && (*g_webview)->remote.is_connected()) {
              (*g_webview)->remote->StopFinding(
                  static_cast<owl::mojom::StopFindAction>(act));
            }
          },
          act));
}

// Round 2 fix: 与现有 Set*Callback 模式一致，直接在 main thread 设置。
// 回调本身由 IO thread 的 observer 触发 dispatch_async(main) 调用。
void OWLBridge_SetFindResultCallback(uint64_t webview_id,
                                      OWLBridge_FindResultCallback callback,
                                      void* ctx) {
  CHECK(*g_webview) << "No active web view";
  (*g_webview)->find_result_callback = callback;
  (*g_webview)->find_result_ctx = ctx;
}
```

**Observer 端的 OnFindReply 分发**（在 IO thread 的 WebViewObserver impl 中）：
```cpp
void OnFindReply(int32_t request_id,
                 int32_t number_of_matches,
                 int32_t active_match_ordinal,
                 bool final_update) override {
  // Read callback pointer set by main thread (atomic read or main-thread-only guarantee).
  // Consistent with existing OnPageInfoChanged/OnRenderSurfaceChanged pattern.
  if (state_->find_result_callback) {
    auto cb = state_->find_result_callback;
    auto ctx = state_->find_result_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(request_id, number_of_matches, active_match_ordinal,
         final_update ? 1 : 0, ctx);
    });
  }
}
```

#### 3.6 SwiftUI FindBarView

```swift
// Round 1 P1 fix: query 用 Binding 到 findState.query 消除状态重复。
struct FindBarView: View {
    @ObservedObject var tab: TabViewModel
    @FocusState private var isQueryFocused: Bool
    @State private var query: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("查找...", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isQueryFocused)
                .frame(width: 200)
                .onSubmit { tab.findNext() }
                .onChange(of: query) { _, newValue in
                    tab.find(query: newValue)
                }

            // 匹配计数
            if let state = tab.findState {
                if state.totalMatches > 0 {
                    Text("\(state.activeOrdinal)/\(state.totalMatches)")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textSecondary)
                        .monospacedDigit()
                } else if !state.query.isEmpty {
                    Text("无匹配")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textTertiary)
                }
            }

            Button(action: { tab.findPrevious() }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(tab.findState?.totalMatches == 0)

            Button(action: { tab.findNext() }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(tab.findState?.totalMatches == 0)

            Button(action: { tab.hideFindBar() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OWL.surfaceSecondary)
        .cornerRadius(8)
        .shadow(radius: 2)
        .onAppear {
            isQueryFocused = true
            // Round 1 P1 fix: 恢复上次搜索词（如果有）
            query = tab.findState?.query ?? ""
        }
        .onDisappear {
            query = ""  // Reset on close
        }
    }
}
```

**集成到 ContentAreaView**：在 `TabContentView` 的 `ZStack` 中添加 overlay：
```swift
.overlay(alignment: .top) {
    if tab.isFindBarVisible {
        FindBarView(tab: tab)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
```

**键盘快捷键**：在 `ContentAreaView` 或 `MainWindowView` 中：
```swift
.onKeyPress(.init("f"), modifiers: .command) {
    viewModel.activeTab?.showFindBar()
    return .handled
}
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/owl_types.mojom` | 修改 | +StopFindAction enum（Round 1 P0 修复） |
| `mojom/web_view.mojom` | 修改 | +Find, +StopFinding（WebViewHost）；+OnFindReply（WebViewObserver） |
| `host/owl_web_contents.h` | 修改 | +RealFindFunc（返回 int32_t）, +RealStopFindingFunc 函数指针；+Find/StopFinding 方法声明 |
| `host/owl_web_contents.cc` | 修改 | +Find（空串守卫+同步返回）/StopFinding 分发实现 |
| `host/owl_real_web_contents.mm` | 修改 | +RealWebContents::Find/StopFinding/FindReply；+find_request_id_/last_find_query_ 成员；+RealFind(同步返回)/RealStopFinding 自由函数；+函数指针注册；+`#include blink find_in_page.mojom.h` |
| `bridge/owl_bridge_api.h` | 修改 | +OWLBridge_Find(fire-and-forget), +OWLBridge_StopFinding, +OWLBridge_SetFindResultCallback |
| `bridge/owl_bridge_api.cc` | 修改 | +Find/StopFinding/SetFindResultCallback 实现；WebViewObserverImpl +OnFindReply；WebViewState +find_result_callback/ctx |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | +FindState（let 字段）；+findState/isFindBarVisible/findGeneration；+find/findNext/findPrevious/stopFinding/showFindBar/hideFindBar；+setupFindResultCallbackIfNeeded |
| `owl-client-app/Views/Content/FindBarView.swift` | **新增** | SwiftUI 查找栏 UI |
| `owl-client-app/Views/Content/ContentAreaView.swift` | 修改 | +FindBar overlay 集成 |
| `host/owl_web_contents_unittest.cc` | 修改 | +Find/StopFinding stub 和 real 模式测试；TearDown 加 g_real_find_func/g_real_stop_finding_func 重置 |

BUILD.gn **无需修改**——`:host_content` 已依赖 `//content/public/common`（content::StopFindAction）和 `//third_party/blink/public/common`（FindOptions）。`blink::mojom::FindOptions` 通过 `//third_party/blink/public/common` 传递可用。

### 5. 测试策略

| 测试类型 | 内容 | AC |
|---------|------|-----|
| C++ 单元测试 | Find stub 模式：callback 返回 request_id=0 | AC-007 |
| C++ 单元测试 | Find real 模式：委托到 g_real_find_func，返回 request_id>0 | AC-007 |
| C++ 单元测试 | Find 空字符串：直接返回 request_id=0（不转发） | AC-007 |
| C++ 单元测试 | StopFinding stub 模式：不 crash | AC-007 |
| C++ 单元测试 | StopFinding real 模式：委托到 g_real_stop_finding_func | AC-007 |
| C++ 单元测试 | FakeWebViewObserver 收到 OnFindReply（验证 observer 推送路径） | AC-007 |
| Swift E2E | Navigate 到含 "hello" 文本的 data: URL → find("hello") → 验证 findState.totalMatches > 0 | AC-002, AC-003, AC-008 |
| Swift E2E | find("nonexistent") → 验证 findState.totalMatches == 0 | AC-006, AC-008 |
| 手动测试 | Cmd+F → 查找栏出现，光标聚焦 | AC-001 |
| 手动测试 | Enter/Shift+Enter 导航匹配项 | AC-004 |
| 手动测试 | Escape 关闭查找栏 + 清除高亮 | AC-005 |

### 6. 风险 & 缓解

| 风险 | 概率 | 缓解 |
|------|------|------|
| FindReply 增量回调导致 UI 闪烁 | 已消除 | Round 2 fix: 仅 finalUpdate=true 时更新 findState |
| 过期 FindReply 回调覆盖新搜索状态 | 已消除 | Round 2 fix: activeFindRequestId 精确匹配，旧 request_id 的 FindReply 被丢弃 |
| 空字符串传给 Chromium Find | 已消除 | 三层守卫：Swift guard + C-ABI null/empty check + OWLWebContents::Find empty check |
| StopFinding action 值越界 | 已消除 | C enum 类型安全 + Mojom enum IPC 校验 + C-ABI bounds clamp + switch-default 兜底 |
| find_result_callback ctx (TabViewModel*) UAF | 极低 | 单 tab 模式下 TabViewModel 与 app 同生命周期；activeFindRequestId=0 兜底丢弃 |
| StopFinding 后 in-flight 回调"诈尸" | 已消除 | hideFindBar 设 activeFindRequestId=0 → 残余 FindReply 的 requestId≠0 → 丢弃 |
| C-ABI query 字符串跨线程 UAF | 已消除 | PostTask 前 std::string(query) 拷贝 |
| `#include` blink::mojom::FindOptions 缺失 | 低 | 需显式添加 `#include "third_party/blink/public/mojom/frame/find_in_page.mojom.h"` |
| 多 tab 模式 find 状态泄漏 | 无（当前） | 单 tab 自然隔离。未来多 tab：per-WebContents find_request_id_ + per-TabViewModel activeFindRequestId |

### Round 1 评审修复记录

| 来源 | 级别 | 问题 | 修复 |
|------|------|------|------|
| Claude P0-1 | P0 | RealFindFunc 用 OnceCallback 传回 request_id 不优雅 | 改为同步返回 int32_t，OWLWebContents 包装 Mojo 回调 |
| Claude+Codex | P0 | StopFinding 用 int32 丢失类型安全 | owl_types.mojom 新增 StopFindAction enum |
| Codex P0 | P0 | find_result_callback ctx UAF（无失效化） | Swift 端 findGeneration counter + 回调比较丢弃过期 |
| Claude P0-3 | P0 | OWLWebContents.h 缺 Find/StopFinding 声明 | 补充到类定义和文件变更清单 |
| Codex P1 | P1 | 过期结果过滤无闭环 | findGeneration 在 find/hideFindBar 时递增 |
| Codex P1 | P1 | OWLBridge_Find 缺 null 校验 | 加 query != NULL + empty 检查 |
| Codex P1 | P1 | 空字符串保护仅在 Swift 层 | Host 层 OWLWebContents::Find + C-ABI 层都加守卫 |
| Codex P1 | P1 | StopFinding 后 in-flight 回调"诈尸" | hideFindBar 先 findGeneration++ 使 in-flight 回调过期 |
| Claude P1-2 | P1 | FindBarView query 与 findState.query 重复 | onAppear 恢复、onDisappear 清空 |
| Claude P1-3 | P1 | setupFindResultCallbackIfNeeded() 未定义 | 补充完整实现 |
| Claude P1-4 | P1 | Find callback 与 SetFindResultCallback 重叠 | Find 改为 fire-and-forget |
| Claude P1-1 | P1 | RealFindFunc const& 参数生命周期歧义 | 改为 std::string by value |
| Gemini P0-1 | 降级P2 | 新增全局函数指针与技术债方向冲突 | 当前架构统一用函数指针模式，技术债 TODO 已记录。本 Phase 不改架构。 |
| Gemini P0-2 | 误判 | 未复用 Observer 推送 FindReply | 方案已通过 observer_->OnFindReply 推送（文档化混合路径说明） |

### Round 2 评审修复记录

| 来源 | 级别 | 问题 | 修复 |
|------|------|------|------|
| Claude NEW-1 | P0 | `GetActiveWebViewState()` 不存在 | 改用 `(*g_webview)` 模式（匹配实际代码） |
| Codex Q1-P0 | P0 | findGeneration 无法精确过滤过期 FindReply（不与请求绑定） | 删除 findGeneration，恢复 OWLBridge_Find callback 传回 request_id，Swift 用 activeFindRequestId 精确匹配 |
| Claude+Codex | P1 | Mojom Find response 被 C-ABI 忽略 | 恢复 OWLBridge_Find callback，request_id 存入 activeFindRequestId |
| Claude+Gemini | P1 | C-ABI StopFinding int→enum 缺 bounds check | 新增 OWLBridgeStopFindAction C enum + bounds clamp |
| Codex Q1-P1 | P1 | RealWebContents::FindReply 缺 DCHECK | 已添加 DCHECK_CURRENTLY_ON |
| Codex Q1-P1 | P1 | 清空输入时没失效在途回调 | find(empty) 设 activeFindRequestId=0 |
| Claude Q1-P1-5 | P1 | finalUpdate 过滤未实现（仅文档提到） | 回调中 `guard finalUpdate != 0` |
| Claude Q3-NEW-3 | P1 | SetFindResultCallback 线程模式与现有 Set*Callback 不一致 | 改为直接在 main thread 设置（与 PageInfo/RenderSurface callback 一致） |

### Round 3 评审修复记录

| 来源 | 级别 | 问题 | 修复 |
|------|------|------|------|
| Codex Q1/Q3 | P1 | OWLBridge_Find empty-query 分支不调用 callback 违反 C-ABI 契约 | 空/null query 改为 `callback(0, ctx)` 后 return |
| Gemini Q3 | P1 | activeFindRequestId 理论竞态（回调乱序） | Task 中添加 `guard requestId > vm.activeFindRequestId` 单调递增守卫 |

## 状态

- [x] 技术方案评审（4 轮，24 P0/P1 修复，最终 0 P0/P1）
- [x] 开发完成（10 文件修改 + 1 新建，~250 行）
- [x] 代码评审通过（6 方并行评审 + P0/P1 修复）
- [x] 测试通过（95 C++ GTest + 26 Swift E2E + 11 XCUITest 全通过，含 8 GTest + 2 E2E + 5 XCUITest Phase 33 新增）
