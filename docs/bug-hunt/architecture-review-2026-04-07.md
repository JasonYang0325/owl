# OWL Browser 架构审查 + Bug 狩猎报告

> 日期: 2026-04-07 | 方法: 5 路全盲 Agent 扫描（Host/Bridge+Mojom/Client/Swift/跨层全链路）
> 扫描文件: ~120 个源文件（.cc/.mm/.h/.swift/.mojom）
> 发现总数: 67 个原始发现 → 去重合并后 **28 个独立问题**
> 多路交叉确认: 8 个（2+ 路独立发现同一问题）

---

## 概要

| 级别 | 数量 | 说明 |
|------|------|------|
| P0 (必须修复) | 3 | 必然触发的严重 bug 或架构阻塞 |
| P1 (高优) | 13 | 特定条件触发或安全相关 |
| P2 (中优) | 12 | 低概率/维护性/性能 |

### 各层架构评分

| 层 | 评分 | 主要问题 |
|----|------|---------|
| Host C++ | 5.5/10 | 全局变量滥用、单例假设、Shutdown 顺序 |
| Bridge + Mojom | 6.5/10 | WatchState 泄漏、UAF、dealloc 线程安全 |
| Client ObjC++ | 6.5/10 | 生产路径 placeholder、URL 编码、线程安全 |
| Swift | 7/10 | 并发安全、passRetained 泄漏、状态竞态 |
| 全栈 | 5.5/10 | g_real_web_contents 单例阻塞多 Tab、双重抽象层 |
| **综合** | **6/10** | |

---

## P0 发现（必须处理）

### BH-001: g_real_web_contents 全局单例导致多 Tab 操作路由到错误 WebView
- **位置**: `host/owl_web_contents.h:25-155`, `host/owl_real_web_contents.mm:1272-1334`
- **发现者**: Host Agent + 跨层 Agent — **交叉确认**
- **描述**: 所有 `g_real_*` 全局函数指针（GoBack/Forward/Reload/Stop/Find/Zoom/ContextMenu 等）只操作 `g_real_web_contents`（最后激活的 WebView），完全忽略 `webview_id`
- **触发条件**: 用户打开多个 tab 并在 tab 之间切换后执行任何导航操作
- **影响**: 操作被发送到错误的 WebView — 多 Tab 功能的根本阻塞
- **建议修复**: 用 `std::map<uint64_t, RealWebContents*>` 替代 `g_real_web_contents`，所有 `g_real_*` 函数接受 `webview_id` 参数

### BH-002: OWLBrowserImpl::Shutdown 绕过 HistoryService::Shutdown，DCHECK crash + WAL 未 flush
- **位置**: `host/owl_browser_impl.cc:118-119`
- **发现者**: Host Agent
- **描述**: `Shutdown()` 直接 `browser_contexts_.clear()` 触发 `~OWLBrowserContext()`（默认析构），跳过 `history_service_->Shutdown()`
- **触发条件**: 进程通过 `OWLBrowserImpl::Shutdown()` 正常退出
- **影响**: Debug 模式 DCHECK crash；Release 模式 WAL 未 flush，数据丢失风险
- **建议修复**: `~OWLBrowserContext()` 中调用 `Destroy()` 或等价的 cleanup 逻辑

### BH-003: DownloadObserverImpl dispatch_async 块捕获悬空 .c_str() — UAF
- **位置**: `bridge/owl_bridge_api.cc:482-495`
- **发现者**: Bridge Agent
- **描述**: `OnDownloadRemoved`/`DispatchEvent` 中，局部 `std::string json` 在当前作用域末析构，但 `dispatch_async` block 异步执行时通过 `json.c_str()` 引用已释放内存
- **触发条件**: 任何下载状态更新事件（必然触发）
- **影响**: use-after-free → crash 或内存损坏
- **建议修复**: block 内用 `std::string` 按值捕获，或在 block 外 `NSString *s = @(json.c_str())`

---

## P1 发现（高优 — 应修复）

### BH-004: WatchState 永久内存泄漏
- **位置**: `bridge/owl_bridge_api.cc:333`
- **发现者**: Bridge Agent
- **描述**: `OWLBridge_WatchPipe` 用 `new WatchState()` 分配堆内存，无任何路径 `delete`
- **触发条件**: 每次调用 `OWLBridge_WatchPipe`
- **影响**: 每次泄漏一个 WatchState + SimpleWatcher（含 fd/port 资源）

### BH-005: g_active_permission_manager 被 OWLBrowserContext 覆盖，权限请求永久 DENIED
- **位置**: `host/owl_permission_manager.cc:30-51`
- **发现者**: Host Agent
- **描述**: `OWLContentBrowserContext` 和 `OWLBrowserContext` 各创建一个 `OWLPermissionManager`，后者覆盖全局指针，但 Chromium 调的是前者，pending requests 在不同实例间找不到
- **触发条件**: 用户访问需要权限的网站
- **影响**: 权限请求被错误 DENIED

### BH-006: OWLBridgeSession/WebView/BrowserContext dealloc 在错误线程销毁 Mojo Remote
- **位置**: `bridge/OWLBridgeSession.mm:113-121`, `OWLBridgeWebView.mm:223-226`, `OWLBridgeBrowserContext.mm:38-41`
- **发现者**: Bridge Agent + 跨层 Agent — **交叉确认**
- **描述**: `dealloc` 直接 `delete state`（含 `mojo::Remote`），但 ARC dealloc 可能在任意线程触发
- **触发条件**: 应用关闭或 context 切换
- **影响**: Mojo CHECK 失败 → crash

### BH-007: OWLContentBrowserContext 数据路径硬编码为 /tmp，安全隔离缺失
- **位置**: `host/owl_content_browser_context.cc:16-18`
- **发现者**: Host Agent
- **描述**: Chromium BrowserContext 路径 = `/tmp/OWLBrowserData`（世界可读），与 OWL 自己的 `--user-data-dir` 不同步
- **触发条件**: 正常运行
- **影响**: 多用户数据泄露、OS 可随时清理导致数据丢失

### BH-008: BrowserViewModel passRetained(self) 回调在异常路径上泄漏
- **位置**: `owl-client-app/ViewModels/BrowserViewModel.swift:255-327, 410-441, 539-578`
- **发现者**: Swift Agent
- **描述**: `Unmanaged.passRetained(self)` 增加引用计数，若 Host 崩溃导致 C 回调永不触发，`takeRetainedValue` 永不执行
- **触发条件**: Host 进程在 WebView 创建回调返回前崩溃
- **影响**: BrowserViewModel 永久泄漏

### BH-009: GetHistoryService 每次调用创建新 Adapter，覆盖旧管道
- **位置**: `host/owl_browser_context.cc:313-325`
- **发现者**: Host Agent + 跨层 Agent — **交叉确认**
- **描述**: `history_mojo_adapter_ = std::move(adapter)` 销毁旧 adapter 的 Mojo 管道
- **触发条件**: `GetHistoryService()` 被调用超过一次
- **影响**: 历史服务 Mojo 管道断开，History 功能失效

### BH-010: RealDetachObserver 只清理 g_real_web_contents，非活跃 Tab 泄漏
- **位置**: `host/owl_real_web_contents.mm:1296-1311`
- **发现者**: Host Agent + 跨层 Agent — **交叉确认**
- **描述**: 关闭非活跃 Tab 时，对应的 `RealWebContents` 不会被 delete
- **触发条件**: 关闭非活跃 tab
- **影响**: 内存泄漏 + 潜在 UAF

### BH-011: Permission/SSL/Auth respond 路由到 active WebView 而非 request 来源
- **位置**: `bridge/owl_bridge_api.cc:2306-2309, 2496-2498, 2552-2554`
- **发现者**: Bridge Agent
- **描述**: 权限/SSL/Auth 的 respond 函数通过 `g_active_webview_id` 路由，而非触发 request 的 webview_id
- **触发条件**: 多 Tab 场景下用户在等待弹窗期间切换 Tab
- **影响**: 响应发给错误 WebView

### BH-012: AIChatViewModel streamBuffer 跨 actor 数据竞争
- **位置**: `owl-client-app/ViewModels/AIChatViewModel.swift:49-75`
- **发现者**: Swift Agent
- **描述**: `streamBuffer` 在 `AIService` actor 执行器上通过 `onToken` 闭包修改，同时在 MainActor 上读取
- **触发条件**: AI 聊天流式响应
- **影响**: data race → 潜在 crash

### BH-013: OWLAddressBarController URL 编码错误 — 搜索词中 &/+/= 未编码
- **位置**: `client/OWLAddressBarController.mm:15-18`
- **发现者**: Client Agent
- **描述**: `URLQueryAllowedCharacterSet` 允许 `&=+#` 不被编码，搜索 `C++ programming` 会丢失 `++`
- **触发条件**: 搜索包含特殊字符的内容
- **影响**: 搜索结果错误

### BH-014: CreateBrowserContext 6 层嵌套回调无错误恢复
- **位置**: `bridge/owl_bridge_api.cc:960-1149`
- **发现者**: Bridge Agent + 跨层 Agent — **交叉确认**
- **描述**: 任何服务创建失败只 LOG error 然后继续，Swift 侧以为初始化成功但某些服务为 null
- **触发条件**: Host 侧任何服务创建失败
- **影响**: 后续调用 null service → CHECK crash

### BH-015: OWLAIChatSession/OWLBrowserMemory 无线程安全保护
- **位置**: `client/OWLAIChatSession.mm:16-18`, `client/OWLBrowserMemory.mm:38-45`
- **发现者**: Client Agent
- **描述**: `NSMutableArray` 并发读写无同步机制
- **触发条件**: 后台 AI 回调与主线程同时操作
- **影响**: EXC_BAD_ACCESS crash

### BH-016: g_owl_history_service 全局单例跨 BrowserContext 共享
- **位置**: `host/owl_web_contents.h:102`, `host/owl_browser_context.cc:366`
- **发现者**: Host Agent + 跨层 Agent — **交叉确认**
- **描述**: 多 BrowserContext 时后创建的覆盖前一个，历史记录写入错误会话
- **触发条件**: 同时存在多个 BrowserContext
- **影响**: 跨 profile 历史泄露

---

## P2 发现（中优 — 记录备忘）

### BH-017: PermissionManager PersistNow() 在 UI 线程同步写文件
- **位置**: `host/owl_permission_manager.cc:473-513`
- **影响**: UI 卡顿 + 非原子写可能数据损坏

### BH-018: OWLBridgeSwift.initialized 静态变量无 actor 保护
- **位置**: `owl-client-app/Services/OWLBridgeSwift.swift:13-20`
- **影响**: 多线程初始化时可能双重调用 OWLBridge_Initialize

### BH-019: HistoryViewModel deleteEntry 乐观删除与后端刷新竞态
- **位置**: `owl-client-app/ViewModels/HistoryViewModel.swift:170-287`
- **影响**: 已删除条目在 loadInitial 后重新出现

### BH-020: OWLAddressBarController inputLooksLikeURL 过于宽泛
- **位置**: `client/OWLAddressBarController.mm:20-25`, `owl-client-app/ViewModels/AddressBarViewModel.swift:29`
- **发现者**: Client Agent + Swift Agent + 跨层 Agent — **三路交叉确认**
- **影响**: 版本号、文件名被误识别为 URL

### BH-021: EvaluateJavaScript 的 OWL_ENABLE_TEST_JS 环境变量可被绕过
- **位置**: `host/owl_web_contents.cc:319-327`
- **影响**: 环境变量继承导致测试 JS 通道在生产中可被利用

### BH-022: BookmarkViewModel.addCurrentPage 无防重复保护
- **位置**: `owl-client-app/ViewModels/BookmarkViewModel.swift:53-72`
- **影响**: 快速双击导致重复书签

### BH-023: OWLWebContentView 生产路径 CALayerHost 未实现（nil placeholder）
- **位置**: `client/OWLWebContentView.mm:77-79`
- **影响**: 如果 OWLWebContentView 用于生产路径则黑屏

### BH-024: WebViewObserverBridge 大量空 stub，ObjC 和 C-ABI 双重抽象
- **位置**: `bridge/OWLBridgeWebView.mm:86-170`
- **发现者**: Bridge Agent + 跨层 Agent — **交叉确认**
- **影响**: 维护成本翻倍，OWLBridgeWebView 作为"完整"包装是残缺抽象

### BH-025: HistoryEntry.id 使用 url 作为标识符，重复 URL 导致 SwiftUI ID 冲突
- **位置**: `owl-client-app/Services/HistoryService.swift:8`
- **影响**: 同一 URL 多次访问时 SwiftUI 行更新异常

### BH-026: HistorySkeletonView 使用 .random(in:) 导致每次 body 重算宽度跳变
- **位置**: `owl-client-app/Views/Sidebar/HistorySidebarView.swift:237-241`
- **影响**: skeleton 动画闪烁

### BH-027: Mojom UpdateViewGeometry 参数名 size_in_pixels 实际语义为 DIP
- **位置**: `mojom/web_view.mojom:191`
- **影响**: 误导维护者传入物理像素导致视口尺寸翻倍

### BH-028: AgentTask 状态机缺少 Pending → Running 转换
- **位置**: `client/OWLAgentSession.mm:40-48`
- **影响**: Agent 任务永远停留在 Pending 状态

---

## 架构级别建议（Tech Design 维度）

### 1. 消灭全局单例变量（最高优先级）

当前全局变量清单：
- `g_real_web_contents` / `g_real_web_contents_map` — 多 Tab 路由
- `g_owl_history_service` — 历史记录
- `g_owl_download_service` — 下载服务
- `g_active_permission_manager` — 权限管理
- 所有 `g_real_*` 函数指针 — 导航操作
- 所有 `g_*_cb` / `g_*_ctx` 回调指针 — C-ABI 回调

**建议**: 引入 `WebViewRegistry` 单例（keyed by webview_id），所有操作通过 ID 路由，废弃全局裸指针。

### 2. 统一 Bridge 抽象层

当前有两套平行的 Bridge 路径：
- `owl_bridge_api.cc` (C-ABI) — 功能完整
- `OWLBridgeWebView.mm` / `OWLBridgeSession.mm` (ObjC++) — 功能残缺

**建议**: 废弃 ObjC++ wrapper 或补全功能，避免双重维护。

### 3. Mojo Adapter 生命周期管理

当前各服务的 Mojo Adapter 由 `BrowserContext` 持有，但 `GetXxxService()` 每次调用创建新 adapter。

**建议**: 改为懒创建 + 缓存模式（只创建一次），或使用 `LazyInstance` 模式。

### 4. C-ABI 回调线程安全

当前 `g_*_cb` 全局回调指针在 IO 线程读、主线程写，非原子操作。

**建议**: 
- 所有回调指针改为 `std::atomic<CallbackType>` 或在同一线程设置/读取
- unregister 使用 noop stub 替代 nullptr（HistoryBridge 已有正确实践）

### 5. Shutdown 序列

当前 `OWLBrowserImpl::Shutdown()` 的清理逻辑不完整。

**建议**: 建立明确的 shutdown 序列文档，`~OWLBrowserContext()` 中确保所有服务的 `Shutdown()` 被调用。

---

## 下一步

1. **P0 修复**: BH-001 (多 Tab 路由)、BH-002 (Shutdown 顺序)、BH-003 (Download UAF)
2. **架构重构**: 消灭全局变量 + 统一 Bridge 层
3. **安全加固**: BH-007 (数据路径)、BH-021 (JS 执行保护)
4. **并发安全**: BH-006 (dealloc 线程)、BH-012 (streamBuffer)、BH-015 (NSMutableArray)
