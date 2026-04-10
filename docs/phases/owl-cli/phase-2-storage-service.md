# Phase 2: Host StorageService C++

## 目标

实现 Cookie/存储管理的 Host 层 + Mojom + Bridge，供 CLI 命令和 UI 共同调用。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 新增 | `mojom/storage.mojom` | StorageService 接口 |
| 新增 | `host/owl_storage_service.h/.cc` | content::StoragePartition 封装 |
| 修改 | `host/owl_browser_context.h/.cc` | 暴露 StorageService |
| 修改 | `bridge/owl_bridge_api.h/.cc` | Storage C-ABI 函数 |
| 修改 | `host/BUILD.gn` + `mojom/BUILD.gn` | 构建目标 |

## 技术方案

### 1. Mojom

```mojom
// storage.mojom
module owl.mojom;

struct CookieDomain {
  string domain;
  int32 cookie_count;
};

struct StorageUsageEntry {
  string origin;
  int64 usage_bytes;
};

interface StorageService {
  GetCookieDomains() => (array<CookieDomain> domains);
  DeleteCookiesForDomain(string domain) => (int32 deleted_count);
  ClearBrowsingData(uint32 data_types, double start_time, double end_time) => (bool success);
  GetStorageUsage() => (array<StorageUsageEntry> usage);
};
```

### 2. Host StorageService

```cpp
class OWLStorageService {
 public:
  explicit OWLStorageService(content::BrowserContext* ctx);

  void GetCookieDomains(GetCookieDomainsCallback cb);
  void DeleteCookiesForDomain(const std::string& domain, DeleteCallback cb);
  void ClearBrowsingData(uint32_t types, double start, double end, ClearCallback cb);
  void GetStorageUsage(GetUsageCallback cb);

 private:
  content::StoragePartition* partition_;  // 不持有，BrowserContext 管理
};
```

核心实现：
- `GetCookieDomains`: `partition_->GetCookieManagerForBrowserProcess()` → `GetAllCookies()` → 按 domain 聚合 count
- `DeleteCookiesForDomain`: `CookieDeletionFilter` 按 domain 匹配 → `DeleteCookies()`
- `ClearBrowsingData`: `partition_->ClearData(removal_mask, ...)` — mask 映射: kCookies=0x01→REMOVE_COOKIES, kCache=0x02→REMOVE_CACHE
- `GetStorageUsage`: `partition_->GetQuotaManager()` → `GetUsageAndQuota` 枚举所有 origin

### 3. Bridge C-ABI

```c
// 异步回调模式（与 History/Download 一致）
typedef void (*OWLBridge_CookieDomainsCallback)(
    const char* json_array, void* ctx);  // JSON: [{"domain":"...","count":N}]
typedef void (*OWLBridge_IntCallback)(int32_t value, void* ctx);
typedef void (*OWLBridge_BoolCallback)(int success, void* ctx);

OWL_EXPORT void OWLBridge_StorageGetCookieDomains(
    OWLBridge_CookieDomainsCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_StorageDeleteDomain(
    const char* domain, OWLBridge_IntCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_StorageClearData(
    uint32_t types, double start, double end,
    OWLBridge_BoolCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_StorageGetUsage(
    OWLBridge_CookieDomainsCallback cb, void* ctx);  // 复用 JSON 回调
```

设计决策：回调返回 JSON 字符串而非结构化 C 类型。原因：
1. Cookie 域名列表长度不定，C struct 数组需额外的 count+free
2. CLI 命令最终输出 JSON，减少转换层
3. 与 History 模块的 JSON 回调模式一致

### 4. CLICommandRouter 扩展

Phase 3 将在 Router 中添加 storage 命令处理，调用 Bridge C-ABI：
```swift
case "cookie.list": OWLBridge_StorageGetCookieDomains(callback, ctx)
case "cookie.delete": OWLBridge_StorageDeleteDomain(domain, callback, ctx)
case "clear-data": OWLBridge_StorageClearData(types, start, end, callback, ctx)
case "storage.usage": OWLBridge_StorageGetUsage(callback, ctx)
```

### 5. 文件变更清单

| 文件 | 操作 |
|------|------|
| `mojom/storage.mojom` | 新增 |
| `mojom/BUILD.gn` | 修改（+storage.mojom） |
| `host/owl_storage_service.h` | 新增 |
| `host/owl_storage_service.cc` | 新增 |
| `host/owl_browser_context.cc` | 修改（创建 StorageService） |
| `host/BUILD.gn` | 修改（+storage 文件） |
| `bridge/owl_bridge_api.h` | 修改（+Storage C-ABI） |
| `bridge/owl_bridge_api.cc` | 修改（+Storage 实现） |

### 6. 测试策略

- C++ GTest: GetCookieDomains/DeleteCookies/ClearData/GetUsage
- 注意：需 mock StoragePartition（Chromium 提供 `content::MockStoragePartition` 或自定义 mock）

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 测试通过
