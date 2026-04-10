# Module D: Cookie 与存储管理

| 属性 | 值 |
|------|-----|
| 优先级 | P1 |
| 依赖 | 无 |
| 预估规模 | ~500 行 |
| 状态 | pending |

## 目标

暴露 Cookie 和站点数据管理能力：查看、删除指定站点数据、一键清除浏览数据。

## 用户故事

As a 浏览器用户, I want 管理网站存储的 Cookie 和缓存数据, so that 我可以保护隐私并解决登录问题。

## 验收标准

- AC-001: 设置页可查看所有存储 Cookie 的站点列表
- AC-002: 可删除指定站点的所有 Cookie
- AC-003: "清除浏览数据" 对话框支持选择：Cookie、缓存、历史（时间范围）
- AC-004: 清除后立即生效（无需重启）
- AC-005: 显示各站点的存储用量估算

## 技术方案

### 层级分解

#### 1. Host C++

通过 `content::StoragePartition` 访问：
- `GetCookieManagerForBrowserProcess()` → Cookie CRUD
- `GetDOMStorageContext()` → localStorage 清除
- `ClearData()` → 按类型批量清除

#### 2. Mojom (`mojom/storage.mojom`)

```
interface StorageService {
  GetCookieDomains() => (array<CookieDomain> domains);
  DeleteCookiesForDomain(string domain) => (int32 deleted_count);
  ClearBrowsingData(uint32 data_types, double start_time, double end_time) => (bool success);
  GetStorageUsage() => (array<StorageUsage> usage);
};

struct CookieDomain {
  string domain;
  int32 cookie_count;
};

struct StorageUsage {
  string origin;
  int64 usage_bytes;
};

// Bitmask for data_types
const uint32 kCookies       = 0x01;
const uint32 kCache          = 0x02;
const uint32 kLocalStorage   = 0x04;
const uint32 kSessionStorage = 0x08;
const uint32 kIndexedDB      = 0x10;
```

#### 3. Bridge C-ABI

```c
OWL_EXPORT void OWLBridge_StorageGetCookieDomains(OWLBridge_CookieDomainsCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_StorageDeleteDomain(const char* domain, OWLBridge_IntCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_StorageClearData(uint32_t types, double start, double end,
    OWLBridge_BoolCallback cb, void* ctx);
```

#### 4. Swift ViewModel (`ViewModels/StorageViewModel.swift`)

- Cookie 域名列表 + 数量
- "清除浏览数据" 选项状态

#### 5. SwiftUI Views

- 设置页 "隐私与安全" 分节中的存储管理
- `ClearDataSheet`: 清除数据确认对话框

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | CookieManager 查询/删除、ClearData 按类型 |
| Swift ViewModel | 域名列表排序、数据类型选择逻辑 |
| E2E Pipeline | 设置 cookie → 查询 → 删除 → 验证 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 新增 | `mojom/storage.mojom` |
| 新增 | `host/owl_storage_service.h/.cc` |
| 修改 | `host/owl_browser_context.h/.cc`（GetStorageService） |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 新增 | `owl-client-app/ViewModels/StorageViewModel.swift` |
| 修改 | `owl-client-app/Views/Settings/SettingsView.swift`（存储管理面板） |
