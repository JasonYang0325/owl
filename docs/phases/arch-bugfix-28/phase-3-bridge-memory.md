# Phase 3: Bridge 内存安全 (BH-004, BH-006, BH-011, BH-014)

## Goal
修复 Bridge 层的内存泄漏、线程安全和错误恢复问题。

## Scope
- **Modified**: `bridge/owl_bridge_api.cc/.h`, `bridge/OWLBridgeSession.mm`, `bridge/OWLBridgeWebView.mm`, `bridge/OWLBridgeBrowserContext.mm`
- **Layers**: Bridge

## Dependencies
- BH-011 部分依赖 Phase 1（需要 webview_id-keyed map 来查找目标 WebView）

## Items

### BH-004: WatchState 自管理生命周期
- `base::flat_map<uint64_t, std::unique_ptr<WatchState>> g_watch_states`
- `MOJO_RESULT_CANCELLED`: 先 `watcher.reset()` 再从 map 移除
- 新增 `OWLBridge_CancelWatch(uint64_t watch_id)` API

### BH-006: ObjC dealloc 线程安全
- `dealloc` 中 PostTask 到 Mojo IO 线程 delete state
- `RunsTasksInCurrentSequence()` 检测已在正确线程
- `BrowserThread::IsThreadInitialized(IO)` 检测 IO 线程停止 fallback
- 影响: OWLBridgeSession, OWLBridgeWebView, OWLBridgeBrowserContext

### BH-011: Permission/SSL/Auth 路由
- 新增 `std::map<uint64_t, uint64_t> g_permission_request_origin`（request_id → webview_id）
- `OnPermissionRequest` 时记录来源 wid
- `RespondToPermission` 时从 map 查找，不用 `g_active_webview_id`
- SSL/Auth 同理

### BH-014: CreateBrowserContext 并行初始化
- 6 层嵌套 → `base::BarrierCallback<bool>` 并行
- 所有回调完成后聚合判断成功/失败
- 失败时 reset 已绑定 remote/receiver
- callback 增加 `const char* error_msg`

## Acceptance Criteria
- [ ] GTest: pipe 关闭后 WatchState 释放（map size 验证）
- [ ] TSan: dealloc 在正确线程执行
- [ ] GTest: 多 WebView 权限响应路由到正确实例
- [ ] GTest: 单个服务失败时 context 创建报错 + 资源回收
- [ ] 新增测试 ≥ 6

## 技术方案

### BH-004: WatchState 自管理生命周期

**现状**: `OWLBridge_WatchPipe` (line 328) 用 `new WatchState()` 分配，`base::Unretained(state)` 传入 watcher 回调，无任何路径 `delete state`。

**方案**:
1. 新增 `base::flat_map<uint64_t, std::unique_ptr<WatchState>> g_watch_states`（匿名 namespace）
2. `OWLBridge_WatchPipe` 返回 `watch_id`，存入 map
3. Watcher 回调中：`MOJO_RESULT_CANCELLED` 时先 `state->watcher.reset()` 再 `g_watch_states.erase(watch_id)`（unique_ptr 析构 delete state）
4. 新增 `OWLBridge_CancelWatch(uint64_t watch_id)` API：手动取消
5. 回调用 `base::Unretained` 仍安全（state 在 map 中存活到 erase）
6. **线程不变量**: `g_watch_states` 的所有操作（insert/erase/lookup）必须在 IO 线程执行。`OWLBridge_WatchPipe` 被调用时在主线程，需通过 `PostTask` 到 IO 线程执行 insert + watcher 创建。watcher 回调天然在 IO 线程，erase 安全
7. `CancelWatch` 与 `MOJO_RESULT_CANCELLED` 双重 erase 是幂等的（flat_map erase 不存在的 key 是 no-op）

### BH-006: ObjC dealloc 线程安全

**现状**: `OWLBridgeSession/WebView/BrowserContext` 的 `dealloc` 直接 `delete _state`（含 mojo::Remote），但 ARC dealloc 可能在任意线程。

**方案**: 在每个 ObjC wrapper 的 `dealloc` 中：
```objc
- (void)dealloc {
  auto* state = _state;
  _state = nullptr;
  if (!state) return;
  
  auto runner = [OWLMojoThread shared].taskRunner;
  if (runner && !runner->RunsTasksInCurrentSequence()) {
    // WrapUnique 确保即使 PostTask 被丢弃（IO 线程已关闭），析构仍执行
    runner->PostTask(FROM_HERE, base::BindOnce([](std::unique_ptr<decltype(*state)>) {},
                                                base::WrapUnique(state)));
  } else {
    delete state;  // 已在正确线程，或 IO 线程已停止
  }
}
```
影响 3 个文件：OWLBridgeSession.mm, OWLBridgeWebView.mm, OWLBridgeBrowserContext.mm。

### BH-011: Permission/SSL/Auth 路由修复

**现状**: `OWLBridge_RespondToPermission` (line 2294) 通过 `g_active_webview_id` 查找 webview，在多 tab 场景下路由错误。

**方案**:
1. 新增 3 个 map（匿名 namespace）：
   ```cpp
   std::map<uint64_t, uint64_t> g_permission_request_origins;  // request_id → webview_id
   std::map<uint64_t, uint64_t> g_ssl_error_origins;           // error_id → webview_id
   std::map<uint64_t, uint64_t> g_auth_request_origins;        // auth_id → webview_id
   ```
2. 在 `OnPermissionRequest` 回调中记录 `g_permission_request_origins[request_id] = wid`
3. `OWLBridge_RespondToPermission` 中从 map 查找 `wid`，而非 `g_active_webview_id`
4. 响应后从 map 中移除
5. SSL/Auth 同理：`g_ssl_error_origins`（error_id → wid）、`g_auth_request_origins`（auth_id → wid），在 `OnSSLError`/`OnAuthRequired` 回调时记录，`RespondToSSLError`/`RespondToAuth` 时查找并移除
6. **orphaned entry 清理**: WebView 销毁时（`g_webviews.erase(wid)`），遍历 3 个 map 并移除所有 value == wid 的条目，防止 map 无限增长
7. 未知 request_id 直接 early return（当前行为已如此，方案保持）

### BH-014: CreateBrowserContext 并行初始化

**现状**: 6 层深度嵌套回调（line 961-1149），任何中间失败静默继续。

**方案**: 重构为并行 + 聚合判断。
1. `CreateBrowserContext` 成功后，并行发起 6 个 `GetXxxService` 请求
2. 使用 `std::shared_ptr<ServiceInitState>` 追踪完成计数和结果
3. 每个回调 `++completed`，检查 `completed == 6` 时统一 dispatch 到 main queue
4. 任何服务失败记录 error，最终回调包含 error_msg
5. 失败时 reset 已绑定的 remote（但不 reset context 本身——context 仍可用，只是某些服务不可用）

使用 `base::BarrierCallback<bool>`（Bridge 层已大量使用 `base::BindOnce/Repeating/NoDestructor` 等 Chromium base 原语，BarrierCallback 适用）。所有 6 个 GetService 回调在 IO 线程串行执行（Mojo 单序列保证），无并发问题。

### 文件变更清单

| 文件 | 说明 |
|------|------|
| `bridge/owl_bridge_api.cc` | BH-004 WatchState map + CancelWatch API; BH-011 request origin maps; BH-014 并行初始化 |
| `bridge/owl_bridge_api.h` | 新增 OWLBridge_CancelWatch 声明; CreateBrowserContext callback 增加 error_msg |
| `bridge/OWLBridgeSession.mm` | BH-006 dealloc PostTask |
| `bridge/OWLBridgeWebView.mm` | BH-006 dealloc PostTask |
| `bridge/OWLBridgeBrowserContext.mm` | BH-006 dealloc PostTask |

## Status
- [x] Tech design
- [x] Development
- [ ] Code review
- [x] Tests pass
