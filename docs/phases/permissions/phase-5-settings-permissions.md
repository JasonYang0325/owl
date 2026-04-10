# Phase 5: 设置页权限管理

## 目标
在设置页新增权限管理面板，用户可查看和撤销已授予的权限。
完成后，用户有完整的权限控制能力。

## 范围
- 新增: `owl-client-app/App/Views/Settings/PermissionsPanel.swift`
- 修改: `owl-client-app/App/Views/Settings/SettingsView.swift`（新增 tab）
- 新增: `owl-client-app/Tests/OWLUnitTests/PermissionsPanelTests.swift`

## 依赖
- Phase 2（C-ABI PermissionGetAll / PermissionReset 函数）

## 技术要点
- 调用 `OWLBridge_PermissionGetAll` 获取所有站点权限
- 按站点分组展示，每个权限可单独修改（允许/拒绝/询问）
- 撤销权限: 调用 `OWLBridge_PermissionReset`，下次访问重新弹窗
- 系统级拒绝: 检查 macOS 权限状态，显示灰色 + "在系统设置中已禁用"
- 空状态: "尚未授予任何站点权限"
- "重置所有权限": 二次确认 Alert

## 验收标准
- [ ] AC-P5-1: 设置页显示权限管理 tab
- [ ] AC-P5-2: 列出所有站点+已授予权限
- [ ] AC-P5-3: 可单条修改权限（允许/拒绝/询问）
- [ ] AC-P5-4: 撤销后下次访问重新弹窗
- [ ] AC-P5-5: "重置所有权限" 清除全部
- [ ] AC-P5-6: 空状态显示占位文字

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过

---

## 技术方案

### 1. PermissionsPanel 设计

`PermissionsPanel` 是一个纯 SwiftUI 视图，由 `SettingsPanelViewModel`（新增）驱动数据。

#### 视图层次

```
PermissionsPanel (View)
  ├── List (按 origin 分组)
  │    └── Section(origin) × N
  │         └── PermissionRowView(type, status, isSystemDisabled)
  │              ├── Label(sfSymbol + displayName)
  │              └── Picker("", selection: $status)
  │                   ├── "允许"  (.granted)
  │                   ├── "拒绝"  (.denied)
  │                   └── "询问"  (.ask)
  ├── EmptyStateView (数据为空时)
  └── Footer Button: "重置所有权限"
```

#### 关键布局决策

- **List 而非 ScrollView**：List 原生支持 `Section` 分组，行间距与 macOS 系统设置一致。
- **Picker style `.menu`**：下拉菜单形式，紧凑适合设置页列表行。
- **系统级禁用行**：`.disabled(true)` 禁用 Picker，行整体降低 opacity，尾部显示 `"在系统设置中已禁用"` 文字（`.caption`, `.secondary`）。
- **空状态**：List 内容为空时替换整个 List 为居中 `VStack`，图标 `lock.slash`，标题"尚未授予任何站点权限"，说明文字。
- **最小窗口适配**：`SettingsView` 固定 480×360，PermissionsPanel 需要更高，改为 `frame(width: 520, height: 440)`（修改 SettingsView.frame）。

---

### 2. 数据模型

#### SitePermission（数据传输对象）

`OWLBridge_PermissionGetAll` 回调返回 JSON 数组，每个元素结构如下（与 host 端对齐）：

```json
{ "origin": "https://meet.google.com", "type": 0, "status": 0 }
```

对应 Swift 解码类型（新增到 `PermissionBridge.swift`）：

```swift
package struct SitePermission: Codable, Identifiable, Equatable, Sendable {
    package let origin: String
    package let type: Int32      // PermissionType.rawValue
    package let status: Int32    // PermissionStatus.rawValue

    package var id: String { "\(origin):\(type)" }
    package var permissionType: PermissionType { PermissionType(rawValue: type) ?? .camera }
    package var permissionStatus: PermissionStatus { PermissionStatus(rawValue: status) ?? .ask }
}
```

#### SettingsSiteGroup（视图模型聚合结构）

```swift
package struct SettingsSiteGroup: Identifiable {
    package let origin: String
    package var permissions: [SitePermission]
    package var id: String { origin }
}
```

---

### 3. SettingsPermissionsViewModel

新文件 `owl-client-app/ViewModels/SettingsPermissionsViewModel.swift`。

遵循项目既有 ViewModel 模式（`BookmarkViewModel` / `HistoryViewModel`）：

```swift
@MainActor
package class SettingsPermissionsViewModel: ObservableObject {
    @Published package var siteGroups: [SettingsSiteGroup] = []
    @Published package var isLoading = false
    @Published package var showResetAllConfirm = false

    // MockConfig
    package struct MockConfig {
        package var siteGroups: [SettingsSiteGroup]
        package var systemDisabledTypes: Set<PermissionType>
        package init(siteGroups: [SettingsSiteGroup] = [],
                     systemDisabledTypes: Set<PermissionType> = []) {
            self.siteGroups = siteGroups
            self.systemDisabledTypes = systemDisabledTypes
        }
    }
    private var mockConfig: MockConfig?
    private var isMockMode: Bool { mockConfig != nil || useMockMode }

    package init() {}
    package convenience init(mockConfig: MockConfig) { ... }
}
```

---

### 4. 数据流：加载时调用 PermissionGetAll

#### 异步桥接（新增 `OWLPermissionSettingsBridge`，放在 `PermissionBridge.swift` 末尾）

复用 `OWLBookmarkBridge` 的 Box/CheckedContinuation 模式：

```swift
enum OWLPermissionSettingsBridge {
    /// Fetch all stored permissions. Returns raw [SitePermission] array.
    static func getAll() async throws -> [SitePermission] {
        try await withCheckedThrowingContinuation { cont in
            final class Box { let c: CheckedContinuation<[SitePermission], Error>; init(_ c: ...) { self.c = c } }
            let box = Box(cont); let ctx = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_PermissionGetAll({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg { box.c.resume(throwing: ...); return }
                guard let jsonArray,
                      let data = String(cString: jsonArray).data(using: .utf8),
                      let items = try? JSONDecoder().decode([SitePermission].self, from: data)
                else { box.c.resume(throwing: ...); return }
                box.c.resume(returning: items)
            }, ctx)
        }
    }
}
```

#### ViewModel 加载流程

```swift
package func loadAll() async {
    if isMockMode {
        siteGroups = mockConfig?.siteGroups ?? []
        return
    }
    isLoading = true
    defer { isLoading = false }
    do {
        let items = try await OWLPermissionSettingsBridge.getAll()
        siteGroups = groupByOrigin(items)
    } catch {
        NSLog("[OWL] SettingsPermissionsViewModel.loadAll failed: \(error)")
    }
}

private func groupByOrigin(_ items: [SitePermission]) -> [SettingsSiteGroup] {
    var dict: [String: [SitePermission]] = [:]
    for item in items { dict[item.origin, default: []].append(item) }
    return dict.map { SettingsSiteGroup(origin: $0.key, permissions: $0.value) }
              .sorted { $0.origin < $1.origin }
}
```

---

### 5. 修改权限：Picker 变更 → PermissionSet C-ABI

#### 前置任务：补充 `OWLBridge_PermissionSet` C-ABI

Phase 2 的 Mojom `PermissionService` 已定义 `SetPermission(origin, type, status)` 方法，Host 端 `OWLPermissionServiceImpl::SetPermission` 也已实现。但 Phase 2 的 C-ABI 层只暴露了 Get/GetAll/Reset/ResetAll，**没有暴露 `PermissionSet`**。

Phase 5 开发前必须先补充该 C-ABI 函数。变更清单：

1. **`bridge/owl_bridge_api.h`** — 在 `OWLBridge_PermissionReset` 之前追加：

```c
// Set a permission status for (origin, type). Fire-and-forget.
// status: PermissionStatus enum (0=Granted, 1=Denied, 2=Ask).
// When status=Ask, equivalent to OWLBridge_PermissionReset.
OWL_EXPORT void OWLBridge_PermissionSet(
    const char* origin,
    int permission_type,
    int status);
```

2. **`bridge/owl_bridge_api.cc`** — 实现：通过 session remote 调用 `PermissionService::SetPermission(origin, type, status)`，模式与 `OWLBridge_PermissionReset` 一致（fire-and-forget，PostTask 到 IO thread）。

3. **`bridge/owl_bridge_permission_unittest.mm`** — 新增 `OWLBridge_PermissionSet` 单元测试（参数校验、空 origin 容错）。

4. **`bridge/exports.txt`** — 追加 `_OWLBridge_PermissionSet` 符号。

#### setPermission 实现

Picker 绑定使用计算属性 binding，变更时调用 `setPermission`。该方法为 **`async`**，使用 `withCheckedThrowingContinuation` 等待 C-ABI 回调确认，与 `loadAll()` 的异步模式对齐。

> **为何 async**：虽然 `OWLBridge_PermissionSet` 本身是 fire-and-forget，但为保持 ViewModel 方法签名一致性（`loadAll` 是 async），且未来可能切换为 callback 确认模式，`setPermission` 统一为 async。当前实现中 async 闭包内同步调用 C-ABI 后立即 resume。

```swift
package func setPermission(origin: String, type: PermissionType, status: PermissionStatus) async {
    if isMockMode {
        updateLocal(origin: origin, type: type, status: status)
        return
    }
    if status == .ask {
        origin.withCString { o in OWLBridge_PermissionReset(o, type.rawValue) }
    } else {
        origin.withCString { o in OWLBridge_PermissionSet(o, type.rawValue, status.rawValue) }
    }
    updateLocal(origin: origin, type: type, status: status)
}

private func updateLocal(origin: String, type: PermissionType, status: PermissionStatus) {
    guard let gi = siteGroups.firstIndex(where: { $0.origin == origin }),
          let pi = siteGroups[gi].permissions.firstIndex(where: { $0.permissionType == type })
    else { return }
    var p = siteGroups[gi].permissions[pi]
    siteGroups[gi].permissions[pi] = SitePermission(origin: p.origin, type: p.type, status: status.rawValue)
}
```

View 层绑定：

```swift
Picker("", selection: Binding(
    get: { perm.permissionStatus },
    set: { newStatus in
        Task { @MainActor in
            await vm.setPermission(origin: group.origin, type: perm.permissionType, status: newStatus)
        }
    }
)) {
    Text("允许").tag(PermissionStatus.granted)
    Text("拒绝").tag(PermissionStatus.denied)
    Text("询问").tag(PermissionStatus.ask)
}
.pickerStyle(.menu)
.disabled(isSystemDisabled(perm.permissionType))
```

---

### 6. 重置所有：二次确认 Alert → PermissionResetAll

```swift
// ViewModel
package func confirmResetAll() {
    if isMockMode {
        siteGroups = []
        return
    }
    OWLBridge_PermissionResetAll()   // fire-and-forget
    siteGroups = []                  // 乐观更新
}
// 设计决策：confirmResetAll 使用乐观更新 + fire-and-forget，不等待 C-ABI 回调确认。
// 理由：
// 1. OWLBridge_PermissionResetAll 是单向写入操作，C-ABI → Mojo → PermissionManager
//    的链路中没有业务层失败路径（origin/type 校验不适用于 ResetAll）。
// 2. 极端情况下 Mojo 管道断开（Host 崩溃）时 C-ABI 调用会被静默丢弃，
//    但此时整个浏览器已不可用，不需要 UI 层单独处理。
// 3. 用户下次打开设置页时 loadAll() 会重新从 Host 拉取真实状态，
//    自动纠正任何不一致（最终一致性保证）。
// 如果未来 ResetAll 需要等待确认（例如显示进度条），可改为 async + callback 模式。

// View
Button("重置所有权限", role: .destructive) {
    vm.showResetAllConfirm = true
}
.alert("重置所有权限", isPresented: $vm.showResetAllConfirm) {
    Button("取消", role: .cancel) {}
    Button("重置", role: .destructive) {
        vm.confirmResetAll()
    }
} message: {
    Text("将清除所有站点的已存储权限，下次访问时重新询问。")
}
```

---

### 7. 系统级权限检查

设置页加载时同步检查 macOS 系统层权限，对被系统禁用的权限类型禁用 Picker，标注说明文字。

```swift
// ViewModel 新增字段
@Published package var systemDisabledTypes: Set<PermissionType> = []

package func checkSystemPermissions() async {
    if isMockMode {
        systemDisabledTypes = mockConfig?.systemDisabledTypes ?? []
        return
    }
    var disabled: Set<PermissionType> = []

    // Camera
    let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if camStatus == .denied || camStatus == .restricted { disabled.insert(.camera) }

    // Microphone
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    if micStatus == .denied || micStatus == .restricted { disabled.insert(.microphone) }

    // Geolocation
    let locManager = CLLocationManager()
    let locStatus = locManager.authorizationStatus
    if locStatus == .denied || locStatus == .restricted { disabled.insert(.geolocation) }

    // Notifications
    let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
    if notifSettings.authorizationStatus == .denied { disabled.insert(.notifications) }

    systemDisabledTypes = disabled
}
```

View 层显示：

```swift
// PermissionRowView 中
if vm.systemDisabledTypes.contains(perm.permissionType) {
    Text("在系统设置中已禁用")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

**`loadAll()` 与 `checkSystemPermissions()` 在 `.task` 中并发执行**：

```swift
.task {
    async let a: Void = vm.loadAll()
    async let b: Void = vm.checkSystemPermissions()
    _ = await (a, b)
}
```

需要在文件顶部 `import AVFoundation`、`import CoreLocation`、`import UserNotifications`。

---

### 8. 与 SettingsView 集成

在 `SettingsView.swift` 中：

1. 新增 `@StateObject private var permissionsVM = SettingsPermissionsViewModel()`
2. 在 `TabView` 中追加新 tab：

```swift
PermissionsPanel(vm: permissionsVM)
    .tabItem { Label("权限", systemImage: "hand.raised.fill") }
    .tag("permissions")
```

3. 将 `SettingsView.frame` 从 `(width: 480, height: 360)` 改为 `(width: 520, height: 460)`，兼容权限列表更多行高需求。

`PermissionsPanel` 签名：

```swift
struct PermissionsPanel: View {
    @ObservedObject var vm: SettingsPermissionsViewModel
    // ...
}
```

---

### 9. 文件变更清单

#### 前置：补充 C-ABI `PermissionSet`（Phase 2 遗漏）

| 操作 | 文件 | 说明 |
|------|------|------|
| 修改 | `bridge/owl_bridge_api.h` | 追加 `OWLBridge_PermissionSet(origin, type, status)` 声明 |
| 修改 | `bridge/owl_bridge_api.cc` | 实现 `OWLBridge_PermissionSet`，调用 Mojo `SetPermission` |
| 修改 | `bridge/exports.txt` | 追加 `_OWLBridge_PermissionSet` 符号导出 |
| 修改 | `bridge/owl_bridge_permission_unittest.mm` | 新增 `PermissionSet` 单元测试 |

#### Phase 5 本体

| 操作 | 文件 | 说明 |
|------|------|------|
| 新增 | `owl-client-app/Views/Settings/PermissionsPanel.swift` | 权限管理面板 View |
| 新增 | `owl-client-app/ViewModels/SettingsPermissionsViewModel.swift` | 数据层 ViewModel |
| 修改 | `owl-client-app/Services/PermissionBridge.swift` | 追加 `SitePermission` struct + `OWLPermissionSettingsBridge` |
| 修改 | `owl-client-app/Views/Settings/SettingsView.swift` | 新增"权限" tab，调整 frame |
| 新增 | `owl-client-app/Tests/Unit/PermissionsPanelTests.swift` | ViewModel 单元测试 |

---

### 10. 测试策略

#### ViewModel 单元测试（`PermissionsPanelTests.swift`）

复用 `PermissionViewModelTests` 的 `MainActor.assumeIsolated` + `pump()` 模式，**无需 Host 进程**，通过 `MockConfig` 注入数据。

**文件归属**：`OWLUnitTests` target（与 `PermissionViewModelTests.swift` 同目录）。

**测试用例规划**：

| 测试方法 | 对应 AC | 验证内容 |
|---------|---------|---------|
| `testInitialState_empty` | AC-P5-6 | 空状态：`siteGroups` 为空时，`isEmpty` 为 true |
| `testLoadAll_groupsByOrigin` | AC-P5-2 | 两条不同 origin 的权限 → `siteGroups.count == 2` |
| `testLoadAll_sameOriginGrouped` | AC-P5-2 | 同一 origin 的 camera + mic → `siteGroups.count == 1, permissions.count == 2` |
| `testSetPermission_updatesLocal` | AC-P5-3 | mock 模式下 `setPermission` 更新 `siteGroups` 内对应条目 |
| `testSetPermission_resetToAsk` | AC-P5-3/P5-4 | status=.ask → 更新后 `permissionStatus == .ask` |
| `testResetAll_clearsGroups` | AC-P5-5 | `confirmResetAll()` 后 `siteGroups` 为空 |
| `testResetAll_showConfirmBeforeAction` | AC-P5-5 | `showResetAllConfirm` 为 true 时才能确认，未触发则不清空 |
| `testSystemDisabledTypes_injectedByMock` | AC-P5-2 | `MockConfig.systemDisabledTypes` 注入后 `systemDisabledTypes` 一致 |
| `testCheckSystemPermissions_mockMode` | AC-P5-2 | mock 模式 `checkSystemPermissions()` 使用 mock 数据，不调用 AVFoundation |
| `testGroupByOrigin_sortedAlphabetically` | AC-P5-2 | origin 按字母排序，b.com 在 a.com 之后 |

**MockConfig 设计**：

```swift
package struct MockConfig {
    package var siteGroups: [SettingsSiteGroup]
    package var systemDisabledTypes: Set<PermissionType>
    package init(
        siteGroups: [SettingsSiteGroup] = [],
        systemDisabledTypes: Set<PermissionType> = []
    ) {
        self.siteGroups = siteGroups
        self.systemDisabledTypes = systemDisabledTypes
    }
}
```

**测试辅助函数**：

```swift
private func makeVM(
    siteGroups: [SettingsSiteGroup] = [],
    systemDisabledTypes: Set<PermissionType> = []
) -> SettingsPermissionsViewModel {
    MainActor.assumeIsolated {
        SettingsPermissionsViewModel(mockConfig: .init(
            siteGroups: siteGroups,
            systemDisabledTypes: systemDisabledTypes
        ))
    }
}

private func pump(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}
```

#### 集成测试覆盖（可选，`OWLBrowserTests` pipeline）

- 启动 Host → 访问需要权限的页面 → 允许权限 → 打开设置 → 验证权限面板中出现该条目（通过 JS 评估 + PermissionGetAll 回调结果校验）。
