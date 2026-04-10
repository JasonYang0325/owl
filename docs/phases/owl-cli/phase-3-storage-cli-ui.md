# Phase 3: Storage CLI 命令 + 设置页 UI

## 目标

将 Phase 2 的 StorageService 连接到 Phase 1 的 CLI 骨架，实现 `owl cookie/clear-data/storage` 命令。同时添加设置页存储管理 UI。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 新增 | `owl-client-app/CLI/Commands/CookieCommands.swift` | `owl cookie list/delete` |
| 新增 | `owl-client-app/CLI/Commands/ClearDataCommand.swift` | `owl clear-data` |
| 新增 | `owl-client-app/CLI/Commands/StorageCommands.swift` | `owl storage usage` |
| 修改 | `owl-client-app/CLI/CLIMain.swift` | 注册新子命令 |
| 修改 | `owl-client-app/Services/CLICommandRouter.swift` | 路由 storage 命令 → C-ABI |
| 新增 | `owl-client-app/ViewModels/StorageViewModel.swift` | 设置页 ViewModel |
| 新增 | `owl-client-app/Views/Settings/StoragePanel.swift` | 设置页存储面板 |

## 依赖

- Phase 1 CLI 骨架（socket IPC 就绪）
- Phase 2 StorageService（C-ABI 就绪）

## 技术方案

### 1. CLI 命令

```swift
// CookieCommands.swift
struct CookieCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cookie",
        subcommands: [List.self, Delete.self]
    )
    
    struct List: ParsableCommand {
        @Option var domain: String?
        func run() throws {
            let resp = try CLISocketClient.send(
                command: "cookie.list",
                args: domain.map { ["domain": $0] } ?? [:]
            )
            print(resp.jsonString)
        }
    }
    
    struct Delete: ParsableCommand {
        @Argument var domain: String
        func run() throws {
            let resp = try CLISocketClient.send(
                command: "cookie.delete",
                args: ["domain": domain]
            )
            print(resp.jsonString)
        }
    }
}

// ClearDataCommand.swift
struct ClearDataCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear-data")
    @Flag var cookies = false
    @Flag var cache = false
    @Flag var history = false
    @Option var since: String?  // ISO 8601 / "1h" / "7d" / Unix timestamp
    
    func run() throws {
        var mask: UInt32 = 0
        if cookies { mask |= 0x01 }
        if cache   { mask |= 0x02 }
        if history { mask |= 0x04 }
        if mask == 0 { mask = 0x01 | 0x02 | 0x04 }  // 无 flag 则全清
        
        let startTime = since.flatMap { parseTime($0) } ?? 0.0
        let resp = try CLISocketClient.send(
            command: "clear-data",
            args: ["types": mask, "start_time": startTime, "end_time": Date().timeIntervalSince1970]
        )
        print(resp.jsonString)
    }
}
```

### 2. CLICommandRouter 扩展

```swift
// 在 handle() switch 中添加
case "cookie.list":
    let domain = request.args["domain"] as? String
    // 调用 C-ABI，异步回调 → 同步等待（通过 DispatchSemaphore）
    let json = await withCheckedContinuation { cont in
        OWLBridge_StorageGetCookieDomains({ json, ctx in
            let s = json.flatMap { String(cString: $0) } ?? "[]"
            Unmanaged<CheckedContinuation<String, Never>>
                .fromOpaque(ctx!).takeRetainedValue().resume(returning: s)
        }, Unmanaged.passRetained(cont).toOpaque())
    }
    return .ok(rawJSON: json)

case "cookie.delete":
    let domain = request.args["domain"] as? String ?? ""
    let count = await withCheckedContinuation { cont in
        OWLBridge_StorageDeleteDomain(domain, { value, ctx in
            Unmanaged<CheckedContinuation<Int32, Never>>
                .fromOpaque(ctx!).takeRetainedValue().resume(returning: value)
        }, Unmanaged.passRetained(cont).toOpaque())
    }
    return .ok(data: ["deleted": count])
```

### 3. 时间解析

```swift
func parseTime(_ input: String) -> Double? {
    // 相对时间: "1h" "7d" "30m"
    if let match = input.wholeMatch(of: /(\d+)([hdm])/) {
        let value = Double(match.1)!
        let multiplier: Double = match.2 == "h" ? 3600 : match.2 == "d" ? 86400 : 60
        return Date().timeIntervalSince1970 - value * multiplier
    }
    // ISO 8601
    if let date = ISO8601DateFormatter().date(from: input) {
        return date.timeIntervalSince1970
    }
    // Unix timestamp
    return Double(input)
}
```

### 4. 设置页 StoragePanel

```swift
// StorageViewModel.swift
@MainActor
class StorageViewModel: ObservableObject {
    @Published var domains: [CookieDomainInfo] = []
    @Published var isLoading = false
    
    func loadDomains() { /* OWLBridge_StorageGetCookieDomains */ }
    func deleteDomain(_ domain: String) { /* OWLBridge_StorageDeleteDomain */ }
    func clearData(types: UInt32) { /* OWLBridge_StorageClearData */ }
}

// StoragePanel.swift
struct StoragePanel: View {
    @StateObject var viewModel = StorageViewModel()
    var body: some View {
        VStack {
            List(viewModel.domains) { domain in
                HStack {
                    Text(domain.domain)
                    Spacer()
                    Text("\(domain.count) cookies")
                    Button("Delete") { viewModel.deleteDomain(domain.domain) }
                }
            }
            Button("Clear All Browsing Data...") { /* show sheet */ }
        }
    }
}
```

### 5. 文件变更清单

| 文件 | 操作 |
|------|------|
| `CLI/Commands/CookieCommands.swift` | 新增 |
| `CLI/Commands/ClearDataCommand.swift` | 新增 |
| `CLI/Commands/StorageCommands.swift` | 新增 |
| `CLI/CLIMain.swift` | 修改（注册命令） |
| `Services/CLICommandRouter.swift` | 修改（路由 storage） |
| `ViewModels/StorageViewModel.swift` | 新增 |
| `Views/Settings/StoragePanel.swift` | 新增 |
| `Models/CLIProtocol.swift` | 修改（parseTime helper） |

### 6. 测试策略

- CLI 集成测试: 启动浏览器 → `owl cookie list` → 验证 JSON
- Swift 单元测试: parseTime 解析、StorageViewModel mock
- C-ABI 回调 → continuation 桥接的正确性

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 测试通过
