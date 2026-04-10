# OWL CLI + Cookie 存储管理 — PRD

## 1. 背景与目标

OWL Browser 当前只能通过 GUI 操作。作为 AI 浏览器，所有能力应可在终端直接调用，让 Claude Code 等 AI agent 通过 `Bash("owl ...")` 程序化控制浏览器。

**目标**: 让 OWL binary 同时支持 GUI 和 CLI 两种模式。CLI 通过 Unix socket 与运行中的 GUI 进程通信。Module D (Cookie/存储) 作为第一批 CLI 命令落地。

**成功指标**:
- 9 个 AC 全部通过
- CLI 命令响应 < 200ms（socket 往返）
- 浏览器未运行时 CLI 给出明确错误（exit code 2）
- JSON 输出可被 `jq` 解析

## 2. 用户故事

- **US-001**: As Claude Code, I want `owl cookie list` 查询 Cookie, so that 我可以自动化隐私管理
- **US-002**: As a 开发者, I want `owl navigate <url>` 控制浏览器, so that 我可以在终端调试
- **US-003**: As a 用户, I want 设置页管理存储, so that 我有图形化管理界面
- **US-004**: As Claude Code, I want `owl clear-data --cookies`, so that 我可以排障登录问题

## 3. 功能描述

### 3.1 CLI 入口

同一 binary 根据参数决定模式：
```
OWLBrowser                → GUI 模式（默认）
OWLBrowser navigate <url> → CLI 模式（有子命令时）
owl navigate <url>        → 符号链接到 OWLBrowser
```

### 3.2 IPC 协议

```
CLI 进程                    GUI 进程（Host）
   |                           |
   |-- connect /tmp/owl.sock ->|
   |-- {"cmd":"cookie.list"}-->|
   |<- {"ok":true,"data":[]}---|
   |-- close ----------------->|
   退出(exit 0)
```

- 传输: Unix domain socket, 路径 `$TMPDIR/owl-$UID.sock`（用户隔离，避免多用户冲突）
- 协议: 换行分隔 JSON (ndjson)，每条请求含 `"id": "<uuid>"` 用于并发请求/响应关联
- 版本握手: 连接后首条消息 `{"protocol":"owl-cli","version":1}`
- 超时: CLI 等待 5 秒无响应则 exit 1
- 残留清理: Host 启动时删除旧 socket 文件；Host 退出时清理

### 3.3 命令清单

#### 标签页寻址

所有命令默认操作**活动标签页**。`--tab <index>`（0-based）可全局使用：

```bash
owl page info                   # 活动标签页
owl page info --tab 2           # 第 3 个标签页
owl navigate <url>              # 在活动标签页导航
owl navigate <url> --new-tab    # 新开标签页
owl back --tab 1                # 第 2 个标签页后退
owl cookie list                 # Cookie 不区分标签页（全局）
owl clear-data --cookies        # 全局清除（不区分标签页）
```

`--tab` 适用于：page info/navigate/back/forward/reload/find。
Cookie/storage/clear-data 是全局操作，不支持 `--tab`。

#### 基础导航（验证骨架）

| 命令 | 输出 |
|------|------|
| `owl page info` | `{"title":"...","url":"...","loading":false,"tab":0}` |
| `owl navigate <url>` | `{"ok":true}` |
| `owl back` | `{"ok":true}` |
| `owl forward` | `{"ok":true}` |
| `owl reload` | `{"ok":true}` |

#### Cookie & 存储（Module D）

| 命令 | 输出 |
|------|------|
| `owl cookie list [--domain <d>]` | `[{"domain":"...","count":N}]` |
| `owl cookie delete <domain>` | `{"deleted":N}` |
| `owl clear-data [--cookies] [--cache] [--history] [--since <time>]` | `{"ok":true}` |

`--since` 支持: ISO 8601 (`2024-01-01T00:00:00Z`)、相对时间 (`1h`/`7d`/`30m`)、Unix timestamp。
| `owl storage usage` | `[{"origin":"...","bytes":N}]` |

### 3.4 错误处理

| 场景 | exit code | stderr |
|------|-----------|--------|
| 成功 | 0 | — |
| 命令错误 | 1 | 用法提示 |
| 浏览器未运行 | 2 | "OWL Browser is not running. Start it first." |
| 超时 | 3 | "Timeout waiting for response" |

## 4. 非功能需求

- **性能**: CLI 命令 < 200ms（含 socket 连接）
- **并发**: 多个 CLI 进程可同时连接
- **安全**: socket 仅本机可访问（Unix domain socket 默认行为）

## 5. 数据模型变更

### Mojom 新增 (`mojom/storage.mojom`)

```mojom
interface StorageService {
  GetCookieDomains() => (array<CookieDomain> domains);
  DeleteCookiesForDomain(string domain) => (int32 deleted_count);
  ClearBrowsingData(uint32 data_types, double start_time, double end_time) => (bool success);
  GetStorageUsage() => (array<StorageUsage> usage);
};

struct CookieDomain { string domain; int32 cookie_count; };
struct StorageUsage { string origin; int64 usage_bytes; };
```

### CLI IPC 协议（无 Mojom，纯 JSON over socket）

```json
// Request (id 必须，用于并发关联)
{"id": "a1b2c3", "cmd": "cookie.list", "args": {"domain": "example.com"}}

// Response
{"id": "a1b2c3", "ok": true, "data": [{"domain": "example.com", "count": 12}]}

// Error
{"id": "a1b2c3", "ok": false, "error": "Browser not running"}
```

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| Swift 入口 | 新增 CLI 模式判定 + ArgumentParser |
| Swift CLI/ | 新增目录：命令定义、socket client |
| Swift Host/ | 新增 socket server + 命令路由 |
| Host C++ | 新增 StorageService (StoragePartition API) |
| Mojom | 新增 storage.mojom |
| Bridge | 新增 Storage C-ABI 函数 |
| 设置页 UI | 新增存储管理面板 |

## 7. 里程碑 & 优先级

| 优先级 | 功能 |
|--------|------|
| P0 | CLI 骨架（ArgumentParser + socket IPC） |
| P0 | 基础导航命令（page info/navigate/back/forward/reload） |
| P0 | Cookie 命令（list/delete） |
| P0 | clear-data 命令 |
| P1 | storage usage 命令 |
| P1 | 设置页存储面板 UI |

## 8. 验收标准（完整定义）

| AC | 描述 | 输入 | 操作 | 预期输出 |
|----|------|------|------|---------|
| AC-001 | page info | OWL 已运行 | `owl page info` | JSON {title,url,loading} |
| AC-002 | navigate | OWL 已运行 | `owl navigate https://example.com` 然后 `owl page info` | `{"ok":true}` + 后续 page info 的 url 为 example.com |
| AC-003 | cookie list | 有 Cookie 的站点 | `owl cookie list` | JSON 域名+数量数组 |
| AC-004 | cookie delete | 指定域名有 Cookie | `owl cookie delete example.com` | `{"deleted":N}` |
| AC-005 | clear-data | 有浏览数据 | `owl clear-data --cookies` | `{"ok":true}` + 立即生效 |
| AC-006 | storage usage | 有站点数据 | `owl storage usage` | JSON origin+bytes 数组 |
| AC-007 | 设置页 UI | — | 打开设置→存储 | 显示域名列表+清除按钮 |
| AC-008 | XCUITest | — | 自动化 | 覆盖 AC-001~007 |
| AC-009 | 未运行错误 | OWL 未启动 | `owl page info` | exit 2 + 错误提示 |

## 9. 开放问题

无。技术方案参考 `docs/design/agent-api-layer.md`。
