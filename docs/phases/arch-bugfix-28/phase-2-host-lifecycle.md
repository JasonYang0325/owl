# Phase 2: Host 服务生命周期 (BH-002, BH-005, BH-009, BH-016)

## Goal
统一 Shutdown 路径，消除服务层全局变量，确保 Mojo adapter 正确缓存。

## Scope
- **Modified**: `host/owl_browser_context.cc/.h`, `host/owl_browser_impl.cc`, `host/owl_permission_manager.cc/.h`, `host/owl_content_browser_context.cc`, `host/owl_real_web_contents.mm`, `host/owl_browser_context_unittest.cc`, `host/owl_permission_manager_unittest.cc`
- **Layers**: Host

## Dependencies
- None (can start in parallel with Phase 1)

## Items

### BH-002: 幂等 DestroyInternal
- 抽取 `DestroyInternal()` 包含所有服务 Shutdown + 状态清理
- `destroyed_` 标志防重入
- 三条路径（Destroy/OnDisconnect/析构）全部调用

### BH-005: 单一 PermissionManager
- 废除 `OWLBrowserContext` 内部的 `OWLPermissionManager`
- `OWLContentBrowserContext` 持有唯一实例，构造参数注入指针
- 删除 `g_active_permission_manager` 全局指针

### BH-009: GetHistoryService adapter 缓存
- `history_mojo_adapter_` 只创建一次（懒创建 + 缓存）
- 后续调用返回缓存实例
- adapter 在 `DestroyInternal()` 中 reset

### BH-016: HistoryService 依赖注入
- `RealWebContents` 构造时注入 `OWLHistoryService*`（通过 `RealNavigate` 扩展参数）
- 删除 `g_owl_history_service` 全局指针
- `DidFinishNavigation` 使用注入实例
- 生命周期保护: `base::WeakPtr<OWLHistoryService>`

## Acceptance Criteria
- [ ] `~OWLBrowserContext()` 正确调用 DestroyInternal()
- [ ] GTest: 多次 DestroyInternal 不 crash
- [ ] GTest: 只有一个 PermissionManager 实例
- [ ] GTest: 多次 GetHistoryService() 返回同一 adapter
- [ ] GTest: 多 BrowserContext 各自独立 HistoryService
- [ ] `g_owl_history_service` 和 `g_active_permission_manager` 已删除
- [ ] 新增测试 ≥ 8

## 技术方案

### BH-002: 幂等 DestroyInternal — 三路径统一

**问题根因**: `Destroy()` (line 449-485) 和 `OnDisconnect()` (line 251-272) 各有一套独立的清理逻辑（约 20 行重复代码），`~OWLBrowserContext()` 是 `= default`（line 242），不做任何清理。`OWLBrowserImpl::Shutdown()` 通过 `browser_contexts_.clear()` 走析构路径，跳过了所有清理。

**关键发现（Round 1 P0-2）**: `web_view_map_.clear()` 触发 `~OWLWebContents()`（= default），**不会**调用 `g_real_detach_observer_func`。必须在清理前显式 detach 所有 WebView 的 RealWebContents。

**方案**:
1. **修改 `~OWLWebContents()`**: 从 `= default` 改为显式析构。添加 `bool detached_ = false` 守卫防双重 detach（OnDisconnect 后再析构的场景）：
   ```cpp
   OWLWebContents::~OWLWebContents() {
     if (!detached_) {
       detached_ = true;
       base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
       if (g_real_detach_observer_func) {
         g_real_detach_observer_func();
       }
     }
   }
   ```
   `OnDisconnect()` 和 `Close()` 中也设置 `detached_ = true`。WebContents 有**四条** detach 路径：`OnDisconnect` / `Close` / 析构 / BrowserContext `web_view_map_.clear()` 触发的析构（等同于析构路径）。所有四条路径统一用 `detached_` 守卫。`Close()` 中需在调用 `g_real_detach_observer_func()` 前加同样的守卫。

2. 新增 `void DestroyInternal()` 私有方法：
   ```cpp
   void OWLBrowserContext::DestroyInternal() {
     if (destroyed_) return;  // 幂等守卫
     destroyed_ = true;
     
     // 先清理 WebViews（~OWLWebContents 会 detach RealWebContents）
     web_view_map_.clear();
     
     // 再清理服务（此时所有 RealWebContents 已销毁，无悬空指针风险）
     if (history_service_) {
       history_observer_.reset();
       history_mojo_adapter_.reset();
       history_service_->Shutdown();
       history_service_.reset();
     }
     bookmark_service_.reset();
     storage_service_.reset();
     permission_mojo_adapter_.reset();
     permission_manager_ = nullptr;  // raw_ptr, 非拥有
     download_observer_.reset();
     download_mojo_adapter_.reset();
     // 清除 download 回调注册（防止 weak_factory_ 析构前仍被触发）
     if (download_service_) {
       download_service_->SetChangedCallback({});
       download_service_->SetRemovedCallback({});
     }
     download_service_ = nullptr;
   }
   ```

3. **destroyed_callback_ 不在 DestroyInternal 中处理**（Round 1 P0-1 修复）：
   - `DestroyInternal()` 只做资源清理，不触发 callback
   - `Destroy()` 调用 `DestroyInternal()` → callback.Run() → receiver reset → PostTask(destroyed_callback_)
   - `OnDisconnect()` 调用 `DestroyInternal()` → 直接调用 destroyed_callback_
   - `~OWLBrowserContext()` 调用 `DestroyInternal()`，不触发 destroyed_callback_（此时 callback 已被 move 或对象即将销毁）
   - `~OWLBrowserContext()` 调用 `DestroyInternal()`，**不调用 destroyed_callback_**（析构在 `browser_contexts_.clear()` 迭代中触发，同步回调会修改 vector 导致 UB）
   - **`OWLBrowserImpl::Shutdown()`** 改为：逐个调用 `context->DestroyInternal()` 后再 `browser_contexts_.clear()`（确保服务 Shutdown 被调用，同时避免析构路径遗漏）
   - **保证**: destroyed_callback_ 最多被调用一次：
     - Destroy 路径：PostTask(destroyed_callback_)，先 clear disconnect handler 防 OnDisconnect 重入
     - OnDisconnect 路径：直接调用 destroyed_callback_
     - 析构路径：**不调用**（DestroyInternal 已被 Shutdown 显式调用过，destroyed_ = true）
     - Shutdown 路径保证：先 DestroyInternal() 再 clear()，析构时 destroyed_ 已 true，DestroyInternal 幂等跳过

**新增成员**: `bool destroyed_ = false;`（OWLBrowserContext）, `bool detached_ = false;`（OWLWebContents）

### BH-009: GetHistoryService Mojo Adapter 缓存

**问题根因**: `GetHistoryService()` 每次调用都创建新 `HistoryServiceMojoAdapter`，覆盖旧 adapter，旧 adapter 的 Mojo receiver 被 reset，管道断开。

**Round 1 P1-3 修复**: 不返回 NullRemote（Bridge 层无法安全处理隐式协议）。

**正确方案**: 将 `HistoryServiceMojoAdapter` 改为使用 `mojo::ReceiverSet` 支持多个 pipe endpoint。每次调用 `GetHistoryService()` 创建新的 pipe endpoint 并添加到 ReceiverSet，所有 endpoint 共享同一个底层 adapter 实例。

```cpp
void OWLBrowserContext::GetHistoryService(GetHistoryServiceCallback callback) {
  GetHistoryServiceRaw();
  
  // 首次调用：创建 adapter
  if (!history_mojo_adapter_) {
    history_mojo_adapter_ = std::make_unique<HistoryServiceMojoAdapter>(
        history_service_.get(), this);
  }
  
  // 每次调用：创建新 pipe endpoint，加入 ReceiverSet
  mojo::PendingRemote<owl::mojom::HistoryService> remote;
  history_mojo_adapter_->AddReceiver(remote.InitWithNewPipeAndPassReceiver());
  std::move(callback).Run(std::move(remote));
}
```

需要修改 `HistoryServiceMojoAdapter`：将 `mojo::Receiver` 改为 `mojo::ReceiverSet`，新增 `AddReceiver()` 方法。`DestroyInternal()` 中 reset adapter 会自动关闭所有 pipe。

**统一适用**: 所有 Service adapter 均改为缓存方案（只创建一次 adapter，后续调用 AddReceiver）：
- `HistoryServiceMojoAdapter`: `Receiver` → `ReceiverSet`，新增 `AddReceiver()`
- `OWLPermissionServiceImpl`: 同上，`Receiver` → `ReceiverSet`
- `DownloadServiceMojoAdapter`: 同上
- `OWLBookmarkService`: 当前 `GetBookmarkService()` 每次创建新 `OWLBookmarkService`（line 295-306）且直接 Bind。改为：缓存 `bookmark_service_`（已有缓存），但 Bind 只执行一次，后续调用返回已缓存实例的新 endpoint（ReceiverSet 或检查 `is_bound()`）
- `OWLStorageService`: 同 BookmarkService 模式

文件变更清单中需额外包含：`host/owl_bookmark_service.cc/.h`、`host/owl_storage_service.cc/.h`（如果它们有 Receiver 成员需改为 ReceiverSet）。

### BH-005: 单一 PermissionManager — 消除双实例

**问题根因**: 
- `OWLContentBrowserContext` 构造时创建 `OWLPermissionManager`（路径 `/tmp/OWLBrowserData/permissions.json`）并设置 `g_active_permission_manager = this`
- `OWLBrowserContext::GetPermissionService()` 懒创建第二个 `OWLPermissionManager`（路径 `user_data_dir/permissions.json`）并覆盖 `g_active_permission_manager`
- 结果：Chromium 调用 `OWLContentBrowserContext` 持有的 PM1 做权限检查，但 `g_active_permission_manager` 指向 PM2，`RealRespondToPermission` 在 PM2 中查找 pending request，永远找不到

**方案**:
1. `OWLBrowserContext` 不再懒创建自己的 `OWLPermissionManager`
2. `OWLBrowserContext` 构造时接受 `OWLPermissionManager*`（非拥有指针，生命周期由 `OWLContentBrowserContext` 管理）
3. `OWLBrowserContext::GetPermissionService()` 使用注入的指针创建 `OWLPermissionServiceImpl` adapter
4. 删除 `g_active_permission_manager` 全局指针 — `OWLPermissionManager` 构造时不再设置全局指针
5. `RealRespondToPermission` 改为通过 `OWLWebContents` → `OWLBrowserContext` → `permission_manager_` 路径调用（利用 Module 1 的 AutoReset 路由）

**签名变更**:
```cpp
// OWLBrowserContext 构造函数新增参数
OWLBrowserContext(const std::string& partition_name,
                  bool off_the_record,
                  const base::FilePath& user_data_dir,
                  OWLPermissionManager* permission_manager,  // NEW
                  DestroyedCallback destroyed_callback);
```

```cpp
// OWLBrowserImpl::CreateBrowserContext 传入
auto context = std::make_unique<OWLBrowserContext>(
    partition_name, config->off_the_record,
    base::FilePath(user_data_dir_),
    content_browser_context_->GetPermissionManager(),  // 注入
    ...);
```

`OWLPermissionManager` 中删除 `g_active_permission_manager` 全局指针和构造函数中的赋值。`RealRespondToPermission` 改为：PM 实例唯一（由 `OWLContentBrowserContext` 持有），构造函数中通过 lambda 捕获 `this` 绑定 `g_real_respond_to_permission_func`，无需多跳路由。

**g_owl_download_service 同步处理**: 删除 `owl_browser_context.h` 中的全局指针，`OWLBrowserContext` 构造时接受 `OWLDownloadService*` 注入（同 PermissionManager 模式），`OWLBrowserImpl::CreateBrowserContext` 从 `content_browser_context_` 获取并传入。

**web_view_map_.clear() 重入防护**: `DestroyInternal()` 中先将 `web_view_map_` move 到局部变量再 clear，避免 `~OWLWebContents()` 的 `closed_callback_` 重入修改 map：
```cpp
auto local_map = std::move(web_view_map_);
local_map.clear();  // 析构在局部变量上，web_view_map_ 已为空
```

### BH-016: HistoryService 依赖注入 — 消除全局指针

**问题根因**: `g_owl_history_service` 全局指针在 `GetHistoryServiceRaw()` 中赋值，`RealWebContents::DidFinishNavigation` 中读取。多 `OWLBrowserContext` 时后者覆盖前者。

**方案**: 直接扩展 `RealNavigateFunc` 签名，传入 `OWLHistoryService*`。彻底消除全局状态，不引入新的全局指针。

1. 删除 `owl_web_contents.h` 中的 `g_owl_history_service` 全局指针声明
2. `OWLWebContents` 构造函数新增 `OWLBrowserContext*` 参数（构造注入）：
   ```cpp
   OWLWebContents(uint64_t webview_id, OWLBrowserContext* browser_context, ClosedCallback);
   ```
3. 修改 `RealNavigateFunc` 签名，添加 `OWLHistoryService*` 参数：
   ```cpp
   using RealNavigateFunc = void (*)(const GURL& url,
                                      mojo::Remote<owl::mojom::WebViewObserver>* observer,
                                      OWLHistoryService* history_service);
   ```
4. `OWLWebContents::Navigate()` 调用时传入 `browser_context_->GetHistoryServiceRaw()`
5. `RealNavigate` 将 `history_service` 传给 `new RealWebContents(wid, url, observer, history_service)`
6. `RealWebContents` 构造时接收 `OWLHistoryService*`，存储为 `raw_ptr<OWLHistoryService> history_service_`
7. `DidFinishNavigation` 使用 `history_service_` 实例成员
8. `GetHistoryServiceRaw()` 不再设置全局指针，加防御：`if (destroyed_) return nullptr;`

**注意**: `RealNavigateFunc` 是唯一需要修改签名的函数指针（其他通过 AutoReset 路由），因为 Navigate 是创建 `RealWebContents` 的唯一入口，必须在此传递 HistoryService。`owl_web_contents_unittest.cc` 中相关 lambda 需同步更新。

**不变量**: `RealNavigate` 中 `new RealWebContents(...)` 是同步完成的，传入的 `history_service` 指针在构造时立即存储到成员，无悬空风险。

**生命周期保护**（Round 1 P0-2 修复后保证成立）：
- `DestroyInternal()` 先 `web_view_map_.clear()`
- `~OWLWebContents()` 显式调用 `g_real_detach_observer_func()`（BH-002 修复）
- `RealDetachObserver` delete `RealWebContents`
- 然后才 `history_service_->Shutdown()` + reset
- 因此 `RealWebContents` 在 `history_service_` reset 前已被销毁，不存在悬空风险

### 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `host/owl_browser_context.h` | 修改 | 添加 `DestroyInternal()`, `destroyed_`, 构造函数添加 `permission_manager*`, `permission_manager_` 改为 `raw_ptr`, 删除 `g_owl_download_service` |
| `host/owl_browser_context.cc` | 修改 | 实现 DestroyInternal, 析构/Destroy/OnDisconnect 调用它, GetHistoryService 改用 ReceiverSet 缓存, GetPermissionService 使用注入 PM, GetHistoryServiceRaw 不设全局指针 |
| `host/owl_browser_context.cc` (HistoryServiceMojoAdapter) | 修改 | `Receiver` → `ReceiverSet`, 新增 `AddReceiver()` |
| `host/owl_browser_impl.cc` | 修改 | CreateBrowserContext 注入 PermissionManager* |
| `host/owl_web_contents.h` | 修改 | 删除 `g_owl_history_service`, 修改 `RealNavigateFunc` 签名添加 `OWLHistoryService*` |
| `host/owl_web_contents.cc` | 修改 | `~OWLWebContents()` 从 `= default` 改为显式析构（调用 detach）, `Navigate()` 传入 history_service |
| `host/owl_real_web_contents.mm` | 修改 | `RealNavigate` 接受 `OWLHistoryService*` 并传给构造, `RealWebContents` 存储 `history_service_` 成员, `DidFinishNavigation` 使用实例成员 |
| `host/owl_permission_manager.cc` | 修改 | 删除 `g_active_permission_manager` 全局指针 |
| `host/owl_content_browser_context.h` | 修改 | 新增 `OWLPermissionManager* GetPermissionManager()` accessor |
| `host/owl_browser_context_unittest.cc` | 修改 | 新增测试 |
| `host/owl_permission_manager_unittest.cc` | 修改 | 适配构造变更 |
| `host/owl_web_contents_unittest.cc` | 修改 | 适配 RealNavigateFunc 签名变更 |

## Status
- [x] Tech design review
- [ ] Development
- [ ] Code review
- [ ] Tests pass
