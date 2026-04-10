# Bookmarks UI — PRD

## 1. 背景与目标

### 问题
OWL Browser 已通过 Phase 35 实现了书签服务层（C-ABI + Host 持久化），但用户无法通过 UI 操作书签。缺少可视化的收藏/管理入口，书签功能处于"后端就绪、前端缺失"的状态。

### 为什么现在做
- Phase 35 服务层已完成并测试通过，具备完整的 CRUD 能力
- 书签是浏览器基本功能，用户期望值高
- SidebarToolbar 已有书签按钮占位（空 closure），说明 UI 架构已预留扩展点

### 成功指标
- 用户可以通过地址栏星标一键收藏/取消收藏当前页面
- 用户可以在侧边栏查看所有书签并点击导航
- 书签增删操作后 UI 实时更新，无需手动刷新
- 所有 8 项验收标准通过（AC-001 至 AC-008）

## 2. 用户故事

| ID | 用户故事 | 优先级 |
|----|---------|--------|
| US-001 | As a 用户, I want 在地址栏看到星标图标, so that 我知道当前页是否已收藏 | P0 |
| US-002 | As a 用户, I want 点击空心星标添加书签, so that 我能快速收藏有价值的网页 | P0 |
| US-003 | As a 用户, I want 点击实心星标移除书签, so that 我能方便地取消不再需要的收藏 | P0 |
| US-004 | As a 用户, I want 在侧边栏切换到书签视图, so that 我能浏览所有已保存的书签 | P0 |
| US-005 | As a 用户, I want 点击书签列表中的项目导航到对应页面, so that 我能快速访问收藏的网页 | P0 |
| US-006 | As a 用户, I want 通过右键菜单或左滑删除书签, so that 我能清理不需要的收藏 | P1 |
| US-007 | As a 用户, I want 书签列表在增删后立即更新, so that 我看到的始终是最新状态 | P0 |

## 3. 功能描述

### 3.1 核心流程

```
用户浏览网页
    ↓
地址栏显示星标按钮（空心☆ / 实心★）
    ↓ 点击星标
[空心] → 调用 BookmarkAdd → 星标变实心 → 如果侧边栏书签面板打开则刷新列表
[实心] → 调用 BookmarkRemove → 星标变空心 → 如果侧边栏书签面板打开则刷新列表
    ↓
用户打开侧边栏书签面板
    ↓
显示所有书签（平铺列表）
    ↓ 点击某书签
当前标签页导航到该 URL
    ↓ 右键某书签
显示上下文菜单 → 删除
```

### 3.2 详细规则

#### 3.2.1 星标按钮

- **位置**：地址栏右侧，紧邻已有的 lock icon 区域
- **图标**：`star` / `star.fill`（SF Symbols）
- **状态判断**：每次当前标签页 URL 变化时，在本地书签列表中查找匹配项
  - 匹配：URL 完全相等（string comparison）
  - 不匹配 → 空心星；匹配 → 实心星
- **点击行为**：
  - 点击期间按钮进入 disabled 状态（防止竞态），请求完成后恢复
  - 空心 → 调用 `OWLBookmarkBridge.add(title:url:)`, title 取当前页标题（若为空则用 URL 作为 fallback），url 取当前页 URL
  - 实心 → 调用 `OWLBookmarkBridge.remove(id:)`，id 从 `currentPageBookmarkId` 获取
  - **成功**：更新 bookmarks 数组（插入/移除）。`isCurrentPageBookmarked` 和 `currentPageBookmarkId` 为 computed property，自动更新
  - **失败**：不更新本地状态，星标保持操作前的样子（无乐观更新，等请求结果再更新 UI）
- **状态触发**：以下事件触发 `bookmarkVM.updateCurrentURL(url)`：
  - 当前标签页 URL 变化（PageInfoCallback）
  - Tab 切换（切换到另一个标签页时）
  - App 启动后首个 Tab 加载完成
- **禁用状态**：当 URL 为空（如新标签页、空白页）时，星标按钮灰色不可点击

#### 3.2.2 侧边栏书签面板

- **入口**：SidebarToolbar 中已有的书签按钮（当前空 closure）
- **切换逻辑**：在 BrowserViewModel 中扩展 sidebar 模式（如 `.tabs` / `.bookmarks`）
- **列表项布局**：
  - 左侧：favicon placeholder（圆角矩形 + 域名首字母）
  - 中间：标题（主行）+ 域名（副行，灰色小字）
  - 右侧：无额外元素
- **文本溢出**：标题和域名均单行显示，超出部分尾部省略号截断（`.lineLimit(1).truncationMode(.tail)`）
- **交互**：
  - 单击 → 当前标签页导航到书签 URL
  - 右键 → contextMenu 显示"删除"选项
  - 左滑 → swipeActions 显示"删除"按钮（contextMenu 的备用路径，macOS 上 contextMenu 有已知不响应问题）
- **空状态**：列表为空时显示引导性文案"暂无书签。点击地址栏的 ☆ 即可收藏当前网页"
- **加载**：每次切换到书签面板时调用 `OWLBookmarkBridge.getAll()` 加载（开销可接受，确保数据最新）

#### 3.2.3 BookmarkViewModel

- `@MainActor class BookmarkViewModel: ObservableObject`
- 属性：
  - `@Published var bookmarks: [BookmarkItem] = []` — 全量书签列表
  - `@Published var currentURL: String?` — 当前活跃标签页的 URL（由 BrowserViewModel 在 URL 变化和 Tab 切换时写入）
  - `var currentPageBookmarkId: String?` — computed property，从 bookmarks 数组中根据 `currentURL` 查找匹配项的 id
  - `var isCurrentPageBookmarked: Bool` — computed property（`currentPageBookmarkId != nil`），驱动星标 UI。因 `bookmarks` 和 `currentURL` 均为 `@Published`，其变化自动触发 UI 刷新
- 方法：
  - `loadAll()` — 调用 C-ABI 获取全量列表，结果按添加时间倒序排列（最新在前）
  - `addCurrentPage(title:url:)` — 添加书签，成功后插入 bookmarks 数组头部
  - `removeBookmark(id:)` — 删除书签，成功后从 bookmarks 数组移除
  - `updateCurrentURL(_ url: String?)` — 更新 currentURL（由 BrowserViewModel 在 PageInfoCallback 和 Tab 切换时调用）
- 生命周期：由 BrowserViewModel 持有，随 app 生命周期存在
- **初始化**：App 启动后首个 Tab 加载完成时调用 `loadAll()` + `updateCurrentURL`，确保星标初始状态正确

#### 3.2.4 实时更新机制

- 添加书签后：插入到 `bookmarks` 数组头部。`isCurrentPageBookmarked` 和 `currentPageBookmarkId` 为 computed property，自动随 `bookmarks` 变化更新
- 删除书签后：从 `bookmarks` 数组中移除。同上，computed property 自动更新
- 不需要轮询：所有变更都由用户操作触发，操作完成后立即更新本地状态
- URL 变化时：BrowserViewModel 通过 PageInfoCallback 调用 `bookmarkVM.updateCurrentURL(url)`，computed property 自动重新计算
- Tab 切换时：BrowserViewModel 调用 `bookmarkVM.updateCurrentURL(newTab.url)`
- `loadAll()` 排序：按添加时间倒序（最新在前），与本地插入头部的顺序一致，确保关闭/重开面板后列表顺序不跳变

### 3.3 异常/边界处理

| 场景 | 处理方式 |
|------|---------|
| 添加书签失败（C-ABI 返回错误） | 星标保持空心，不更新本地状态。console log 错误信息（`os_log`） |
| 删除书签失败 | 星标保持实心，不更新本地状态。console log 错误信息 |
| URL 为空或无效 | 星标灰色禁用 |
| 书签标题为空 | 使用 URL 作为标题 fallback。列表中若标题等于 URL 则隐藏域名副行，避免重复显示 |
| 重复添加同一 URL | 服务层已处理（返回已有书签），UI 无需额外处理 |
| 快速连续点击星标 | 点击后按钮进入 disabled 状态，请求完成后恢复。无乐观更新，等待请求结果再更新 UI |
| 侧边栏书签面板未打开时添加书签 | 仅更新 bookmarks 数组（computed property 自动更新星标），下次打开面板时 loadAll 确保数据最新 |
| Tab 切换 | 调用 `updateCurrentURL(url)` 更新 currentURL，computed property 自动更新星标状态 |
| App 启动 | 首个 Tab 加载完成后调用 `loadAll()` + `updateCurrentURL(url)` 确保初始星标状态正确 |

## 4. 非功能需求

- **性能**：`isCurrentPageBookmarked` computed property 内部做本地 O(n) 查找，书签量 <10000 时性能可接受
- **线程安全**：所有 UI 操作在 MainActor，C-ABI 回调通过 `dispatch_get_main_queue` 回到主线程
- **兼容性**：macOS SwiftUI，与现有 sidebar/address bar 布局兼容

## 5. 数据模型变更

无新增数据模型。复用 Phase 35 已定义的 `BookmarkItem`（id, title, url, parent_id）。

BookmarkViewModel 为新增 ViewModel，不修改已有数据结构。

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| AddressBarView | 新增星标按钮 |
| SidebarView | 新增书签面板视图切换 |
| SidebarToolbar | 连接已有书签按钮到功能 |
| BrowserViewModel | 新增 bookmarkVM 属性、sidebar 模式切换 |
| BookmarkViewModel（新） | 书签数据管理核心 |
| BookmarkListView（新） | 书签列表 UI |
| 对现有功能的影响 | 最小化：仅在已有 View 中添加组件，不修改已有逻辑 |

## 7. 里程碑 & 优先级

### P0（必须交付）
- 星标按钮显示与切换（AC-001, AC-002, AC-003）
- 侧边栏书签面板与列表（AC-004）
- 点击书签导航（AC-005）
- 实时更新（AC-007）—— 通过 @Published 自动满足，无需轮询等额外机制
- 多标签页星标状态同步（AC-008）

### P1（应该交付）
- 右键菜单或左滑删除书签（AC-006）—— contextMenu + swipeActions 双路径，任一可用即交付

### P2（本次不做）
- 书签文件夹/层级
- 书签编辑
- 书签搜索
- 书签导入/导出
- 书签排序/拖拽
- Cmd+D 快捷键添加书签

## 8. 开放问题

| # | 问题 | 建议 | 状态 |
|---|------|------|------|
| 1 | contextMenu 在 macOS 右键不响应时怎么办？ | 同时实现 contextMenu + swipeActions 双路径，互为备用 | 已决定 |
| 2 | 是否需要添加书签的动画反馈？ | Phase 36 先不做动画，保持简洁 | 已决定 |
| 3 | 星标按钮在新标签页（空 URL）时是否显示？ | 显示但灰色禁用 | 已决定 |
| 4 | sidebar 模式切换时 tabs 面板状态是否保留？ | 使用条件渲染（if/else），tabs 面板状态随 BrowserViewModel 保持不变 | 已决定 |

## 9. 验收标准（精确定义）

| ID | 标准 | 通过判定 | 失败判定 |
|----|------|---------|---------|
| AC-001 | 地址栏显示星标按钮，当前页已收藏时显示实心星 | 导航到已收藏 URL，星标为 `star.fill`；导航到未收藏 URL，星标为 `star` | 星标状态与收藏状态不一致 |
| AC-002 | 点击空心星添加当前页到书签，星标变为实心 | 点击空心星 → 请求成功 → 星标变为 `star.fill` → bookmarks 数组包含该项 | 点击后星标未变化，或 bookmarks 数组无新增 |
| AC-003 | 点击实心星移除书签，星标变为空心 | 点击实心星 → 请求成功 → 星标变为 `star` → bookmarks 数组不含该项 | 点击后星标未变化，或 bookmarks 数组仍含该项 |
| AC-004 | 侧边栏可切换到书签视图，显示所有书签 | 点击侧边栏书签按钮 → 面板切换到书签列表 → 显示所有已保存书签 | 面板未切换，或列表为空但有书签数据 |
| AC-005 | 点击书签项在当前标签页导航到对应 URL | 单击书签项 → 当前标签页 URL 变为书签 URL | 未导航，或在新标签页打开 |
| AC-006 | 可删除书签（右键菜单或左滑删除） | 右键或左滑 → 点击删除 → 该书签从列表消失 → bookmarks 数组不含该项 | 无法触发删除操作，或删除后列表未更新 |
| AC-007 | 书签列表在增删后实时更新 | 侧边栏打开时通过星标添加书签 → 列表头部立即出现新项（下一 SwiftUI 渲染帧内）；删除同理 | 需手动刷新或重新打开面板才能看到变化 |
| AC-008 | 多标签页场景星标状态正确 | Tab A 收藏某 URL → 切到 Tab B（不同 URL）→ 星标为空心 → 切回 Tab A → 星标为实心 | Tab 切换后星标状态未更新 |
