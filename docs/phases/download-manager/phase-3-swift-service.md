# Phase 3: Swift 服务层 + ViewModel

## 目标
- 提供 Swift async/await 接口包装 C-ABI 函数
- 实现 DownloadViewModel，管理下载列表状态和进度更新

## 范围

### 新增文件
- `owl-client-app/Services/DownloadService.swift` — async/await 包装 C-ABI
- `owl-client-app/Services/DownloadBridge.swift` — 全局推送回调注册
- `owl-client-app/ViewModels/DownloadViewModel.swift` — 下载列表 ViewModel
- `owl-client-app/Models/DownloadItem.swift` — 数据模型

### 修改文件
- `owl-client-app/ViewModels/BrowserViewModel.swift` — 添加 downloadVM 属性

## 依赖
- Phase 2（C-ABI 函数已实现）

## 技术要点

1. **DownloadService.swift**: 沿用 HistoryService 的 Box/CheckedContinuation 模式
2. **DownloadBridge.swift**: 全局单例注册 C 回调，转发给 DownloadViewModel
3. **DownloadViewModel**:
   - `@Published items: [DownloadItemVM]`
   - `@Published activeCount: Int`（IN_PROGRESS 且未暂停的数量）
   - 进度更新节流: 100ms 最小间隔（`Task.sleep(nanoseconds:)` 或 `Combine debounce`）
4. **DownloadItemVM**: 独立 ObservableObject
   - `@Published progress: Double`
   - `@Published state: DownloadState`
   - `@Published receivedBytes: Int64`
   - `@Published totalBytes: Int64`
   - `@Published speed: String`（计算属性，基于最近 3 秒平均）
   - `@Published errorDescription: String?`
   - `@Published canResume: Bool`
5. **DownloadState 枚举**: inProgress, paused, complete, cancelled, interrupted
6. **速度计算**: 维护最近 3 秒的 (timestamp, bytes) 环形缓冲区

## 验收标准
- [ ] DownloadService async/await 调用成功
- [ ] DownloadBridge 推送回调到 ViewModel
- [ ] DownloadViewModel 正确维护下载列表
- [ ] activeCount 准确反映活跃下载数
- [ ] 进度更新 100ms 节流生效
- [ ] 速度计算准确
- [ ] Swift 单元测试

## 技术方案

### 1. 架构设计

```
C-ABI (bridge/owl_bridge_api.h)
  ↓ CheckedContinuation + Box
OWLDownloadBridge (Services/DownloadService.swift)
  ├── getAll() async throws → [DownloadItem]
  ├── pause/resume/cancel/remove/openFile/showInFolder(id:)
  └── 静态方法，无状态
  ↓
DownloadBridge (Services/DownloadBridge.swift)
  ├── singleton, 注册 C-ABI 推送回调
  └── 转发到 DownloadViewModel
  ↓
DownloadViewModel (ViewModels/DownloadViewModel.swift)
  ├── @Published items: [DownloadItemVM]
  ├── @Published activeCount: Int
  └── 100ms 节流 + 速度计算
  ↓
BrowserViewModel.downloadVM (注入点)
```

### 2. 数据模型

```swift
// Models/DownloadItem.swift
package enum DownloadState: Int, Codable {
    case inProgress = 0
    case paused = 1
    case complete = 2
    case cancelled = 3
    case interrupted = 4
}

package struct DownloadItem: Codable, Identifiable {
    package var id: UInt32
    package let url: String
    package let filename: String
    package let mimeType: String
    package var totalBytes: Int64
    package var receivedBytes: Int64
    package var speedBytesPerSec: Int64
    package var state: DownloadState
    package var errorDescription: String?
    package var canResume: Bool
    package let targetPath: String

    // JSON key 映射（C-ABI 使用 snake_case）
    enum CodingKeys: String, CodingKey {
        case id, url, filename
        case mimeType = "mime_type"
        case totalBytes = "total_bytes"
        case receivedBytes = "received_bytes"
        case speedBytesPerSec = "speed_bytes_per_sec"
        case state
        case errorDescription = "error_description"
        case canResume = "can_resume"
        case targetPath = "target_path"
    }
}
```

### 3. Service 层 — C-ABI 包装

```swift
// Services/DownloadService.swift
#if canImport(OWLBridge)
enum OWLDownloadBridge {
    // 查询所有下载
    static func getAll() async throws -> [DownloadItem] {
        return try await withCheckedThrowingContinuation { cont in
            final class Box {
                let value: CheckedContinuation<[DownloadItem], Error>
                init(_ v: CheckedContinuation<[DownloadItem], Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_DownloadGetAll({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(domain: "OWLDownload",
                        code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                guard let jsonArray else {
                    box.value.resume(returning: [])
                    return
                }
                let jsonStr = String(cString: jsonArray)
                guard let data = jsonStr.data(using: .utf8) else {
                    box.value.resume(throwing: NSError(domain: "OWLDownload",
                        code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 in JSON"]))
                    return
                }
                do {
                    let items = try JSONDecoder().decode([DownloadItem].self, from: data)
                    box.value.resume(returning: items)
                } catch {
                    box.value.resume(throwing: error)  // 抛出解码错误而非静默返回空
                }
            }, ctx)
        }
    }

    // 控制操作（fire-and-forget，无回调）
    static func pause(id: UInt32) { OWLBridge_DownloadPause(id) }
    static func resume(id: UInt32) { OWLBridge_DownloadResume(id) }
    static func cancel(id: UInt32) { OWLBridge_DownloadCancel(id) }
    static func removeEntry(id: UInt32) { OWLBridge_DownloadRemoveEntry(id) }
    static func openFile(id: UInt32) { OWLBridge_DownloadOpenFile(id) }
    static func showInFolder(id: UInt32) { OWLBridge_DownloadShowInFolder(id) }
}
#endif
```

### 4. Bridge 层 — 推送回调

```swift
// Services/DownloadBridge.swift
@MainActor
final class DownloadBridge {
    static let shared = DownloadBridge()
    private weak var downloadVM: DownloadViewModel?

    func register(downloadVM: DownloadViewModel) {
        self.downloadVM = downloadVM
        #if canImport(OWLBridge)
        OWLBridge_SetDownloadCallback(downloadEventCallback, nil)
        #endif
    }

    func unregister() {
        #if canImport(OWLBridge)
        OWLBridge_SetDownloadCallback(nil, nil)
        #endif
        downloadVM = nil
    }

    fileprivate func forward(item: DownloadItem, eventType: Int32) {
        switch eventType {
        case 0: downloadVM?.onDownloadCreated(item)
        case 1: downloadVM?.onDownloadUpdated(item)
        default: break
        }
    }

    fileprivate func forwardRemoved(id: UInt32) {
        downloadVM?.onDownloadRemoved(id: id)
    }
}

// 全局 C 回调函数
private func downloadEventCallback(jsonItem: UnsafePointer<CChar>?,
                                    eventType: Int32,
                                    ctx: UnsafeMutableRawPointer?) {
    guard let jsonItem else { return }
    let jsonStr = String(cString: jsonItem)
    guard let data = jsonStr.data(using: .utf8) else { return }

    if eventType == 2 {
        // removed 事件：JSON 只包含 {"id": N}，不解码为完整 DownloadItem
        struct RemovedEvent: Decodable { let id: UInt32 }
        guard let event = try? JSONDecoder().decode(RemovedEvent.self, from: data) else { return }
        Task { @MainActor in
            DownloadBridge.shared.forwardRemoved(id: event.id)
        }
    } else {
        // created/updated 事件：完整 DownloadItem JSON
        guard let item = try? JSONDecoder().decode(DownloadItem.self, from: data) else {
            NSLog("[OWL] DownloadBridge: failed to decode event JSON: \(jsonStr.prefix(200))")
            return
        }
        Task { @MainActor in
            DownloadBridge.shared.forward(item: item, eventType: eventType)
        }
    }
}
```

### 5. ViewModel 层

```swift
// ViewModels/DownloadViewModel.swift
@MainActor
package class DownloadViewModel: ObservableObject {
    @Published package var items: [DownloadItemVM] = []
    @Published package var activeCount: Int = 0
    @Published package var isLoading: Bool = false

    // 节流：per-item 级别，避免多下载并发更新互相取消
    private var pendingUpdates: [UInt32: Task<Void, Never>] = [:]
    private var lastUpdateTimes: [UInt32: CFAbsoluteTime] = [:]
    private var isLoadingAll: Bool = false  // 防止 loadAll 与增量推送竞态

    package func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        isLoadingAll = true
        #if canImport(OWLBridge)
        do {
            let downloads = try await OWLDownloadBridge.getAll()
            let fetchedIds = Set(downloads.map { $0.id })
            // Upsert：更新已有 item，新增不存在的
            for dl in downloads {
                if let idx = items.firstIndex(where: { $0.id == dl.id }) {
                    items[idx].update(from: dl)
                } else {
                    items.append(DownloadItemVM(from: dl))
                }
            }
            // 移除 host 端已不存在的 item（在 fetched 结果中没出现的）
            items.removeAll { !fetchedIds.contains($0.id) }
            updateActiveCount()
        } catch {
            NSLog("[OWL] DownloadViewModel.loadAll failed: \(error)")
            // 不清空 items — 保留已有数据，避免闪烁
        }
        #endif
        isLoadingAll = false
        isLoading = false
    }

    // 推送回调处理
    func onDownloadCreated(_ item: DownloadItem) {
        // 去重：如果已存在则更新而非插入
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].update(from: item)
        } else {
            let vm = DownloadItemVM(from: item)
            items.insert(vm, at: 0)  // 最新在上
        }
        updateActiveCount()
    }

    func onDownloadUpdated(_ item: DownloadItem) {
        throttlePerItem(id: item.id) {
            // Upsert：如果不存在则新增（覆盖 loadAll 未完成时的推送）
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx].update(from: item)
            } else {
                self.items.insert(DownloadItemVM(from: item), at: 0)
            }
            self.updateActiveCount()
        }
    }

    func onDownloadRemoved(id: UInt32) {
        items.removeAll { $0.id == id }
        updateActiveCount()
    }

    // 操作
    package func pause(id: UInt32) {
        #if canImport(OWLBridge)
        OWLDownloadBridge.pause(id: id)
        #endif
    }
    package func resume(id: UInt32) { /* 同上 */ }
    package func cancel(id: UInt32) { /* 同上 */ }
    package func removeEntry(id: UInt32) {
        items.removeAll { $0.id == id }  // 乐观删除
        #if canImport(OWLBridge)
        OWLDownloadBridge.removeEntry(id: id)
        #endif
    }
    package func clearCompleted() {
        let toRemove = items.filter { $0.state != .inProgress && $0.state != .paused }
        for item in toRemove {
            #if canImport(OWLBridge)
            OWLDownloadBridge.removeEntry(id: item.id)
            #endif
        }
        items.removeAll { $0.state != .inProgress && $0.state != .paused }
        updateActiveCount()
    }

    private func updateActiveCount() {
        activeCount = items.filter { $0.state == .inProgress }.count
    }

    private func throttlePerItem(id: UInt32, _ action: @escaping () -> Void) {
        let now = CFAbsoluteTimeGetCurrent()
        let lastTime = lastUpdateTimes[id] ?? 0
        if now - lastTime >= 0.1 {
            lastUpdateTimes[id] = now
            action()
        } else {
            pendingUpdates[id]?.cancel()
            pendingUpdates[id] = Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                self.lastUpdateTimes[id] = CFAbsoluteTimeGetCurrent()
                action()
            }
        }
    }
}
```

```swift
// DownloadItemVM（独立 ObservableObject 用于 per-row 更新）
package class DownloadItemVM: ObservableObject, Identifiable {
    package let id: UInt32
    @Published package var filename: String
    @Published package var state: DownloadState
    @Published package var progress: Double  // 0.0-1.0
    @Published package var receivedBytes: Int64
    @Published package var totalBytes: Int64
    @Published package var speed: String
    @Published package var errorDescription: String?
    @Published package var canResume: Bool
    package let url: String
    package let targetPath: String

    // 速度计算：3 秒环形缓冲区
    private var speedSamples: [(time: CFAbsoluteTime, bytes: Int64)] = []

    init(from item: DownloadItem) {
        id = item.id; filename = item.filename; state = item.state
        receivedBytes = item.receivedBytes; totalBytes = item.totalBytes
        progress = item.totalBytes > 0 ? Double(item.receivedBytes) / Double(item.totalBytes) : 0
        speed = Self.formatSpeed(item.speedBytesPerSec)
        errorDescription = item.errorDescription; canResume = item.canResume
        url = item.url; targetPath = item.targetPath
    }

    func update(from item: DownloadItem) {
        state = item.state; receivedBytes = item.receivedBytes; totalBytes = item.totalBytes
        progress = item.totalBytes > 0 ? Double(item.receivedBytes) / Double(item.totalBytes) : 0
        errorDescription = item.errorDescription; canResume = item.canResume
        // 速度计算
        let now = CFAbsoluteTimeGetCurrent()
        speedSamples.append((now, item.receivedBytes))
        speedSamples.removeAll { now - $0.time > 3.0 }
        if let first = speedSamples.first, now - first.time > 0.1 {
            let avgSpeed = Double(item.receivedBytes - first.bytes) / (now - first.time)
            speed = Self.formatSpeed(Int64(avgSpeed))
        } else {
            speed = Self.formatSpeed(item.speedBytesPerSec)
        }
    }

    static func formatSpeed(_ bytesPerSec: Int64) -> String {
        if bytesPerSec < 1024 { return "\(bytesPerSec) B/s" }
        if bytesPerSec < 1024 * 1024 { return String(format: "%.1f KB/s", Double(bytesPerSec) / 1024) }
        return String(format: "%.1f MB/s", Double(bytesPerSec) / (1024 * 1024))
    }
}
```

### 6. BrowserViewModel 集成

```swift
// 在 BrowserViewModel 中新增:
package let downloadVM = DownloadViewModel()

// 在 registerAllCallbacks(_:) 中新增:
DownloadBridge.shared.register(downloadVM: downloadVM)

// 在 context 创建成功的回调中调用（此时 download service 已注入）:
// 位于 BrowserViewModel.initializeAndLaunch() 的 createContext 成功回调内部，
// 在 registerAllCallbacks() 之后:
Task { await downloadVM.loadAll() }
// 注意：不能在 registerAllCallbacks 之前调用，因为 C-ABI service 尚未绑定
```

### 7. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/Models/DownloadItem.swift` | 新增 | DownloadItem + DownloadState |
| `owl-client-app/Services/DownloadService.swift` | 新增 | C-ABI async/await 包装 |
| `owl-client-app/Services/DownloadBridge.swift` | 新增 | 推送回调注册 + 转发 |
| `owl-client-app/ViewModels/DownloadViewModel.swift` | 新增 | ViewModel + DownloadItemVM |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | 新增 downloadVM + 注册 |

### 8. 测试策略

Swift 单元测试（Mock 模式，不依赖 Host 进程）：
- `DownloadItem_Codable` — JSON 解码/编码 + CodingKeys 映射
- `DownloadItemVM_Update` — update(from:) 更新字段
- `DownloadItemVM_Progress` — progress 计算（含 totalBytes=0）
- `DownloadItemVM_FormatSpeed` — 速度格式化（B/s, KB/s, MB/s）
- `DownloadViewModel_OnDownloadCreated` — 新增 item 到列表顶部
- `DownloadViewModel_OnDownloadUpdated` — 更新已有 item
- `DownloadViewModel_OnDownloadRemoved` — 移除 item
- `DownloadViewModel_ActiveCount` — 只计 inProgress 状态
- `DownloadViewModel_ClearCompleted` — 清除非活跃项
- `DownloadViewModel_Throttle` — 100ms 节流验证

### 9. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| CheckedContinuation 双重 resume | Box 模式确保 takeRetainedValue 只调一次 |
| 速度计算除零 | 检查 time diff > 0.1 秒 |
| 节流导致最后一次更新丢失 | pendingUpdate Task 保证最终执行 |
| Mock 模式下 C-ABI 不可用 | `#if canImport(OWLBridge)` 守卫 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
