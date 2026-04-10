# Phase 1: 基础管线 + 空白区域菜单

## 目标

建立 context menu 的全栈管线（Mojom → Host → Bridge → Swift），并实现空白区域右键菜单作为端到端验证。完成后用户可在页面空白处右键看到"后退/前进/重新加载"菜单并执行操作。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 修改 | `mojom/web_view.mojom` | 新增 ContextMenuType enum、ContextMenuParams struct、OnContextMenu/ExecuteContextMenuAction 方法 |
| 修改 | `host/owl_real_web_contents.mm` | HandleContextMenu: 提取 params 转发（仍返回 true） |
| 修改 | `host/owl_web_contents.h/.cc` | 新增 context menu 转发 + menu_id 管理 + action 分发 |
| 修改 | `bridge/owl_bridge_api.h/.cc` | 新增 C-ABI 回调注册 + ExecuteContextMenuAction |
| 修改 | `bridge/OWLBridgeWebView.mm` | Mojo Observer → C-ABI 桥接 |
| 新增 | `client/ContextMenuHandler.swift` (或 OWLRemoteLayerView 扩展) | NSMenu 构建框架 + Page 类型菜单 |
| 新增 | `host/owl_context_menu_unittest.cc` | GTest: params 提取、menu_id 管理 |

## 依赖

- 无前置 phase
- 依赖已有的导航基础设施（GoBack/GoForward/Reload）

## 技术要点

1. **HandleContextMenu 返回值**: 仍返回 `true`（已处理），防止 Chromium 弹出默认菜单。但不再丢弃 params，而是提取后转发
2. **menu_id 管理**: Host 维护递增 `uint64_t current_menu_id_`，每次 HandleContextMenu 递增。页面导航也递增。ExecuteContextMenuAction 校验 id 匹配
3. **坐标转换**: ContextMenuParams 的 (x, y) 是 WebContents 坐标，Swift 侧需转换为 NSWindow 坐标
4. **action_id 枚举**: 在 Mojom 或 Host 头文件中定义常量（kGoBack=1, kGoForward=2, kReload=3, ...），Phase 2/3 扩展

## 验收标准

- [ ] 右键空白区域弹出 NSMenu，含"后退"、"前进"、"重新加载"三项
- [ ] 后退/前进在无历史时置灰
- [ ] 点击"后退"/"前进"/"重新加载"执行对应导航操作
- [ ] 菜单项显示快捷键提示（⌘[, ⌘], ⌘R）
- [ ] C++ GTest 通过：ContextMenuParams 正确提取、menu_id 递增、无效 id 被忽略

## 技术方案

### 1. 架构设计

遵循已建立的全栈模式（与 PageInfo/SSLError 等现有 Observer 一致）：

```
HandleContextMenu(content::ContextMenuParams)
  → RealWebContents 提取字段，组装 owl::mojom::ContextMenuParams
  → observer_->OnContextMenu(params, menu_id)
  → WebViewObserverImpl::OnContextMenu()
  → dispatch_async(main_queue) { context_menu_cb(...) }
  → Swift ContextMenuHandler 构建 NSMenu
  → 用户选择菜单项
  → 两条执行路径：
    a) Swift 本地操作（导航、剪贴板）→ 直接调用已有 Swift API
    b) 需要 Host 的操作（新标签页、保存图片等）→ ExecuteContextMenuAction IPC
```

**设计原则**: 能在 Swift 端完成的操作不走 IPC 回 Host。Phase 1 的导航操作（GoBack/GoForward/Reload）全部在 Swift 本地执行。ExecuteContextMenuAction 为 Phase 2/3 的 Host-only 操作预留。

### 2. 数据模型

#### Mojom 新增（web_view.mojom）

```mojom
// 上下文菜单类型
enum ContextMenuType {
  kPage = 0,
  kLink = 1,
  kImage = 2,
  kSelection = 3,
  kEditable = 4,
};

// 上下文菜单操作（仅需要 Host 参与的操作，Swift 本地操作不在此枚举中）
enum ContextMenuAction {
  kOpenLinkInNewTab = 10,   // Phase 2
  kSaveImage = 20,          // Phase 3
  kCopyImage = 21,          // Phase 3
  kCut = 31,                // Phase 2 (WebContents::Cut)
  kPaste = 32,              // Phase 2 (WebContents::Paste)
  kSelectAll = 33,          // Phase 2 (WebContents::SelectAll)
  kSearch = 34,             // Phase 2
  kViewSource = 40,         // Phase 3
};

// 上下文菜单参数
struct ContextMenuParams {
  ContextMenuType type;
  bool is_editable;
  string? link_url;
  string? src_url;
  bool has_image_contents;
  string? selection_text;  // 截断至 10KB
  string page_url;
  int32 x;
  int32 y;
};

// WebViewObserver 新增方法
OnContextMenu(ContextMenuParams params, uint64 menu_id);

// WebViewHost 新增方法（Phase 2+ 使用）
ExecuteContextMenuAction(uint64 menu_id, ContextMenuAction action);
```

注意：
- `can_go_back`/`can_go_forward` **不在 ContextMenuParams 中传递**。Swift 客户端已通过 PageInfo Observer 实时维护导航状态，构建菜单时直接读取端侧状态。
- 导航操作（GoBack/GoForward/Reload）在 Swift 本地执行，不走 IPC。
- 剪贴板复制操作（复制链接、复制文本）在 Swift 本地 NSPasteboard 执行，不走 IPC。
- 只有 Host-only 操作（新标签页、保存图片、WebContents 编辑命令、搜索、查看源码）才走 ExecuteContextMenuAction。

### 3. 接口设计

#### Bridge C-ABI（owl_bridge_api.h）

```c
// 回调类型 — 遵循现有 OWLBridge_*Callback 命名
typedef void (*OWLBridge_ContextMenuCallback)(
    int32_t type,           // ContextMenuType
    bool is_editable,
    const char* link_url,   // nullable (空字符串表示无)
    const char* src_url,    // nullable
    bool has_image_contents,
    const char* selection_text, // nullable (空字符串表示无)
    const char* page_url,
    int32_t x, int32_t y,
    uint64_t menu_id,
    void* context);

// 注册回调 — 遵循 OWLBridge_Set*Callback 模式
OWL_EXPORT void OWLBridge_SetContextMenuCallback(
    uint64_t webview_id,
    OWLBridge_ContextMenuCallback callback,
    void* context);

// 执行操作 — 客户端 → Host 方向
OWL_EXPORT void OWLBridge_ExecuteContextMenuAction(
    uint64_t webview_id,
    uint64_t menu_id,
    int32_t action_id);
```

#### WebViewState 扩展（owl_bridge_api.cc）

```cpp
struct WebViewState {
  // ... 现有字段 ...
  OWLBridge_ContextMenuCallback context_menu_cb = nullptr;
  void* context_menu_ctx = nullptr;
};
```

### 4. 核心逻辑

#### Host: HandleContextMenu

```cpp
bool RealWebContents::HandleContextMenu(
    content::RenderFrameHost& render_frame_host,
    const content::ContextMenuParams& params) {
  // 确定类型（按优先级）
  auto type = ContextMenuType::kPage;
  if (params.is_editable)
    type = ContextMenuType::kEditable;
  else if (!params.link_url.is_empty())
    type = ContextMenuType::kLink;
  else if (params.has_image_contents)
    type = ContextMenuType::kImage;
  else if (!params.selection_text.empty())
    type = ContextMenuType::kSelection;

  // 组装 Mojom params
  auto mojo_params = owl::mojom::ContextMenuParams::New();
  mojo_params->type = type;
  mojo_params->is_editable = params.is_editable;
  mojo_params->link_url = params.link_url.spec();
  mojo_params->src_url = params.src_url.spec();
  mojo_params->has_image_contents = params.has_image_contents;
  // selection_text 截断至 10KB
  mojo_params->selection_text = params.selection_text.substr(0, 10240);
  mojo_params->page_url = web_contents()->GetLastCommittedURL().spec();
  mojo_params->x = params.x;
  mojo_params->y = params.y;

  uint64_t menu_id = ++current_menu_id_;
  (*observer_)->OnContextMenu(std::move(mojo_params), menu_id);

  return true;  // 阻止 Chromium 默认菜单
}
```

#### Host: ExecuteContextMenuAction（Phase 1 为空壳，Phase 2/3 扩展）

```cpp
void RealWebContents::ExecuteContextMenuAction(
    uint64_t menu_id, ContextMenuAction action) {
  if (menu_id != current_menu_id_) return;  // 过期菜单，忽略

  switch (action) {
    // Phase 1: 无 Host-only 操作（导航在 Swift 本地执行）
    // Phase 2: kOpenLinkInNewTab, kCut, kPaste, kSelectAll, kSearch
    // Phase 3: kSaveImage, kCopyImage, kViewSource
    default:
      break;
  }
}
```

**Phase 1 导航操作在 Swift 本地执行**，不经过此路径。Swift 已通过现有 Bridge API（GoBack/GoForward/Reload）直接操作。

#### Bridge: WebViewObserverImpl

```cpp
void OnContextMenu(owl::mojom::ContextMenuParamsPtr params,
                   uint64_t menu_id) override {
  auto cb = state_->context_menu_cb;
  auto ctx = state_->context_menu_ctx;
  if (!cb) return;

  // 以值捕获 std::string，确保 block 在 main queue 执行时数据仍有效
  // （ObjC++ block 对 C++ 对象是值拷贝，c_str() 在 block 内指向拷贝后的字符串）
  int32_t type = static_cast<int32_t>(params->type);
  bool is_editable = params->is_editable;
  std::string link_url = params->link_url.value_or("");
  std::string src_url = params->src_url.value_or("");
  bool has_image = params->has_image_contents;
  std::string sel_text = params->selection_text.value_or("");
  std::string page_url = params->page_url;
  int32_t x = params->x;
  int32_t y = params->y;

  dispatch_async(dispatch_get_main_queue(), ^{
    // cb/ctx 生命周期由 WebViewState 管理：
    // WebViewState 在 webview 销毁时将 cb 置 nullptr，
    // 且 WebViewState 本身的销毁在 main queue 执行，
    // 因此此处 cb 调用不会 UAF。
    cb(type, is_editable,
       link_url.c_str(), src_url.c_str(), has_image,
       sel_text.c_str(), page_url.c_str(),
       x, y, menu_id, ctx);
  });
}
```

#### Swift: ContextMenuHandler（Phase 1 仅 Page 菜单）

```swift
// C-ABI 回调注册
// contextPtr 生命周期：ContextMenuHandler 与 WebView 生命周期绑定，
// handler 销毁时调用 OWLBridge_SetContextMenuCallback(id, nil, nil) 注销回调。
// 使用 Unmanaged.passUnretained 因为 handler 的生命周期由 WebView 持有的强引用管理。
let contextPtr = Unmanaged.passUnretained(self).toOpaque()
OWLBridge_SetContextMenuCallback(webviewId, { type, isEditable,
    linkUrl, srcUrl, hasImage, selText, pageUrl,
    x, y, menuId, ctx in
    guard let ctx = ctx else { return }
    let handler = Unmanaged<ContextMenuHandler>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in
        handler.showContextMenu(type: Int(type), x: Int(x), y: Int(y), menuId: menuId)
    }
}, contextPtr)

// NSMenu 构建（Phase 1: 仅 Page 类型）
@MainActor
func showContextMenu(type: Int, x: Int, y: Int, menuId: UInt64) {
    self.currentMenuId = menuId  // 实例变量保存，不用 NSMenuItem.tag

    let menu = NSMenu()

    // 导航状态从已有 PageInfo Observer 状态读取（不走 IPC）
    let backItem = NSMenuItem(title: "后退", action: #selector(menuGoBack), keyEquivalent: "[")
    backItem.keyEquivalentModifierMask = .command
    backItem.isEnabled = webViewState.canGoBack  // 读取端侧维护的导航状态
    menu.addItem(backItem)

    let fwdItem = NSMenuItem(title: "前进", action: #selector(menuGoForward), keyEquivalent: "]")
    fwdItem.keyEquivalentModifierMask = .command
    fwdItem.isEnabled = webViewState.canGoForward
    menu.addItem(fwdItem)

    let reloadItem = NSMenuItem(title: "重新加载", action: #selector(menuReload), keyEquivalent: "r")
    reloadItem.keyEquivalentModifierMask = .command
    menu.addItem(reloadItem)

    // 坐标转换（WebContents 逻辑坐标 → NSWindow 坐标）+ 弹出
    let windowPoint = view.convert(NSPoint(x: CGFloat(x), y: CGFloat(y)), to: nil)
    menu.popUp(positioning: nil, at: windowPoint, in: view)
}

// 导航操作直接调用已有 Swift API（不走 IPC 回 Host）
@objc func menuGoBack(_ sender: NSMenuItem) {
    OWLBridge_GoBack(webviewId)  // 已有的导航 API
}
@objc func menuGoForward(_ sender: NSMenuItem) {
    OWLBridge_GoForward(webviewId)
}
@objc func menuReload(_ sender: NSMenuItem) {
    OWLBridge_Reload(webviewId)
}
```

### 5. 文件变更清单

| 文件 | 操作 | 变更 |
|------|------|------|
| `mojom/web_view.mojom` | 修改 | +ContextMenuType enum, +ContextMenuAction enum, +ContextMenuParams struct, +OnContextMenu, +ExecuteContextMenuAction |
| `host/owl_real_web_contents.mm` | 修改 | HandleContextMenu: 提取→转发; +ExecuteContextMenuAction; +current_menu_id_ 成员 |
| `host/owl_web_contents.h` | 修改 | +ExecuteContextMenuAction 声明 |
| `bridge/owl_bridge_api.h` | 修改 | +ContextMenuCallback typedef, +SetContextMenuCallback, +ExecuteContextMenuAction |
| `bridge/owl_bridge_api.cc` | 修改 | +WebViewState 字段, +回调注册实现, +ExecuteContextMenuAction 实现 |
| `bridge/OWLBridgeWebView.mm` | 修改 | +OnContextMenu Observer 实现 |
| `client/ContextMenuHandler.swift` | 新增 | NSMenu 构建 + Page 菜单 + action dispatch |
| `host/owl_context_menu_unittest.cc` | 新增 | GTest |

### 6. 测试策略

**C++ GTest**:
- `ContextMenuParamsExtraction`: 验证从 `content::ContextMenuParams` 到 `owl::mojom::ContextMenuParams` 的字段映射正确
- `ContextMenuTypeDetection`: 验证 kEditable > kLink > kImage > kSelection > kPage 优先级
- `MenuIdIncrement`: 验证每次 HandleContextMenu 后 menu_id 递增
- `StaleMenuIdIgnored`: 验证 ExecuteContextMenuAction 拒绝不匹配的 menu_id
- `NavigationIncrementsMenuId`: 验证 DidStartNavigation 触发 menu_id 递增，旧 menu_id 失效
- `SelectionTextTruncation`: 验证超长 selection_text 被截断至 10KB

**手动验证**: 启动 OWL → 访问任意网页 → 空白区域右键 → 验证菜单弹出和导航操作

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| 坐标转换不准确（Retina/多显示器） | 使用 `NSView.convert(_:to:)` 标准方法，不手动计算 |
| HandleContextMenu 在非主线程调用 | Chromium UI 线程即主线程，但 Bridge dispatch_async 仍确保安全 |
| menu_id 溢出 | uint64 在实际使用中不可能溢出 |
| dispatch_async 回调时 WebView 已销毁（UAF） | WebViewState 的回调指针在 webview 销毁时置 nullptr，销毁操作也在 main queue，与 dispatch_async 回调串行，不会 UAF |
| Block 捕获 c_str() 悬空指针 | std::string 以值捕获进 block，block 内 c_str() 指向拷贝后的字符串，安全 |
| 导航时旧菜单操作被执行 | menu_id 递增机制 + DidStartNavigation 时递增 current_menu_id_（新增 WebContentsObserver 钩子） |

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
