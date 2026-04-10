# Phase 1: Host PermissionManager + 持久化

## 目标
实现 C++ 层的权限管理核心：`PermissionControllerDelegate` 和权限持久化（JSON 文件）。
完成后，Host 进程能正确处理 Chromium 的权限查询和权限决定的持久化存储。

## 范围
- 新增: `host/owl_permission_manager.h/.cc`
- 修改: `host/owl_content_browser_context.h/.cc`（返回 delegate）
- 新增: `host/owl_permission_manager_unittest.cc`

## 依赖
- 无前置依赖

## 技术要点
- 实现 `content::PermissionControllerDelegate` 的**所有**纯虚方法
- `RequestPermissionsFromCurrentDocument()`: 核心方法，携带 callback，须在 UI 线程回调
- 权限持久化: 从 `user_data_dir/permissions.json` 读写
- 内存缓存: 启动时全量加载到 `std::map<url::Origin, std::map<PermissionType, PermissionStatus>>`
- 写入策略: 权限变更后立即写入（UI 线程，单线程无并发）
- JSON 损坏恢复: 解析失败时回退到空 map（全部 ASK），记录 LOG(ERROR)

## 验收标准
- [ ] AC-P1-1: PermissionManager 能查询权限状态（默认返回 ASK）
- [ ] AC-P1-2: SetPermission 后 GetPermission 返回新状态
- [ ] AC-P1-3: 权限决定写入 JSON 文件，重启后读回
- [ ] AC-P1-4: JSON 文件损坏时不崩溃，回退到 ASK
- [ ] AC-P1-5: BrowserContext 正确返回 PermissionControllerDelegate

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过

---

## 技术方案

### 1. 架构设计

#### 1.1 类结构

```
OWLContentBrowserContext
  └── owns: OWLPermissionManager  (content::PermissionControllerDelegate)

OWLPermissionManager
  ├── owns: PermissionStore       (内存缓存 + JSON 持久化，纯 C++ 数据层)
  └── impl: content::PermissionControllerDelegate (所有纯虚方法)
```

`OWLPermissionManager` 继承 `content::PermissionControllerDelegate`，负责：
- 响应 Chromium content 层的权限查询/请求
- 维护内存缓存（启动时从 JSON 全量加载）
- 权限变更后同步写回 JSON

`OWLContentBrowserContext::GetPermissionControllerDelegate()` 从 `nullptr` 改为返回
`permission_manager_.get()`，这是 Chromium 接入 delegate 的唯一入口点。

#### 1.2 设计原则

- **单线程**：所有操作在 UI 线程（BrowserThread::UI）执行，与 Chromium content 层的线程约定一致。无需锁。
- **内存优先**：启动时全量加载到 `std::map`，查询 O(log n)，不做任何文件 I/O。
- **写后即存**：权限变更后调用 `PersistNow()`，同步序列化到磁盘（文件较小，< 100KB，无需异步）。
- **容错降级**：JSON 解析失败时清空 map（全部返回 ASK），不崩溃，记录 `LOG(ERROR)`。

#### 1.3 Phase 1 范围边界

Phase 1 **只实现** Host C++ 层，不涉及 Mojo IPC 和 Bridge。为满足此 Phase 的验收标准：

- `RequestPermissions` / `RequestPermissionsFromCurrentDocument`：**立即拒绝**（返回 `DENIED` 或已存 status）。等 Phase 2（Mojo IPC）实现弹窗后再改为异步等待用户决策。
- `SetPermission`（供 C++ GTest 直接调用，不对外暴露 Mojo）：Phase 1 专为测试 AC-P1-2/P1-3 提供的内部方法。

---

### 2. 数据模型

#### 2.1 内存表示

```cpp
// key1: origin string, e.g. "https://meet.google.com"
// key2: PermissionType (blink::PermissionType enum, int value)
// value: PermissionStatus (blink::mojom::PermissionStatus: GRANTED/DENIED/ASK)
using OriginPermissionMap =
    std::map<std::string,
             std::map<blink::PermissionType, content::PermissionStatus>>;
```

使用 `std::string` 作为 origin key（`url::Origin::Serialize()` 输出），避免跨头文件引入 `url::Origin` 依赖到数据层。

#### 2.2 JSON 格式

```json
{
  "https://meet.google.com": {
    "camera": "granted",
    "microphone": "granted"
  },
  "https://maps.google.com": {
    "geolocation": "granted"
  }
}
```

Key 使用**稳定字符串名**（不用整数枚举值，因为 `blink::PermissionType` 的数值会随 Chromium 版本变动）。
代码中维护 `string ↔ PermissionType` 双向映射表（仅 4 种，硬编码即可）。

值固定为两种字符串：`"granted"` / `"denied"`。不存 `"ask"`（ASK 是默认值，不写入 JSON）。

#### 2.3 Permission Type 映射（Phase 1 支持范围）

| 用户可见名 | blink::PermissionType | 整数值 |
|------------|----------------------|--------|
| camera     | VIDEO_CAPTURE        | 9      |
| microphone | AUDIO_CAPTURE        | 8      |
| geolocation| GEOLOCATION          | 4      |
| notifications | NOTIFICATIONS     | 3      |

其余类型（MIDI_SYSEX、CLIPBOARD_READ_WRITE 等）查询时也走同一路径，默认返回 DENIED（Phase 1 不弹窗，未存储=拒绝）。

**PermissionDescriptor → PermissionType 转换**: 所有 `GetPermissionStatus` 系列方法接收 `PermissionDescriptorPtr`，需调用 `blink::PermissionDescriptorToPermissionType()` 转换。⚠️ 该函数对未知类型会 `CHECK()` 崩溃，必须改用 `blink::MaybePermissionDescriptorToPermissionType()` (返回 `std::optional`)，未知类型返回 DENIED。

**Origin 获取**: 统一使用 `url::Origin::Serialize()`（不用已弃用的 `GURL::GetOrigin().spec()`）。

#### 2.4 读写逻辑

**加载（构造时）**

```
LoadFromFile():
  1. base::ReadFileToString(permissions_path_, &json_str)
     → 若文件不存在：直接返回（空 map，正常状态）
     → 若读取失败：LOG(ERROR)，返回（空 map）
  2. base::JSONReader::ReadAndReturnValueWithError(json_str)
     → 若解析失败：LOG(ERROR)，return（空 map，AC-P1-4）
  3. 遍历 Value::Dict:
     - 外层 key = origin string
     - 内层 key = permission type 整数字符串 → 解析为 int → 强制转换为 blink::PermissionType
     - 内层 value = "granted"/"denied"/"ask" → 转换为 PermissionStatus
     - 非法条目：LOG(WARNING) 跳过，不影响其他条目
  4. 写入 permissions_map_
```

**写入（权限变更后）**

```
PersistNow():
  1. 构建 base::Value::Dict（两层嵌套）
  2. base::JSONWriter::Write(dict, &json_str)
  3. base::WriteFile(permissions_path_, json_str)
     → 失败：LOG(ERROR)（内存状态不回滚，本次会话仍有效，AC-P1-4 容错）
```

写入在 UI 线程同步完成，文件较小（4 种权限 × 若干 origin，预期 < 10KB），P99 延迟远低于 5ms。

---

### 3. 接口设计

#### 3.1 PermissionControllerDelegate 纯虚方法实现策略

| 方法 | Phase 1 实现策略 | 说明 |
|------|----------------|------|
| `RequestPermissions()` | 查内存 map，已有 GRANTED 则返回；否则返回 **DENIED**（Phase 1 不弹窗=静默拒绝） | Phase 2 改为异步弹窗 |
| `RequestPermissionsFromCurrentDocument()` | 同上，使用 `render_frame_host->GetMainFrame()->GetLastCommittedOrigin()` 提取 origin | 嵌套 iframe 上溯 main frame origin |
| `GetPermissionStatus()` | 查内存 map，未找到返回 ASK | 同步查询，O(log n) |
| `GetPermissionResultForOriginWithoutContext()` | 同 GetPermissionStatus，包装为 `PermissionResult` | source = UNSPECIFIED |
| `GetPermissionResultForCurrentDocument()` | 从 RenderFrameHost 提取 origin，查内存 map；`should_include_device_status` 忽略（Phase 1） | |
| `GetPermissionResultForWorker()` | 从 worker_origin (GURL) 提取 origin，查内存 map | |
| `GetPermissionResultForEmbeddedRequester()` | 使用 `requesting_origin` 查内存 map（忽略 embedding_origin） | TOP_LEVEL_STORAGE_ACCESS 场景，Phase 1 简化处理 |
| `ResetPermission()` | 从 map 删除对应条目，调用 `PersistNow()` | |

非纯虚方法（`IsPermissionOverridable`、`GetExclusionAreaBoundsInScreen`）：继承基类默认实现，不 override。

#### 3.2 OWLPermissionManager 公开接口（头文件）

```cpp
namespace owl {

class OWLPermissionManager : public content::PermissionControllerDelegate {
 public:
  // |permissions_path|: 路径为空时为 memory-only 模式（测试/off-the-record）
  explicit OWLPermissionManager(const base::FilePath& permissions_path);
  ~OWLPermissionManager() override;

  OWLPermissionManager(const OWLPermissionManager&) = delete;
  OWLPermissionManager& operator=(const OWLPermissionManager&) = delete;

  // 查询权限（供 Phase 2 Mojo 层调用）
  content::PermissionStatus GetPermission(
      const url::Origin& origin,
      blink::PermissionType type) const;

  // 设置权限（供 Phase 2 Mojo 层调用，也供测试调用）
  void SetPermission(const url::Origin& origin,
                     blink::PermissionType type,
                     content::PermissionStatus status);

  // 获取所有已存储的权限（供 Phase 2 Mojo 层 GetAllPermissions 使用）
  std::vector<std::tuple<std::string, blink::PermissionType,
                          content::PermissionStatus>>
  GetAllPermissions() const;

  // 重置某 origin 的所有权限（供设置页"撤销全部"使用）
  void ResetOrigin(const url::Origin& origin);

  // content::PermissionControllerDelegate:
  void RequestPermissions(...) override;
  void RequestPermissionsFromCurrentDocument(...) override;
  content::PermissionStatus GetPermissionStatus(...) override;
  content::PermissionResult GetPermissionResultForOriginWithoutContext(...) override;
  content::PermissionResult GetPermissionResultForCurrentDocument(...) override;
  content::PermissionResult GetPermissionResultForWorker(...) override;
  content::PermissionResult GetPermissionResultForEmbeddedRequester(...) override;
  void ResetPermission(...) override;

  // 测试辅助
  size_t permission_count_for_testing() const;
  void LoadFromFileForTesting() { LoadFromFile(); }
  void PersistNowForTesting() { PersistNow(); }

 private:
  content::PermissionStatus LookupPermission(
      const std::string& origin_str,
      blink::PermissionType type) const;

  void LoadFromFile();
  void PersistNow();

  static content::PermissionStatus StatusFromString(const std::string& s);
  static std::string StatusToString(content::PermissionStatus s);

  const base::FilePath permissions_path_;

  // 内存缓存：origin string → (permission_type → status)
  // 仅存 non-ASK 条目（ASK 是默认值，不写入 JSON）
  std::map<std::string,
           std::map<blink::PermissionType, content::PermissionStatus>>
      permissions_map_;

  SEQUENCE_CHECKER(sequence_checker_);
};

}  // namespace owl
```

**关键设计决策**：

- `permissions_map_` 只存 `GRANTED` 和 `DENIED`。查不到 = ASK（默认）。JSON 也只写非 ASK 条目，保持文件紧凑。
- `GetPermission()` / `SetPermission()` 接受 `url::Origin` 而非字符串，在接口层做序列化，内部统一用字符串 key。
- Phase 1 `RequestPermissions` 的回调**必须在 UI 线程调用**。由于当前同步返回，可直接 `std::move(callback).Run(results)`，无需 PostTask。

---

### 4. 核心逻辑

#### 4.1 权限查询流程

```
Chromium JS: navigator.permissions.query({ name: 'camera' })
  → content::PermissionController::GetPermissionStatusForCurrentDocument()
  → OWLPermissionManager::GetPermissionResultForCurrentDocument()
    1. rfh->GetMainFrame()->GetLastCommittedOrigin() → origin
    2. origin.Serialize() → origin_str
    3. LookupPermission(origin_str, VIDEO_CAPTURE)
       → permissions_map_.find(origin_str) → inner_map.find(type)
       → 找到: 返回存储的 status
       → 未找到: 返回 PermissionStatus::ASK
    4. 包装为 PermissionResult{status, UNSPECIFIED}
  → 返回给 JS
```

#### 4.2 权限设置流程（Phase 2 将通过 Mojo 触发，Phase 1 供测试调用）

```
SetPermission(origin, type, status):
  1. DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_)
  2. origin_str = origin.Serialize()
  3. if status == ASK:
       permissions_map_[origin_str].erase(type)
       if permissions_map_[origin_str].empty():
         permissions_map_.erase(origin_str)
     else:
       permissions_map_[origin_str][type] = status
  4. PersistNow()  ← 立即写磁盘
```

#### 4.3 ResetPermission 流程

```
ResetPermission(permission_type, requesting_origin, embedding_origin):
  1. origin_str = requesting_origin.spec()
     （注：Chromium 传入 GURL，需转换为 url::Origin 再 Serialize，
       或直接用 requesting_origin.GetOrigin().spec()）
  2. permissions_map_[origin_str].erase(type)
  3. 清理空 map entry
  4. PersistNow()
```

#### 4.4 RequestPermissionsFromCurrentDocument 流程（Phase 1 简化）

```
RequestPermissionsFromCurrentDocument(rfh, request_desc, callback):
  1. origin = rfh->GetMainFrame()->GetLastCommittedOrigin()
  2. 对 request_desc.permissions 中每个 PermissionDescriptorPtr:
     a. type = PermissionDescriptorToPermissionType(descriptor)
     b. status = LookupPermission(origin.Serialize(), type)
     c. 构建 PermissionResult{status, UNSPECIFIED}
  3. std::move(callback).Run(results)
     ← Phase 1: 同步返回（不弹窗）
     ← Phase 2: 发 Mojo 请求后挂起 callback，等用户决策后回调
```

---

### 5. 文件变更清单

| 操作 | 文件 | 说明 |
|------|------|------|
| 新增 | `host/owl_permission_manager.h` | OWLPermissionManager 类声明 |
| 新增 | `host/owl_permission_manager.cc` | 实现（约 200 行） |
| 新增 | `host/owl_permission_manager_unittest.cc` | GTest，约 150 行 |
| 修改 | `host/owl_content_browser_context.h` | 新增 `#include` 和 `permission_manager_` 成员 |
| 修改 | `host/owl_content_browser_context.cc` | 构造时初始化 manager，`GetPermissionControllerDelegate()` 返回 `permission_manager_.get()` |
| 修改 | `BUILD.gn`（host target） | 新增 `owl_permission_manager.cc` 源文件和依赖 |

#### 5.1 BUILD.gn 依赖新增

```gn
# host target 新增 sources:
"owl_permission_manager.cc",

# host target 新增 deps:
"//content/public/browser",          # PermissionControllerDelegate, PermissionResult
"//third_party/blink/public/common/permissions",  # PermissionType, PermissionDescriptorToPermissionType
"//url",                             # url::Origin, GURL
"//base",                            # base::JSONReader, JSONWriter, FilePath, ReadFileToString
```

#### 5.2 owl_content_browser_context.h 变更

新增 include 和成员：

```cpp
// 新增 include
#include <memory>
#include "third_party/owl/host/owl_permission_manager.h"

// OWLContentBrowserContext 类内新增私有成员
std::unique_ptr<OWLPermissionManager> permission_manager_;
```

#### 5.3 owl_content_browser_context.cc 变更

```cpp
// 构造函数：初始化 PermissionManager
OWLContentBrowserContext::OWLContentBrowserContext(bool off_the_record)
    : off_the_record_(off_the_record) {
  base::PathService::Get(base::DIR_TEMP, &path_);
  path_ = path_.AppendASCII("OWLBrowserData");

  // Phase 1: 初始化 PermissionManager（off_the_record 模式传空路径）
  base::FilePath permissions_path;
  if (!off_the_record_) {
    permissions_path = path_.AppendASCII("permissions.json");
  }
  permission_manager_ =
      std::make_unique<OWLPermissionManager>(permissions_path);
}

// GetPermissionControllerDelegate 改为返回实例
content::PermissionControllerDelegate*
OWLContentBrowserContext::GetPermissionControllerDelegate() {
  return permission_manager_.get();
}
```

---

### 6. 测试策略

#### 6.1 测试文件：`host/owl_permission_manager_unittest.cc`

无需 Mojo，无需 BrowserContext，纯单元测试。使用 `base::ScopedTempDir` 管理临时文件。

**测试类结构：**

```cpp
class OWLPermissionManagerTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(temp_dir_.CreateUniqueTempDir());
    permissions_path_ = temp_dir_.GetPath().AppendASCII("permissions.json");
    manager_ = std::make_unique<OWLPermissionManager>(permissions_path_);
  }

  base::ScopedTempDir temp_dir_;
  base::FilePath permissions_path_;
  base::test::TaskEnvironment task_environment_;  // 用于 base::RunLoop（如有）
  std::unique_ptr<OWLPermissionManager> manager_;
};
```

**测试用例列表（对应 AC）：**

| 测试名 | 验收标准 | 覆盖逻辑 |
|--------|---------|---------|
| `DefaultReturnsAsk` | AC-P1-1 | 未设置的权限查询返回 ASK |
| `SetPermissionGranted` | AC-P1-1/2 | SetPermission(GRANTED) → GetPermission = GRANTED |
| `SetPermissionDenied` | AC-P1-2 | SetPermission(DENIED) → GetPermission = DENIED |
| `ResetPermission` | AC-P1-2 | SetPermission → ResetPermission → GetPermission = ASK |
| `DifferentOriginsIsolated` | AC-P1-2 | origin A 的权限不影响 origin B |
| `DifferentPermissionTypesIsolated` | AC-P1-2 | camera 权限不影响 microphone |
| `PersistAndReload` | AC-P1-3 | SetPermission → 新建 manager 从同路径加载 → 状态一致 |
| `OffTheRecordNoFile` | AC-P1-3 | 空路径 → SetPermission 不产生文件 |
| `CorruptJsonFallsBackToAsk` | AC-P1-4 | 写入非法 JSON → 加载 → 所有权限返回 ASK，不崩溃 |
| `EmptyJsonFallsBackToAsk` | AC-P1-4 | 空文件 → 加载 → 不崩溃 |
| `MultiplePermissionsPerOrigin` | AC-P1-2/3 | 同一 origin 设置多个权限类型，持久化后全部恢复 |
| `GetAllPermissionsReturnsAll` | AC-P1-1 | GetAllPermissions() 返回所有已设置的条目 |
| `ResetPermissionDeletesEntry` | AC-P1-2 | ResetPermission 后 JSON 中不再有对应条目 |
| `BrowserContextReturnsDelegate` | AC-P1-5 | OWLContentBrowserContext::GetPermissionControllerDelegate() != nullptr |

**BrowserContext 集成测试：**（追加到现有 `owl_browser_context_unittest.cc` 或独立文件）

```cpp
// AC-P1-5: BrowserContext 返回非 nullptr 的 delegate
TEST(OWLContentBrowserContextTest, PermissionDelegateNotNull) {
  OWLContentBrowserContext ctx(false);
  EXPECT_NE(ctx.GetPermissionControllerDelegate(), nullptr);
}
```

#### 6.2 不需要 Mock 的理由

`OWLPermissionManager` 不依赖 `RenderFrameHost` 进行 Get/Set（只在 RequestPermissions 中用到），因此 Phase 1 的核心路径（查询/持久化）完全可以无 mock 测试。Phase 2 测试 `RequestPermissionsFromCurrentDocument` 时再引入 `content::MockRenderFrameHost`。

---

### 7. 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| `PermissionDescriptorToPermissionType` 对未知权限 `CHECK()` 失败 | 中 | crash | 使用 `MaybePermissionDescriptorToPermissionType()`（返回 `std::optional`），未知类型返回 ASK |
| `GetLastCommittedOrigin()` 返回 opaque origin（file://、data:）| 中 | 误存权限 | `origin.opaque()` 检查，opaque origin 直接返回 ASK，不存储 |
| JSON 写入竞争（两个 tab 同时触发权限决定）| 低 | 数据丢失 | UI 线程单线程，Chromium 所有权限回调保证在 BrowserThread::UI，无需额外同步 |
| `base::WriteFile` 原子性（断电中途写入）| 极低 | JSON 损坏 | AC-P1-4 已有容错；生产级可改为写临时文件后 rename，Phase 1 暂不处理 |
| `GetPermissionControllerDelegate()` 在 `OWLContentBrowserContext` 销毁后被调用 | 低 | UAF | `permission_manager_` 是成员，随 context 一同销毁；Chromium 保证 context 销毁前所有 WebContents 已关闭 |
| 类型转换：int → blink::PermissionType 越界 | 低 | 未定义行为 | 加载 JSON 时做范围检查，超出 `[MIDI_SYSEX, NUM)` 的值跳过并记 LOG(WARNING) |
