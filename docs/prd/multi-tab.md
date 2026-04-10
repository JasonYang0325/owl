# 多标签管理 — PRD

## 1. 背景与目标

### 现状分析

OWL Browser 当前的 WebView 管理存在**接口与实现的语义分裂**：

- **C-ABI header** (`owl_bridge_api.h`) 已经以 `webview_id` 作为 per-webview 函数的入参（40+ 函数）
- **C-ABI 实现** (`owl_bridge_api.cc`) 忽略 `webview_id` 参数，所有调用路由到全局单例 `g_session`
- **ObjC 层**已有 `OWLTabManager`/`OWLTab`/`OWLBridgeWebView`，支持创建多个 webview、切换可见性
- **Host 层** `OWLBrowserContext::CreateWebView()` 已能返回独立实例
- **Swift 层** `BrowserViewModel` 有 `tabs` 数组和 `activeTab` 骨架，但所有 per-webview 回调（PageInfo、RenderSurface、Navigation、Auth、Console、ContextMenu）全部硬编码写入 `activeTab`，后台标签的回调会**静默污染**前台标签状态

**核心问题**: 不是"从零搭建多标签"，而是**修复 bridge 的单实例路由缺陷 + 建立 per-webview 回调路由 + 统一 ObjC/Swift 双轨架构**。

### 目标

实现真正的多标签浏览，每个标签页拥有独立的 WebView 实例（独立渲染表面、独立历史栈、独立生命周期）。Host 层 `webview_id` 统一管理所有实例，为未来多窗口和影子空间预留扩展点。

### 成功指标

- 8 个 AC 全部通过（含 XCUITest 端到端验收）
- 标签切换主观感知无延迟（功能正确性以 AC-002 验收，量化性能指标待 perf 基础设施就绪后补充）
- 关闭标签后 WebView 资源完全释放（无内存泄漏，通过 GTest 析构验证）
- 会话恢复准确率 100%（保存的标签列表与恢复后一致，非活跃标签延迟加载）
- 已有功能（Find-in-Page、Zoom、Bookmarks、History、Downloads、Permissions、ContextMenu）在多标签模式下无回归

## 2. 用户故事

- **US-001**: As a 浏览器用户, I want 打开新标签页并在其中独立浏览, so that 我可以同时查看多个网页而不丢失当前页面。
- **US-002**: As a 浏览器用户, I want 切换标签页时立即看到该页面的渲染内容, so that 标签切换体验流畅无感。
- **US-003**: As a 浏览器用户, I want 关闭不需要的标签页, so that 释放内存资源并保持界面整洁。
- **US-004**: As a 浏览器用户, I want 退出浏览器后重新打开时恢复之前的标签, so that 我不用每次都重新打开常用页面。
- **US-005**: As a 浏览器用户, I want 固定重要标签页, so that 常用页面始终保留且不会被意外关闭（UI 隐藏关闭按钮，但 Cmd+W 仍可关闭活跃固定标签）。
- **US-006**: As a 浏览器用户, I want 撤销刚关闭的标签页 (Cmd+Shift+T), so that 误关页面可以快速恢复。
- **US-007**: As a 浏览器用户, I want 通过多种方式在新标签页打开链接（target="_blank"、window.open()、Cmd+Click）, so that 当前页面不被覆盖。
- **US-008**: As a 开发者, I want WebView 管理基于 webview_id 统一路由, so that 未来可以扩展到多窗口和影子空间而无需变更 Host/Bridge 层。

## 验收标准（完整定义）

| AC | 描述 | 输入 | 操作 | 预期输出 |
|----|------|------|------|---------|
| AC-001 | 独立 WebView | 已有标签 A 在浏览 | 创建新标签 B，导航到不同 URL | A 和 B 各自独立渲染，各自有独立的前进/后退历史栈；后台标签的回调不污染前台标签 |
| AC-002 | 渲染表面切换 | 标签 A 活跃，标签 B 在后台（已完成加载） | 点击标签 B | 渲染区域切换到 B 的 CALayerHost contextId，显示 B 的页面内容；切换到正在加载中的标签应显示其实时渲染画面 |
| AC-003 | 资源释放 | 有多个标签 | 关闭标签 B | B 的 WebView 实例销毁，对应的 Host 端 WebContents 释放，A 不受影响；关闭后不再收到 B 的任何回调 |
| AC-004 | 会话恢复 | 有 3 个标签（含 1 个固定标签） | 退出浏览器 → 重新启动 | 3 个标签全部恢复，URL/title 正确，固定状态保留，活跃标签正确；非活跃标签延迟加载（只有切换到时才创建 WebView） |
| AC-005 | 固定标签 | 有普通标签 A | 右键 → 固定标签 | A 显示为固定样式（侧边栏置顶、缩小为图标），UI 隐藏关闭按钮；Cmd+W 在活跃固定标签上仍可关闭（对齐 Safari/Chrome 行为） |
| AC-006 | 撤销关闭 | 刚关闭了标签 B（含固定状态） | 按 Cmd+Shift+T | B 恢复到关闭前的 URL，恢复 isPinned 状态，插入到原始 index（若越界则追加到末尾） |
| AC-007 | 新标签打开 | 页面中有链接 | ① 点击 target="_blank" ② Cmd+Click 普通链接 | ① 新标签打开目标 URL，自动激活；② 新标签在后台打开，不切换焦点。新标签插入到当前活跃标签的紧邻右侧 |
| AC-008 | XCUITest E2E | 全部 AC 场景 | 运行 XCUITest suite | 所有测试用例通过 |
| AC-009 | 已有功能回归 | 多标签环境下 | 执行 Find-in-Page、Zoom、Bookmarks、Downloads、History 等操作 | 所有操作正确作用于当前活跃标签，不影响其他标签 |

## 3. 功能描述

### 3.1 核心流程

#### 创建新标签
```
用户按 Cmd+T / 点击"+"
  → Swift BrowserViewModel.createTab(url?)
  → 通过 OWLTabManager 创建新 WebView（内部调用 OWLBridge_CreateWebView）
  → Host OWLBrowserContext 创建新的 OWLRealWebContents 实例，分配 webview_id
  → 建立独立的 Mojo observer 管道
  → Bridge 回调通知 Swift: onWebViewCreated(webview_id, ca_context_id)
  → Swift 创建 TabViewModel(webviewId: webview_id)，注册到 webviewId→TabViewModel 路由表
  → 自动激活新标签: SetActiveWebView(webview_id)
  → RemoteLayerView 切换到新标签的 CALayerHost
```

#### 回调路由（关键架构变更）
```
Host/Bridge 的任何 per-webview 回调到达 Swift 时：
  → 回调携带 webview_id
  → BrowserViewModel 通过 webviewIdMap[webview_id] 查找目标 TabViewModel
  → 若找到 → 将回调分发到该 TabViewModel（不论是否为 activeTab）
  → 若未找到（webview_id 已销毁）→ 丢弃回调，记录 warning
  → 禁止直接写入 activeTab — 所有回调必须经过路由表
```

#### 切换标签
```
用户点击侧边栏标签 / 按 Cmd+数字
  → Swift BrowserViewModel.activateTab(tab)
  → OWLBridge_SetActiveWebView(webview_id)
  → Host 切换活跃 WebContents
  → Host 推送当前标签的 RenderSurface (ca_context_id) 给 Bridge
  → Swift RemoteLayerView 更新 CALayerHost.contextId
  → 渲染区域显示目标标签页面
```

#### 关闭标签
```
用户点击关闭按钮 / 按 Cmd+W
  → Swift 检查 isPinned：
    - 若固定且非活跃 → 不关闭（UI 无关闭按钮）
    - 若固定且活跃 → 允许 Cmd+W 关闭（对齐 Safari/Chrome）
  → 将关闭记录压入 closedTabsStack（保存 url, title, isPinned, originalIndex）
  → 从 webviewIdMap 移除映射
  → OWLBridge_DestroyWebView(webview_id)
  → Host 销毁 OWLRealWebContents，释放资源
  → Swift 移除 TabViewModel
  → 如果关闭的是活跃标签 → 激活相邻标签（优先下方，其次上方——侧边栏垂直布局）
  → 如果是最后一个标签：
    - 若该标签是空白页 (about:blank) → 关闭整个窗口（macOS 惯例）
    - 否则 → 创建新的空白标签
```

#### 新标签打开链接（target="_blank" / window.open / Cmd+Click）
```
Host 端有两个拦截点（Chromium WebContentsDelegate）：

1. OpenURLFromTab() — target="_blank" 链接 / Cmd+Click
   → 检查 disposition（NEW_FOREGROUND_TAB / NEW_BACKGROUND_TAB 等）
   → 创建新的 OWLRealWebContents，分配 webview_id
   → 通过 Bridge 回调通知 Swift: onNewTabRequested(webview_id, url, foreground)

2. AddNewContents() — window.open() / JS 弹窗
   → 接收 Chromium 已创建的 new_contents
   → 为其分配 webview_id，注册到管理 map
   → 通过 Bridge 回调通知 Swift: onNewTabRequested(webview_id, url, foreground)
   → 无 user_gesture 的 window.open → 触发弹窗拦截（已有逻辑）

Swift 侧统一处理：
  → foreground=true（target="_blank" 默认）→ 创建 Tab + 自动激活
  → foreground=false（Cmd+Click）→ 创建 Tab 但不切换焦点
  → 新标签插入到当前活跃标签的紧邻下方（侧边栏垂直布局，保持上下文关联）
```

#### 网页主动关闭（window.close）
```
网页 JS 调用 window.close()（如 OAuth 弹窗、临时页面）：
  → Host 端 WebContentsDelegate::CloseContents() 被触发
  → Host 通过 Bridge 回调通知 Swift: onWebViewCloseRequested(webview_id)
  → Swift 执行关闭标签流程（同用户手动关闭，含入栈 closedTabsStack）
  → 若未处理此回调 → UI 残留"僵尸标签"（webview_id 已无效但 TabViewModel 仍在列表中）
```

#### 撤销关闭标签
```
用户按 Cmd+Shift+T
  → Swift 从 closedTabsStack 弹出最近关闭的记录
  → 执行创建标签流程，传入保存的 URL
  → 恢复 isPinned 状态
  → 插入到 originalIndex（若越界则追加到末尾）
  → v1 仅恢复 URL，不恢复前进/后退历史栈（技术限制：序列化 NavigationController 复杂度高）
```

#### 会话恢复（含崩溃保护）
```
保存时机（多触发点）:
  → 正常退出时触发
  → 标签增删/固定状态变更时触发
  → 定时自动保存（每 30 秒，有变更才写）
  → 使用原子写入：先写 session.json.tmp → rename 覆盖 session.json

保存内容:
  → Swift 遍历 tabs 数组，序列化为 JSON:
    [{url, title, isPinned, isActive, index}]
  → 写入 ~/Library/Application Support/OWL/session.json（权限 0600）

启动恢复（延迟加载）:
  → 读取 session.json
  → 为每个条目创建 TabViewModel（UI 骨架：显示 title，isPinned 状态）
    - TabViewModel 此时标记为 isDeferred=true，不持有真实 webviewId
    - 不通过 OWLTabManager 创建 WebView（避免资源风暴）
  → 仅为 isActive=true 的标签通过 OWLTabManager 创建真正的 WebView 并导航
    - 创建成功后 isDeferred=false，绑定真实 webviewId，注册到路由表
  → 其余标签首次被 activateTab() 时：
    - 通过 OWLTabManager 创建 WebView，导航到保存的 URL
    - isDeferred=false，绑定 webviewId，注册到路由表
  → 恢复 index 顺序
  → 若 session.json 不存在 / 为空 / JSON 解析失败 → 创建空白新标签
```

### 3.2 详细规则

**WebView ID 管理**:
- Host 端使用单调递增的 `uint64_t` 分配 webview_id（从 1 开始，0 为无效值）
- webview_id 在进程生命周期内唯一，不回收
- C-ABI header 已有 webview_id 参数，本次的核心工作是**修复 .cc 实现使其真正按 webview_id 路由**，而非"增加参数"

**ObjC/Swift 架构统一**:
- `OWLTabManager`（ObjC）是 tab 生命周期的**唯一写入者**：创建/销毁/激活 WebView 只能通过它
- Swift `BrowserViewModel` 是 **UI 投影层**：通过 OWLTabManager delegate 同步 tab 列表，维护 `webviewId → TabViewModel` 路由表，处理 UI 状态（isPinned、deferred 等非 Host 概念）
- 禁止 Swift 层绕过 OWLTabManager 直接调用 C-ABI 创建/销毁 WebView
- **数据边界**: OWLTabManager/OWLTab 持有 Host 层状态（webviewId, url, title, isLoading）；TabViewModel 额外持有 UI 层状态（isPinned, isDeferred, originalIndex 等），二者通过 delegate 回调保持同步

**标签排序**（侧边栏垂直布局，方位词：上=靠前，下=靠后）:
- 固定标签始终在侧边栏顶部
- 用户主动新建标签（Cmd+T）→ 插入到非固定标签的末尾（最下方）
- 页面派生新标签（target="_blank" / Cmd+Click）→ 插入到当前活跃标签的紧邻下方
- 固定/取消固定时自动调整位置

**固定标签交互**:
- 固定标签：UI 隐藏关闭按钮，显示为图标样式，置顶于侧边栏
- 取消固定：右键 → "取消固定"，标签移到固定区域之后的第一个位置
- Cmd+W 行为：活跃的固定标签可被 Cmd+W 关闭（对齐 Safari/Chrome 惯例），非活跃固定标签无法通过 UI 关闭
- 固定标签允许导航到其他 URL（不限制）

**撤销关闭栈**:
- 维护最近 20 个关闭记录（v1 保守值，后续可调）
- 记录包含：url, title, isPinned, originalIndex
- v1 仅恢复 URL + isPinned，不恢复 history stack

**键盘快捷键**:

| 快捷键 | 行为 |
|--------|------|
| Cmd+T | 新建空白标签（末尾） |
| Cmd+W | 关闭当前活跃标签（含固定标签） |
| Cmd+Shift+T | 撤销关闭最近的标签 |
| Cmd+1~8 | 切换到第 N 个标签 |
| Cmd+9 | 切换到最后一个标签 |
| Cmd+Option+↓ | 切换到下方标签（Next） |
| Cmd+Option+↑ | 切换到上方标签（Previous） |

**空白新标签**:
- v1 显示 `about:blank`
- 后续迭代可做自定义新标签页（常用网站/书签等）

### 3.3 异常/边界处理

- **大量标签**: 无硬上限（v1），后续可通过标签休眠优化内存
- **快速连续操作与 stale 回调**: Bridge 的 Mojo 调用在 IO 线程，回调在 main thread。关闭标签后可能仍收到该 webview_id 的回调 → Swift 路由表查找失败 → 丢弃回调。需确保 `webviewIdMap.removeValue(forKey:)` 在 `DestroyWebView` 调用后**立即执行**，不等待 Host 确认
- **session.json 损坏**: 原子写入（tmp + rename）防止写入中断导致损坏；解析失败视为空文件
- **WebView 创建失败**: Host 端返回 webview_id = 0，Swift 侧 fallback 到当前标签
- **关闭最后一个空白标签**: 关闭窗口而非循环创建（macOS 惯例）

## 4. 非功能需求

**性能**:
- 标签切换：主观感知无延迟（量化指标待 perf 基础设施就绪后补充）
- 创建新标签：CreateWebView 到首个 RenderSurface 就绪 < 200ms（本地指标，不含网络）
- 关闭标签：资源释放 < 100ms

**内存**:
- 每个活跃标签 ~10-50MB（取决于页面复杂度）
- 延迟加载标签仅占 Swift 层 TabViewModel 内存（< 1KB/标签）

**安全**:
- 各 WebView 实例间无跨 WebContents 访问（Chromium SiteInstance 隔离保证）
- session.json 文件权限 0600，使用原子写入

## 5. 数据模型变更

### Mojom 变更

在现有接口上扩展，**不新增独立接口**（避免与 `BrowserContextHost`/`WebViewObserver` 并存产生分裂）：

```mojom
// 扩展现有 BrowserContextHost（browser_context.mojom）
interface BrowserContextHost {
  // 现有：CreateWebView(pending_receiver<WebViewObserver>) => (pending_remote<WebViewHost>);
  // 扩展：CreateWebView 成功后，webview_id 通过 WebViewObserver 回调返回
  DestroyWebView(uint64 webview_id);       // 新增
  SetActiveWebView(uint64 webview_id);     // 新增
};

// 扩展现有 WebViewObserver（web_view.mojom）
interface WebViewObserver {
  // 现有回调已通过 observer 管道绑定到特定 WebView，无需加 webview_id
  // 新增生命周期回调：
  OnWebViewReady(uint64 webview_id, uint32 ca_context_id);  // CreateWebView 成功
  OnWebViewCloseRequested(uint64 webview_id);                // window.close() 触发
};
```

**webview_id 分配**: 由 Host 端 `OWLBrowserContext` 分配（单调递增 uint64），通过 `OnWebViewReady` 回调告知 Bridge/Swift。Bridge 层维护 `webview_id → WebViewHost remote` 映射。

### C-ABI 变更

**不是增加参数**（header 已有），而是**修复实现**：
- `owl_bridge_api.cc` 中所有 per-webview 函数从 `g_session` 单例路由改为 `webview_map[webview_id]` 路由
- 新增 `OWLBridge_DestroyWebView(webview_id)` 和 `OWLBridge_SetActiveWebView(webview_id)`
- **兼容层策略**: `webview_id = 0` 在迁移期间路由到活跃 WebView。**风险**: 未迁移的调用方会静默路由到错误标签。**缓解**: 在 debug build 中对 webview_id=0 打印 `LOG(WARNING)` + 调用栈，便于逐步发现并迁移。Module H 完成时移除（0 变为错误 `DCHECK_NE(webview_id, 0u)`）

### Swift 数据模型

```swift
// 会话持久化模型
struct SessionTab: Codable {
    let url: String
    let title: String
    let isPinned: Bool
    let isActive: Bool
    let index: Int  // 用于恢复排序
}

// 撤销关闭记录
struct ClosedTabRecord {
    let url: String
    let title: String
    let isPinned: Bool
    let originalIndex: Int
}

// TabViewModel 新增 UI 层状态字段
// isDeferred: Bool      — 延迟加载标记，true 时无真实 webviewId
// isPinned: Bool         — 固定标签（Host 不感知，纯 UI 层概念）
// originalIndex: Int?    — 恢复时的原始位置
```

## 6. 影响范围

### 修改的模块/子系统

| 层级 | 影响 |
|------|------|
| **Mojom** | `web_view.mojom` — 新增 WebView 生命周期管理和回调接口 |
| **Host C++** | `owl_browser_context` — WebView 实例管理 map；`owl_real_web_contents` — `AddNewContents()` 新标签拦截 |
| **Bridge C-ABI** | `owl_bridge_api.cc` — 修复 per-webview 路由（header 无需变更） |
| **Bridge ObjC** | `OWLTabManager`/`OWLBridgeWebView` — 作为 tab 生命周期单一真相源 |
| **Swift ViewModel** | `BrowserViewModel` — webviewId→TabViewModel 路由表，per-webview 回调分发 |
| **Swift View** | `RemoteLayerView` — 按 activeTab 切换 CALayerHost；侧边栏固定标签样式 |
| **Swift Service** | 新增 `SessionRestoreService` — 会话持久化与延迟加载恢复 |

### Per-WebView 回调/功能矩阵

以下功能在多标签下需确保正确路由到目标 webview_id（而非 activeTab）：

| 功能 | 回调/操作 | 路由方式 |
|------|----------|----------|
| PageInfo | OnPageInfoChanged | webview_id → TabViewModel |
| RenderSurface | OnRenderSurfaceChanged | webview_id → TabViewModel |
| Navigation | OnNavigationStarted/Committed/Finished | webview_id → TabViewModel |
| Auth Challenge | OnAuthRequired | webview_id → TabViewModel（前台弹窗） |
| SSL State | security indicator | webview_id → TabViewModel |
| Find-in-Page | FindInPage/OnFindResult | 只对 activeTab 发起 |
| Zoom | SetZoomLevel | per-tab 独立 |
| Context Menu | OnContextMenuRequested | webview_id → 弹出菜单 |
| Console | OnConsoleMessage | webview_id → TabViewModel |
| Caret/IME | 输入事件 | 只发给 activeTab 的 WebView |
| Downloads | DownloadObserver | 全局（不 per-tab） |
| History | HistoryObserver | 全局（不 per-tab） |
| Bookmarks | BookmarkObserver | 全局（不 per-tab） |
| Permissions | PermissionRequest | webview_id → 对应标签弹窗 |
| OWL CLI | activeWebviewId | 操作当前活跃标签 |

### 回归测试策略

Module H 完成后，需验证以下已有功能在多标签环境下无回归：
- Find-in-Page：仅对活跃标签生效
- Zoom：各标签独立缩放
- Context Menu：右键操作对应正确标签
- Downloads：全局下载不受标签切换影响
- History：所有标签的导航均记录到全局历史
- Bookmarks：标签无关，不受影响
- Permissions：权限弹窗路由到请求标签，非活跃标签的权限请求排队到切换时展示

### 架构扩展方向（本次不实现）

Host 层 `webview_id` 统一管理所有 WebView 实例，不区分可见/不可见。可见性/容器归属在 Swift 层决定：
- **多窗口**: Swift 侧增加 Window → [TabViewModel] 映射，Host/Bridge 无需变更
- **影子空间**: Swift 侧创建不绑定 UI 的 WebView，Host/Bridge 无需变更

## 7. 里程碑 & 优先级

### P0（核心基础设施）
- 修复 Bridge 单实例路由 → webview_id 路由
- 多 WebView 实例创建/销毁（Host + Bridge + OWLTabManager）
- 渲染表面切换（标签切换时切换 CALayerHost）
- Per-webview 回调路由表（Swift BrowserViewModel）
- 已有功能回归测试

### P1（核心体验）
- target="_blank" / window.open 新标签打开（Host `AddNewContents` 拦截）
- Cmd+Click 后台打开标签
- 固定标签（Pin Tab）
- 撤销关闭标签（Cmd+Shift+T）
- 会话恢复（延迟加载 + 原子写入 + 崩溃保护）
- XCUITest E2E 验收

### P2（本次不实现）
- 标签拖拽排序
- 标签分组/颜色标记
- 多窗口支持
- 影子空间（后台 WebView）
- 标签休眠（内存优化）
- 自定义新标签页
- 撤销关闭恢复 history stack

## 8. 已决策问题

| # | 问题 | 决策 |
|---|------|------|
| 1 | C-ABI 兼容层（webview_id=0）| 仅在 Module H 开发期间存在，Module H 完成时所有调用方迁移完毕后移除（0 变为错误）|
| 2 | 会话恢复历史栈 | v1 只恢复 URL + isPinned，history stack 恢复列入 P2 |
| 3 | 标签上限 | 不设硬上限，后续可通过标签休眠优化 |
| 4 | 空白新标签内容 | v1 为 about:blank，后续迭代可做自定义页 |
| 5 | 撤销关闭栈容量 | v1 保守值 20，后续可按需调整 |
| 6 | ObjC/Swift 双轨 | 以 OWLTabManager 为 tab 生命周期单一真相源，Swift 层只做 UI 代理 |
