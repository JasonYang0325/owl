# Phase 35: Bookmarks 服务层

## 目标

将已有的 BookmarkService mojom 和 Host 实现接通 C-ABI 层，使 Swift 端可以进行书签 CRUD 操作。本 phase 不含 UI。

## 范围

### 修改文件

| 层级 | 文件 | 变更 |
|------|------|------|
| Mojom | `mojom/session.mojom` 或 `mojom/browser_context.mojom` | 暴露 BookmarkService 到 Client |
| Host | `host/owl_bookmark_service.h/.cc` | 添加磁盘持久化（JSON 文件） |
| Host | `host/owl_browser_context_host.h/.mm` 或类似 | 注册 BookmarkService |
| C-ABI | `bridge/owl_bridge_api.h/.cc` | +OWLBridge_Bookmark* 系列函数 |
| Swift | `Services/OWLBridgeSwift.swift` 或新文件 | async/await wrapper |
| GN | `host/BUILD.gn` | 确认 bookmark_service 编入 |
| Tests | `host/owl_bookmark_service_unittest.cc` | CRUD + 持久化单元测试 |
| Tests | `Tests/OWLBrowserTests.swift` | Bookmark C-ABI E2E 测试 |

## 依赖

- 无前置 phase 依赖
- 已有基础：`mojom/bookmarks.mojom` + `host/owl_bookmark_service.h/.cc`

## 技术要点

### 已有实现分析

`bookmarks.mojom` 已定义完整 CRUD 接口：
```mojom
struct BookmarkItem { string id; string title; string url; string? parent_id; };
interface BookmarkService {
  GetAll() => (array<BookmarkItem> items);
  Add(string title, string url, string? parent_id) => (BookmarkItem? item);
  Remove(string id) => (bool success);
  Update(string id, string? title, string? url) => (bool success);
};
```

`OWLBookmarkService` 已有内存存储实现，需要补充：
1. JSON 文件持久化（读写 `{user_data_dir}/bookmarks.json`）
2. 通过 BrowserContext/Session 暴露给 Client

### 服务注册模式

参考 WebView 的创建模式，BookmarkService 需要通过某个已有的 Mojo 接口暴露。两种方案：

**方案 A**：在 `BrowserContextHost` 加 `GetBookmarkService() => (pending_remote<BookmarkService>)`
**方案 B**：独立的 C-ABI 函数直接操作（不走 Mojo，Host 内部调用）

推荐**方案 A**（Mojo），与已有架构一致。

### C-ABI 设计

```c
// 获取所有书签
typedef void (*OWLBridge_BookmarkListCallback)(
    const char* json_array,  // JSON: [{"id":"...","title":"...","url":"..."}]
    const char* error_msg,
    void* context);
OWL_EXPORT void OWLBridge_BookmarkGetAll(
    OWLBridge_BookmarkListCallback callback, void* ctx);

// 添加书签
typedef void (*OWLBridge_BookmarkAddCallback)(
    const char* bookmark_json,  // JSON: {"id":"...","title":"...","url":"..."}
    const char* error_msg,
    void* context);
OWL_EXPORT void OWLBridge_BookmarkAdd(
    const char* title, const char* url, const char* parent_id,
    OWLBridge_BookmarkAddCallback callback, void* ctx);

// 删除书签
typedef void (*OWLBridge_BookmarkRemoveCallback)(int success, const char* error_msg, void* ctx);
OWL_EXPORT void OWLBridge_BookmarkRemove(
    const char* bookmark_id,
    OWLBridge_BookmarkRemoveCallback callback, void* ctx);

// 更新书签
typedef void (*OWLBridge_BookmarkUpdateCallback)(int success, const char* error_msg, void* ctx);
OWL_EXPORT void OWLBridge_BookmarkUpdate(
    const char* bookmark_id, const char* title, const char* url,
    OWLBridge_BookmarkUpdateCallback callback, void* ctx);
```

### 持久化设计

简单 JSON 文件存储（不用 Chromium BookmarkModel，避免引入复杂依赖）：
- 路径：`{user_data_dir}/bookmarks.json`
- 写入策略：每次修改后延迟写入（debounce 1s）
- 读取：启动时加载

### 已知陷阱

- BookmarkService 当前用 `std::vector` 内存存储，ID 是 `base::Uuid` 生成
- JSON 序列化用 `base::Value` + `base::JSONWriter`（Chromium 内置）
- C-ABI 返回 JSON 字符串比逐字段传更灵活（书签结构可能扩展）

## 验收标准

- [ ] AC-001: `OWLBridge_BookmarkAdd` 可添加书签，回调返回完整 BookmarkItem JSON
- [ ] AC-002: `OWLBridge_BookmarkGetAll` 返回所有书签的 JSON 数组
- [ ] AC-003: `OWLBridge_BookmarkRemove` 删除指定 ID 的书签
- [ ] AC-004: `OWLBridge_BookmarkUpdate` 更新书签标题或 URL
- [ ] AC-005: 书签数据持久化到 `{user_data_dir}/bookmarks.json`，重启后保留
- [ ] AC-006: C++ 单元测试覆盖 CRUD + 持久化（写入后重新加载验证）
- [ ] AC-007: E2E 测试通过 C-ABI 验证完整 CRUD 流程

---

## 技术方案

### 1. 架构设计

**核心决策**：BookmarkService 挂在 BrowserContextHost 上（方案 A），与 WebView 同级。原因：书签是 per-profile 的，不是 per-tab。一个 BrowserContext 共享一个 BookmarkService。

**数据流（Add Bookmark）**：
```
Swift 调用 OWLBridge_BookmarkAdd("Google", "https://google.com", nil, callback, ctx)
  │
  Bridge: 拷贝字符串 → PostTask IO thread
  │
  IO thread: (*g_bookmark_service)->remote->Add(title, url, parent_id,
      base::BindOnce → dispatch_async(main) → callback)
  │
  Host UI thread: OWLBookmarkService::Add
      → 创建 BookmarkItem (id=GenerateId(), title, url)
      → bookmarks_.push_back(item)
      → SchedulePersist()  // debounce 1s 写入 bookmarks.json
      → callback(item.Clone())
  │
  Mojo → IO thread → dispatch_async(main) → C callback
  │
  Swift: 解析 JSON → BookmarkItem struct
```

**模块关系**：
```
BrowserContextHost
  ├── CreateWebView() → WebViewHost   (已有)
  └── GetBookmarkService() → BookmarkService  (新增)
```

### 2. 数据模型

**持久化格式**（`{user_data_dir}/bookmarks.json`）：
```json
{
  "version": 1,
  "bookmarks": [
    {"id": "1", "title": "Google", "url": "https://google.com", "parent_id": null},
    {"id": "2", "title": "GitHub", "url": "https://github.com", "parent_id": null}
  ],
  "next_id": 3
}
```

**设计要点**：
- `version` 字段用于未来 schema 迁移
- `next_id` 持久化避免 ID 碰撞（当前 `next_id_` 是内存递增，重启会重置为 1）
- 使用 `base::Value::Dict` + `base::JSONWriter::Write` 序列化
- 写入使用 write-to-temp + rename 原子替换模式（防半写文件损坏）
- 读取使用 `base::JSONReader::Read` 容错解析

### 3. 接口设计

#### 3.1 Mojom 变更（browser_context.mojom）

```mojom
import "third_party/owl/mojom/bookmarks.mojom";

interface BrowserContextHost {
  CreateWebView(pending_remote<WebViewObserver> observer)
      => (pending_remote<WebViewHost> web_view);
  // Phase 35: 获取书签服务
  GetBookmarkService() => (pending_remote<BookmarkService> service);
  Destroy() => ();
};
```

#### 3.2 OWLBookmarkService 新增持久化接口

```cpp
class OWLBookmarkService : public owl::mojom::BookmarkService {
 public:
  // 新增：构造时传入持久化路径
  explicit OWLBookmarkService(const base::FilePath& storage_path);
  // 原有构造保留用于测试（内存模式，空路径）
  OWLBookmarkService();
  ~OWLBookmarkService() override;  // Round 1 fix: 析构时 flush

  // 新增：从文件加载
  void LoadFromFile();

 private:
  // Round 1 P1 fix: 输入校验
  static bool IsUrlAllowed(const std::string& url);
  static bool IsTitleValid(const std::string& title);

  // 新增：延迟写入
  void SchedulePersist();
  void PersistNow();
  std::string SerializeToJson();  // 纯内存操作，UI thread 安全

  base::FilePath storage_path_;  // 空 = 纯内存模式
  base::OneShotTimer persist_timer_;
  // Round 2 fix: 专属 SequencedTaskRunner 串行化文件 I/O
  scoped_refptr<base::SequencedTaskRunner> file_task_runner_;
  SEQUENCE_CHECKER(sequence_checker_);
};
```

**输入校验（Round 1 P1 fix）**：
- `IsUrlAllowed`: 复用 `OWLWebContents::IsUrlAllowed` 的 scheme 白名单（http/https/data），拒绝 javascript:/file:/chrome: 等
- `IsTitleValid`: 非空 + 长度 ≤ 1024 字符
- `Add` 和 `Update` 均做校验，拒绝非法输入返回 null/false

#### 3.3 C-ABI（owl_bridge_api.h 新增）

```c
// === Bookmarks (Phase 35) ===

// 获取所有书签。回调返回 JSON 数组。
typedef void (*OWLBridge_BookmarkListCallback)(
    const char* json_array,    // JSON: [{"id":"1","title":"...","url":"..."}]
    const char* error_msg,     // NULL on success
    void* context);
OWL_EXPORT void OWLBridge_BookmarkGetAll(
    OWLBridge_BookmarkListCallback callback, void* callback_context);

// 添加书签。回调返回单个书签 JSON。
typedef void (*OWLBridge_BookmarkAddCallback)(
    const char* bookmark_json, // JSON: {"id":"1","title":"...","url":"..."}
    const char* error_msg,
    void* context);
OWL_EXPORT void OWLBridge_BookmarkAdd(
    const char* title, const char* url, const char* parent_id,
    OWLBridge_BookmarkAddCallback callback, void* callback_context);

// 删除书签。
typedef void (*OWLBridge_BookmarkResultCallback)(
    int success,               // 1=success, 0=not found
    const char* error_msg,
    void* context);
OWL_EXPORT void OWLBridge_BookmarkRemove(
    const char* bookmark_id,
    OWLBridge_BookmarkResultCallback callback, void* callback_context);

// 更新书签标题或 URL。title/url 为 NULL 表示不更新该字段。
OWL_EXPORT void OWLBridge_BookmarkUpdate(
    const char* bookmark_id,
    const char* title,         // NULL = don't change
    const char* url,           // NULL = don't change
    OWLBridge_BookmarkResultCallback callback, void* callback_context);
```

**设计要点**：
- Bookmark C-ABI 不经过 `g_webview`（书签是 per-context 不是 per-webview），经过 `g_bookmark_service`
- Remove 和 Update 共用 `OWLBridge_BookmarkResultCallback` 类型（返回 success+error）
- JSON 序列化在 Host→Bridge 回调中进行（bridge 层负责 `base::Value → JSONWriter`）
- 无 webview_id 参数（全局唯一 bookmark service）

#### 3.4 Bridge 实现结构

```cpp
// 新增全局状态（在匿名命名空间 namespace {} 内，与 g_context/g_webview 同级）
struct BookmarkState {
  mojo::Remote<owl::mojom::BookmarkService> remote;
};
base::NoDestructor<std::unique_ptr<BookmarkState>> g_bookmark_service;
```

`OWLBridge_BookmarkGetAll` 实现模式（与 Navigate 一致）：
1. `CHECK(g_initialized)` + `CHECK(*g_bookmark_service)` — 如 bookmark service 未绑定，立即 crash（同 g_webview 模式）
2. PostTask to IO thread
3. `(*g_bookmark_service)->remote->GetAll(base::BindOnce(...))`
4. Mojo 回调中：序列化 `vector<BookmarkItemPtr>` 为 JSON 字符串
5. `dispatch_async(dispatch_get_main_queue(), ^{ callback(json, nullptr, ctx); })`

**disconnect handler（Round 1 P1 fix）**：
```cpp
(*g_bookmark_service)->remote.set_disconnect_handler(base::BindOnce([]() {
  LOG(ERROR) << "[OWL] BookmarkService pipe disconnected";
  g_bookmark_service->reset();
}));
```

#### 3.5 BookmarkService 获取流程

**Round 1 P0 fix**：`GetBookmarkService()` 是异步 Mojo RPC，不能在发起后立即 dispatch main queue callback。必须等 bookmark remote 绑定完成后再通知 Swift。

修改 `OWLBridge_CreateBrowserContext` 的回调链为：

```
CreateBrowserContext callback
  → bind g_context
  → (*g_context)->remote->GetBookmarkService(...)
     → 回调中 bind g_bookmark_service + set disconnect handler
     → dispatch_async(main, cb(context_id, nil, ctx))  // 这里才通知 Swift
```

```cpp
// 在 OWLBridge_CreateBrowserContext 的 Mojo 回调中（IO thread）：
// Step 1: bind context
*g_context = std::make_unique<ContextState>();
(*g_context)->remote.Bind(std::move(context_remote));

// Step 2: 串行获取 BookmarkService，等绑定完成后才通知 Swift
(*g_context)->remote->GetBookmarkService(
    base::BindOnce([](OWLBridge_ContextCallback cb, void* ctx,
                      mojo::PendingRemote<owl::mojom::BookmarkService> service) {
      *g_bookmark_service = std::make_unique<BookmarkState>();
      (*g_bookmark_service)->remote.Bind(std::move(service));
      (*g_bookmark_service)->remote.set_disconnect_handler(
          base::BindOnce([]() {
            LOG(ERROR) << "[OWL] BookmarkService pipe disconnected";
            g_bookmark_service->reset();
          }));
      // Step 3: 现在 bookmark service 已就绪，通知 Swift
      dispatch_async(dispatch_get_main_queue(), ^{
        cb(1, nullptr, ctx);
      });
    }, cb, ctx));
```

**关键保证**：Swift 收到 `CreateBrowserContext` 成功回调时，`g_context` 和 `g_bookmark_service` 都已绑定完成。后续调用 `OWLBridge_Bookmark*` 不会 null crash。

#### 3.6 Swift 层

在 `Services/OWLBridgeSwift.swift` 或新建 `Services/BookmarkService.swift` 中添加 async/await wrappers：

```swift
enum OWLBookmarkBridge {
    struct BookmarkItem: Codable, Identifiable {
        let id: String
        let title: String
        let url: String
        let parentId: String?
        
        enum CodingKeys: String, CodingKey {
            case id, title, url
            case parentId = "parent_id"
        }
    }
    
    static func getAll() async throws -> [BookmarkItem] {
        // withCheckedThrowingContinuation + OWLBridge_BookmarkGetAll
        // 回调中 JSON → [BookmarkItem] via JSONDecoder
    }
    
    static func add(title: String, url: String, parentId: String? = nil) async throws -> BookmarkItem {
        // withCheckedThrowingContinuation + OWLBridge_BookmarkAdd
    }
    
    static func remove(id: String) async throws {
        // withCheckedThrowingContinuation + OWLBridge_BookmarkRemove
    }
    
    static func update(id: String, title: String? = nil, url: String? = nil) async throws {
        // withCheckedThrowingContinuation + OWLBridge_BookmarkUpdate
    }
}
```

### 4. 核心逻辑

#### 4.1 持久化 - LoadFromFile

```cpp
void OWLBookmarkService::LoadFromFile() {
  if (storage_path_.empty()) return;  // 纯内存模式
  
  std::string json;
  if (!base::ReadFileToString(storage_path_, &json)) return;  // 文件不存在 → 空列表
  
  auto parsed = base::JSONReader::Read(json);
  if (!parsed || !parsed->is_dict()) return;
  
  const auto* bookmarks = parsed->GetDict().FindList("bookmarks");
  if (!bookmarks) return;
  
  for (const auto& val : *bookmarks) {
    if (!val.is_dict()) continue;
    auto item = owl::mojom::BookmarkItem::New();
    const auto* id = val.GetDict().FindString("id");
    const auto* title = val.GetDict().FindString("title");
    const auto* url = val.GetDict().FindString("url");
    if (!id || !title || !url) continue;
    item->id = *id;
    item->title = *title;
    item->url = *url;
    const auto* parent = val.GetDict().FindString("parent_id");
    if (parent) item->parent_id = *parent;
    bookmarks_.push_back(std::move(item));
  }
  
  // 恢复 next_id（避免 ID 碰撞）
  auto next_id = parsed->GetDict().FindInt("next_id");
  if (next_id) next_id_ = *next_id;
}
```

#### 4.2 持久化 - SchedulePersist / PersistNow

```cpp
// Round 2 P1 fix: 用专属 SequencedTaskRunner 串行化文件 I/O，防止并发写同一 .tmp
OWLBookmarkService::OWLBookmarkService(const base::FilePath& storage_path)
    : storage_path_(storage_path),
      file_task_runner_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::BEST_EFFORT})) {}

// Round 1+2 P1 fix: 析构时同步 flush（直接写文件，不 PostTask）
OWLBookmarkService::~OWLBookmarkService() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (persist_timer_.IsRunning()) {
    persist_timer_.Stop();
    // Round 2 fix: 析构时直接同步写入，不投递 ThreadPool（避免与 in-flight task 竞争）
    std::string json = SerializeToJson();
    if (!json.empty() && !storage_path_.empty()) {
      base::FilePath tmp = storage_path_.AddExtension(FILE_PATH_LITERAL(".tmp"));
      if (base::WriteFile(tmp, json)) {
        base::Move(tmp, storage_path_);
      }
    }
  }
}

void OWLBookmarkService::SchedulePersist() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (storage_path_.empty()) return;
  persist_timer_.Stop();
  persist_timer_.Start(FROM_HERE, base::Seconds(1),
      base::BindOnce(&OWLBookmarkService::PersistNow,
                     base::Unretained(this)));
}

// 序列化为 JSON 字符串（纯内存操作，UI thread 安全）
std::string OWLBookmarkService::SerializeToJson() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  base::Value::List list;
  for (const auto& item : bookmarks_) {
    base::Value::Dict dict;
    dict.Set("id", item->id);
    dict.Set("title", item->title);
    dict.Set("url", item->url);
    if (item->parent_id.has_value())
      dict.Set("parent_id", item->parent_id.value());
    list.Append(std::move(dict));
  }
  base::Value::Dict root;
  root.Set("version", 1);
  root.Set("bookmarks", std::move(list));
  root.Set("next_id", next_id_);
  std::string json;
  base::JSONWriter::WriteWithOptions(
      root, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json);
  return json;
}

void OWLBookmarkService::PersistNow() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (storage_path_.empty()) return;
  std::string json = SerializeToJson();
  // Round 2 fix: 投递到专属 SequencedTaskRunner，串行化写入
  file_task_runner_->PostTask(FROM_HERE,
      base::BindOnce([](base::FilePath path, std::string json) {
        base::FilePath tmp = path.AddExtension(FILE_PATH_LITERAL(".tmp"));
        if (base::WriteFile(tmp, json)) {
          base::Move(tmp, path);
        }
      }, storage_path_, std::move(json)));
}
```

**持久化策略总结（Round 1+2 修复后）**：
- debounce 1s：多次修改只触发一次写入，由 `base::OneShotTimer` 管理
- I/O 在专属 SequencedTaskRunner：`PersistNow` 序列化在 UI thread，实际文件写入投递到 `file_task_runner_`（串行化，防并发写同一 `.tmp`）
- 原子替换：write-to-temp + `base::Move`（POSIX rename），防止半写文件
- 析构 flush：`~OWLBookmarkService` 直接同步写入文件（不 PostTask），避免与 in-flight task 竞争
- **LoadFromFile 调用时机**：在 `GetBookmarkService()` 被调用时（lazy create），此时处于 `OWLBridge_CreateBrowserContext` 的 Mojo 回调链内（UI thread），Swift 尚未收到 context 创建成功通知。书签文件预期 <1MB，同步读取 <10ms，不阻塞用户可见操作（可接受的 tradeoff）
- **durability 语义**：Add/Remove/Update 成功回调 = 内存中已修改。持久化是最终一致（1s 内写入）。正常退出（Destroy/析构）保证 flush；kill -9 可能丢失最后 1s 修改（可接受）
- **多 BrowserContext 约束**：当前架构为单活跃 BrowserContext（与 `g_context` 同级约束），`g_bookmark_service` 在新 `CreateBrowserContext` 时覆盖旧的，旧 BookmarkService 随旧 OWLBrowserContext 析构时 flush
- **off_the_record 隔离（Round 2 Codex P0 fix）**：`OWLBrowserContext::GetBookmarkService` 检查 `off_the_record_`——隐私模式下传空路径给 `OWLBookmarkService`（纯内存模式，不落盘）。正常模式下路径为 `{user_data_dir}/bookmarks.json`
- **LoadFromFile 校验（Round 2 Codex P1 fix）**：`LoadFromFile` 对每个加载的 entry 调用 `IsUrlAllowed` + `IsTitleValid`，跳过非法条目（不 crash、不加载到内存），防止通过损坏文件注入 `javascript:` 等非法 URL

#### 4.3 Bridge JSON 序列化

```cpp
// BookmarkItem → JSON string (in Mojo callback, on IO thread)
static std::string BookmarkItemToJson(const owl::mojom::BookmarkItemPtr& item) {
  base::Value::Dict dict;
  dict.Set("id", item->id);
  dict.Set("title", item->title);
  dict.Set("url", item->url);
  if (item->parent_id.has_value())
    dict.Set("parent_id", item->parent_id.value());
  std::string json;
  base::JSONWriter::Write(dict, &json);
  return json;
}

static std::string BookmarkListToJson(
    const std::vector<owl::mojom::BookmarkItemPtr>& items) {
  base::Value::List list;
  for (const auto& item : items) {
    base::Value::Dict dict;
    dict.Set("id", item->id);
    dict.Set("title", item->title);
    dict.Set("url", item->url);
    if (item->parent_id.has_value())
      dict.Set("parent_id", item->parent_id.value());
    list.Append(std::move(dict));
  }
  std::string json;
  base::JSONWriter::Write(list, &json);
  return json;
}
```

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/browser_context.mojom` | 修改 | +`import bookmarks.mojom`; +`GetBookmarkService()` 方法 |
| `host/owl_bookmark_service.h` | 修改 | +`base::FilePath` 构造, +`LoadFromFile`, +`SchedulePersist`, +`PersistNow`, +`persist_timer_`, +`storage_path_` |
| `host/owl_bookmark_service.cc` | 修改 | +持久化实现, Add/Remove/Update 后调用 `SchedulePersist()` |
| `host/owl_browser_context.h` | 修改 | +`OWLBookmarkService` 成员, +`GetBookmarkService()` 声明 |
| `host/owl_browser_context.cc` | 修改 | +`GetBookmarkService()` 实现（lazy create + Bind） |
| `bridge/owl_bridge_api.h` | 修改 | +4 个 C-ABI 函数声明 + 2 个 callback typedef |
| `bridge/owl_bridge_api.cc` | 修改 | +`BookmarkState` + `g_bookmark_service`, +GetBookmarkService 在 CreateBrowserContext 后调用, +4 个函数实现 |
| `owl-client-app/Services/BookmarkService.swift` | 新增 | `OWLBookmarkBridge` 的 async/await wrappers |
| `mojom/BUILD.gn` | 确认 | `browser_context.mojom` deps 包含 bookmarks mojom（已有，bookmarks.mojom 在同一 `:mojom` target） |
| `host/BUILD.gn` | 确认 | `owl_bookmark_service` 已在 `:host` source_set（已有）；新增 `base/timer` dep |
| `host/owl_bookmark_service_unittest.cc` | 修改 | +持久化测试 (LoadFromFile + PersistNow round-trip) |
| `Tests/OWLBrowserTests.swift` | 修改 | +Bookmark CRUD E2E 测试 |
| `Tests/OWLTestBridge.swift` | 修改 | +Bookmark C-ABI helpers |

### 6. 测试策略

| 测试类型 | 内容 | AC |
|---------|------|-----|
| C++ 单元测试 | 现有 8 个 CRUD 测试（保持不变） | AC-001~004 |
| C++ 单元测试 | PersistNow → LoadFromFile round-trip | AC-005, AC-006 |
| C++ 单元测试 | LoadFromFile 容错（空文件、格式错误、缺失字段） | AC-005, AC-006 |
| C++ 单元测试 | SchedulePersist debounce 行为（多次修改只写一次） | AC-005 |
| C++ 单元测试 | OWLBrowserContext::GetBookmarkService Mojo 绑定 | AC-001 |
| Swift E2E | Add → GetAll 验证 | AC-001, AC-002, AC-007 |
| Swift E2E | Add → Remove → GetAll 验证已删除 | AC-003, AC-007 |
| Swift E2E | Add → Update → GetAll 验证已更新 | AC-004, AC-007 |
| Swift E2E | Add 空 title → 返回 error | AC-001 |

### 7. 风险 & 缓解

| 风险 | 概率 | 缓解 |
|------|------|------|
| `GetBookmarkService()` Mojo 绑定失败 | 低 | Round 1 P0 fix: CreateBrowserContext 回调链串行等待 GetBookmarkService 完成后才通知 Swift |
| 文件 I/O 阻塞 UI thread | 已消除 | Round 1 P1 fix: I/O 投递到 ThreadPool {MayBlock(), BEST_EFFORT} |
| 持久化文件损坏（半写） | 已消除 | Round 1 P1 fix: write-to-temp + rename 原子替换 |
| 进程退出前丢数据 | 已消除 | Round 1 P1 fix: ~OWLBookmarkService 析构时 flush |
| 非法 URL/title 持久化 | 已消除 | Round 1 P1 fix: Add/Update 校验 scheme 白名单 + 长度限制 |
| ID 碰撞（next_id 未正确恢复） | 中 | 持久化 `next_id` 到 JSON 文件，LoadFromFile 时恢复 |
| BookmarkService Mojo pipe 断连 | 低 | Round 1 P1 fix: disconnect handler 重置 g_bookmark_service + LOG(ERROR) |
| `base::OneShotTimer` 需要 TaskRunner | 低 | Host 运行在 UI thread（有 MessageLoop），OneShotTimer 默认使用当前 SequencedTaskRunner。SEQUENCE_CHECKER 断言 |

### Round 1 评审修复记录

| 来源 | 级别 | 问题 | 修复 |
|------|------|------|------|
| Claude+Codex | P0 | GetBookmarkService 异步绑定竞态：dispatch main 在 remote 绑定前触发 | 将 dispatch_async 移入 GetBookmarkService 回调内，串行等待 |
| Claude | P1 | base::WriteFile 在 UI thread 同步 I/O 违反线程模型 | PersistNow 序列化在 UI thread，WriteJsonToFile 投递到 ThreadPool |
| Codex | P1 | 析构/Destroy 路径不 flush，debounce 1s 内退出丢数据 | ~OWLBookmarkService 检查 timer running 则同步 flush |
| Codex | P1 | base::WriteFile 非原子替换，崩溃时半写文件 | 改用 write-to-temp + base::Move (POSIX rename) |
| Codex | P1 | 无 URL scheme/长度校验，任意字符串可持久化 | 新增 IsUrlAllowed + IsTitleValid 校验 |
| Claude | P1 | g_bookmark_service Remote 无 disconnect handler | 添加 set_disconnect_handler → LOG + reset |
| Claude | P2 | g_bookmark_service 未明确放入匿名命名空间 | 注释标注与 g_context/g_webview 同一 namespace {} |
| Claude | P2 | 文件变更表遗漏 mojom/BUILD.gn | 补充 |
| Claude | P2 | 缺少 SEQUENCE_CHECKER | 添加到 OWLBookmarkService 类 |

### Round 2 评审修复记录

| 来源 | 级别 | 问题 | 修复 |
|------|------|------|------|
| Claude Q1 | P0 | 多 BrowserContext 下 g_bookmark_service 单例覆盖 | 文档约束：当前架构为单活跃 BrowserContext（与 g_context 同级），旧 bookmark service 随旧 context 析构 |
| Claude Q3 | P1 | 析构 PersistNow PostTask 与 in-flight ThreadPool task 并发写 .tmp | 析构改为直接同步写文件；正常路径用专属 SequencedTaskRunner 串行化 |
| Claude Q1/Q3 | P1 | LoadFromFile 同步 I/O 未处理 | 明确为可接受 tradeoff：书签文件 <1MB，读取在 CreateBrowserContext 回调链内，Swift 未收到通知，不阻塞用户操作 |
| Claude Q1 | P1 | disconnect handler reset 与主线程 CHECK TOCTOU | 与 g_webview 同级已知架构限制，文档说明 |
| Claude Q2 | P1 | Update optional url 校验逻辑 | 明确：Update 只对有值的参数做校验，nullopt 跳过校验 |
| Claude Q1 | P2 | lazy vs eager 创建矛盾 | 明确为 lazy create：GetBookmarkService 被调用时才构造 + LoadFromFile |
| Claude Q1 | P2 | Swift 未说明 Box 模式 | Swift wrappers 使用 Box<CheckedContinuation> 模式（参考 feedback_swift_continuation_box_pattern.md） |
| Claude Q1 | P2 | 测试未说明 ScopedTempDir | 测试策略补充：持久化测试使用 base::ScopedTempDir 隔离 |

## 状态

- [x] 技术方案评审（2 轮，Round 1: 1 P0 + 5 P1；Round 2 Claude: 1 P0 + 4 P1；Round 2 Codex: 1 P0 + 1 P1，全部已修复，最终 0 P0/P1）
- [x] 开发完成（9 文件修改/新增，~350 行）
- [x] 代码评审通过（6-agent 双波评审，3 P0 + 1 P1 修复）
- [x] 测试通过（112 C++ GTest + 6 Swift E2E，含 19+6 Phase 35 新增）
