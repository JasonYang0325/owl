# OWL Browser — CLI-first 架构设计

> OWL 既是 GUI 浏览器，也是 CLI 工具。所有浏览器能力通过 `owl <command>` 在终端直接调用。

## 核心理念

```bash
owl navigate "https://example.com"    # 导航
owl cookie list                       # 查看 Cookie
owl cookie delete example.com         # 删除 Cookie
owl history search "github"           # 搜索历史
owl screenshot                        # 截图
owl page text                         # 获取页面文本
```

Claude Code 通过 Bash tool 直接调用，零适配成本。输出为 JSON（机器可解析）或人类可读文本。

## 架构

```
终端 / Claude Code (Bash tool)
  ↓ shell 命令
owl CLI (Swift ArgumentParser, 同一 binary)
  ↓ Unix domain socket / Mojo IPC
OWL Host (已运行的 GUI 进程)
  ↓
Chromium content layer
```

### 关键设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| CLI 入口 | 同一 binary，`--cli` 模式 | 无需额外安装，`OWLBrowser --cli navigate ...` |
| IPC 方式 | Unix domain socket (`/tmp/owl.sock`) | 简单可靠，支持并发，CLI 进程秒退 |
| 输出格式 | 默认 JSON，`--human` 切换表格 | 机器/人类双模式 |
| 错误码 | 0=成功，1=错误，2=浏览器未运行 | shell 标准 |
| 符号链接 | `ln -s OWLBrowser /usr/local/bin/owl` | 短命令 |

### IPC 协议（Unix socket）

```
CLI → Host: {"command": "cookie.list", "args": {"domain": "example.com"}}
Host → CLI: {"status": "ok", "data": [{"domain": "example.com", "count": 12}]}
```

Host 侧启动 socket listener，接收 JSON 命令，路由到对应 handler，返回 JSON 结果。

## 命令体系

### 导航

```bash
owl navigate <url>              # 导航到 URL
owl back                        # 后退
owl forward                     # 前进  
owl reload                      # 重新加载
owl page info                   # 当前页面信息 {title, url, loading}
owl page text                   # 获取页面纯文本
owl page screenshot [path]      # 截图保存到文件
```

### Cookie & 存储 (Module D)

```bash
owl cookie list [--domain <d>]  # Cookie 域名列表
owl cookie delete <domain>      # 删除指定域名 Cookie
owl storage usage               # 各站点存储用量
owl clear-data [--cookies] [--cache] [--history] [--since <time>]
```

### 书签

```bash
owl bookmark add <url> [title]  # 添加书签
owl bookmark list [--query <q>] # 列出/搜索书签
owl bookmark remove <id>        # 删除书签
```

### 历史

```bash
owl history search <query>      # 搜索历史
owl history delete <url>        # 删除单条
owl history clear [--since <t>] # 清除历史
```

### 权限

```bash
owl permission get <origin> <type>           # 查询权限
owl permission set <origin> <type> <status>  # 设置权限
owl permission list [--origin <o>]           # 列出所有权限
```

### 下载

```bash
owl download list               # 下载列表
owl download pause <id>         # 暂停
owl download resume <id>        # 恢复
owl download cancel <id>        # 取消
```

### 查找

```bash
owl find <query>                # 页面内查找
owl find --stop                 # 停止查找
```

### 缩放

```bash
owl zoom [level]                # 设置/查看缩放
```

## 实施路线

### Phase 1: CLI 骨架 + IPC + Module D 命令（本次）

```
owl-client-app/
  Sources/
    CLI/
      OWLCLIMain.swift            — ArgumentParser 入口
      CLIRouter.swift             — 命令 → IPC → 结果
      Commands/
        CookieCommands.swift      — owl cookie list/delete
        ClearDataCommand.swift    — owl clear-data
        StorageCommands.swift     — owl storage usage
    Host/
      CLISocketServer.swift       — Unix socket listener (Host 侧)
      CLICommandHandler.swift     — 命令路由 → C-ABI 调用
```

新增文件 ~300 行（CLI 框架） + Module D 正常实现 ~500 行。

### Phase 2: 回填已有能力

每个命令 ~30 行 Swift（调用已有 C-ABI wrapper）：
- NavigationCommands.swift
- BookmarkCommands.swift
- HistoryCommands.swift
- PermissionCommands.swift
- DownloadCommands.swift

### Phase 3: 高级能力

- `owl page text` — EvaluateJS 获取 document.body.innerText
- `owl page screenshot` — 新增截图 C-ABI
- `owl console` — Console 消息流（Module G）
- `owl network` — 网络请求监控（Module K）

## GUI → CLI 融合

OWL Host 启动时自动监听 `/tmp/owl-{pid}.sock`。CLI 模式通过 socket 连接：

```swift
// OWLBrowser binary 入口
@main struct OWLApp {
    static func main() {
        if CommandLine.arguments.contains("--cli") || CommandLine.arguments.count > 1 {
            CLIMain.run()  // CLI 模式，执行完即退出
        } else {
            NSApplicationMain(...)  // GUI 模式
        }
    }
}
```

## Claude Code 使用示例

```
用户: 帮我清除 example.com 的 Cookie
Claude: 
  Bash("owl cookie delete example.com")
  → {"status": "ok", "deleted": 12}
  已清除 example.com 的 12 条 Cookie。

用户: 当前页面是什么？
Claude:
  Bash("owl page info")
  → {"title": "GitHub", "url": "https://github.com", "loading": false}
  当前页面是 GitHub (https://github.com)。
```
