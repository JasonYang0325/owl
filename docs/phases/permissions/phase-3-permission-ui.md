# Phase 3: 权限弹窗 UI + ViewModel

## 目标
实现权限弹窗的完整 UI 和状态管理。
完成后，用户看到权限请求弹窗，可以允许/拒绝，决定自动持久化。

## 范围
- 新增: `owl-client-app/Services/PermissionBridge.swift`（C-ABI 回调接收）
- 新增: `owl-client-app/App/ViewModels/PermissionViewModel.swift`
- 新增: `owl-client-app/App/Views/Alert/PermissionAlertView.swift`
- 新增: `owl-client-app/Tests/OWLUnitTests/PermissionViewModelTests.swift`

## 依赖
- Phase 2（C-ABI 回调和响应函数）

## 技术要点
- PermissionViewModel: 弹窗队列管理、30 秒超时定时器、权限类型→图标映射
- PermissionAlertView: ZStack overlay（不是 .sheet），从地址栏下方滑入
- notifications 双授权: 先检查 UNUserNotificationCenter 状态，系统拒绝则 Toast
- C-ABI 回调在 main thread，Swift 用 `Task { @MainActor in }` 桥接

## 验收标准
- [ ] AC-P3-1: 权限请求时弹出弹窗（显示 origin + 权限类型 + 图标）
- [ ] AC-P3-2: 点击"允许"后权限生效 + 弹窗消失
- [ ] AC-P3-3: 点击"拒绝"后权限拒绝 + 弹窗消失
- [ ] AC-P3-4: 30 秒超时自动拒绝 + Toast 提示
- [ ] AC-P3-5: 多个请求队列化逐个弹出
- [ ] AC-P3-6: notifications 先检查系统授权，系统拒绝时 Toast

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过

---

## 技术方案

### 1. 总体架构

```
C-ABI 回调 (main thread)
    │
    ▼
PermissionBridge.swift          ← 全局单例，注册 OWLBridge_SetPermissionRequestCallback
    │  将 C 回调转为 Swift 事件
    ▼
PermissionViewModel             ← @MainActor ObservableObject，队列 + 状态机 + 定时器
    │  @Published pendingAlert
    ▼
BrowserViewModel                ← 持有 permissionVM，通过构造参数传入 View
    │
    ▼
BrowserWindow / ContentAreaView ← .overlay(alignment: .top) 挂载 PermissionAlertView
    │
    ▼
PermissionAlertView             ← @ObservedObject permissionVM，.move(edge: .top) 动画
```

权限响应路径（允许/拒绝/超时）：

```
PermissionAlertView 按钮
    → PermissionViewModel.respond(id:, status:)
    → OWLPermissionBridge.respond(requestId:, status:)  ← fire-and-forget C-ABI
    → 出队，弹出下一个（如有）
```

---

### 2. PermissionViewModel 设计

#### 2.1 数据模型

```swift
// Services/PermissionBridge.swift 中定义的共享类型
package enum PermissionType: Int32, CaseIterable {
    case camera        = 0
    case microphone    = 1
    case geolocation   = 2
    case notifications = 3

    package var displayName: String { /* "摄像头" / "麦克风" / "位置" / "通知" */ }
    package var sfSymbol: String    { /* "camera.fill" / "mic.fill" / "location.fill" / "bell.fill" */ }
    package var iconColor: Color    { /* .blue / .red / .green / .orange */ }
}

package enum PermissionStatus: Int32 {
    case granted = 0
    case denied  = 1
    case ask     = 2
}

package struct PermissionRequest: Identifiable, Equatable {
    package let id: UInt64          // request_id from C-ABI
    package let origin: String      // e.g. "https://meet.google.com"
    package let type: PermissionType
}
```

#### 2.2 状态机

```
idle
  │ ← enqueue(request)
  ▼
pending                         ← 队列非空但尚未显示（processQueue() 立刻提升）
  │ ← processQueue()
  ▼
showing(request, countdown: 30)
  │                    │
  │ ← respond()        │ ← timer fires (countdown == 0)
  ▼                    ▼
decided             timeout → auto-denied → Toast
  │
  ▼
idle / pending（若队列还有请求则立即再次 showing）
```

#### 2.3 PermissionViewModel 接口

```swift
// ViewModels/PermissionViewModel.swift

#if canImport(OWLBridge)
import OWLBridge
private let useMockMode = false
#else
private let useMockMode = true
#endif

@MainActor
package class PermissionViewModel: ObservableObject {

    // MARK: - Published 状态

    /// 当前弹窗请求。非 nil → PermissionAlertView 显示。
    @Published package var pendingAlert: PermissionRequest? = nil

    /// 倒计时（秒），仅在 pendingAlert 非 nil 时有意义。
    @Published package var countdown: Int = 30

    /// Toast 消息（权限超时 / notifications 系统拒绝）。
    @Published package var toastMessage: String? = nil
    @Published package var showToast: Bool = false

    // MARK: - MockConfig（单元测试用）

    package struct MockConfig {
        package var simulatedRequests: [PermissionRequest]
        /// Mock 模式下模拟系统通知授权被拒绝（用于测试 notifications denied 分支）
        package var simulateSystemNotificationsDenied: Bool
        package init(simulatedRequests: [PermissionRequest] = [],
                     simulateSystemNotificationsDenied: Bool = false) {
            self.simulatedRequests = simulatedRequests
            self.simulateSystemNotificationsDenied = simulateSystemNotificationsDenied
        }
    }

    private var mockConfig: MockConfig?
    private var isMockMode: Bool { mockConfig != nil || useMockMode }

    package init() {}
    package convenience init(mockConfig: MockConfig) {
        self.init()
        self.mockConfig = mockConfig
    }

    // MARK: - 公开 API

    /// 外部（PermissionBridge）调用：入队一个权限请求。
    package func enqueue(_ request: PermissionRequest) { ... }

    /// View 层调用：用户点击"允许"或"拒绝"。
    package func respond(status: PermissionStatus) { ... }

    /// 仅 Mock 模式：模拟收到一个权限请求（用于单元测试）。
    package func simulateRequest(_ request: PermissionRequest) {
        guard isMockMode else { return }
        enqueue(request)
    }

    // MARK: - 私有

    private var queue: [PermissionRequest] = []
    private var timerTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
}
```

#### 2.4 核心逻辑实现细节

**enqueue / processQueue：**

```swift
package func enqueue(_ request: PermissionRequest) {
    queue.append(request)
    if pendingAlert == nil {
        processQueue()
    }
}

private func processQueue() {
    guard !queue.isEmpty else {
        pendingAlert = nil
        return
    }
    let next = queue.removeFirst()
    pendingAlert = next
    countdown = 30
    startTimer()
}
```

**30 秒定时器（Task-based，可取消）：**

```swift
private func startTimer() {
    timerTask?.cancel()
    timerTask = Task { @MainActor [weak self] in
        for remaining in stride(from: 30, through: 1, by: -1) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.countdown = remaining - 1
        }
        guard !Task.isCancelled else { return }
        self?.handleTimeout()
    }
}

private func handleTimeout() {
    guard let req = pendingAlert else { return }
    timerTask?.cancel()
    // 自动拒绝
    if !isMockMode {
        OWLPermissionBridge.respond(requestId: req.id, status: .denied)
    }
    pendingAlert = nil
    showToastMessage("权限请求已超时，已自动拒绝")
    processQueue()
}
```

**respond（用户点击）：**

```swift
package func respond(status: PermissionStatus) {
    guard let req = pendingAlert else { return }
    timerTask?.cancel()
    timerTask = nil
    if !isMockMode {
        OWLPermissionBridge.respond(requestId: req.id, status: status)
    }
    pendingAlert = nil
    processQueue()
}
```

**Toast 自动消失（3 秒）：**

```swift
private func showToastMessage(_ msg: String) {
    toastTask?.cancel()
    toastMessage = msg
    showToast = true
    toastTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            self?.showToast = false
        }
    }
}
```

#### 2.5 权限类型 → SF Symbol / 颜色映射

| PermissionType | sfSymbol | iconColor |
|----------------|----------|-----------|
| `.camera` | `"camera.fill"` | `.blue` |
| `.microphone` | `"mic.fill"` | `.red` |
| `.geolocation` | `"location.fill"` | `.green` |
| `.notifications` | `"bell.fill"` | `.orange` |

颜色使用 SwiftUI 语义系统色，自动适配 Dark Mode。

---

### 3. PermissionAlertView 设计

#### 3.1 挂载方式

弹窗通过 `BrowserWindow.body` 顶层 `.overlay(alignment: .top)` 挂载，**不使用 `.sheet`**。挂载点选 `BrowserWindow` 而非 `ContentAreaView`，确保遮盖完整窗口内容区，不被地址栏本身遮挡。

```swift
// BrowserWindow.swift — 在 VStack 最外层加 overlay
VStack(spacing: 0) {
    TopBarView(...)
    HStack(spacing: 0) { ... }
}
.overlay(alignment: .top) {
    PermissionAlertView(permissionVM: viewModel.permissionVM)
        .padding(.top, OWL.topBarHeight)   // 从地址栏下方开始
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.permissionVM.pendingAlert != nil)
}
```

#### 3.2 View 结构

```swift
// Views/Alert/PermissionAlertView.swift

struct PermissionAlertView: View {
    @ObservedObject var permissionVM: PermissionViewModel

    var body: some View {
        if let request = permissionVM.pendingAlert {
            alertCard(for: request)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func alertCard(for request: PermissionRequest) -> some View {
        VStack(spacing: 16) {
            // 图标（48pt）
            Image(systemName: request.type.sfSymbol)
                .font(.system(size: 48))
                .foregroundColor(request.type.iconColor)

            // 文案
            VStack(spacing: 4) {
                Text("「\(request.displayOrigin)」想要使用")
                    .font(.headline)
                Text("你的\(request.type.displayName)")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            // 按钮行
            HStack(spacing: 12) {
                Button("拒绝") {
                    withAnimation { permissionVM.respond(status: .denied) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("允许") {
                    withAnimation { permissionVM.respond(status: .granted) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // 倒计时提示
            Text("\(permissionVM.countdown) 秒后自动拒绝")
                .font(.caption)
                .foregroundColor(.tertiary)
        }
        .padding(24)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: OWL.radiusCard))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("权限请求：\(request.displayOrigin) 请求使用 \(request.type.displayName)")
    }
}
```

`request.displayOrigin` 是 `PermissionRequest` 上的计算属性，从 origin 字符串提取 host（去掉 scheme）：

```swift
package var displayOrigin: String {
    URL(string: origin)?.host ?? origin
}
```

#### 3.3 动画规格

- **进入**：`.move(edge: .top).combined(with: .opacity)`，`spring(response: 0.4, dampingFraction: 0.8)`
- **退出**：相同 transition 反向，由 `withAnimation` 包裹 `respond()` 触发
- **倒计时数字**：`.contentTransition(.numericText(countsDown: true))`（macOS 14+）

#### 3.4 Toast View

Toast 与权限弹窗共用同一 overlay，具体代码见 6.2 节 BrowserWindow 变更中的 VStack 实现。Toast 显示在弹窗正下方（有弹窗时）或 overlay 顶部（无弹窗时），由 VStack 自动布局。

---

### 4. PermissionBridge.swift 设计

#### 4.1 职责

- 在 `BrowserViewModel.initializeAndLaunch()` 中调用 `PermissionBridge.shared.register(permissionVM:)` 完成 C-ABI 回调注册
- C 回调（已在 main thread）→ `Task { @MainActor in permissionVM.enqueue(...) }`
- 提供 `OWLPermissionBridge.respond(requestId:status:)` 静态方法（fire-and-forget）

#### 4.2 实现

```swift
// Services/PermissionBridge.swift

import Foundation
#if canImport(OWLBridge)
import OWLBridge
#endif

/// 全局 C-ABI 回调持有者（弱持有 PermissionViewModel）。
/// 必须作为全局/单例存活（C 回调随时可能触发）。
final class PermissionBridge {
    static let shared = PermissionBridge()

    // 弱引用：避免循环引用；PermissionViewModel 由 BrowserViewModel 强持有
    private weak var permissionVM: PermissionViewModel?

    /// 在 BrowserViewModel.initializeAndLaunch() 中调用一次。
    func register(permissionVM: PermissionViewModel) {
        self.permissionVM = permissionVM

        #if canImport(OWLBridge)
        // C 回调为全局函数，不捕获 self，通过 g_permissionBridge 访问单例
        OWLBridge_SetPermissionRequestCallback(
            permissionRequestCallback,
            nil   // context 不需要，通过 PermissionBridge.shared 访问
        )
        #endif
    }

    /// 取消注册（app 退出时调用）。
    func unregister() {
        #if canImport(OWLBridge)
        OWLBridge_SetPermissionRequestCallback(nil, nil)
        #endif
        permissionVM = nil
    }
}

// MARK: - C 回调（全局函数，无闭包捕获）

#if canImport(OWLBridge)
private func permissionRequestCallback(
    origin: UnsafePointer<CChar>?,
    permissionType: Int32,
    requestId: UInt64,
    context: UnsafeMutableRawPointer?
) {
    let originStr = origin.map { String(cString: $0) } ?? ""
    let type = PermissionType(rawValue: permissionType) ?? .camera
    let request = PermissionRequest(id: requestId, origin: originStr, type: type)

    // C-ABI 保证在 main thread，但 Swift 不知道，用 Task @MainActor 桥接
    Task { @MainActor in
        PermissionBridge.shared.permissionVM?.enqueue(request)
    }
}
#endif

// MARK: - 响应（fire-and-forget）

enum OWLPermissionBridge {
    static func respond(requestId: UInt64, status: PermissionStatus) {
        #if canImport(OWLBridge)
        OWLBridge_RespondToPermission(requestId, status.rawValue)
        #endif
    }
}
```

#### 4.3 注册时序

```
OWLBrowserApp.init()
  └── BrowserViewModel.init()           ← permissionVM = PermissionViewModel()
        └── initializeAndLaunch()
              ├── OWLBridgeSwift.initialize()
              └── PermissionBridge.shared.register(permissionVM: permissionVM)
                                         ← 此后 C-ABI 回调即可触发
```

注意：`OWLBridge_SetPermissionRequestCallback` 必须在 `OWLBridge_Initialize()` 之后调用，`initializeAndLaunch()` 已保证这一顺序。

---

### 5. notifications 双授权流程

notifications 权限比其他三种多一步 macOS 系统级授权。流程如下：

```
PermissionViewModel.enqueue(request) 收到 .notifications 请求
    │
    ▼
检查 UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    │
    ├── .notDetermined → 调用 UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
    │       ├── 授权成功 → 继续正常 processQueue()，弹出 OWL 自有 PermissionAlertView
    │       └── 授权失败 → 拒绝 Chromium 侧请求（OWLBridge_RespondToPermission denied）
    │
    ├── .authorized / .provisional → 直接继续 processQueue()，弹 OWL 弹窗
    │
    └── .denied / .ephemeral 降级 → 拒绝 Chromium 侧请求 + Toast 提示
         Toast: "请在系统设置中允许 OWL Browser 发送通知"
```

在 `enqueue()` 内分支处理：

```swift
package func enqueue(_ request: PermissionRequest) {
    if request.type == .notifications {
        if isMockMode {
            // Mock 模式：根据 MockConfig 模拟系统通知授权结果
            if mockConfig?.simulateSystemNotificationsDenied == true {
                showToastMessage("请在系统设置中允许 OWL Browser 发送通知")
                return  // 不入队，模拟系统拒绝
            }
            // Mock 模式 + 系统未拒绝 → 正常入队
            queue.append(request)
            if pendingAlert == nil { processQueue() }
        } else {
            Task { @MainActor [weak self] in
                await self?.handleNotificationsEnqueue(request)
            }
        }
    } else {
        queue.append(request)
        if pendingAlert == nil { processQueue() }
    }
}

private func handleNotificationsEnqueue(_ request: PermissionRequest) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .notDetermined:
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            queue.append(request)
            if pendingAlert == nil { processQueue() }
        } else {
            OWLPermissionBridge.respond(requestId: request.id, status: .denied)
        }
    case .authorized, .provisional:
        queue.append(request)
        if pendingAlert == nil { processQueue() }
    default: // .denied, .ephemeral
        OWLPermissionBridge.respond(requestId: request.id, status: .denied)
        showToastMessage("请在系统设置中允许 OWL Browser 发送通知")
    }
}
```

---

### 6. 与现有组件的集成

#### 6.1 BrowserViewModel 变更

新增 `permissionVM` 属性，并在 `initializeAndLaunch()` 中注册 Bridge：

```swift
// BrowserViewModel.swift

@MainActor
package class BrowserViewModel: NSObject, ObservableObject {
    // ... 现有属性 ...
    package let permissionVM = PermissionViewModel()   // ← 新增

    func initializeAndLaunch() async {
        guard !hasLaunched else { return }
        hasLaunched = true

        #if canImport(OWLBridge)
        OWLBridgeSwift.initialize()
        PermissionBridge.shared.register(permissionVM: permissionVM)  // ← 新增
        #endif

        await bookmarkVM.loadAll()
        // ... 其余不变 ...
    }
}
```

#### 6.2 BrowserWindow 变更

在 `VStack` 最外层加 permission overlay 和 toast overlay：

```swift
// BrowserWindow.swift — body

VStack(spacing: 0) {
    TopBarView(...)
    HStack(spacing: 0) { ... }
}
.frame(minWidth: 480, minHeight: 400)
.overlay(alignment: .top) {
    // 权限弹窗：从地址栏（topBarHeight）下方滑入
    VStack(spacing: 8) {
        PermissionAlertView(permissionVM: viewModel.permissionVM)
            .padding(.top, OWL.topBarHeight)
        if permissionVM.showToast, let msg = permissionVM.toastMessage {
            Text(msg)
                .font(.caption)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    .animation(.spring(response: 0.4, dampingFraction: 0.8),
               value: permissionVM.pendingAlert?.id)
    .animation(.easeOut(duration: 0.3), value: permissionVM.showToast)
}
.background { ... /* 现有快捷键按钮不变 */ }
```

其中 `permissionVM` 通过 `viewModel.permissionVM` 取得（`viewModel` 是 `BrowserWindow` 的 `@EnvironmentObject var viewModel: BrowserViewModel`）。`PermissionAlertView` 接受 `permissionVM` 作为构造参数（`@ObservedObject`），不使用 `@EnvironmentObject`，避免注入遗漏导致运行时崩溃。

#### 6.3 MainContentView / OWLBrowserApp

无需改动。`BrowserViewModel` 已经作为 `.environmentObject` 注入，`PermissionAlertView` 通过构造参数直接接收 `PermissionViewModel`。

---

### 7. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/Services/PermissionBridge.swift` | **新增** | C-ABI 回调注册、`PermissionType`、`PermissionStatus`、`PermissionRequest`、`OWLPermissionBridge` |
| `owl-client-app/ViewModels/PermissionViewModel.swift` | **新增** | 状态机、队列、定时器、Toast、MockConfig |
| `owl-client-app/Views/Alert/PermissionAlertView.swift` | **新增** | ZStack overlay 弹窗 View + Toast |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | **修改** | 新增 `permissionVM`；`initializeAndLaunch()` 调用 `PermissionBridge.shared.register` |
| `owl-client-app/Views/BrowserWindow.swift` | **修改** | 新增 `.overlay(alignment: .top)` 挂载 PermissionAlertView + Toast |
| `owl-client-app/Tests/Unit/PermissionViewModelTests.swift` | **新增** | 单元测试（见第 8 节） |

---

### 8. 测试策略

#### 8.1 单元测试（OWLUnitTests，MockConfig 模式，无需 Host）

文件：`owl-client-app/Tests/Unit/PermissionViewModelTests.swift`

| 测试名 | 验证内容 |
|--------|---------|
| `testInitialState` | 初始 `pendingAlert == nil`，`countdown == 30`，`showToast == false` |
| `testSingleRequest_showsAlert` | `enqueue` 后 `pendingAlert` 变为对应请求 |
| `testAllow_clearsAlert` | `respond(.granted)` 后 `pendingAlert == nil` |
| `testDeny_clearsAlert` | `respond(.denied)` 后 `pendingAlert == nil` |
| `testQueue_secondRequestShowsAfterFirst` | 入队两个请求，第一个处理完后自动弹出第二个 |
| `testQueue_multipleRequestsProcessedInOrder` | 入队 3 个，按序逐个弹出 |
| `testTimeout_autoReject` | `countdown` 归零后 `pendingAlert == nil` + `showToast == true` |
| `testTimeout_toastMessage` | 超时 Toast 内容包含"已自动拒绝" |
| `testCountdown_decrements` | 1 秒后 `countdown` 从 30 → 29 |
| `testRespond_cancelsTimer` | `respond()` 后计时器取消，不再触发 Toast |
| `testPermissionTypeMapping_camera` | `PermissionType.camera.sfSymbol == "camera.fill"` |
| `testPermissionTypeMapping_allCases` | 所有 4 种类型均有非空 sfSymbol 和 displayName |
| `testMockMode_simulateRequest` | `simulateRequest()` 使 `pendingAlert` 变为该请求 |
| `testNotifications_systemDenied_toastShown` | `MockConfig(simulateSystemNotificationsDenied: true)` 下 enqueue notifications 请求，验证不入队 + showToast + Toast 包含"系统设置" |

**测试模板（参照 HistoryViewModelTests 风格）：**

```swift
import XCTest
@testable import OWLBrowserLib

final class PermissionViewModelTests: XCTestCase {

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func makeVM(requests: [PermissionRequest] = []) -> PermissionViewModel {
        MainActor.assumeIsolated {
            PermissionViewModel(mockConfig: .init(simulatedRequests: requests))
        }
    }

    func testSingleRequest_showsAlert() {
        let vm = makeVM()
        let req = PermissionRequest(id: 1, origin: "https://example.com", type: .camera)
        MainActor.assumeIsolated { vm.enqueue(req) }
        pump()
        MainActor.assumeIsolated {
            XCTAssertEqual(vm.pendingAlert?.id, 1)
            XCTAssertEqual(vm.pendingAlert?.type, .camera)
        }
    }

    func testAllow_clearsAlert() {
        let vm = makeVM()
        let req = PermissionRequest(id: 2, origin: "https://example.com", type: .microphone)
        MainActor.assumeIsolated {
            vm.enqueue(req)
            vm.respond(status: .granted)
            XCTAssertNil(vm.pendingAlert)
        }
    }

    // ... 其余测试类似
}
```

#### 8.2 边界场景

- **重复 enqueue 同 origin+type**：正常入队（每个 request_id 唯一），不去重（Host 层已保证不重复发）
- **enqueue 在 showing 状态**：加入队列，等当前弹窗关闭后自动弹出
- **app 后台时收到请求**：C-ABI 仍在 main thread 回调，弹窗正常显示（SwiftUI 会在窗口可见时渲染）
- **快速连续 respond**：`guard let req = pendingAlert` 防止 nil 崩溃

#### 8.3 不覆盖范围（留给 Phase 4 E2E）

- 实际 C-ABI 回调触发（需 Host）
- notifications UNUserNotificationCenter 系统弹窗（需真机/真系统授权）
- 持久化验证（Phase 2 已覆盖）

---

### 9. 设计决策记录

| 决策 | 选择 | 理由 |
|------|------|------|
| 弹窗位置 | `BrowserWindow` 顶层 `.overlay(alignment: .top)` | 避免被子 View 裁剪；能精确控制相对 TopBar 的偏移 |
| 定时器实现 | `Task { @MainActor }` + `Task.sleep` | 可取消、无 DispatchSourceTimer 内存管理风险；与项目其他地方一致（HistoryViewModel undo timer） |
| C 回调接收 | 全局单例 `PermissionBridge.shared` + 弱引用 VM | C 函数不支持闭包捕获；弱引用避免循环持有 |
| notifications 分支 | 在 `enqueue()` 内 async 分支处理 | 保持 VM 是唯一状态机入口，Bridge 不含业务逻辑 |
| PermissionType 定义位置 | `Services/PermissionBridge.swift` | 与 C-ABI 原始枚举值绑定，减少分散定义 |
| Toast 位置 | 同一 overlay VStack 内，弹窗正下方 | 不遮盖正在显示的弹窗；动画与弹窗联动 |
| PermissionAlertView 参数传递 | 构造参数 `@ObservedObject`（非 `@EnvironmentObject`） | 避免注入遗漏导致运行时崩溃；调用点显式传入更安全 |
| `package` access level | 所有对外类型和方法均用 `package` | 与项目约定一致（HistoryViewModel/BookmarkViewModel 同） |
