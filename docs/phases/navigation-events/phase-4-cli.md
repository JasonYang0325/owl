# Phase 4: CLI 导航命令

## 目标
- 实现 `owl nav status` 查询当前导航状态
- 实现 `owl nav events [--limit N]` 查询事件历史
- 扩展 CLI 路由和 BrowserControl 协议

## 范围

### 新增文件
| 文件 | 内容 |
|------|------|
| `owl-client-app/CLI/Commands/NavStatusCommand.swift` | nav status + nav events 子命令 |

### 修改文件
| 文件 | 变更 |
|------|------|
| `owl-client-app/CLI/CLIMain.swift` | 注册 NavCommand 子命令组 |
| `owl-client-app/Services/CLICommandRouter.swift` | 新增 nav.status / nav.events 路由 |
| `owl-client-app/Services/BrowserControl.swift` | 协议扩展 navStatus() / navEvents(limit:) |
| `owl-client-app/Models/NavigationEvent.swift` | 确保 NavigationEventRing 已实现（Phase 2 创建） |

## 依赖
- Phase 2（TabViewModel.loadingProgress/navigationError + NavigationEventRing）

## 技术要点

### CLI 命令结构
```swift
struct NavCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nav",
        subcommands: [StatusCommand.self, EventsCommand.self]
    )
}

struct StatusCommand: ParsableCommand {
    // owl nav status [--tab N]
    // 输出: { "state": "loading"|"error"|"idle", "progress": 0.6, "url": "...", "navigation_id": 123 }
}

struct EventsCommand: ParsableCommand {
    @Option var limit: Int = 20  // 最大 100
    // owl nav events --limit 5
    // 输出: JSON 数组
}
```

### Socket 消息
```json
// Request: nav.status
{ "cmd": "nav.status" }
// Response:
{ "state": "loading", "progress": 0.6, "url": "https://...", "navigation_id": 123 }

// Request: nav.events
{ "cmd": "nav.events", "data": { "limit": "20" } }
// Response:
{ "events": [
    { "navigation_id": 123, "event_type": "started", "url": "...", "timestamp": "..." },
    ...
] }
```

### NavigationEventRing
- 环形缓冲区，容量 100 条，FIFO
- 全局共享（单 tab 架构）
- 每条: navigation_id, event_type, url, timestamp, http_status?, error_code?
- timestamp 由 Swift 层 Date() 生成

### 已知陷阱
- CLI 协议是 request/response 模型，nav.events 返回 JSON 数组需序列化
- limit 参数 clamp 到 [1, 100] 范围
- 无活跃 tab 时 nav.status 返回 `{ "state": "idle" }`

## 验收标准
- [ ] `owl nav status` 返回正确的 JSON（loading/error/idle + progress + url）
- [ ] `owl nav events` 返回最近导航事件 JSON 数组
- [ ] `owl nav events --limit 5` 限制返回条数
- [ ] 事件包含 navigation_id, event_type, url, timestamp
- [ ] 重定向事件 event_type 为 "redirected"
- [ ] build_all.sh 编译通过

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
