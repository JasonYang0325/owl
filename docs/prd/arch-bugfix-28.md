# Architecture Bugfix Batch — PRD

> Round 3 — 基于 Round 1（4 路）+ Round 2（2 路）评审反馈修订

## 1. 背景与目标

### 问题

2026-04-07 全栈架构审查（5 路全盲 Agent 扫描）发现 28 个问题，涵盖内存安全、线程安全、生命周期管理、数据一致性等多个维度。其中 2 个 P0 为必然触发的严重 bug，13 个 P1 为特定条件下触发的明确 bug。

### 为什么现在做

- P0-BH-001（多 Tab 路由错误）是 MOD-H（多标签增强）的前置阻塞
- P0-BH-002（Shutdown 数据丢失）影响用户浏览历史持久化
- 13 个 P1 包含内存泄漏、权限系统错误、线程安全等关键问题

### BH-003 状态变更

**降级为"仅补测试"**：Round 1 评审中确认 ObjC block 按值捕获 `std::string json`（C++ 对象在 block 堆拷贝时调用拷贝构造函数），`json.c_str()` 访问 block 持有的副本，不存在 UAF。代码注释 "Copy json into block (prevent UAF)" 也证实了这一设计意图。BH-003 不再需要代码修改，仅补充测试验证此行为。

### 成功指标

- 27 个问题修复（BH-003 仅补测试，BH-024 不修复）
- 每个修复有对应的自动化测试（GTest / Swift Unit Test）或 TSan/ASan 覆盖
- 现有测试 0 回归
- 新增自动化测试 ≥ 45

## 2. 技术故事

### TS-1: Host 层全局变量消除
As a developer, I want WebView operations routed by webview_id instead of global pointers, so that multi-tab works correctly and services don't leak across BrowserContext instances.

### TS-2: Bridge 层内存安全
As a developer, I want all C-ABI callbacks to be memory-safe (no UAF, no leaks), so that the bridge layer is reliable under async dispatch.

### TS-3: Mojo 生命周期正确性
As a developer, I want Mojo Remote/Receiver pairs to be created, cached, and destroyed on the correct thread, so that IPC is stable.

### TS-4: Swift 层并发安全
As a developer, I want all ViewModels and Services to be thread-safe under Swift concurrency, so that data races are eliminated.

### TS-5: 业务逻辑正确性
As a developer, I want URL detection, search encoding, history entry identity, and agent task state machine to work correctly, so that user-facing features behave as expected.

## 3. 功能描述

### 3.1 P0 修复（2 个，必须首先完成）

#### BH-001: 多 Tab 路由 — 重新键控现有 map，消除 g_real_web_contents 单例

- **现状**: Bridge 层已有 `g_webviews` map 按 `webview_id` 路由，C-ABI 函数（Navigate/MouseEvent/KeyEvent 等）已接受 `webview_id`。**真正的 gap** 在 Host 层：`g_real_web_contents`（单一裸指针）+ `g_real_web_contents_map`（按 `Remote*` 键）+ `g_real_go_back_func` 等 15+ 个无参全局函数指针。
- **方案（三步）**:
  1. **重新键控现有 map**: 将 `g_real_web_contents_map` 的键从 `mojo::Remote<WebViewObserver>*` 改为 `uint64_t webview_id`，不新增第三张 map
  2. **修改函数指针类型**: 所有 `g_real_*` 函数指针（`g_real_go_back_func`, `g_real_go_forward_func`, `g_real_reload_func`, `g_real_stop_func`, `g_real_find_func`, `g_real_stop_finding_func`, `g_real_set_zoom_func`, `g_real_get_zoom_func`, `g_real_resize_func`, `g_real_eval_js_func`, `g_real_detach_observer_func`, `g_real_update_observer_func`, `g_real_execute_context_menu_action_func`, `g_real_set_visible_func`）的签名添加 `uint64_t webview_id` 参数
  3. **让 OWLWebContents 存储自己的 webview_id**: 在 `OWLWebContents` 构造时注入 `webview_id`，用于在 `GoBack/Forward/Reload/Stop` 等方法中传递给函数指针
  4. **删除 `g_real_web_contents` 全局裸指针**
  5. **Cursor swizzle 例外**: Chromium 内部 cursor change callback 签名不由 OWL 控制，不携带 webview_id。此处保留 `g_active_webview_id` 作为唯一允许的全局路由状态（在 tab 切换时更新），并在 PRD 中标注为已知限制
- **影响文件**: `host/owl_web_contents.h`, `host/owl_web_contents.cc`, `host/owl_real_web_contents.mm`, `host/owl_web_contents_unittest.cc`（3500+ 行，所有 lambda 需更新）, `bridge/owl_bridge_api.cc`
- **测试**: GTest 验证多 WebView 独立操作（GoBack on WebView A 不影响 WebView B）

#### BH-002: Shutdown 序列 — 幂等 DestroyInternal + 析构守卫

- **现状**: 三条清理路径行为不一致：
  - `Destroy()` — 显式销毁，有完整 cleanup（`history_service_->Shutdown()` 等）
  - `OnDisconnect()` — Mojo 断开，也有完整 cleanup 但调用方式不同
  - `~OWLBrowserContext()` — 默认析构，**无 cleanup**，`OWLBrowserImpl::Shutdown()` 通过 `browser_contexts_.clear()` 触发此路径
- **方案**: 
  1. 抽取 `DestroyInternal()` 幂等方法，包含所有服务的 `Shutdown()` + 状态清理
  2. 添加 `bool destroyed_ = false` 状态位防重入
  3. `Destroy()`、`OnDisconnect()`、`~OWLBrowserContext()` 全部调用 `DestroyInternal()`
- **影响文件**: `host/owl_browser_context.cc/.h`, `host/owl_browser_impl.cc`
- **测试**: GTest 验证：(1) `Shutdown` 后 `is_shutdown_` 为 true；(2) 多次调用 `DestroyInternal` 不 crash；(3) 析构路径调用了 `HistoryService::Shutdown()`

### 3.2 P1 修复（13 个）

#### BH-004: WatchState 泄漏 — 自管理生命周期 + CancelWatch API
- **方案**: 
  1. 用 `base::flat_map<uint64_t, std::unique_ptr<WatchState>> g_watch_states` 管理所有活跃 watcher
  2. `MOJO_RESULT_CANCELLED` 分支：先 `state->watcher.reset()`（停止 watcher），再从 map 中移除（触发 delete）
  3. 新增 `OWLBridge_CancelWatch(uint64_t watch_id)` API
- **测试**: GTest 验证 pipe 关闭后 WatchState 被释放（通过 map size 验证）

#### BH-005: 双 PermissionManager 问题
- **方案**: 废除 `OWLBrowserContext` 内部懒创建的 PermissionManager。`OWLContentBrowserContext` 持有唯一实例，在 `OWLBrowserContext` 创建时通过构造参数注入指针（`OWLBrowserContext` 不持有所有权，`OWLContentBrowserContext` 管理生命周期）。注意两者写入路径不同（`/tmp` vs `user_data_dir`），BH-007 修复后统一为 `user_data_dir`
- **测试**: GTest 验证只有一个 PermissionManager 实例，权限请求在该实例中正确解析

#### BH-006: ObjC dealloc 线程安全
- **方案**: `dealloc` 中将 `delete state` PostTask 到 Mojo IO 线程（`[OWLMojoThread shared].taskRunner`）。边界条件：通过 `taskRunner->RunsTasksInCurrentSequence()` 检测是否已在正确线程（如果是则直接 delete），`BrowserThread::IsThreadInitialized(BrowserThread::IO)` 检测 IO 线程是否仍在运行（如果已停止则当前线程直接 delete 作为 fallback）
- **测试**: TSan 覆盖（GTest 环境无法可靠模拟跨线程 dealloc）。代码审查验证 PostTask 逻辑

#### BH-007: 数据路径硬编码
- **方案**: `OWLContentBrowserContext` 使用 `--user-data-dir` 命令行参数构建路径，权限 0700
- **测试**: GTest 在 `base::ScopedTempDir` 下验证路径来自命令行参数且权限正确

#### BH-008: passRetained 泄漏
- **方案**: one-shot C 回调改用 `withCheckedContinuation` + `Box` 模式（参考 BookmarkService 已有的正确实践）
- **测试**: Swift Unit Test 验证正常路径和取消路径均正确释放

#### BH-009: GetHistoryService Adapter 缓存
- **方案**: 缓存 `HistoryServiceMojoAdapter`（只创建一次），后续调用返回缓存的 adapter。adapter 在 `DestroyInternal()` 中 reset
- **测试**: GTest 验证多次调用 `GetHistoryService()` 返回同一 adapter（receiver 不被 reset）

#### BH-010: RealDetachObserver 按 webview_id 清理
- **方案**: detach 时按 `webview_id` 从重新键控的 map 中查找并删除对应 RealWebContents（依赖 BH-001）
- **测试**: GTest 验证关闭非活跃 tab 后对应实例被删除，活跃 tab 不受影响

#### BH-011: Permission/SSL/Auth 路由修复
- **现状**: `OWLBridge_RespondToPermission` 等函数通过 `g_active_webview_id.load()` 查找 webview（`owl_bridge_api.cc:2307`），再从 `g_webviews[wid]` 找到 Mojo remote 调用 `RespondToPermissionRequest`。`request_id` 只用于匹配 Host 侧的 pending request，不用于路由到正确的 webview
- **方案**: 在 Bridge 侧维护 `std::map<uint64_t, uint64_t> g_permission_request_origin`（request_id → 来源 webview_id），在 `OnPermissionRequest` 回调时记录来源 wid，`RespondToPermission` 时从此 map 查找而非使用 `g_active_webview_id`。SSL/Auth 同理
- **受影响 C-ABI 函数**: `OWLBridge_RespondToPermission`, `OWLBridge_RespondToSSLError`, `OWLBridge_RespondToAuth`
- **受影响 Swift 文件**: `PermissionViewModel.swift`, `SecurityViewModel.swift`, `OWLBridgeSwift.swift`
- **测试**: GTest 验证多 WebView 场景下权限响应路由到正确实例

#### BH-012: AIChatViewModel 并发竞争
- **方案**: 改用 `AsyncStream<String>` 替代 `onToken` 闭包，消除 actor 边界上的闭包传递
- **测试**: Swift Unit Test 验证并发 stream 访问无 data race

#### BH-013: URL 编码错误
- **方案**: `OWLAddressBarController.mm` 使用 `NSURLComponents.queryItems`（该 API 会自动处理 query value 的编码，无需手动 percent-encode）
- **双重编码协调**: URL 编码只在 `OWLAddressBarController` 中做一次（通过 `NSURLComponents` 生成完整 URL 字符串），传入 C-ABI 后 Host 侧用 `GURL(url_string)` 直接解析（GURL 对已编码的 URL 不做二次编码）。关键：不要在 Swift 侧先 percent-encode 再传给 `OWLAddressBarController`
- **测试**: GTest 验证 `C++ programming`、`a=1&b=2` 等特殊搜索词正确编码 + 端到端测试覆盖

#### BH-014: CreateBrowserContext 并行初始化 + 错误恢复
- **方案**: 
  1. 将 6 层嵌套改为**并行初始化**（`base::BarrierCallback<bool>` 管理 6 个并发服务请求），而非串行（避免冷启动延迟叠加）
  2. **聚合判断**: BarrierCallback 等待所有 6 个回调完成后统一判断成功/失败（Mojo 请求一旦发出无法取消，fast-fail 不可行）。在 final callback 中检查每个服务的状态
  3. **失败处理**: 若任何服务失败，在 final callback 中 reset 已绑定的 remote/receiver，通过 callback 增加的 `const char* error_msg` 参数通知 Swift 侧
  4. 注意：不是"任一失败立即取消其他"，而是"等所有完成后统一判断"
- **测试**: GTest 验证单个服务创建失败时整体 context 创建报错 + 已绑定资源被回收

#### BH-015: ObjC 集合线程安全
- **方案**: 声明 main-thread-only 约束 + DEBUG 下添加 `NSThread.isMainThread` 断言
- **测试**: GTest 验证断言在错误线程上触发

#### BH-016: g_owl_history_service 单例消除
- **方案**: 移除全局变量。`RealWebContents` 构造时注入 `OWLHistoryService*`
- **注入路径**: `RealNavigate`（`owl_real_web_contents.mm:1265`）是 `new RealWebContents(url, observer)` 的唯一构造点。`RealNavigate` 由 `OWLWebContents::Navigate()` 通过函数指针调用，此时 `OWLWebContents` 持有 `OWLBrowserContext*`（通过 `context_` 成员），可从中获取 `GetHistoryServiceRaw()` 并传入。需扩展 `RealNavigate` 函数签名添加 `OWLHistoryService*` 参数，或在构造 `RealWebContents` 时额外传入
- **生命周期保护**: `OWLHistoryService*` 裸指针在 `DestroyInternal()` 后变为悬空。`RealWebContents` 在 `DidFinishNavigation` 中使用前需检查 `OWLBrowserContext::destroyed_` 标志，或改用 `base::WeakPtr<OWLHistoryService>`
- **注意**: 此变更独立于 BH-001 的 WebViewRegistry
- **测试**: GTest 验证多 BrowserContext 各自有独立的 HistoryService

### 3.3 P2 修复（11 个，BH-024 不修复）

#### BH-017: PermissionManager 异步持久化
- **方案**: 
  1. PersistNow() 在 UI 线程先**深拷贝/snapshot** 当前权限数据
  2. 将 snapshot 通过 PostTask 传给 `file_task_runner_` 进行后台写入
  3. 使用 temp file + rename 原子写
- **测试**: GTest 验证异步写入完成且文件完整

#### BH-018: OWLBridgeSwift.initialized 保护
- **方案**: 不使用 `@MainActor`（与 C-ABI 同步调用不兼容）。改用 `os_unfair_lock` 或 `nonisolated(unsafe) static var` + `OSAllocatedUnfairLock` 保护 `initialized` 标志
- **测试**: Swift Unit Test 验证并发初始化只执行一次

#### BH-019: HistoryViewModel 删除竞态
- **方案**: commitPendingUndo 时检查条目是否仍在 `entries` 中（若已被 `loadInitial` 刷新覆盖则跳过后端删除）
- **测试**: Swift Unit Test 模拟竞态场景

#### BH-020: inputLooksLikeURL 改进
- **方案**: 合并 `OWLAddressBarController.mm` 和 `AddressBarViewModel.swift` 两处独立判断为单一入口（C-ABI 的 `OWLBridge_InputLooksLikeURL`）。改进启发式：添加 TLD 白名单检查
- **影响文件**: `client/OWLAddressBarController.mm`, `bridge/owl_bridge_api.cc`, `owl-client-app/ViewModels/AddressBarViewModel.swift`, `owl-client-app/Services/OWLBridgeSwift.swift`
- **测试**: GTest + Swift Unit Test 覆盖边界用例（版本号 `1.0.0`、`localhost:8080`、IP `192.168.1.1`、路径 `/usr/local/bin`）

#### BH-021: EvaluateJavaScript 安全加固
- **方案**: 移除环境变量检查，仅保留命令行开关 `--enable-owl-test-js`
- **测试**: GTest 验证无命令行开关时 JS 执行被拒绝

#### BH-022: BookmarkViewModel 防重复
- **方案**: 添加 `isAdding` 标志，挂起期间阻止重复调用
- **测试**: Swift Unit Test 验证快速双击只添加一次

#### BH-023: OWLWebContentView — 标记为 test-only
- **方案**: 在 GN 中设置 `testonly = true`，添加注释说明生产路径使用 `OWLRemoteLayerView`（bridge 层），移除 placeholder 代码
- **测试**: 编译验证

#### BH-025: HistoryEntry.id — 引入 visit_id
- **方案**: 使用数据库自增 `visit_id`（Host 层 SQL schema 已有 `id INTEGER PRIMARY KEY AUTOINCREMENT`，见 `owl_history_service.cc:192`，无需 schema migration）。Mojom `HistoryEntry` 需新增 `int64 id` 字段，Swift `HistoryEntry.id` 改为 `String(id)`
- **测试**: Swift Unit Test 验证相同 URL 不同访问的条目有唯一 ID

#### BH-026: HistorySkeletonView 随机宽度
- **方案**: 在 View 创建时固定随机值（预计算 `static let` 数组）
- **测试**: 手动验收（不计入自动化测试指标）

#### BH-027: Mojom 参数名修正
- **方案**: `size_in_pixels` → `size_in_dips`，同步更新所有引用。Mono-repo 同步编译，无版本倾斜风险
- **测试**: 编译通过即验证

#### BH-028: AgentTask 状态机补全
- **方案**: 添加 `startTask:` 方法实现 `Pending → Running` 转换。注意当前 Agent 功能是 UI mock，此修复仅补全状态机接口
- **测试**: GTest 验证完整状态机流转（Pending → Running → NeedsConfirmation → Running → Completed）

## 4. 非功能需求

### 性能
- PermissionManager 持久化不阻塞 UI 线程（BH-017）
- CreateBrowserContext 并行初始化（BH-014），失败时 fast-fail
- WebViewRegistry 使用 `base::flat_map`（连续内存，缓存友好）而非 `std::map`

### 安全
- EvaluateJavaScript 仅命令行开关控制（BH-021）
- 数据路径不使用世界可读目录（BH-007）

### 可维护性
- 消除全局变量，改为依赖注入 / per-instance 成员
- Mojom 参数名与实际语义一致
- Shutdown 路径统一为幂等 DestroyInternal

### 测试策略分级

| 类别 | 测试方式 | 适用修复 |
|------|---------|---------|
| 逻辑正确性 | GTest 单元测试 | BH-001,002,004,005,007,009,010,011,013,014,016,017,020,021,028 |
| 并发安全 | TSan + 代码审查 + DEBUG 断言 | BH-006,012,015,018 |
| Swift 业务逻辑 | Swift Unit Test (MockConfig) | BH-008,012,018,019,022,025 |
| 编译验证 | 编译通过 | BH-023,027 |
| 手动验收 | 人工检查 | BH-026 |
| 补充测试（无代码修改） | GTest | BH-003 |

## 5. 数据模型变更

### Host 层变更
- `g_real_web_contents_map`: 键从 `Remote*` 改为 `uint64_t webview_id`，使用 `base::flat_map`
- 删除 `g_real_web_contents` 全局裸指针
- 删除 `g_owl_history_service` 全局指针，改为 `RealWebContents` 构造参数
- 删除 `g_active_permission_manager` 全局指针
- 所有 `g_real_*` 函数指针签名添加 `uint64_t webview_id` 参数
- `OWLWebContents` 新增 `webview_id_` 成员
- `OWLBrowserContext` 新增 `DestroyInternal()` 幂等方法 + `destroyed_` 标志

### Mojom 变更
- `UpdateViewGeometry`: 参数名 `size_in_pixels` → `size_in_dips`

### Swift 层变更
- `HistoryEntry.id`: `url` → `visit_id`（从 Host 层映射）
- `OWLBridgeSwift.initialized`: `@MainActor` → `os_unfair_lock`

### C-ABI 签名变更
- 所有 host 层导航操作的函数指针类型：添加 `uint64_t webview_id` 参数
- `OWLBridge_RespondToPermission/SSL/Auth`: 内部路由逻辑从 `g_active_webview_id` 改为从 request 对象获取来源 `webview_id`
- `OWLBridge_CancelWatch`: 新增 API
- `OWLBridge_CreateBrowserContext` callback: 增加 `const char* error_msg` 参数

### Bridge 层变更
- 删除 `g_owl_download_service` 全局指针
- 删除 `g_context`、`g_history_service`、`g_permission_service`、`g_download_service` 等 bridge 侧全局单例状态

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| host/ | BH-001,002,005,007,009,010,016,017,021 — 9 个修复 |
| bridge/ | BH-003(仅测试),004,006,011,014 — 5 个修复 |
| client/ | BH-013,015,020,023,028 — 5 个修复 |
| mojom/ | BH-027 — 1 个修复 |
| owl-client-app/ | BH-008,011,012,018,019,020,022,025,026 — 9 个修复 |

### 依赖关系（完整）
- BH-010（RealDetachObserver）依赖 BH-001（重新键控的 map）
- BH-011（respond 路由）与 BH-001 独立（通过 request_id 匹配，不依赖 map）
- BH-016（HistoryService 注入）与 BH-001 独立（通过 RealWebContents 构造参数注入）
- BH-005（PermissionManager 统一）依赖 BH-007（数据路径统一）
- BH-009（adapter 缓存）与 BH-002（DestroyInternal）有交互（adapter 在 DestroyInternal 中 reset）
- BH-001 的 `owl_web_contents_unittest.cc` 更新量大（3500+ 行），需作为独立子任务

## 7. 里程碑 & 优先级

### Phase 1: 核心路由 + Shutdown（P0 + 高影响 P1）
- BH-001: WebView 路由重构（最高优先级，BH-010 依赖它）
- BH-002: 幂等 DestroyInternal
- BH-009: GetHistoryService adapter 缓存（与 BH-002 交互）
- BH-016: HistoryService 依赖注入（RealWebContents 构造参数）
- BH-005: PermissionManager 统一

### Phase 2: 生命周期与线程安全（可部分并行）
- **可并行组 A**: BH-006(dealloc 线程) + BH-007(数据路径) + BH-015(集合线程安全)
- **可并行组 B**: BH-010(RealDetachObserver, 依赖 Phase 1) + BH-011(respond 路由)
- BH-004: WatchState 泄漏
- BH-014: CreateBrowserContext 并行初始化

### Phase 3: Swift 层修复（全部可并行）
- BH-008: passRetained → withCheckedContinuation
- BH-012: AIChatViewModel AsyncStream
- BH-018: OWLBridgeSwift os_unfair_lock
- BH-019: HistoryViewModel 竞态
- BH-022: BookmarkViewModel 防重复
- BH-025: HistoryEntry visit_id

### Phase 4: 功能与维护性（全部可并行）
- BH-003: Download dispatch_async 补测试
- BH-013: URL 编码（需跨层验证无双重编码）
- BH-017: PermissionManager 异步持久化（snapshot + PostTask）
- BH-020: inputLooksLikeURL 统一
- BH-021: EvaluateJavaScript 安全
- BH-023: OWLWebContentView test-only 标记
- BH-026: HistorySkeletonView
- BH-027: Mojom 参数名
- BH-028: AgentTask 状态机

## 8. 开放问题

1. ~~BH-001 范围~~ → 已明确：重新键控现有 map，修改所有函数指针签名，不新增第三张 map
2. ~~BH-023 决策~~ → 标记为 test-only，生产路径使用 OWLRemoteLayerView
3. **BH-024 不修复**: Bridge 双重抽象的统一是更大范围的重构，不在此批次
4. ~~BH-003 是否仍存在~~ → 确认为假阳性，仅补测试
5. ~~BH-025 visit_id 来源~~ → 已确认 schema 有 `id INTEGER PRIMARY KEY AUTOINCREMENT`，无需 migration
6. **Cursor swizzle 已知限制**: Chromium 内部 cursor callback 不携带 webview_id，保留 `g_active_webview_id` 作为该回调的唯一路由状态（已在 BH-001 方案第 5 步标注）
