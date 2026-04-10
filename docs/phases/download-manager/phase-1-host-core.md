# Phase 1: Mojom + Host 核心

## 目标
- 实现 Chromium content layer 的下载拦截：点击下载链接后，文件自动保存到 ~/Downloads
- 定义 Mojom 接口，为后续 Bridge/Swift 层提供类型契约

## 范围

### 新增文件
- `mojom/downloads.mojom` — DownloadItem 结构、DownloadState 枚举、DownloadService 接口、DownloadObserver 接口
- `host/owl_download_manager_delegate.h/.cc` — 实现 `content::DownloadManagerDelegate` + `download::DownloadItem::Observer`

### 修改文件
- `mojom/BUILD.gn` — 添加 downloads.mojom
- `host/BUILD.gn` — 添加新源文件
- `host/owl_content_browser_context.h/.cc` — `GetDownloadManagerDelegate()` 返回新 delegate
- `mojom/browser_context.mojom` — 添加 `GetDownloadService()` 方法

## 依赖
- 无前置 phase
- 外部依赖: `content::DownloadManagerDelegate`, `download::DownloadItem`, `components/download/public/common/`

## 技术要点

1. **DetermineDownloadTarget()**: 必须填充完整 `DownloadTargetInfo`（target_path, intermediate_path, display_name, mime_type, danger_type）
2. **保存路径**: 使用 `base::apple::GetUserDirectory(NSDownloadsDirectory)` 获取 ~/Downloads
3. **重名处理**: 使用 `base::GetUniquePathNumber()` 或手动追加 `(N)` 后缀
4. **文件名清洗**: 过滤 `/`, `\`, `\0`，截断超过 255 字节
5. **quarantine xattr**: 调研 Chromium 是否自动设置。若不自动，在 `ShouldCompleteDownload` 回调中手动调用 macOS API
6. **DownloadItem::Observer**: 监听 `OnDownloadUpdated()` 和 `OnDownloadDestroyed()` 回调
7. **线程模型**: Delegate 回调在 UI 线程，文件路径操作在 FILE 线程

## 验收标准
- [ ] `downloads.mojom` 编译通过，生成 C++ 绑定
- [ ] `OWLDownloadManagerDelegate` 正确拦截下载请求
- [ ] 文件保存到 ~/Downloads，重名自动追加序号
- [ ] DownloadItem::Observer 收到状态变化回调
- [ ] C++ 单元测试: delegate 回调、状态转换、文件名清洗

## 技术方案

### 1. 架构设计

```
content::DownloadManager (Chromium 内置)
  ├── Observer: OWLDownloadManagerDelegate (捕获所有新建下载)
  └── Delegate: OWLDownloadManagerDelegate
        ├── DetermineDownloadTarget() → 异步计算保存路径
        ├── GetNextId() → 生成下载 ID
        └── ShouldCompleteDownload() → 允许完成 + quarantine 设置
                ↓ 通知
OWLDownloadService (业务层，独立于 Delegate)
  ├── GetAll / Pause / Resume / Cancel / Open / Show / Remove
  ├── 维护 DownloadItem::Observer per-item
  └── 通过 change_callback 通知 OWLBrowserContext
                ↓
OWLBrowserContext → DownloadServiceMojoAdapter → Mojo pipe → Bridge (Phase 2)
```

**类职责分离**（遵循 OWL 模式：HistoryService/BookmarkService 与 Chromium delegate 分离）:
- `OWLDownloadManagerDelegate`: 仅实现 `content::DownloadManagerDelegate` + `content::DownloadManager::Observer` 的 Chromium 回调
- `OWLDownloadService`: 业务层（查询/操作/通知），参考 `OWLHistoryService` 模式

**数据流**:
1. 用户点击下载链接 → Chromium 创建 DownloadItem
2. `DownloadManager::Observer::OnDownloadCreated()` → Delegate 将 item 注册到 Service
3. `DetermineDownloadTarget()` → 异步 PostTask 到 FILE 线程计算路径 → 回调 UI 线程
4. Chromium 开始下载 → Service 的 per-item Observer 收到 `OnDownloadUpdated()` 
5. Service 通过 change_callback 通知 OWLBrowserContext → Mojo → Bridge → Swift

### 2. Mojom 数据模型

```mojom
// mojom/downloads.mojom
module owl.mojom;

enum DownloadState {
  kInProgress,
  kPaused,       // 映射自 IN_PROGRESS + IsPaused()
  kComplete,
  kCancelled,
  kInterrupted,
};

struct DownloadItem {
  uint32 id;                    // DownloadItem::GetId()
  string url;
  string filename;              // 最终文件名（不含路径）
  string mime_type;
  int64 total_bytes;            // -1 表示未知
  int64 received_bytes;
  int64 speed_bytes_per_sec;    // DownloadItem::CurrentSpeed()
  DownloadState state;
  string? error_description;    // 仅 kInterrupted 时非 null
  bool can_resume;
  string target_path;           // 完整保存路径
};

interface DownloadService {
  GetAll() => (array<DownloadItem> items);
  Pause(uint32 download_id);
  Resume(uint32 download_id);
  Cancel(uint32 download_id);
  RemoveEntry(uint32 download_id);
  OpenFile(uint32 download_id);       // Phase 1 实现为 NOTIMPLEMENTED()
  ShowInFolder(uint32 download_id);   // Phase 1 实现为 NOTIMPLEMENTED()
};

interface DownloadObserver {
  OnDownloadCreated(DownloadItem item);
  OnDownloadUpdated(DownloadItem item);
  OnDownloadRemoved(uint32 download_id);
};
```

### 3. 核心类设计

```cpp
// host/owl_download_manager_delegate.h
// 职责: 仅实现 Chromium delegate 回调 + DownloadManager::Observer

class OWLDownloadManagerDelegate 
    : public content::DownloadManagerDelegate,
      public content::DownloadManager::Observer {
 public:
  OWLDownloadManagerDelegate();
  ~OWLDownloadManagerDelegate() override;

  // DownloadManagerDelegate
  void GetNextId(DownloadIdCallback callback) override;
  bool DetermineDownloadTarget(
      download::DownloadItem* item,
      download::DownloadTargetCallback* callback) override;
  bool ShouldCompleteDownload(
      download::DownloadItem* item,
      base::OnceClosure complete_callback) override;
  void GetSaveDir(content::BrowserContext* context,
                  base::FilePath* website_save_dir,
                  base::FilePath* download_save_dir) override;

  // DownloadManager::Observer
  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override;
  void ManagerGoingDown(content::DownloadManager* manager) override;

  void Shutdown();
  void SetDownloadManager(content::DownloadManager* manager);

  // 供 OWLDownloadService 使用
  content::DownloadManager* download_manager() { return download_manager_; }
  void SetDownloadService(OWLDownloadService* service);

 private:
  // 异步路径计算
  static base::FilePath ComputeTargetPathOnFileThread(
      const GURL& url,
      const std::string& content_disposition,
      const std::string& suggested_filename,
      const std::string& mime_type,
      const base::FilePath& download_dir);

  uint32_t next_id_ = 1;
  raw_ptr<content::DownloadManager> download_manager_ = nullptr;
  raw_ptr<OWLDownloadService> download_service_ = nullptr;
  scoped_refptr<base::SequencedTaskRunner> file_task_runner_;
  // 构造函数中初始化:
  // file_task_runner_ = base::ThreadPool::CreateSequencedTaskRunner(
  //     {base::MayBlock(), base::TaskPriority::USER_VISIBLE});

  SEQUENCE_CHECKER(ui_sequence_checker_);
};
```

```cpp
// host/owl_download_service.h
// 职责: 业务层 — 查询/操作/通知（参考 OWLHistoryService 模式）

class OWLDownloadService : public download::DownloadItem::Observer {
 public:
  explicit OWLDownloadService(OWLDownloadManagerDelegate* delegate);
  ~OWLDownloadService() override;

  void Shutdown();

  // 查询
  std::vector<download::DownloadItem*> GetAllDownloads();
  download::DownloadItem* FindById(uint32_t id);

  // 操作
  void PauseDownload(uint32_t id);
  void ResumeDownload(uint32_t id);
  void CancelDownload(uint32_t id);
  void RemoveEntry(uint32_t id);
  void OpenFile(uint32_t id);       // NOTIMPLEMENTED in Phase 1
  void ShowInFolder(uint32_t id);   // NOTIMPLEMENTED in Phase 1

  // 新下载注册（由 delegate 的 OnDownloadCreated 调用）
  void OnNewDownload(download::DownloadItem* item);

  // Observer 回调（桥接到 OWLBrowserContext）
  using DownloadChangedCallback = 
      base::RepeatingCallback<void(download::DownloadItem*, bool /*created*/)>;
  void SetChangedCallback(DownloadChangedCallback callback);

  // download::DownloadItem::Observer
  void OnDownloadUpdated(download::DownloadItem* item) override;
  void OnDownloadDestroyed(download::DownloadItem* item) override;

 private:
  raw_ptr<OWLDownloadManagerDelegate> delegate_;
  DownloadChangedCallback changed_callback_;
  std::set<raw_ptr<download::DownloadItem>> observed_items_;

  SEQUENCE_CHECKER(ui_sequence_checker_);
};
```

### 4. 核心逻辑

**DetermineDownloadTarget()**: 异步路径决策
```cpp
bool OWLDownloadManagerDelegate::DetermineDownloadTarget(
    download::DownloadItem* item,
    download::DownloadTargetCallback* callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);

  // 获取下载目录
  base::FilePath download_dir;
  GetSaveDir(nullptr, nullptr, &download_dir);

  // 异步计算路径（避免 UI 线程阻塞 I/O）
  auto cb = std::move(*callback);
  file_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&ComputeTargetPathOnFileThread,
                     item->GetURL(),
                     item->GetContentDisposition(),
                     item->GetSuggestedFilename(),
                     item->GetMimeType(),
                     download_dir),
      base::BindOnce([](download::DownloadTargetCallback callback,
                        base::FilePath target_path) {
        download::DownloadTargetInfo info;
        info.target_path = target_path;
        info.intermediate_path = target_path.AddExtensionASCII("crdownload");
        info.danger_type = download::DOWNLOAD_DANGER_TYPE_NOT_DANGEROUS;
        info.target_disposition =
            download::DownloadItem::TARGET_DISPOSITION_OVERWRITE;
        info.interrupt_reason = download::DOWNLOAD_INTERRUPT_REASON_NONE;
        info.insecure_download_status =
            download::DownloadItem::InsecureDownloadStatus::SAFE;
        std::move(callback).Run(std::move(info));
      }, std::move(cb)));
  return true;
}
```

**ComputeTargetPathOnFileThread()**: FILE 线程计算路径（Chromium API 复用）
```cpp
// static
base::FilePath OWLDownloadManagerDelegate::ComputeTargetPathOnFileThread(
    const GURL& url,
    const std::string& content_disposition,
    const std::string& suggested_filename,
    const std::string& mime_type,
    const base::FilePath& download_dir) {
  // 使用 Chromium 的 net::GenerateFileName() 处理文件名
  // 自动解析 Content-Disposition、URL、MIME、默认名
  base::FilePath generated = net::GenerateFileName(
      url, content_disposition, /*referrer_charset=*/std::string(),
      suggested_filename, mime_type, /*default_name=*/"download");

  base::FilePath target_path = download_dir.Append(generated.BaseName());

  // 使用 base::GetUniquePath() 原子化去重（避免 TOCTOU 竞态）
  return base::GetUniquePath(target_path);
}
```

**GetSaveDir()**: macOS ~/Downloads（使用系统 API）
```cpp
void OWLDownloadManagerDelegate::GetSaveDir(
    content::BrowserContext* context,
    base::FilePath* website_save_dir,
    base::FilePath* download_save_dir) {
  if (download_save_dir) {
    // 使用 Chromium 封装的 macOS API（.cc 中可调用，无需 ObjC）
    base::apple::GetUserDirectory(NSDownloadsDirectory, download_save_dir);
  }
}
```

**quarantine 处理**: 通过 `GetQuarantineConnectionCallback()` 接入
```cpp
// 在 OWLDownloadManagerDelegate 中实现（如果 Chromium 未自动设置）：
download::QuarantineConnectionCallback
OWLDownloadManagerDelegate::GetQuarantineConnectionCallback() override {
  // macOS 上 Chromium 默认使用 quarantine service，
  // 但 OWL 作为 content layer embedder 可能未配置。
  // 若调研发现未自动设置，在此处返回自定义 callback
  // 调用 @import QuartzCore; 的 quarantine API。
  // 当前先返回空 callback，Phase 1 集成测试验证行为。
  return {};
}
```

**OnDownloadCreated()**: 统一捕获新下载
```cpp
void OWLDownloadManagerDelegate::OnDownloadCreated(
    content::DownloadManager* manager,
    download::DownloadItem* item) {
  // 通知 OWLDownloadService 注册 per-item observer
  if (download_service_) {
    download_service_->OnNewDownload(item);
  }
}
```

**OWLDownloadService 操作方法**:
```cpp
void OWLDownloadService::OnNewDownload(download::DownloadItem* item) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(ui_sequence_checker_);
  item->AddObserver(this);
  observed_items_.insert(item);
  if (changed_callback_) {
    changed_callback_.Run(item, /*created=*/true);
  }
}

void OWLDownloadService::OnDownloadUpdated(download::DownloadItem* item) {
  if (changed_callback_) {
    changed_callback_.Run(item, /*created=*/false);
  }
}

void OWLDownloadService::OnDownloadDestroyed(download::DownloadItem* item) {
  uint32_t id = item->GetId();
  item->RemoveObserver(this);
  observed_items_.erase(item);
  // 通知上层移除（通过 removed_callback）
  if (removed_callback_) {
    removed_callback_.Run(id);
  }
}

// removed_callback_ 类型:
// base::RepeatingCallback<void(uint32_t)> removed_callback_;
// 在 OWLBrowserContext 中注册，触发 DownloadObserver::OnDownloadRemoved()

void OWLDownloadService::Shutdown() {
  for (auto* item : observed_items_) {
    item->RemoveObserver(this);
  }
  observed_items_.clear();
}
```

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/downloads.mojom` | 新增 | DownloadItem struct, DownloadState enum, DownloadService, DownloadObserver |
| `mojom/BUILD.gn` | 修改 | 添加 "downloads.mojom" 到 sources |
| `mojom/browser_context.mojom` | 修改 | 添加 GetDownloadService() + SetDownloadObserver() |
| `host/owl_download_manager_delegate.h/.cc` | 新增 | DownloadManagerDelegate + DownloadManager::Observer |
| `host/owl_download_service.h/.cc` | 新增 | 业务层服务（查询/操作/per-item Observer） |
| `host/BUILD.gn` | 修改 | 新源文件 + deps: //components/download/public/common, //net |
| `host/owl_content_browser_context.h/.cc` | 修改 | GetDownloadManagerDelegate() 返回实例 |
| `host/owl_browser_context.h/.cc` | 修改 | 新增 download_service_ + DownloadServiceMojoAdapter |

### 6. 测试策略

**单元测试** (`host/owl_download_service_unittest.cc`):
- `ComputeTargetPath_UsesGenerateFileName` — 验证 net::GenerateFileName 正确解析 Content-Disposition
- `ComputeTargetPath_UniquePathOnConflict` — 验证 base::GetUniquePath 去重
- `OnNewDownload_RegistersObserver` — 验证 observer 注册
- `OnDownloadDestroyed_RemovesObserver` — 验证 observer 清理
- `Shutdown_RemovesAllObservers` — 验证 shutdown 清理
- `PauseResumeCancelDownload` — 验证操作方法调用 DownloadItem API
- `GetAllDownloads_ReturnsCorrectList`

**集成验证**: 编译通过 + 启动 OWL 后点击下载链接，文件保存到 ~/Downloads

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| quarantine xattr | Phase 1 明确降级：实现 `GetQuarantineConnectionCallback()` 空返回，集成测试验证 Chromium 是否自动设置 xattr。**若集成测试发现 xattr 缺失，Phase 2 开始前必须先补充 quarantine 逻辑**，不可进入后续 phase |
| `net::GenerateFileName` 依赖链 | 需在 BUILD.gn 添加 `//net` 依赖 |
| DownloadManager 指针生命周期 | `ManagerGoingDown()` + `Shutdown()` 中清空指针、移除 observer |
| 多个 tab 同时触发下载 | Delegate 是 browser-context 级单例，SEQUENCE_CHECKER 保证单序列 |
| 并发下载同名文件 TOCTOU | `base::GetUniquePath()` 在 FILE 线程预选候选路径，但两个并发下载可能拿到同一路径。Phase 1 可接受此限制（与 content_shell 行为一致），后续可通过内存锁串行化解决 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
