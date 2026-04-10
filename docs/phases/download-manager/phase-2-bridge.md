# Phase 2: Mojo 适配层 + Bridge C-ABI

## 目标
- 将 Host 层的下载能力通过 Mojo 和 C-ABI 暴露给 Swift 客户端
- Swift 侧可通过 C 函数查询/控制下载，并接收推送回调

## 范围

### 修改文件
- `host/owl_browser_context.h/.cc` — 新增 `DownloadServiceMojoAdapter` + `GetDownloadService()` + `SetDownloadObserver()`
- `bridge/owl_bridge_api.h` — 新增下载相关 C-ABI 函数声明和回调类型
- `bridge/owl_bridge_api.cc` — 实现下载 C-ABI 函数

## 依赖
- Phase 1（Mojom 接口 + Host delegate 已实现）

## 技术要点

1. **DownloadServiceMojoAdapter**: 沿用 HistoryServiceMojoAdapter 模式，绑定 Mojo receiver，委托给底层 delegate
2. **C-ABI 函数签名**:
   ```c
   // 查询
   OWLBridge_DownloadGetAll(callback, ctx)
   // 控制
   OWLBridge_DownloadPause(download_id)
   OWLBridge_DownloadResume(download_id)
   OWLBridge_DownloadCancel(download_id)
   OWLBridge_DownloadOpenFile(download_id)
   OWLBridge_DownloadShowInFolder(download_id)
   OWLBridge_DownloadRemoveEntry(download_id)
   // 推送回调
   OWLBridge_SetDownloadCallback(callback, ctx)
   ```
3. **JSON 序列化**: DownloadItem → JSON，包含 id, url, filename, mime_type, total_bytes, received_bytes, state, error_description, can_resume
4. **推送事件**: 两种回调 — `OnDownloadCreated` 和 `OnDownloadUpdated`，统一为一个回调类型
5. **线程**: C-ABI 调用在 IO 线程 PostTask，回调 dispatch 到 main queue

## 验收标准
- [ ] Mojo 适配层绑定成功，GetDownloadService() 返回 remote
- [ ] C-ABI 函数从 Swift 侧可调用
- [ ] GetAll 返回正确的 JSON 数组
- [ ] Pause/Resume/Cancel 操作生效
- [ ] 推送回调在下载状态变化时触发
- [ ] Bridge 单元测试

## 技术方案

### 1. 架构设计

```
OWLBrowserContext (Mojo 层)
  ├── GetDownloadService() → 创建 DownloadServiceMojoAdapter
  │     └── DownloadServiceMojoAdapter : owl::mojom::DownloadService
  │           ├── GetAll() → service->GetAllDownloads() → 转 mojom 类型
  │           ├── Pause/Resume/Cancel/Remove → service->XxxDownload()
  │           └── OpenFile/ShowInFolder → service->Xxx()
  ├── SetDownloadObserver() → 存储 mojo::Remote<DownloadObserver>
  └── download_service_ change/removed callback → observer->OnXxx()
            ↓
Bridge C-ABI (owl_bridge_api.h/.cc)
  ├── DownloadState { remote, observer_impl, observer_receiver }
  ├── OWLBridge_DownloadGetAll() → IO thread → remote->GetAll() → JSON → main queue
  ├── OWLBridge_DownloadPause/Resume/Cancel/Remove/Open/Show() → IO thread → remote->Xxx()
  └── OWLBridge_SetDownloadCallback() → DownloadObserverImpl → main queue dispatch
```

**数据流**（以 GetAll 为例）:
1. Swift 调用 `OWLBridge_DownloadGetAll(callback, ctx)` [main thread]
2. PostTask 到 IO thread
3. `g_download_service->remote->GetAll(...)` [IO thread, Mojo IPC]
4. DownloadServiceMojoAdapter 收到请求 → 调用 OWLDownloadService::GetAllDownloads()
5. 转换为 mojom::DownloadItem 数组 → 通过 Mojo 返回
6. Bridge 收到回调 → JSON 序列化 → `dispatch_async(main_queue)` → Swift callback

### 2. Mojo 适配层

#### browser_context.mojom 修改

```mojom
// browser_context.mojom 修改:
// 1. 添加 import
import "third_party/owl/mojom/downloads.mojom";

// 2. 在 BrowserContextHost 接口中新增:
GetDownloadService() => (pending_remote<DownloadService> service);
SetDownloadObserver(pending_remote<DownloadObserver> observer);
```

**Observer 注册点**: 统一通过 `BrowserContextHost::SetDownloadObserver()` 注册。

**mojom import**: `browser_context.mojom` 必须 import `downloads.mojom` 才能引用 `DownloadService` 和 `DownloadObserver` 类型。

#### DownloadServiceMojoAdapter

沿用 HistoryServiceMojoAdapter 模式（定义在 owl_browser_context.cc 中）：

```cpp
class DownloadServiceMojoAdapter : public owl::mojom::DownloadService {
 public:
  DownloadServiceMojoAdapter(OWLDownloadService* service,
                              OWLBrowserContext* context);
  void Bind(mojo::PendingReceiver<owl::mojom::DownloadService> receiver);

  // owl::mojom::DownloadService:
  void GetAll(GetAllCallback callback) override;
  void Pause(uint32_t download_id) override;
  void Resume(uint32_t download_id) override;
  void Cancel(uint32_t download_id) override;
  void RemoveEntry(uint32_t download_id) override;
  void OpenFile(uint32_t download_id) override;
  void ShowInFolder(uint32_t download_id) override;

 private:
  // 将 download::DownloadItem* 转为 owl::mojom::DownloadItemPtr
  static owl::mojom::DownloadItemPtr ToMojom(download::DownloadItem* item);
  // 将 Chromium DownloadState + IsPaused 转为 owl::mojom::DownloadState
  static owl::mojom::DownloadState MapState(download::DownloadItem* item);
  // 将 InterruptReason 转为用户可读错误描述
  static std::string MapErrorDescription(
      download::DownloadInterruptReason reason);

  raw_ptr<OWLDownloadService> service_;
  raw_ptr<OWLBrowserContext> context_;
  mojo::Receiver<owl::mojom::DownloadService> receiver_{this};
};
```

**关键转换逻辑** — `ToMojom()`:
```cpp
static owl::mojom::DownloadItemPtr ToMojom(download::DownloadItem* item) {
  auto result = owl::mojom::DownloadItem::New();
  result->id = item->GetId();
  result->url = item->GetURL().spec();
  result->filename = item->GetTargetFilePath().BaseName().AsUTF8Unsafe();
  result->mime_type = item->GetMimeType();
  result->total_bytes = item->GetTotalBytes();
  result->received_bytes = item->GetReceivedBytes();
  result->speed_bytes_per_sec = item->CurrentSpeed();
  result->state = MapState(item);
  result->can_resume = item->CanResume();
  result->target_path = item->GetTargetFilePath().AsUTF8Unsafe();
  if (item->GetState() == download::DownloadItem::INTERRUPTED) {
    result->error_description = MapErrorDescription(item->GetLastReason());
  }
  return result;
}
```

**状态映射** — `MapState()`:
```cpp
static owl::mojom::DownloadState MapState(download::DownloadItem* item) {
  switch (item->GetState()) {
    case download::DownloadItem::IN_PROGRESS:
      return item->IsPaused() ? owl::mojom::DownloadState::kPaused
                              : owl::mojom::DownloadState::kInProgress;
    case download::DownloadItem::COMPLETE:
      return owl::mojom::DownloadState::kComplete;
    case download::DownloadItem::CANCELLED:
      return owl::mojom::DownloadState::kCancelled;
    case download::DownloadItem::INTERRUPTED:
      return owl::mojom::DownloadState::kInterrupted;
    default:
      return owl::mojom::DownloadState::kInProgress;
  }
}
```

#### OWLBrowserContext 集成

**Service 所有权**: `OWLDownloadService` 已由 `OWLContentBrowserContext` 在 Phase 1 创建并拥有（`GetDownloadManagerDelegate()` 中 lazy-create）。`OWLBrowserContext` **不创建新 service**，而是通过指针引用已有实例。

```cpp
// owl_browser_context.h 新增成员:
raw_ptr<OWLDownloadService> download_service_ = nullptr;  // 不拥有，引用自 ContentBrowserContext
std::unique_ptr<DownloadServiceMojoAdapter> download_mojo_adapter_;
mojo::Remote<owl::mojom::DownloadObserver> download_observer_;

// owl_browser_context.cc:

// 在 OWLBrowserContext 构造或初始化时注入 service 指针:
void OWLBrowserContext::SetDownloadService(OWLDownloadService* service) {
  download_service_ = service;
  // 注册 change/removed 回调
  if (download_service_) {
    download_service_->SetChangedCallback(
        base::BindRepeating(&OWLBrowserContext::OnDownloadChanged,
                            weak_factory_.GetWeakPtr()));
    download_service_->SetRemovedCallback(
        base::BindRepeating(&OWLBrowserContext::OnDownloadRemoved,
                            weak_factory_.GetWeakPtr()));
  }
}

void OWLBrowserContext::GetDownloadService(GetDownloadServiceCallback cb) {
  if (!download_service_) {
    std::move(cb).Run(mojo::NullRemote());
    return;
  }
  // 创建 adapter（与 History 模式一致，Bridge 只调一次）
  auto adapter = std::make_unique<DownloadServiceMojoAdapter>(
      download_service_, this);
  mojo::PendingRemote<owl::mojom::DownloadService> remote;
  adapter->Bind(remote.InitWithNewPipeAndPassReceiver());
  download_mojo_adapter_ = std::move(adapter);
  std::move(cb).Run(std::move(remote));
}

void OWLBrowserContext::SetDownloadObserver(
    mojo::PendingRemote<owl::mojom::DownloadObserver> observer) {
  download_observer_.Bind(std::move(observer));
}

// download_service_ 的 change/removed callback → push to observer:
void OWLBrowserContext::OnDownloadChanged(download::DownloadItem* item,
                                           bool created) {
  if (!download_observer_.is_bound() || !download_observer_.is_connected())
    return;
  auto mojom_item = DownloadServiceMojoAdapter::ToMojom(item);
  if (created) {
    download_observer_->OnDownloadCreated(std::move(mojom_item));
  } else {
    download_observer_->OnDownloadUpdated(std::move(mojom_item));
  }
}

void OWLBrowserContext::OnDownloadRemoved(uint32_t id) {
  if (!download_observer_.is_bound() || !download_observer_.is_connected())
    return;
  download_observer_->OnDownloadRemoved(id);
}

// Destroy() 清理（在现有 Destroy() 方法中补充）:
void OWLBrowserContext::Destroy() {
  // ... 现有清理 ...
  download_observer_.reset();
  download_mojo_adapter_.reset();
  download_service_ = nullptr;  // 不 delete（不拥有）
  // ... 继续现有清理 ...
}
```

**初始化时机**: 在 Bridge 层 `OWLBridge_CreateContext` 回调中，`OWLContentBrowserContext::GetDownloadManagerDelegate()` 触发 delegate+service 创建后，将 service 指针注入 `OWLBrowserContext`:
```cpp
// 在 context 创建完成后:
auto* content_ctx = g_content_browser_context;
auto* delegate = content_ctx->GetDownloadManagerDelegate();
auto* service = content_ctx->download_service();  // 需要新增 accessor
browser_context->SetDownloadService(service);
```

### 3. Bridge C-ABI 设计

#### 回调类型

```c
// 查询回调（JSON 数组）
typedef void (*OWLBridge_DownloadListCallback)(
    const char* json_array,    // JSON-encoded array of DownloadItem
    const char* error_msg,     // NULL on success
    void* context);

// 推送回调（单个下载事件）
typedef void (*OWLBridge_DownloadEventCallback)(
    const char* json_item,     // JSON-encoded single DownloadItem
    int32_t event_type,        // 0=created, 1=updated, 2=removed
    void* context);
```

#### C-ABI 函数

```c
// 查询所有下载
OWL_EXPORT void OWLBridge_DownloadGetAll(
    OWLBridge_DownloadListCallback callback, void* ctx);

// 控制操作（无回调，fire-and-forget）
OWL_EXPORT void OWLBridge_DownloadPause(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadResume(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadCancel(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadRemoveEntry(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadOpenFile(uint32_t download_id);
OWL_EXPORT void OWLBridge_DownloadShowInFolder(uint32_t download_id);

// 推送回调注册（内部 PostTask 到 IO thread 写入全局变量，避免跨线程竞争）
OWL_EXPORT void OWLBridge_SetDownloadCallback(
    OWLBridge_DownloadEventCallback callback, void* ctx);
```

#### Bridge 全局状态

```cpp
struct DownloadState {
  mojo::Remote<owl::mojom::DownloadService> remote;
  // Observer 生命周期由此 struct 管理（防止析构）
  std::unique_ptr<DownloadObserverImpl> observer_impl;
  std::unique_ptr<mojo::Receiver<owl::mojom::DownloadObserver>> observer_receiver;
};
base::NoDestructor<std::unique_ptr<DownloadState>> g_download_service;

// 推送回调 — 只在 IO thread 上读写（注册也 PostTask 到 IO thread）
static OWLBridge_DownloadEventCallback g_download_event_cb = nullptr;
static void* g_download_event_ctx = nullptr;

class DownloadObserverImpl : public owl::mojom::DownloadObserver {
  void OnDownloadCreated(owl::mojom::DownloadItemPtr item) override {
    DispatchEvent(std::move(item), 0);  // event_type=0
  }
  void OnDownloadUpdated(owl::mojom::DownloadItemPtr item) override {
    DispatchEvent(std::move(item), 1);  // event_type=1
  }
  void OnDownloadRemoved(uint32_t id) override {
    if (!g_download_event_cb) return;
    auto cb = g_download_event_cb;
    auto ctx = g_download_event_ctx;
    // removed 事件: 统一 JSON 格式（包含 id 字段，其他字段为默认值）
    auto dict = base::Value::Dict();
    dict.Set("id", static_cast<int>(id));
    dict.Set("url", "");
    dict.Set("filename", "");
    dict.Set("state", static_cast<int>(owl::mojom::DownloadState::kCancelled));
    std::string json;
    base::JSONWriter::Write(base::Value(std::move(dict)), &json);
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(json.c_str(), 2, ctx);  // event_type=2
    });
  }
 private:
  void DispatchEvent(owl::mojom::DownloadItemPtr item, int32_t type) {
    if (!g_download_event_cb) return;
    std::string json = DownloadItemToJson(item);
    auto cb = g_download_event_cb;
    auto ctx = g_download_event_ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      cb(json.c_str(), type, ctx);
    });
  }
};
```

#### JSON 序列化

```cpp
static std::string DownloadItemToJson(
    const owl::mojom::DownloadItemPtr& item) {
  auto dict = base::Value::Dict();
  dict.Set("id", static_cast<int>(item->id));
  dict.Set("url", item->url);
  dict.Set("filename", item->filename);
  dict.Set("mime_type", item->mime_type);
  dict.Set("total_bytes", static_cast<double>(item->total_bytes));
  dict.Set("received_bytes", static_cast<double>(item->received_bytes));
  dict.Set("speed_bytes_per_sec",
           static_cast<double>(item->speed_bytes_per_sec));
  dict.Set("state", static_cast<int>(item->state));
  dict.Set("can_resume", item->can_resume);
  dict.Set("target_path", item->target_path);
  if (item->error_description.has_value()) {
    dict.Set("error_description", item->error_description.value());
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(dict)), &json);
  return json;
}

static std::string DownloadItemListToJson(
    const std::vector<owl::mojom::DownloadItemPtr>& items) {
  auto list = base::Value::List();
  for (const auto& item : items) {
    // 直接构建 dict，不经过序列化-反序列化
    auto dict = base::Value::Dict();
    dict.Set("id", static_cast<int>(item->id));
    dict.Set("url", item->url);
    dict.Set("filename", item->filename);
    dict.Set("mime_type", item->mime_type);
    dict.Set("total_bytes", static_cast<double>(item->total_bytes));
    dict.Set("received_bytes", static_cast<double>(item->received_bytes));
    dict.Set("speed_bytes_per_sec",
             static_cast<double>(item->speed_bytes_per_sec));
    dict.Set("state", static_cast<int>(item->state));
    dict.Set("can_resume", item->can_resume);
    dict.Set("target_path", item->target_path);
    if (item->error_description.has_value()) {
      dict.Set("error_description", item->error_description.value());
    }
    list.Append(base::Value(std::move(dict)));
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(list)), &json);
  return json;
}
```

#### 服务绑定（在 Context 创建时）

沿用 History 的绑定模式，在 `OWLBridge_CreateContext` 回调链中新增：

```cpp
// 在 context 创建成功后:
(*g_context)->remote->GetDownloadService(
    base::BindOnce([](mojo::PendingRemote<owl::mojom::DownloadService> remote) {
      if (remote.is_valid()) {
        *g_download_service = std::make_unique<DownloadState>();
        (*g_download_service)->remote.Bind(std::move(remote));
        (*g_download_service)->remote.set_disconnect_handler(
            base::BindOnce([]() { g_download_service->reset(); }));

        // 设置 observer（存储在 DownloadState 中防止析构）
        (*g_download_service)->observer_impl =
            std::make_unique<DownloadObserverImpl>();
        (*g_download_service)->observer_receiver =
            std::make_unique<mojo::Receiver<owl::mojom::DownloadObserver>>(
                (*g_download_service)->observer_impl.get());
        mojo::PendingRemote<owl::mojom::DownloadObserver> obs_remote;
        (*g_download_service)->observer_receiver->Bind(
            obs_remote.InitWithNewPipeAndPassReceiver());
        // 通过 BrowserContextHost 注册 observer（不在 DownloadService 上）
        (*g_context)->remote->SetDownloadObserver(std::move(obs_remote));
      }
    }));
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/browser_context.mojom` | 修改 | import downloads.mojom + 添加 GetDownloadService() + SetDownloadObserver() |
| `host/owl_browser_context.h` | 修改 | 添加 download 成员(raw_ptr service, adapter, observer) + 方法声明 |
| `host/owl_browser_context.cc` | 修改 | DownloadServiceMojoAdapter + GetDownloadService + SetDownloadObserver + observer 回调 + Destroy 清理 |
| `host/owl_content_browser_context.h` | 修改 | 添加 `download_service()` public accessor |
| `bridge/owl_bridge_api.h` | 修改 | 新增下载 C-ABI 函数声明和回调类型 |
| `bridge/owl_bridge_api.cc` | 修改 | 实现下载 C-ABI 函数 + DownloadObserverImpl + JSON 序列化 + context 创建时 SetDownloadService 注入 |

### 5. 测试策略

**单元测试** (`host/owl_browser_context_unittest.cc` 追加 / `bridge/owl_bridge_download_unittest.cc` 新增):
- `DownloadServiceMojoAdapter_GetAll` — 验证 GetAll 返回正确的 mojom 类型
- `DownloadServiceMojoAdapter_MapState` — 验证状态映射（IN_PROGRESS→kInProgress, IN_PROGRESS+IsPaused→kPaused, etc.）
- `DownloadServiceMojoAdapter_ToMojom` — 验证字段转换
- `DownloadServiceMojoAdapter_MapError` — 验证错误描述映射
- `OWLBrowserContext_GetDownloadService` — 验证 lazy-create + Mojo pipe 建立
- `OWLBrowserContext_DownloadObserver` — 验证 change/removed 回调推送到 observer
- `Bridge_DownloadGetAll_ReturnsJson` — 验证 JSON 序列化格式
- `Bridge_DownloadPause_PostsToIOThread` — 验证线程模型

### 6. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| OWLBrowserContext 已有大量成员 | 下载相关只增加 3 个成员（service, adapter, observer），与 history 模式一致 |
| Bridge 全局状态管理 | 沿用 History 的 NoDestructor 模式，disconnect_handler 自动清理 |
| 全局回调指针线程安全 | `g_download_event_cb/ctx` 只在 IO thread 读写。`OWLBridge_SetDownloadCallback()` 通过 PostTask 到 IO thread 设置。Observer 的 `DispatchEvent` 在 IO thread 读取，`dispatch_async(main_queue)` 投递到 main thread |
| Observer 推送节流 | Phase 2 不做节流，Phase 3 的 Swift ViewModel 负责 100ms 节流 |
| DownloadItem 指针在 Mojo 回调中可能已失效 | ToMojom 在 UI 线程即时转换，不跨线程持有 DownloadItem 指针 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
