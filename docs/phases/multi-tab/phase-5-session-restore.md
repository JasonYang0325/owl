# Phase 5: 会话恢复

## 目标
- 退出浏览器时保存标签列表，重启时恢复
- 延迟加载：非活跃标签只恢复 UI 骨架，首次切换时才创建 WebView
- 崩溃保护：原子写入 + 多触发点保存

## 范围

### 新增文件
| 文件 | 内容 |
|------|------|
| `owl-client-app/Services/SessionRestoreService.swift` | 会话持久化 + 恢复 + 定时保存 |

### 修改文件
| 文件 | 变更 |
|------|------|
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 启动时调用恢复、标签变更时触发保存 |
| `owl-client-app/ViewModels/TabViewModel.swift` | isDeferred 状态 + deferred→loading 激活流程 |

## 依赖
- Phase 4（isPinned 属性，用于序列化）
- Phase 2（createTab + activateTab 基础流程）

## 技术要点

### 保存
- 数据模型: `[SessionTab]`（url, title, isPinned, isActive, index）
- 路径: `~/Library/Application Support/OWL/session.json`
- 权限: 0600
- 原子写入: 先写 session.json.tmp → FileManager.moveItem 覆盖
- 触发时机: 正常退出 + 标签增删/固定变更 + 定时 30 秒（有变更才写）

### 恢复（延迟加载）
- 读取 session.json → 为每个条目创建 TabViewModel（isDeferred=true，无真实 webviewId）
- 仅 isActive=true 的标签通过 OWLTabManager 创建真正 WebView
- 其余标签首次 activateTab() 时：OWLTabManager.createTab → 导航 → isDeferred=false
- session.json 不存在/为空/解析失败 → 创建空白新标签

### 已知陷阱
- deferred 标签无 webviewId，不注册到 webviewIdMap → 回调不会路由到它（正确行为）
- deferred 标签点击后应立即显示 loading 状态（UI 先切换，不等 CreateWebView 完成）
- 定时保存需要 Timer，注意 app 进入后台时 Timer 暂停

## 验收标准
- [ ] 退出 → 重启后标签全部恢复（URL, title, isPinned, isActive, 顺序）（AC-004）
- [ ] 非活跃标签为 deferred 状态（浅色标题），不创建 WebView
- [ ] 点击 deferred 标签后创建 WebView 并导航
- [ ] 强制退出（kill）后重启恢复到最近一次保存的状态
- [ ] session.json 损坏时安全降级到空白新标签

## 技术方案

### 1. 架构设计

```
SessionRestoreService (新增)
  ├── save() → 序列化 tabs → 原子写入 session.json
  ├── load() → 读取 session.json → 返回 [SessionTab]
  └── startAutoSave(interval: 30s) → Timer 定期保存（有变更才写）

BrowserViewModel
  ├── 启动时: service.load() → 创建 deferred TabViewModels
  ├── 标签变更时: service.scheduleSave()
  └── 退出时: service.save()
```

### 2. 数据模型

```swift
/// 序列化到 session.json 的标签数据
struct SessionTab: Codable {
    let url: String         // 空字符串表示 about:blank
    let title: String
    let isPinned: Bool
    let isActive: Bool
    let index: Int          // 排序用
}

/// SessionRestoreService
@MainActor
class SessionRestoreService {
    private let fileURL: URL  // ~/Library/Application Support/OWL/session.json
    private var isDirty = false
    private var autoSaveTimer: Timer?
    
    func save(tabs: [TabViewModel], activeTab: TabViewModel?) throws
    func load() throws -> [SessionTab]
    func scheduleSave()      // 标记 dirty，等 timer 触发
    func startAutoSave(interval: TimeInterval = 30)
    func stopAutoSave()
}
```

### 3. 核心逻辑

#### 保存流程
```swift
func save(tabs: [TabViewModel], activeTab: TabViewModel?) throws {
    let sessionTabs = tabs.enumerated().map { idx, tab in
        SessionTab(
            url: tab.url ?? "",
            title: tab.title,
            isPinned: tab.isPinned,
            isActive: tab.id == activeTab?.id,
            index: idx
        )
    }
    let data = try JSONEncoder().encode(sessionTabs)
    // 原子写入：tmp → rename
    let tmpURL = fileURL.appendingPathExtension("tmp")
    try data.write(to: tmpURL, options: .atomic)
    try FileManager.default.moveItem(at: tmpURL, to: fileURL)
    // 权限 0600
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    isDirty = false
}
```

#### 恢复流程（延迟加载）
```swift
func restoreTabs(into vm: BrowserViewModel) {
    guard let sessionTabs = try? load(), !sessionTabs.isEmpty else {
        vm.createTab()  // 空/损坏 → 新建空白标签
        return
    }
    
    let sorted = sessionTabs.sorted(by: { $0.index < $1.index })
    var activeIdx: Int? = nil
    
    for (i, st) in sorted.enumerated() {
        let tab = TabViewModel.mock(title: st.title, url: st.url.isEmpty ? nil : st.url)
        tab.isPinned = st.isPinned
        tab.isDeferred = true           // 所有标签初始为 deferred
        tab.webviewId = 0              // 无真实 WebView
        vm.tabs.append(tab)
        if st.isActive { activeIdx = i }
    }
    
    // 激活 active 标签（创建真实 WebView）
    if let idx = activeIdx, idx < vm.tabs.count {
        vm.activateDeferredTab(vm.tabs[idx])
    } else if let first = vm.tabs.first {
        vm.activateDeferredTab(first)
    }
}
```

#### 延迟激活（BrowserViewModel 新增）
```swift
func activateDeferredTab(_ tab: TabViewModel) {
    guard tab.isDeferred else {
        activateTab(tab)
        return
    }
    // 立即切换 UI（显示 loading 状态）
    tab.isDeferred = false
    tab.isLoading = true
    activeTab = tab
    
    // 异步创建真实 WebView
    #if canImport(OWLBridge)
    guard browserContextId > 0 else { return }
    let url = tab.url
    pendingURLQueue.append(url ?? "")
    OWLBridge_CreateWebView(browserContextId, { wvId, errMsg, ctx in
        let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeRetainedValue()
        Task { @MainActor in
            guard errMsg == nil else { return }
            tab.webviewId = wvId
            vm.webviewIdMap[wvId] = tab
            vm.registerAllCallbacks(wvId)
            OWLBridge_SetActiveWebView(wvId)
            if let url, !url.isEmpty {
                tab.navigate(to: url)
            }
        }
    }, Unmanaged.passRetained(self).toOpaque())
    #endif
}
```

#### 自动保存触发
```swift
// BrowserViewModel 中：
private func notifySessionChanged() {
    sessionRestoreService?.scheduleSave()
}

// 在以下方法末尾调用 notifySessionChanged():
// - createTab (回调中)
// - closeTab
// - pinTab / unpinTab
// - activateTab (切换活跃标签)
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/Services/SessionRestoreService.swift` | 新增 | 完整的保存/恢复/自动保存逻辑 |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | 启动恢复 + activateDeferredTab + notifySessionChanged |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | isDeferred 已有(Phase 2)；确保 webviewId=0 时 deferred 行为正确 |

### 5. 测试策略

| 测试 | 类型 | 验证点 |
|------|------|--------|
| SaveAndLoad_RoundTrip | Swift Unit | 保存 3 标签 → 加载 → 数据一致 |
| Save_AtomicWrite | Swift Unit | 写入期间中断 → 旧文件不损坏 |
| Load_CorruptJSON | Swift Unit | 无效 JSON → 返回空数组 |
| Load_EmptyFile | Swift Unit | 空文件 → 返回空数组 |
| Load_FileNotFound | Swift Unit | 文件不存在 → 返回空数组 |
| Restore_DeferredTabs | Swift Unit | 恢复后非活跃标签 isDeferred=true |
| Restore_ActiveTabCreated | Swift Unit | 活跃标签 isDeferred=false |
| Restore_PinnedPreserved | Swift Unit | isPinned 状态恢复 |
| Restore_OrderPreserved | Swift Unit | index 顺序恢复 |
| AutoSave_DirtyFlag | Swift Unit | 变更后 isDirty=true，保存后 false |

### 6. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| FileManager.moveItem 跨卷失败 | tmp 文件与目标在同目录 |
| Timer 在 app 后台暂停 | macOS 桌面 app 不自动进入后台 |
| deferred 标签点击时 Host 未就绪 | guard browserContextId > 0 |
| 大量标签恢复时 UI 卡顿 | 延迟加载，只创建 active 标签的 WebView |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
