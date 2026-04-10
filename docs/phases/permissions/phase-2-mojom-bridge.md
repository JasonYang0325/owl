# Phase 2: Mojom + Bridge 权限通道

## 目标
建立权限请求的跨进程通道：Mojom 接口定义 + C-ABI Bridge 函数。
完成后，Swift 客户端能通过 C-ABI 回调接收权限请求，并回传用户决定。

## 范围
- 新增: `mojom/permissions.mojom`
- 修改: `mojom/web_view.mojom`（Observer + Host 扩展）
- 修改: `bridge/owl_bridge_api.h`（新增权限 C-ABI 函数）
- 修改: `bridge/OWLBridgeSession.mm`（Mojo ↔ C-ABI 桥接）
- 新增: `bridge/owl_bridge_permission_unittest.mm`

## 依赖
- Phase 1（PermissionManager 提供权限查询/设置接口）

## 技术要点
- Mojom `PermissionService` 接口: Get/Set/GetAll/Reset
- Observer 扩展: `OnPermissionRequest(origin, type, request_id)`
- Host 扩展: `RespondToPermissionRequest(request_id, status)`
- C-ABI: callback 注册 + 响应函数 + 全量查询
- request_id 生命周期: 用 `std::map<uint64_t, PermissionDecidedCallback>` 管理

## 验收标准
- [ ] AC-P2-1: Mojom PermissionService 编译通过
- [ ] AC-P2-2: 权限请求从 Host → Observer → C-ABI callback 成功传递
- [ ] AC-P2-3: RespondToPermission 从 C-ABI → Mojo → Host 成功回传
- [ ] AC-P2-4: PermissionGetAll 返回所有持久化权限
- [ ] AC-P2-5: PermissionReset 清除指定权限

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过

---

## 技术方案

### 1. Mojom 接口设计

#### 1.1 `mojom/permissions.mojom`（新增）

参照 `bookmarks.mojom` / `history.mojom` 的风格，定义独立的权限 Mojom 文件。

```mojom
// Copyright 2026 AntlerAI. All rights reserved.
module owl.mojom;

// 支持的权限类型（与 blink::PermissionType 子集对应）。
// int 值不可变——已持久化到 JSON，变更会破坏存量数据。
enum PermissionType {
  kCamera = 0,
  kMicrophone = 1,
  kGeolocation = 2,
  kNotifications = 3,
};

// 权限状态（与 content::PermissionStatus 对齐）。
enum PermissionStatus {
  kGranted = 0,
  kDenied = 1,
  kAsk = 2,      // 默认，未决定
};

// 单条站点权限记录。
struct SitePermission {
  string origin;            // e.g. "https://example.com"
  PermissionType type;
  PermissionStatus status;
};

// 权限管理服务（per-BrowserContext，与 BookmarkService 同级）。
interface PermissionService {
  // 查询单条权限。未找到时返回 kAsk。
  GetPermission(string origin, PermissionType type)
      => (PermissionStatus status);

  // 设置权限。status=kAsk 等效于删除该条目。
  SetPermission(string origin, PermissionType type, PermissionStatus status);

  // 获取所有已存储的权限（不含 kAsk 条目）。
  GetAllPermissions() => (array<SitePermission> permissions);

  // 重置单条权限（恢复为 kAsk）。
  ResetPermission(string origin, PermissionType type);

  // 重置全部权限。
  ResetAll();
};
```

**设计要点：**
- `PermissionType` 显式标注 int 值，防止枚举顺序变化导致持久化数据不兼容。
- `PermissionService` 为 per-context 服务，通过 `BrowserContextHost.GetPermissionService()` 获取（类比 `GetBookmarkService()`）。
- `PermissionService` 本身只做 CRUD，不处理权限请求弹窗流。弹窗流走 `WebViewObserver.OnPermissionRequest` → `WebViewHost.RespondToPermissionRequest` 通道。

#### 1.2 `mojom/web_view.mojom` 扩展

在现有 `WebViewObserver` 和 `WebViewHost` 中新增权限请求通道。

**WebViewObserver 新增（Host → Client）：**
```mojom
// 权限请求弹窗通知。Host 在 Chromium 触发 RequestPermissions 时发送。
// Client 必须调用 WebViewHost.RespondToPermissionRequest 回传决定。
// 如果 Client 超时未回传（或 pipe 断开），Host 自动 DENY。
OnPermissionRequest(string origin,
                    PermissionType permission_type,
                    uint64 request_id);
```

**WebViewHost 新增（Client → Host）：**
```mojom
// 回传权限决定。request_id 必须匹配此前 OnPermissionRequest 的值。
// 无效 request_id 静默忽略（日志 WARNING）。
RespondToPermissionRequest(uint64 request_id, PermissionStatus status);
```

**`mojom/browser_context.mojom` 新增：**
```mojom
import "third_party/owl/mojom/permissions.mojom";

interface BrowserContextHost {
  // ... existing ...

  // 获取 PermissionService（per-context，lazy create）。
  GetPermissionService() => (pending_remote<PermissionService> service);
};
```

**Mojom import 依赖链：**
```
web_view.mojom  ─imports→  permissions.mojom（PermissionType, PermissionStatus）
browser_context.mojom  ─imports→  permissions.mojom（PermissionService）
```

#### 1.3 Mojom 与 Phase 1 类型的映射

| Mojom | C++ (Phase 1) | 转换位置 |
|-------|--------------|---------|
| `PermissionType::kCamera` | `blink::PermissionType::VIDEO_CAPTURE` | Host PermissionService impl |
| `PermissionType::kMicrophone` | `blink::PermissionType::AUDIO_CAPTURE` | Host PermissionService impl |
| `PermissionType::kGeolocation` | `blink::PermissionType::GEOLOCATION` | Host PermissionService impl |
| `PermissionType::kNotifications` | `blink::PermissionType::NOTIFICATIONS` | Host PermissionService impl |
| `PermissionStatus::kGranted` | `content::PermissionStatus::GRANTED` | 双向 static_cast |
| `PermissionStatus::kDenied` | `content::PermissionStatus::DENIED` | 双向 static_cast |
| `PermissionStatus::kAsk` | `content::PermissionStatus::ASK` | 双向 static_cast |

转换使用静态工具函数 `ToMojomPermissionType` / `FromMojomPermissionType`，放在 Host 的 `owl_permission_service_impl.cc` 中。不支持的 `blink::PermissionType`（如 MIDI）在转换时返回 `std::nullopt`，由 Host 自动 DENY。

---

### 2. C-ABI Bridge 函数

参照 `owl_bridge_api.h` 的风格（`OWL_EXPORT`、callback typedef + 注册函数 + context 指针模式），新增权限相关的 C-ABI 函数。

#### 2.1 回调类型定义

```c
// === Permissions (Phase 2 Permissions) ===

// 权限请求回调（Renderer 请求权限时触发）。
// origin: 请求方 origin（UTF-8, e.g. "https://example.com"）。
// permission_type: PermissionType enum (0=Camera, 1=Mic, 2=Geo, 3=Notifications)。
// request_id: 唯一标识此次请求，回传时使用。
// Callback guaranteed on main thread.
typedef void (*OWLBridge_PermissionRequestCallback)(
    const char* origin,
    int permission_type,
    uint64_t request_id,
    void* context);

// 权限列表回调（GetAll 结果）。
// json_array: JSON array of {origin, type, status} objects. NULL on error.
// error_msg: NULL on success.
// Callback guaranteed on main thread.
typedef void (*OWLBridge_PermissionListCallback)(
    const char* json_array,
    const char* error_msg,
    void* context);

// 权限查询回调（GetPermission 结果）。
// status: PermissionStatus enum (0=Granted, 1=Denied, 2=Ask).
typedef void (*OWLBridge_PermissionGetCallback)(
    int status,
    const char* error_msg,
    void* context);
```

#### 2.2 注册/响应/查询函数

```c
// 注册权限请求回调（全局，非 per-webview）。
// 每次 OnPermissionRequest 到达时触发。设置 NULL 取消注册。
OWL_EXPORT void OWLBridge_SetPermissionRequestCallback(
    OWLBridge_PermissionRequestCallback callback,
    void* callback_context);

// 回传权限决定。request_id 对应 OnPermissionRequest 的 request_id。
// status: PermissionStatus enum (0=Granted, 1=Denied, 2=Ask)。
// 无效 request_id 静默忽略。
OWL_EXPORT void OWLBridge_RespondToPermission(
    uint64_t request_id,
    int status);

// 查询单条权限。
OWL_EXPORT void OWLBridge_PermissionGet(
    const char* origin,
    int permission_type,
    OWLBridge_PermissionGetCallback callback,
    void* callback_context);

// 获取所有已存储的权限。Callback 返回 JSON array。
OWL_EXPORT void OWLBridge_PermissionGetAll(
    OWLBridge_PermissionListCallback callback,
    void* callback_context);

// 重置单条权限（恢复为 Ask）。Fire-and-forget。
OWL_EXPORT void OWLBridge_PermissionReset(
    const char* origin,
    int permission_type);

// 重置全部权限。Fire-and-forget。
OWL_EXPORT void OWLBridge_PermissionResetAll(void);
```

**设计要点：**
- `SetPermissionRequestCallback` 是全局的（不是 per-webview），因为权限请求绑定到 BrowserContext，而当前架构只有一个 context。如果未来多 context，可以通过 webview_id 参数区分。
- `RespondToPermission` 是 fire-and-forget（无回调），简化 Swift 端使用。
- `PermissionGet` 有回调（异步查询），`PermissionReset`/`PermissionResetAll` 是 fire-and-forget（操作本身无失败语义，且 Swift 端不需要 ack）。

---

### 3. Mojo ↔ C-ABI 桥接逻辑

#### 3.1 数据流

```
                       权限请求流（Host → Swift）:
  ┌─────────────────┐      ┌─────────────────────┐      ┌──────────────────┐
  │ Chromium         │ Mojo │ WebViewObserver      │ C-ABI│ Swift Client     │
  │ RequestPerms()   │─────→│ OnPermissionRequest  │─────→│ callback(origin, │
  │                  │      │ (IO thread)          │ main │ type, request_id)│
  └─────────────────┘      └─────────────────────┘ thread└──────────────────┘
                                                                 │
                       权限回传流（Swift → Host）:                  │ 用户点击
                                                                 ▼
  ┌─────────────────┐ UI   ┌─────────────────────┐ Post  ┌──────────────────┐
  │ PermissionManager│◄────│ WebViewHost          │ Task  │ RespondToPermis- │
  │ ResolvePermis-   │ thrd │ RespondToPermission  │◄─────│ sion(request_id, │
  │ sionRequest()    │      │ Request (IO thread)  │ IO   │ status)          │
  │ callback.Run()   │      │   ──PostTask(UI)──→  │ thrd └──────────────────┘
  │ + persist        │      └─────────────────────┘
  └─────────────────┘

                       权限管理流（Swift → Host → Swift）:
  ┌──────────────────┐      ┌─────────────────────┐      ┌──────────────────┐
  │ PermissionManager│ Mojo │ PermissionService    │ C-ABI│ PermissionGetAll │
  │ GetAllPermissions│◄─────│ GetAllPermissions()  │◄─────│ (callback, ctx)  │
  │                  │─────→│ => [SitePermission]  │─────→│ callback(json)   │
  └──────────────────┘      └─────────────────────┘      └──────────────────┘
```

#### 3.2 request_id 生命周期管理

**Host 端（owl_web_contents.cc 或专门的 PermissionRequestDispatcher）：**

```cpp
namespace {
// 只在 UI thread 读写，不需要 atomic（无跨线程访问）。
uint64_t g_next_request_id = 1;

// 活跃权限请求的上下文。
struct PendingPermissionRequest {
  base::OnceCallback<void(const std::vector<PermissionResult>&)> callback;
  size_t num_permissions;  // 原始 permissions.size()，用于构造正确长度的 results。
};
// 活跃权限请求：request_id → 上下文。
// 只在 UI thread 读写（无锁）。
std::map<uint64_t, PendingPermissionRequest> g_pending_requests;
}

// 在 OWLPermissionManager::RequestPermissions 中（Phase 2 改写）:
//
// **多权限请求处理策略（Phase 2 简化方案）：**
// Chromium 的 RequestPermissions 的 request_description.permissions 是 vector，
// 可能包含多个权限类型（如同时请求 Camera + Microphone）。
// Phase 2 只处理第一个权限类型（单弹窗），其余类型自动 DENY。
// 多权限场景（为每个 type 生成独立弹窗/合并弹窗）在后续迭代处理。
void OWLPermissionManager::RequestPermissions(..., Callback callback) {
  // Phase 2: 只取第一个权限类型，其余自动 DENY。
  // 构造 results 时，index 0 走异步弹窗流程，index 1..N 填充 DENIED。
  if (request_description.permissions.size() > 1) {
    LOG(WARNING) << "OWLPermissionManager: multiple permissions requested, "
                 << "only first will be prompted (Phase 2 limitation)";
  }
  uint64_t request_id = g_next_request_id++;

  // 存储 callback 和权限数量，等待客户端回传。
  // num_permissions 用于构造正确长度的 results vector（Chromium 要求
  // results.size() == permissions.size()，否则 DCHECK 失败）。
  g_pending_requests[request_id] = {
      std::move(callback),
      request_description.permissions.size()
  };

  // 通过 Mojo Observer 通知客户端
  if (observer_) {
    observer_->OnPermissionRequest(
        origin_str,
        ToMojomPermissionType(permission_type),
        request_id);
  } else {
    // 无 Observer → 自动 DENY（Phase 1 行为）
    ResolvePendingRequest(request_id, PermissionStatus::DENIED);
  }

  // 超时保护：30s 无回传自动 DENY。
  // 使用 weak_factory_ 的 WeakPtr，防止 OWLPermissionManager 被销毁后
  // delayed task 访问 dangling 指针。weak.MaybeValid() 在析构后返回 false，
  // BindOnce + weak_ptr 会自动跳过已失效的回调。
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&OWLPermissionManager::ResolvePendingRequestIfAlive,
                     weak_factory_.GetWeakPtr(), request_id,
                     PermissionStatus::DENIED),
      base::Seconds(30));
}
```

**超时安全：** `ResolvePendingRequest` 使用 `extract()` 从 map 中取出 callback。如果 request_id 已被消费（用户已回传或已超时），`extract` 返回空，静默忽略。这保证 callback 只执行一次。

**WeakPtr 安全：** `ResolvePendingRequestIfAlive` 是成员方法，通过 `weak_factory_.GetWeakPtr()` 绑定到 `PostDelayedTask`。当 `OWLPermissionManager` 在 30s 超时前被销毁时，`WeakPtr` 自动失效，`BindOnce` 不会执行回调，避免 dangling 指针。

```cpp
// 成员方法：由超时 delayed task 通过 WeakPtr 调用。
void OWLPermissionManager::ResolvePendingRequestIfAlive(
    uint64_t request_id, PermissionStatus status) {
  ResolvePendingRequest(request_id, status);
}

// 核心实现：也由 ResolvePermissionRequest（外部调用）直接调用。
void OWLPermissionManager::ResolvePendingRequest(
    uint64_t request_id, PermissionStatus status) {
  auto node = g_pending_requests.extract(request_id);
  if (node.empty()) return;  // 已回传或已超时

  auto& pending = node.mapped();
  const size_t n = pending.num_permissions;

  // Chromium 要求 results.size() == permissions.size()。
  // Phase 2 只处理第一个权限（index 0），其余填充 DENIED。
  std::vector<PermissionResult> results;
  results.reserve(n);
  results.emplace_back(status, PermissionStatusSource::UNSPECIFIED);
  for (size_t i = 1; i < n; ++i) {
    results.emplace_back(PermissionStatus::DENIED,
                         PermissionStatusSource::UNSPECIFIED);
  }
  std::move(pending.callback).Run(std::move(results));
}
```

#### 3.3 Bridge 端（owl_bridge_api.cc）回调转发

**全局状态扩展：**

```cpp
// 权限请求回调——全局变量（不放 WebViewState）。
// 设计决策：权限请求绑定到 BrowserContext，当前架构只有一个 context，
// 因此使用全局变量最简单。多 context 时需改为 per-webview 或 per-context。
// 只在 main thread 读写（C-ABI 保证回调在 main thread），无需加锁。
static OWLBridge_PermissionRequestCallback g_permission_request_cb = nullptr;
static void* g_permission_request_ctx = nullptr;
```

**`SetPermissionRequestCallback` 实现：**

```cpp
void OWLBridge_SetPermissionRequestCallback(
    OWLBridge_PermissionRequestCallback callback,
    void* callback_context) {
  // main thread only（与所有 C-ABI 注册函数一致）。
  g_permission_request_cb = callback;
  g_permission_request_ctx = callback_context;
}
```

**WebViewObserverImpl 新增：**

```cpp
void OnPermissionRequest(const std::string& origin,
                         owl::mojom::PermissionType type,
                         uint64_t request_id) override {
  if (!g_permission_request_cb) return;
  std::string origin_copy = origin;
  int type_int = static_cast<int>(type);
  auto cb = g_permission_request_cb;
  auto ctx = g_permission_request_ctx;
  dispatch_async(dispatch_get_main_queue(), ^{
    cb(origin_copy.c_str(), type_int, request_id, ctx);
  });
}
```

**`RespondToPermission` 实现：**

```cpp
void OWLBridge_RespondToPermission(uint64_t request_id, int status) {
  if (!g_initialized.load(std::memory_order_acquire)) return;
  if (!*g_webview) return;

  // 范围校验：PermissionStatus 只有 0=Granted, 1=Denied, 2=Ask。
  // 越界值默认 DENIED，防止 static_cast 产生未定义枚举值。
  if (status < 0 || status > 2) {
    LOG(WARNING) << "OWLBridge_RespondToPermission: invalid status "
                 << status << ", defaulting to DENIED";
    status = 1;  // kDenied
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](uint64_t rid, int st) {
            if (!*g_webview || !(*g_webview)->remote.is_connected()) return;
            (*g_webview)->remote->RespondToPermissionRequest(
                rid, static_cast<owl::mojom::PermissionStatus>(st));
          },
          request_id, status));
}
```

**`PermissionGetAll` 实现（参照 BookmarkGetAll 模式）：**

```cpp
void OWLBridge_PermissionGetAll(OWLBridge_PermissionListCallback callback,
                                 void* ctx) {
  if (!callback) return;
  if (!*g_permission_service) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(nullptr, "No permission service", ctx);
    });
    return;
  }

  (*g_io_thread)->task_runner()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](OWLBridge_PermissionListCallback cb, void* ctx) {
            (*g_permission_service)->remote->GetAllPermissions(
                base::BindOnce(
                    [](OWLBridge_PermissionListCallback cb, void* ctx,
                       std::vector<owl::mojom::SitePermissionPtr> perms) {
                      // Serialize to JSON array
                      base::Value::List list;
                      for (const auto& p : perms) {
                        base::Value::Dict dict;
                        dict.Set("origin", p->origin);
                        dict.Set("type", static_cast<int>(p->type));
                        dict.Set("status", static_cast<int>(p->status));
                        list.Append(std::move(dict));
                      }
                      std::string json;
                      base::JSONWriter::Write(base::Value(std::move(list)), &json);
                      std::string json_copy = json;
                      dispatch_async(dispatch_get_main_queue(), ^{
                        cb(json_copy.c_str(), nullptr, ctx);
                      });
                    },
                    cb, ctx));
          },
          callback, ctx));
}
```

#### 3.4 PermissionService 绑定（参照 BookmarkService 模式）

在 `OWLBridge_CreateBrowserContext` 的 callback 链中，与 BookmarkService / HistoryService 并行请求：

```cpp
// 新增全局状态
struct PermissionServiceState {
  mojo::Remote<owl::mojom::PermissionService> remote;
};
base::NoDestructor<std::unique_ptr<PermissionServiceState>> g_permission_service;

// 在 CreateBrowserContext 成功后
(*g_context)->remote->GetPermissionService(
    base::BindOnce(
        [](mojo::PendingRemote<owl::mojom::PermissionService> perm_remote) {
          if (perm_remote.is_valid()) {
            *g_permission_service = std::make_unique<PermissionServiceState>();
            (*g_permission_service)->remote.Bind(std::move(perm_remote));
            (*g_permission_service)->remote.set_disconnect_handler(
                base::BindOnce([]() {
                  LOG(ERROR) << "OWLBridge: PermissionService disconnected";
                  g_permission_service->reset();
                }));
            LOG(INFO) << "OWLBridge: PermissionService bound";
          }
        }));
```

---

### 4. Host 端实现要点

#### 4.1 OWLPermissionServiceImpl（新增）

实现 `owl::mojom::PermissionService`，桥接到 Phase 1 的 `OWLPermissionManager`：

```cpp
class OWLPermissionServiceImpl : public owl::mojom::PermissionService {
 public:
  explicit OWLPermissionServiceImpl(OWLPermissionManager* manager);

  void GetPermission(const std::string& origin,
                     owl::mojom::PermissionType type,
                     GetPermissionCallback callback) override;
  void SetPermission(const std::string& origin,
                     owl::mojom::PermissionType type,
                     owl::mojom::PermissionStatus status) override;
  void GetAllPermissions(GetAllPermissionsCallback callback) override;
  void ResetPermission(const std::string& origin,
                       owl::mojom::PermissionType type) override;
  void ResetAll() override;

 private:
  raw_ptr<OWLPermissionManager> manager_;  // Not owned, outlives this.
};
```

- 所有方法在 UI thread 执行（与 OWLPermissionManager 相同线程）。
- 类型转换使用静态函数 `ToBlinkType()` / `FromBlinkType()` / `ToMojomStatus()` / `FromMojomStatus()`。

**ResetPermission 实现说明：** `OWLPermissionManager` 没有独立的 `ResetPermission(origin, type)` 公共方法。`ResetPermission` 通过 `SetPermission(origin, type, ASK)` 等效实现——因为 `SetPermission` 在收到 `ASK` 状态时会删除该条目（等同于重置）。实现代码：

```cpp
void OWLPermissionServiceImpl::ResetPermission(
    const std::string& origin,
    owl::mojom::PermissionType type) {
  auto blink_type = FromMojomType(type);
  if (!blink_type) return;
  // ASK 等效于删除条目，即 reset。
  manager_->SetPermission(
      url::Origin::Create(GURL(origin)),
      *blink_type,
      content::PermissionStatus::ASK);
}
```

#### 4.2 OWLPermissionManager 改写（Phase 2）

`RequestPermissions` 从 "自动 DENY" 改为 "通过 delegate 通知客户端"：

```cpp
class OWLPermissionManager {
 public:
  // 新增：权限请求 delegate（由 OWLWebContents 设置）。
  // delegate 负责通过 Mojo Observer 通知客户端。
  class Delegate {
   public:
    virtual ~Delegate() = default;
    // 返回 true 表示请求已转发给客户端（异步等待回传）。
    // 返回 false 表示没有可用通道，RequestPermissions 应立即 DENY。
    virtual bool ForwardPermissionRequest(
        const std::string& origin,
        blink::PermissionType type,
        uint64_t request_id) = 0;
  };

  void SetDelegate(Delegate* delegate);

  // 外部调用：当客户端回传权限决定时。
  void ResolvePermissionRequest(uint64_t request_id,
                                content::PermissionStatus status);

  // 外部调用获取 UI-thread 上预创建的 WeakPtr（用于跨线程 PostTask）。
  // 注意：GetWeakPtr() 只能在绑定序列（UI thread）调用——这是 Chromium 约定。
  // 需要从 IO thread 投递到 UI thread 的场景，必须在 UI thread 初始化时
  // 提前获取 WeakPtr 存为成员，再 capture 该成员（见 OWLWebContents 示例）。
  base::WeakPtr<OWLPermissionManager> GetWeakPtr() {
    DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
    return weak_factory_.GetWeakPtr();
  }

 private:
  // 超时 delayed task 通过 WeakPtr 调用，防止析构后 dangling。
  void ResolvePendingRequestIfAlive(uint64_t request_id,
                                    content::PermissionStatus status);
  void ResolvePendingRequest(uint64_t request_id,
                             content::PermissionStatus status);

  SEQUENCE_CHECKER(sequence_checker_);
  // weak_factory_ 必须是最后一个成员（Chromium 约定）。
  base::WeakPtrFactory<OWLPermissionManager> weak_factory_{this};
};
```

**OWLWebContents 作为 Delegate：**
OWLWebContents 持有 `mojo::Remote<WebViewObserver>`，实现 `Delegate::ForwardPermissionRequest` 时调用 `observer_->OnPermissionRequest()`。
OWLWebContents 同时处理 `RespondToPermissionRequest` Mojo 调用，将其转发到 `OWLPermissionManager::ResolvePermissionRequest()`。

**线程安全（IO→UI PostTask）：** `WebViewHost::RespondToPermissionRequest` 的 Mojo handler 在 IO thread 上被调用（Mojo IPC 的默认调度），但 `OWLPermissionManager` 的所有状态（`g_pending_requests` map）只能在 UI thread 上访问。因此 `RespondToPermissionRequest` 的实现必须通过 `content::GetUIThreadTaskRunner({})->PostTask()` 将调用转发到 UI thread。

**WeakPtr 线程规则：** Chromium 的 `WeakPtrFactory::GetWeakPtr()` 只能在绑定序列（创建序列，即 UI thread）上调用。IO thread 上直接调用 `permission_manager_->GetWeakPtr()` 会触发 DCHECK 失败。解决方案：在 `OWLWebContents` 初始化时（UI thread 上构造），提前获取 WeakPtr 存为成员 `permission_manager_weak_`，IO thread 的 Mojo handler 直接 capture 这个已有的 WeakPtr 副本。WeakPtr 本身是可跨线程拷贝的（只有 GetWeakPtr() 创建操作受序列约束）：

```cpp
class OWLWebContents : ... {
 public:
  // 在构造函数（UI thread）中初始化。
  OWLWebContents(..., OWLPermissionManager* permission_manager)
      : permission_manager_(permission_manager),
        permission_manager_weak_(permission_manager->GetWeakPtr()) {}

 private:
  raw_ptr<OWLPermissionManager> permission_manager_;
  // UI thread 上预获取，IO thread 安全 capture。
  base::WeakPtr<OWLPermissionManager> permission_manager_weak_;
};

// WebViewHost Mojo handler（IO thread 上被调用）
void OWLWebContents::RespondToPermissionRequest(
    uint64_t request_id,
    owl::mojom::PermissionStatus status) {
  // Mojo handler 运行在 IO thread，必须 PostTask 到 UI thread。
  // 使用预获取的 WeakPtr（UI thread 创建），不在 IO thread 调用 GetWeakPtr()。
  content::GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE,
      base::BindOnce(
          &OWLPermissionManager::ResolvePermissionRequest,
          permission_manager_weak_,
          request_id,
          FromMojomStatus(status)));
}
```

---

### 5. 文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| **新增** | `mojom/permissions.mojom` | PermissionType, PermissionStatus, SitePermission, PermissionService |
| **修改** | `mojom/web_view.mojom` | Observer +OnPermissionRequest, Host +RespondToPermissionRequest |
| **修改** | `mojom/browser_context.mojom` | +import permissions.mojom, +GetPermissionService() |
| **修改** | `mojom/BUILD.gn` | 新增 permissions.mojom 编译目标 |
| **新增** | `host/owl_permission_service_impl.h/.cc` | PermissionService Mojo 实现 |
| **修改** | `host/owl_permission_manager.h/.cc` | +Delegate 接口, +ResolvePermissionRequest, RequestPermissions 改为异步 |
| **修改** | `host/owl_web_contents.h/.cc` | 实现 Delegate, 处理 RespondToPermissionRequest |
| **修改** | `host/owl_content_browser_context.h/.cc` | 暴露 PermissionService Mojo binding |
| **修改** | `host/BUILD.gn` | 新增 owl_permission_service_impl 编译 |
| **修改** | `bridge/owl_bridge_api.h` | 新增权限 C-ABI 函数声明 |
| **修改** | `bridge/owl_bridge_api.cc` | 权限回调转发 + PermissionService 绑定 |
| **新增** | `bridge/owl_bridge_permission_unittest.mm` | Bridge 层权限函数单元测试 |

---

### 6. 测试策略

#### 6.1 C++ GTest（host 层）

| 测试 | 文件 | 验证点 |
|------|------|--------|
| PermissionServiceImpl 类型转换 | `owl_permission_service_impl_unittest.cc` | Mojom↔blink 类型正确映射 |
| PermissionServiceImpl CRUD | 同上 | GetPermission/SetPermission/GetAll/Reset/ResetAll 通过 Mojo 接口正确调用 PermissionManager |
| RequestPermissions 异步路径 | `owl_permission_manager_unittest.cc` | 设置 Delegate 后 RequestPermissions 不立即 DENY，而是转发给 delegate |
| RequestPermissions 无 delegate 回退 | 同上 | 无 delegate 时自动 DENY（Phase 1 兼容） |
| RequestPermissions 超时 | 同上 | 使用 `base::test::TaskEnvironment(TimeSource::MOCK_TIME)` + `task_environment.FastForwardBy(base::Seconds(30))`，验证 30s 无回传后自动 DENY（不实际等待 30s） |
| ResolvePermissionRequest 幂等性 | 同上 | 同一 request_id 多次调用只有第一次生效 |

**参数：** `owl-client-app/scripts/run_tests.sh cpp`

#### 6.2 Bridge 单元测试

| 测试 | 文件 | 验证点 |
|------|------|--------|
| SetPermissionRequestCallback 注册/取消 | `owl_bridge_permission_unittest.mm` | 注册后 OnPermissionRequest 触发回调；NULL 取消后不触发 |
| RespondToPermission 转发 | 同上 | 调用后 WebViewHost mock 收到正确 request_id + status |
| PermissionGetAll JSON 序列化 | 同上 | 返回正确 JSON 结构 |
| PermissionGet 单条查询 | 同上 | 返回正确 status |
| PermissionReset fire-and-forget | 同上 | 调用不崩溃，PermissionService mock 收到调用 |
| 线程安全：回调在 main thread | 同上 | 使用 XCTAssert + dispatch_get_main_queue 验证 |
| Bridge 未初始化时调用 RespondToPermission | 同上 | `g_initialized=false` 时调用 `OWLBridge_RespondToPermission` → 静默返回不崩溃（`g_initialized` 守卫生效） |
| Bridge 未初始化时调用 PermissionGetAll | 同上 | `g_permission_service` 为空时调用 → callback 收到 error_msg 不为 NULL、json_array 为 NULL |

**参数：** `owl-client-app/scripts/run_tests.sh cpp`（bridge unittest 编入 C++ GTest target）

#### 6.3 测试顺序

1. 先确保 `mojom/permissions.mojom` 编译通过（AC-P2-1）
2. Host 端 PermissionServiceImpl GTest 通过
3. Host 端 RequestPermissions 异步路径 GTest 通过
4. Bridge 层单元测试通过（AC-P2-2 ~ AC-P2-5）

#### 6.4 不在 Phase 2 测试的

- Swift ViewModel 测试（Phase 3 Swift UI 层）
- E2E Pipeline 测试（需要真实 Chromium renderer 触发 `navigator.permissions.query()`，留到 Phase 3）
- 手动验证（Phase 4 集成测试）
