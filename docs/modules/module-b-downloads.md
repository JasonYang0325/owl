# Module B: 下载管理系统

| 属性 | 值 |
|------|-----|
| 优先级 | P0 |
| 依赖 | 无 |
| 预估规模 | ~700 行 |
| 状态 | pending |

## 目标

实现文件下载：拦截下载请求、显示进度、支持暂停/续传、管理已下载文件。

## 用户故事

As a 浏览器用户, I want 下载文件并查看下载进度, so that 我可以保存网页上的资源到本地。

## 验收标准

- AC-001: 点击下载链接触发下载，显示保存对话框或自动保存到 ~/Downloads
- AC-002: 下载过程中显示实时进度（百分比 + 速度）
- AC-003: 可暂停和恢复下载
- AC-004: 可取消下载
- AC-005: 下载完成后可通过面板打开文件或所在文件夹
- AC-006: 下载面板显示历史下载列表
- AC-007: 下载失败时显示错误信息

## 技术方案

### 层级分解

#### 1. Host C++ (`host/owl_download_manager_delegate.h/.mm`)

- 实现 `content::DownloadManagerDelegate`
- `DetermineDownloadTarget()`: 决定保存路径（默认 ~/Downloads）
- `ShouldCompleteDownload()`: 下载完成确认
- 监听 `download::DownloadItem::Observer`：状态变化 → Mojo 通知

#### 2. Mojom (`mojom/downloads.mojom`)

```
interface DownloadService {
  GetAll() => (array<DownloadItem> items);
  Pause(string download_id);
  Resume(string download_id);
  Cancel(string download_id);
  RemoveEntry(string download_id);
  OpenFile(string download_id);
  ShowInFolder(string download_id);
};

struct DownloadItem {
  string id;
  string url;
  string filename;
  string mime_type;
  int64 total_bytes;
  int64 received_bytes;
  DownloadState state;
  string? error_description;
};

enum DownloadState {
  kInProgress,
  kComplete,
  kCancelled,
  kInterrupted,
  kPaused,
};
```

Observer 回调通过 `WebViewObserver` 扩展：
```
OnDownloadUpdated(DownloadItem item);
OnDownloadCreated(DownloadItem item);
```

#### 3. Bridge C-ABI

```c
OWL_EXPORT void OWLBridge_DownloadGetAll(OWLBridge_DownloadListCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_DownloadPause(const char* download_id);
OWL_EXPORT void OWLBridge_DownloadResume(const char* download_id);
OWL_EXPORT void OWLBridge_DownloadCancel(const char* download_id);
OWL_EXPORT void OWLBridge_DownloadOpenFile(const char* download_id);
OWL_EXPORT void OWLBridge_DownloadShowInFolder(const char* download_id);
OWL_EXPORT void OWLBridge_SetDownloadCallback(OWLBridge_DownloadEventCallback cb, void* ctx);
```

#### 4. Swift ViewModel (`ViewModels/DownloadViewModel.swift`)

- `@Published var downloads: [DownloadItem]`
- `@Published var activeCount: Int`
- 进度更新节流（100ms 最小间隔）
- 完成通知（macOS `NSUserNotification`）

#### 5. SwiftUI Views

- `DownloadPanelView`: 右侧面板下载列表
- `DownloadRow`: 单条下载（文件名 + 进度条 + 速度 + 操作按钮）
- 工具栏下载图标（有活跃下载时显示 badge）

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | DownloadManagerDelegate 回调、状态转换 |
| Swift ViewModel | 进度更新、状态管理、节流 |
| E2E Pipeline | 触发下载 → 进度 → 完成/取消 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 新增 | `mojom/downloads.mojom` |
| 新增 | `host/owl_download_manager_delegate.h/.mm` |
| 修改 | `host/owl_content_browser_context.h/.cc`（返回 delegate） |
| 修改 | `mojom/web_view.mojom`（扩展 Observer） |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 新增 | `owl-client-app/ViewModels/DownloadViewModel.swift` |
| 新增 | `owl-client-app/Views/Sidebar/DownloadSidebarView.swift` |
| 新增 | `owl-client-app/Views/Sidebar/DownloadRow.swift` |
| 修改 | `owl-client-app/Views/Sidebar/SidebarToolbar.swift`（下载图标） |
