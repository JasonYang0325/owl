# 下载管理系统 — PRD

## 1. 背景与目标

OWL Browser 当前不支持文件下载。用户点击下载链接后无任何响应，无法保存网页上的资源（PDF、图片、安装包等）到本地。文件下载是浏览器最基础的 P0 功能之一。

**目标**: 实现完整的文件下载管理功能，支持下载拦截、进度显示、暂停/续传/取消、历史管理。

**成功指标**:
- 8 个 AC 全部通过自动化测试（含 XCUITest 端到端验收）
- 下载进度更新延迟 < 200ms（节流 100ms，测量方式：Observer 回调时间戳 → SwiftUI onReceive 时间戳差值）
- 下载完成文件可正常打开、可在 Finder 中定位
- 大文件（>100MB）下载过程中 app 内存增长不超过 20MB（Chromium 流式写磁盘）

## 2. 用户故事

- **US-001**: As a 浏览器用户, I want 点击下载链接后文件自动保存到 ~/Downloads, so that 我可以保存网页上的资源到本地。
- **US-002**: As a 下载中用户, I want 看到下载进度（百分比和速度）, so that 我知道下载还需要多久。
- **US-003**: As a 下载中用户, I want 暂停和恢复下载, so that 我可以在网络拥堵时暂停、空闲时恢复。
- **US-004**: As a 下载中用户, I want 取消不需要的下载, so that 我可以释放带宽和磁盘空间。
- **US-005**: As a 下载完成用户, I want 快速打开文件或在 Finder 中显示, so that 我可以立即使用下载的文件。
- **US-006**: As a 浏览器用户, I want 查看历史下载列表, so that 我可以找到之前下载过的文件。
- **US-007**: As a 浏览器用户, I want 在下载失败时看到错误信息, so that 我知道失败原因并可以重试。
- **US-008**: As a 浏览器用户, I want 清除已完成的下载记录, so that 下载列表保持整洁。

## 验收标准（完整定义）

| AC | 描述 | 输入 | 操作 | 预期输出 |
|----|------|------|------|---------|
| AC-001 | 触发下载 | 访问含下载链接的页面 | 点击下载链接 | 文件自动保存到 ~/Downloads，工具栏下载图标显示进度指示 |
| AC-002 | 进度显示 | 下载进行中 | 打开下载面板 | 显示文件名、进度条、已下载/总大小、下载速度（如 "2.3 MB/s"） |
| AC-003 | 暂停/恢复 | 下载进行中 | 点击暂停按钮 → 点击恢复按钮 | 暂停后进度停止、速度归零；恢复后继续（若 `CanResume()==false`，恢复按钮不可用） |
| AC-004 | 取消下载 | 下载进行中 | 点击取消按钮 | 下载停止，状态显示"已取消"，临时文件被清理 |
| AC-005 | 打开/显示 | 下载完成 | 点击"打开"按钮 / 点击"在 Finder 中显示"按钮 | 系统默认应用打开文件 / Finder 打开文件所在目录并选中文件 |
| AC-006 | 历史列表 | 有多个历史下载 | 打开下载面板 | 列出所有下载历史（完成的、失败的、进行中的），按时间倒序 |
| AC-007 | 错误显示 | 下载失败（网络断开/磁盘满等） | 观察下载面板 | 显示"下载失败"状态 + 具体错误原因（如"网络连接中断"/"磁盘空间不足"） |
| AC-008 | 清除记录 | 有已完成/已取消/已失败的下载 | 点击"清除所有记录" | 已完成/已取消/已失败的记录从列表移除，进行中/已暂停的保留 |

## 3. 功能描述

### 3.1 核心流程

#### 下载触发流程
```
用户点击下载链接 / 网站触发 Content-Disposition: attachment / JS 触发 <a download>
  → Chromium content layer 创建 download::DownloadItem
  → DownloadManagerDelegate::DetermineDownloadTarget() 决定保存路径
  → Host 填充完整 DownloadTargetInfo (target_path, intermediate_path, display_name, mime_type, danger_type)
  → download::DownloadItem 开始下载
  → DownloadItem::Observer 回调状态变化
  → Host OWLDownloadManagerDelegate 将状态通知给 OWLBrowserContext
  → OWLBrowserContext 通过 DownloadObserver Mojo 接口推送给客户端
  → Bridge C-ABI 回调通知 Swift
  → DownloadViewModel 更新 UI
  → SwiftUI 工具栏图标/下载面板实时刷新
```

#### 暂停/恢复流程
```
用户点击暂停
  → Swift → Bridge C-ABI → Host
  → Host 调用 DownloadItem::Pause()
  → DownloadItem::Observer::OnDownloadUpdated()
  → 状态仍为 IN_PROGRESS，但 IsPaused() == true
  → 反向通知链更新 UI（显示"已暂停"）

用户点击恢复
  → Swift → Bridge C-ABI → Host
  → Host 检查 DownloadItem::CanResume()
  → 若可恢复: 调用 DownloadItem::Resume(true)，从断点继续
  → 若不可恢复: 恢复按钮不可用（灰显），仅显示"重新下载"按钮
    → 重新下载 = 用原 URL 创建新的 DownloadItem，原记录保持 INTERRUPTED 状态不变（保留失败原因供用户查看）
```

### 3.2 详细规则

**保存路径规则**:
- 默认保存到 `~/Downloads/`（通过 macOS Foundation `NSSearchPathForDirectoriesInDomains` 获取，兼容 sandbox）
- 文件名优先级: HTTP `Content-Disposition` header → `<a download="name">` 属性 → 最终 URL 路径末段（重定向后的最终 URL）
- 文件名清洗: 过滤路径分隔符(`/`, `\`)、空字节、控制字符；截断超过 255 字节的文件名
- 重名处理: `file.pdf` → `file (1).pdf` → `file (2).pdf`
- 不弹出"另存为"对话框（🔮 后续迭代）

**右键另存为行为**:
- 右键菜单入口由 Module E（右键上下文菜单）提供，本模块不实现右键菜单
- 当 Module E 触发"链接另存为"/"图片另存为"时，下载引擎行为与点击下载链接一致 — 自动保存到 ~/Downloads
- 不弹出文件选择对话框（🔮 后续迭代统一实现"另存为"对话框）

**进度显示规则**:
- 进度条: 已下载字节 / 总字节（如服务器未返回 Content-Length，显示不确定进度条）
- 速度: 最近 3 秒的平均速度，格式为 "X.X KB/s" / "X.X MB/s"
- 节流: 进度更新最小间隔 100ms，避免 UI 线程过载
- 大小显示: 自动选择 KB/MB/GB 单位

**下载状态机**（对齐 Chromium `download::DownloadItem` 实际 API）:
```
  IN_PROGRESS (IsPaused()=false)
       │
       ├─── Pause() ──→ IN_PROGRESS (IsPaused()=true)
       │                      │
       │                      └─── Resume(true) ──→ IN_PROGRESS (IsPaused()=false)
       │
       ├─── 正常完成 ──→ COMPLETE
       │
       ├─── Cancel(true) ──→ CANCELLED
       │
       └─── 错误 ──→ INTERRUPTED
                         │
                         └─── CanResume()? Resume(true) ──→ IN_PROGRESS
```

注意: Chromium 没有独立的 `kPaused` 状态，暂停是 `IN_PROGRESS` + `IsPaused()==true`。Mojom 层将此映射为独立的 `kPaused` 枚举值，便于 Swift 侧状态判断。

**下载面板行为**:
- 位置: 右侧面板（与书签面板类似的 sidebar 位置，同一时间只显示一个面板）
- 触发: 新下载开始时 **不自动展开面板**（避免打断用户），而是工具栏图标显示进度动画 + badge
- 手动切换: 点击工具栏下载图标切换面板开关
- 工具栏图标: 有活跃下载时显示 badge（IN_PROGRESS 且未暂停的下载数量）+ 进度环动画
- 下载完成反馈: 工具栏图标短暂高亮/弹跳动画，提示用户下载完成
- 列表排序: 按创建时间倒序，通过进度条和状态颜色区分状态（避免分组导致项目位置跳跃）
- 清除按钮: 面板顶部提供"清除所有记录"按钮，移除所有已完成/已取消/已失败记录，进行中/已暂停的保留

**下载项显示规格**:
- 文件图标: 使用 macOS `NSWorkspace.icon(forFileType:)` 获取对应文件类型系统图标
- 进行中: 文件图标 + 文件名 + 进度条 + "X.X MB / Y.Y MB" + 速度 + 暂停/取消按钮
- 已暂停: 文件图标 + 文件名 + 进度条（静止）+ "已暂停" + 恢复/取消按钮
- 已完成: 文件图标 + 文件名 + 文件大小 + "打开" / "在 Finder 中显示" 按钮
- 已取消: 文件图标 + 文件名 + "已取消"（灰色）
- 失败: 文件图标 + 文件名 + 错误信息（红色）+ 操作按钮：`CanResume()==true` → "恢复"按钮（断点续传）；`CanResume()==false` → "重新下载"按钮（创建新下载）
- 双击行为: 双击已完成的下载项 → 打开文件

**错误类型映射**（归并 Chromium `download::DownloadInterruptReason`）:
| Chromium InterruptReason 组 | 用户可见描述 |
|-----------------------------|-------------|
| NETWORK_DISCONNECTED | 网络连接中断 |
| NETWORK_TIMEOUT, NETWORK_SERVER_DOWN | 网络连接超时 |
| NETWORK_FAILED, NETWORK_INVALID_REQUEST | 网络错误 |
| SERVER_FAILED, SERVER_BAD_CONTENT | 服务器错误 |
| SERVER_NO_RANGE | 服务器不支持断点续传 |
| FILE_NO_SPACE | 磁盘空间不足 |
| FILE_ACCESS_DENIED | 没有写入权限 |
| FILE_NAME_TOO_LONG | 文件名过长 |
| FILE_VIRUS_INFECTED | 文件被安全软件阻止 |
| USER_CANCELED | 已取消 |
| USER_SHUTDOWN, CRASH | 下载被中断 |
| 其他未归类 | 下载失败 |

### 3.3 异常/边界处理

- **Content-Length 未知**: 显示不确定进度条（indeterminate），仅显示已下载大小和速度
- **重名文件**: 自动追加序号 `(1)`, `(2)` ...，不覆盖已有文件
- **磁盘空间不足**: 下载中断，显示"磁盘空间不足"错误
- **网络断开后恢复**: 下载变为 INTERRUPTED 状态。`CanResume()==true` → 显示"恢复"按钮（断点续传）；`CanResume()==false` → 显示"重新下载"按钮（创建新下载）
- **服务器不支持 Range**: `CanResume()` 返回 false，恢复按钮不可用。用户可点击"重新下载"创建新的 DownloadItem 从头开始
- **下载完成后文件被删除**: "打开"操作时检测文件是否存在，不存在则提示"文件已被移动或删除"，按钮变为不可用
- **并发下载**: 支持多个同时下载，不设人为并发上限（Chromium 内部有网络层并发控制）。所有下载立即开始，由网络层自然调度
- **批量下载拦截**: 同一页面在 2 秒内触发 > 3 个下载时，执行前 3 个，后续暂停并在下载面板顶部显示提示："此网页试图下载多个文件（已拦截 N 个）"+ "全部允许"按钮。用户点击"全部允许"后释放被拦截的下载
- **app 退出时有活跃下载**: 当前版本不支持跨 session 恢复（活跃下载丢失）。🔮 后续迭代实现 DownloadItem 序列化
- **blob: / data: URL 下载**: 正常处理，文件名从 Content-Disposition 或默认名获取。注意 blob URL 不可恢复
- **JS 触发下载**: `<a download="name">` 属性指定的文件名优先级高于 URL 推断。`window.open` 触发的下载由 Chromium 自动转为 download 处理
- **混合内容下载**: HTTPS 页面上的 HTTP 下载链接，遵循 Chromium 默认策略（可能阻止或警告），不做自定义干预
- **恶意文件名**: 路径穿越字符（`../`）、控制字符、过长文件名均需清洗（由 `DetermineDownloadTarget` 处理）

## 4. 非功能需求

- **性能**: 进度更新节流 100ms；大文件下载内存占用稳定（Chromium 流式写磁盘，不缓存全量数据）
- **安全**:
  - 下载路径通过 `NSSearchPathForDirectoriesInDomains` 获取，兼容 App Sandbox（需要 `com.apple.security.files.downloads.read-write` entitlement）
  - macOS quarantine 属性（`com.apple.quarantine` xattr）: 需技术调研 Chromium content layer 是否自动设置。若不自动设置，在文件落盘/下载完成阶段按技术方案补设。**此项为 P0 安全需求**，具体实现时机和方式在技术方案阶段确定
  - 文件名清洗: 过滤路径分隔符、空字节、控制字符，截断超长文件名
  - 混合内容下载: 遵循 Chromium 内置安全策略
  - MIME 类型与扩展名不匹配时: 依赖 Chromium 默认的 safe browsing 行为（当前未集成 Safe Browsing，后续迭代）
- **兼容性**: 实现 `content::DownloadManagerDelegate` 接口（`DetermineDownloadTarget`、`ShouldCompleteDownload`、`GetNextId` 等必要方法）
- **预估规模**: ~1100 行（C++ ~500 + Swift ~400 + Bridge/Mojom ~200）

## 5. 数据模型变更

新增 Mojom:
- `mojom/downloads.mojom` — DownloadService 接口 + DownloadItem 结构 + DownloadObserver

**持久化**: 当前版本下载列表仅在 app 生命周期内有效（in-memory）。OWL 的 `OWLContentBrowserContext` 当前未配置 Chromium 的 download history 后端，因此不依赖 Chromium 自动持久化。下载历史跨 session 持久化 → 🔮 后续迭代。

**服务归属**: 下载是 browser-context 级能力（非 per-tab），`DownloadService` 和 `DownloadObserver` 定义在独立的 `downloads.mojom` 中，通过 `BrowserContextHost` 接口暴露，**不挂在 `WebViewObserver` 上**。

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| `host/owl_content_browser_context` | `GetDownloadManagerDelegate()` 返回 OWLDownloadManagerDelegate |
| `host/owl_download_manager_delegate` | **新增**: DownloadManagerDelegate 实现 + DownloadItem::Observer |
| `host/owl_browser_context` | 新增 DownloadService Mojo 适配层，暴露给客户端 |
| `mojom/downloads.mojom` | **新增**: DownloadService + DownloadItem + DownloadObserver |
| `mojom/browser_context.mojom` | 扩展: 新增 `GetDownloadService()` 方法 |
| `bridge/owl_bridge_api.h/.cc` | 新增: 下载相关 C-ABI 函数 |
| `owl-client-app/Services/` | 新增 DownloadBridge + DownloadService Swift 层 |
| `owl-client-app/ViewModels/` | 新增 DownloadViewModel |
| `owl-client-app/Views/` | 新增 DownloadPanelView、DownloadRow |
| `owl-client-app/Views/Toolbar/` | 修改: 工具栏新增下载图标 |
| `host/BUILD.gn` | 新增源文件 |
| `bridge/BUILD.gn` | 无需修改（已有的 owl_bridge_api.cc 包含新增代码） |
| `mojom/BUILD.gn` | 新增 downloads.mojom |

## 7. 里程碑 & 优先级

| 优先级 | 功能 | 说明 |
|--------|------|------|
| P0 | AC-001 触发下载 + 自动保存 | 最基础能力，无此则模块无意义 |
| P0 | AC-002 进度显示 | 用户必须知道下载状态 |
| P0 | AC-004 取消下载 | 用户必须能终止不需要的下载 |
| P0 | AC-007 错误显示 | 用户必须知道失败原因 |
| P1 | AC-005 打开文件/Finder 显示 | 提高效率但不阻断基本使用 |
| P1 | AC-003 暂停/恢复 | 依赖服务器 Range 支持，部分场景不可用 |
| P1 | AC-006 历史列表 | 当前版本仅 in-memory，app 重启后清空 |
| P1 | AC-008 清除记录 | 依赖 AC-006 |

## 8. 开放问题

- **quarantine xattr 设置方式**: Chromium 内置 quarantine 逻辑是否在 OWL 的 content layer 配置下自动生效，还是需要手动调用 macOS API？→ 需在技术方案阶段调研确定，P0 安全需求不可跳过
- **Download history 跨 session 持久化**: 当前 `OWLContentBrowserContext` 未配置 download history 后端。是否在本期实现简单的 JSON 持久化，还是留待后续？→ 🔮 后续迭代
- **右键菜单集成**: 当前右键上下文菜单（Module E）尚未实现，"链接另存为"/"图片另存为" 的触发依赖 Module E 完成。本模块仅实现下载引擎，右键触发入口由 Module E 提供 → 明确依赖
