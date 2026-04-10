# Module A: 浏览历史系统

| 属性 | 值 |
|------|-----|
| 优先级 | P0 |
| 依赖 | 无 |
| 预估规模 | ~600 行 |
| 状态 | done |

## 目标

为 OWL Browser 添加持久化浏览历史：自动记录、按日期分组查看、全文搜索、清除历史。

## 用户故事

As a 浏览器用户, I want 查看和搜索我的浏览历史, so that 我可以快速回到之前访问过的页面。

## 验收标准

- AC-001: 每次导航完成后自动记录 URL、标题、访问时间
- AC-002: 侧边栏可切换到历史视图，按日期分组显示
- AC-003: 历史列表支持关键字搜索（匹配标题和 URL）
- AC-004: 点击历史项在当前标签页导航
- AC-005: 可删除单条历史记录
- AC-006: 可一键清除所有历史（今天/最近7天/全部）
- AC-007: 地址栏输入时显示历史自动补全建议
- AC-008: 历史数据在应用重启后持久保留

## 技术方案

### 层级分解

#### 1. Mojom (`mojom/history.mojom`)

```
interface HistoryService {
  AddVisit(string url, string title) => (bool success);
  Query(string query, int32 max_results, int32 offset) => (array<HistoryEntry> entries, int32 total);
  Delete(string url) => (bool success);
  DeleteRange(mojo_base.mojom.Time start, mojo_base.mojom.Time end) => (int32 deleted_count);
  Clear() => (bool success);
};

struct HistoryEntry {
  string url;
  string title;
  mojo_base.mojom.Time last_visit_time;
  int32 visit_count;
};
```

#### 2. Host C++ (`host/owl_history_service.h/.cc`)

- SQLite 存储 (`user_data_dir/history.db`)
- 表结构: `visits(id, url, title, visit_time, visit_count)`
- URL 索引 + FTS5 全文搜索索引
- 写入去重：同一 URL 在 30s 内不重复记录
- 在 `OWLBrowserContext` 中懒创建（同 BookmarkService 模式）
- 导航完成时自动调用 AddVisit（hook `OnPageInfoChanged` 中 URL 变化）

#### 3. Bridge C-ABI (`bridge/owl_bridge_api.h`)

```c
OWL_EXPORT void OWLBridge_HistoryQuery(const char* query, int32_t max_results,
    int32_t offset, OWLBridge_HistoryQueryCallback callback, void* context);
OWL_EXPORT void OWLBridge_HistoryDelete(const char* url,
    OWLBridge_BoolCallback callback, void* context);
OWL_EXPORT void OWLBridge_HistoryDeleteRange(double start_time, double end_time,
    OWLBridge_IntCallback callback, void* context);
OWL_EXPORT void OWLBridge_HistoryClear(OWLBridge_BoolCallback callback, void* context);
```

注意：AddVisit 由 Host 内部自动触发，不需要 C-ABI 暴露。

#### 4. Swift ViewModel (`ViewModels/HistoryViewModel.swift`)

- `@Published var entries: [HistoryEntry]`
- `@Published var searchQuery: String`
- 按日期分组（今天/昨天/本周/更早）
- 分页加载（每次 50 条）
- 搜索防抖（300ms）

#### 5. SwiftUI Views

- `HistorySidebarView`: 侧边栏历史面板（复用 SidebarView 模式切换）
- `HistoryRow`: 单条历史（favicon placeholder + 标题 + URL + 时间）
- `HistoryEmptyState`: 空状态
- 地址栏自动补全：在 `AddressBarViewModel` 中集成历史查询

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | HistoryService CRUD、FTS 搜索、去重、范围删除 |
| Swift ViewModel | 分组逻辑、搜索防抖、分页 |
| E2E Pipeline | 导航后查询历史、清除验证 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 新增 | `mojom/history.mojom` |
| 新增 | `host/owl_history_service.h`, `host/owl_history_service.cc` |
| 修改 | `host/owl_browser_context.h/.cc`（添加 GetHistoryService） |
| 修改 | `host/BUILD.gn` |
| 修改 | `bridge/owl_bridge_api.h`, `bridge/owl_bridge_api.cc` |
| 新增 | `owl-client-app/ViewModels/HistoryViewModel.swift` |
| 新增 | `owl-client-app/Views/Sidebar/HistorySidebarView.swift` |
| 新增 | `owl-client-app/Views/Sidebar/HistoryRow.swift` |
| 修改 | `owl-client-app/Views/Sidebar/SidebarView.swift`（添加历史模式） |
| 修改 | `owl-client-app/ViewModels/AddressBarViewModel.swift`（自动补全） |
