# Phase 1: CLI 骨架 + 导航命令

## 目标

OWL binary 支持 CLI 模式。CLI 通过 Unix socket 与运行中的 GUI 进程通信。实现基础导航命令验证端到端可用。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 新增 | `owl-client-app/CLI/` | 独立 executable target 目录 |
| 新增 | `owl-client-app/CLI/CLIMain.swift` | ArgumentParser 根命令 |
| 新增 | `owl-client-app/CLI/CLISocketClient.swift` | POSIX Unix socket 客户端 |
| 新增 | `owl-client-app/CLI/Commands/*.swift` | 各子命令 |
| 新增 | `owl-client-app/Services/CLISocketServer.swift` | Host 侧 socket 服务 |
| 新增 | `owl-client-app/Services/CLICommandRouter.swift` | 命令路由（协议注入，不依赖 ViewModel） |
| 新增 | `owl-client-app/Models/CLIProtocol.swift` | Request/Response JSON 模型 |
| 修改 | `owl-client-app/Package.swift` | +OWLCLI target, +ArgumentParser 依赖 |
| 不修改 | `owl-client-app/App/` | GUI 入口不变 |

## 依赖

- 无前置 phase
- Swift ArgumentParser 包

## 技术方案

### 1. SPM 结构（独立 executable target）

CLI 是独立的 SPM target，不修改 GUI 入口：

```swift
// Package.swift 新增
.executableTarget(
    name: "OWLCLI",
    dependencies: [
        "OWLBrowserLib",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ],
    path: "CLI",
    swiftSettings: owlBridgeSwiftSettings,
    linkerSettings: owlBridgeLinkerSettings
),

// 新增依赖
.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
```

构建后 `ln -s .build/debug/OWLCLI /usr/local/bin/owl`。GUI 入口 `App/` 不变。

CLI 不依赖 ViewModel（纯 socket client），只需 `OWLBrowserLib` 中的 CLIProtocol 模型。

### 2. IPC 协议

```
请求: {"id":"<uuid>","cmd":"page.info","args":{}}
响应: {"id":"<uuid>","ok":true,"data":{"title":"...","url":"..."}}
错误: {"id":"<uuid>","ok":false,"error":"..."}
握手: 连接后 client 发 {"protocol":"owl-cli","version":1}
      server 回 {"protocol":"owl-cli","version":1,"ok":true}
```

### 3. Socket Server（Host 侧）

```swift
// CLISocketServer.swift — 在 GUI 启动时创建
class CLISocketServer {
    let socketPath: String  // $TMPDIR/owl-$UID.sock
    
    func start() {
        // 清理旧 socket → bind → listen → accept loop
        // 每个连接在独立 Task 中处理
    }
    
    func handleConnection(_ fd: Int32) async {
        // 1. 读握手 → 验证版本
        // 2. 循环: 读 JSON → 路由 → 返回 JSON
    }
}
```

Socket 路径: `NSTemporaryDirectory() + "owl-\(getuid()).sock"`（不依赖 $TMPDIR 环境变量）。

消息分帧: 每条 JSON 以 `\n` 结尾。读取时按 `\n` 分割。大消息用 4 字节长度前缀（length-prefixed）作为备选。

残留处理: Server 启动时 `unlink()` 旧 socket；Server 退出时 `atexit` 清理。

### 4. 命令路由（Host 侧，不依赖 ViewModel）

```swift
// CLICommandRouter.swift — 在 Services/ 中，通过协议注入 C-ABI
protocol BrowserControl {
    var activeWebviewId: UInt64 { get }
    func pageInfo(tab: Int?) -> PageInfoData
}

@MainActor
class CLICommandRouter {
    let browser: BrowserControl  // BrowserViewModel 实现此协议
    
    func handle(_ request: CLIRequest) -> CLIResponse {
        let wvId = browser.activeWebviewId
        switch request.cmd {
        case "page.info":
            let info = browser.pageInfo(tab: request.args["tab"] as? Int)
            return .ok(data: info)
        case "navigate":
            let url = request.args["url"] as? String ?? ""
            OWLBridge_Navigate(wvId, url, 0)
            return .ok()
        case "back":    OWLBridge_GoBack(wvId); return .ok()
        case "forward": OWLBridge_GoForward(wvId); return .ok()
        case "reload":  OWLBridge_Reload(wvId); return .ok()
        default:
            return .error("Unknown command: \(request.cmd)")
        }
    }
}
```

### 4.1 CLI 客户端 sync/async 桥接

ArgumentParser 的 `run()` 是同步的。Socket I/O 使用 POSIX API（`socket/connect/write/read`），本身是同步阻塞的，无需 async：

```swift
// CLISocketClient 使用 POSIX socket（不用 NIO/Network.framework）
func send(command: String, args: [String: Any]) throws -> CLIResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    // connect → write(handshake) → read(ack) → write(request) → read(response)
    // 全部 POSIX 同步调用，5s timeout 用 setsockopt SO_RCVTIMEO
}
```

### 5. CLI 客户端

```swift
// CLISocketClient.swift
struct CLISocketClient {
    static func send(command: String, args: [String: Any] = [:]) throws -> CLIResponse {
        let socketPath = "\(ProcessInfo.processInfo.environment["TMPDIR"]!)/owl-\(getuid()).sock"
        
        // 1. 连接 socket（失败 → exit 2 "Browser not running"）
        // 2. 发送握手
        // 3. 发送请求 JSON
        // 4. 读取响应（5s 超时 → exit 3）
        // 5. 关闭连接
    }
}
```

### 6. ArgumentParser 命令

```swift
// CLI/Commands/PageCommand.swift
struct PageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "page",
        subcommands: [Info.self]
    )
    
    struct Info: ParsableCommand {
        @Option var tab: Int?
        
        func run() throws {
            let response = try CLISocketClient.send(
                command: "page.info",
                args: tab.map { ["tab": $0] } ?? [:]
            )
            print(response.data.jsonString)
        }
    }
}

// CLI/Commands/NavigateCommand.swift  
struct NavigateCommand: ParsableCommand {
    @Argument var url: String
    @Flag var newTab = false
    @Option var tab: Int?
    
    func run() throws {
        let response = try CLISocketClient.send(
            command: "navigate",
            args: ["url": url, "new_tab": newTab, "tab": tab as Any]
        )
        print(response.data.jsonString)
    }
}
```

### 7. 文件变更清单

| 文件 | 操作 | 变更 |
|------|------|------|
| `owl-client-app/Sources/CLI/CLIMain.swift` | 新增 | ArgumentParser 根命令 |
| `owl-client-app/Sources/CLI/CLISocketClient.swift` | 新增 | Unix socket 客户端 |
| `owl-client-app/Sources/CLI/Commands/PageCommand.swift` | 新增 | `owl page info` |
| `owl-client-app/Sources/CLI/Commands/NavigateCommand.swift` | 新增 | `owl navigate` |
| `owl-client-app/Sources/CLI/Commands/NavCommands.swift` | 新增 | `owl back/forward/reload` |
| `owl-client-app/Sources/CLI/Models/CLIProtocol.swift` | 新增 | Request/Response JSON 模型 |
| `owl-client-app/Services/CLISocketServer.swift` | 新增 | Host 侧 socket 服务 |
| `owl-client-app/Services/CLICommandRouter.swift` | 新增 | 命令 → C-ABI 路由 |
| `owl-client-app/Sources/OWLBrowserApp.swift` | 修改 | 入口分流 |
| `owl-client-app/Package.swift` | 修改 | +ArgumentParser 依赖 |

### 8. 测试策略

- **集成测试**: 启动 OWL GUI → `owl page info` → 验证 JSON 输出
- **单元测试**: CLIProtocol encode/decode、命令路由 dispatch
- **错误路径**: 浏览器未运行 → exit 2；超时 → exit 3

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 测试通过
