# Phase: OWL Browser 统一测试框架

## 概述

为 OWL Browser 设计一套完整的、专属的自动化测试框架，解决当前无法测试 SwiftUI 界面、无法跨层联动测试（native UI + web content）、无法测试拖拽等复杂交互的核心问题。

## 现状分析

### 当前测试层次

| 层级 | 框架 | 状态 | 覆盖范围 |
|------|------|------|---------|
| C++ GTest | GTest | 正常 | Bridge/Client/Host 内部逻辑 |
| Swift XCTest | XCTest + OWLTestBridge | 正常 | C-ABI -> Mojo -> Host 管道 |
| CGEvent 系统测试 | OWLUITest | 不稳定 | 系统级输入注入 |
| XCUITest | XCUIApplication | 不可用 | 无（签名问题） |
| Python CDP | DevTools Protocol | 正常 | 仅 web 内容 |

### 核心缺陷

1. **SwiftUI 界面不可测**：XCUITest 因签名不可用，CGEvent 是系统全局的且不稳定
2. **跨层割裂**：C++ 测 Host、Swift 测管道，二者无法在同一个测试中协作
3. **复杂交互无法覆盖**：拖拽标签、文件拖入网页等需要同时操作 native UI 和 web content
4. **CI 不友好**：CGEvent 受用户操作干扰，无法在有人操作的机器上稳定运行

### XCUITest 签名问题确认

**问题本质**：macOS library validation 要求动态加载的代码与加载进程有相同 Team ID。

**注册开发者账号后能否修复？** 可以。用同一 Team ID 重签所有组件即可。免费 Personal Team 可用于本地测试，正式 CI 需要付费团队账号。

### Phase A POC 结论：NSEvent 进程内注入不可行

**已验证**（2026-03-30）：在 `swift test` 环境中，NSEvent 注入无法触发 SwiftUI 交互。

| 尝试方法 | 结果 | 根因 |
|---------|------|------|
| `NSApp.sendEvent(mouseDown)` | 失败 | 窗口无法成为 key window |
| `NSApp.postEvent` + `RunLoop.main.run` | 失败 | RunLoop 不驱动 NSApp 事件分发 |
| 先 `postEvent(mouseUp)` 再 `sendEvent(mouseDown)` | 失败 | 非 key window 不路由到 SwiftUI |
| 直接 `hostingView.mouseDown(with:)` | 失败 | SwiftUI 内部 hit testing 不工作 |
| AXUIElement AXPress | 失败 | SwiftUI Button 未暴露到 AX 树 |

**根因**：`swift test` 进程不是通过 `NSApplicationMain` 启动的正常 GUI app。窗口无法成为 key window，SwiftUI 手势系统在非 key window 中不工作。这是 macOS 的基础限制，无法绕过。

---

## 技术方案（v2 — 三层混合架构）

### 1. 架构设计

#### 核心思路：分层混合（Layered Hybrid）

基于 POC 实证和 Codex 评估，放弃 NSEvent 进程内注入方案，改用三层混合架构：

```
+------------------------------------------------------------------+
|                    OWL Browser 测试体系                            |
|                                                                  |
|  L1: OWLTestBridge (主力)                CI: 无 GUI，高频         |
|  +-----------------------------+                                 |
|  | C-ABI -> Mojo -> Host       |  覆盖：输入管线、JS、IME、       |
|  | -> Renderer 全链路           |        导航、鼠标点击、           |
|  | swift test --filter          |        ViewModel 状态            |
|  +-----------------------------+                                 |
|                                                                  |
|  L2: CGEvent 真实输入 (补充)     CI: 需要 GUI session + 独占       |
|  +-----------------------------+                                 |
|  | CGEvent -> macOS -> NSApp    |  覆盖：系统输入链验证、           |
|  | -> OWLRemoteLayerView        |        Tab 键焦点、Enter 提交    |
|  | -> C-ABI -> Chromium         |                                |
|  | .build/debug/OWLUITest       |                                |
|  +-----------------------------+                                 |
|                                                                  |
|  L3: XCUITest 原生壳层 (可选)    CI: 需要签名 + GUI session        |
|  +-----------------------------+                                 |
|  | XCUIApplication -> AX tree   |  覆盖：启动、窗口管理、菜单、     |
|  | -> SwiftUI 原生控件           |        工具栏、地址栏、Tab 切换   |
|  | xcodebuild test              |                                |
|  +-----------------------------+                                 |
|                                                                  |
|  补充: Python CDP (已有)         CI: 需要 Host 运行               |
|  +-----------------------------+                                 |
|  | Chrome DevTools Protocol     |  覆盖：Web 内容、DOM 交互、      |
|  | python3 test_e2e_input.py    |        表单提交                  |
|  +-----------------------------+                                 |
+------------------------------------------------------------------+
```

#### 每层的定位

**L1: OWLTestBridge — 主力层（覆盖 80% 场景）**

现有 OWLBrowserTests 已经非常成熟：16 个测试全部通过，覆盖 JS 执行、键盘输入、鼠标点击、IME、导航等核心功能。这是性价比最高、最稳定的一层。

优势：
- 不需要 GUI session，`swift test` 直接跑
- 测试完整管线：C-ABI -> Mojo -> Host -> Renderer
- 可以用 `OWLBridge_EvaluateJavaScript` 做精确断言
- CI 友好，可在任何 macOS runner 上运行

**L2: CGEvent 真实输入 — 补充层（系统级验证）**

现有 OWLUITest 已经可以工作。CGEvent 是唯一能在 `swift test` 之外验证"系统输入 -> NSApp -> NSView -> C-ABI -> Chromium"完整链路的方式。

限制：
- 需要 GUI session（有桌面、有显示器）
- 需要前台窗口 + 独占机器
- 用户操作会干扰

适用场景：真实输入链验证、Tab/Enter 等特殊按键、多屏坐标、文件拖入网页（CGEvent drag + C-ABI drop 验证）

**L3: XCUITest — 原生壳层（需签名后启用）**

XCUITest 是 Apple 官方 UI 测试框架，底层基于 Accessibility。签名后可测试 SwiftUI 原生控件。

适用场景：启动流程、窗口激活、菜单栏、工具栏点击、地址栏输入、Tab 切换、侧边栏折叠

不适用：Chromium 渲染的 web 内容（AX 树看不到 DOM）

#### 已完成：Library-Executable Split（Phase 0）

OWLBrowser 已拆分为 OWLBrowserLib + OWLBrowser 可执行入口：
- `OWLBrowserLib`：Views + ViewModels + Services（library target）
- `OWLBrowser`：仅 @main 入口（depends on OWLBrowserLib）
- `OWLTestKit`：占位库（depends on OWLBrowserLib）
- 关键类型已标 `package` access level
- `OWLBridgeSwift.initialize()` 已加幂等守卫

### 2. 接口设计

#### 2.1 增强 OWLTestBridge（L1 主力层）

现有 OWLTestBridge 已有完整的 C-ABI async 包装。增强方向：

```swift
// 新增 ViewModel 测试支持（MockConfig）
extension BrowserViewModel {
    struct MockConfig {
        var initialTabs: [(title: String, url: String?)]
        var connectionDelay: TimeInterval
        var shouldFail: Bool
        var failMessage: String
    }
    convenience init(mockConfig: MockConfig) { ... }
}

// launch() 顶部加运行时覆盖
func launch() {
    if mockConfig != nil { launchMock(); return }
    // 原有逻辑不变
}
```

#### 2.2 CGEvent 测试改进（L2）

现有 OWLUITest 的 OWLUITestRunner + OWLSystemInput + OWLAccessibility 继续使用。改进方向：

- 统一到 OWLTestKit 共享 ManagedBox、WaitHelper 等工具
- 测试前自动检查 `AXIsProcessTrusted()` 和前台窗口状态
- 添加 `ensureForeground()` 前置检查

#### 2.3 XCUITest（L3，需签名后实现）

```bash
# 自动重签脚本
scripts/resign_for_testing.sh
# 用同一 Team ID 重签 OWLBridge.framework + Chromium dylibs + OWL Host.app
```

XCUITest target 使用现有 `UITests/OWLBrowserUITests.swift`。签名后需要先收缩范围：现有用例中 `testTypeInWebContent`、`testClickInWebContent` 等 web content 交互应迁移到 L1/L2，L3 只保留原生壳层测试。

### 3. 核心逻辑

#### 3.1 ViewModel 单元测试（无需 Host）

```swift
// OWLUnitTests — 通过 MockConfig 测试 ViewModel 状态机
class TabManagementTests: XCTestCase {
    func testCloseLastTabCreatesNew() {
        let vm = BrowserViewModel(mockConfig: .init(initialTabs: [("Tab 1", nil)]))
        // 触发 mock 启动
        vm.launch()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(vm.tabs.count, 1)
        vm.closeTab(vm.tabs.first!)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(vm.tabs.count, 1) // 自动创建新标签
    }
}
```

#### 3.2 管道集成测试（需 Host，现有 + 扩展）

现有 OWLBrowserTests 继续扩展。新增覆盖：
- Post-navigation 交互稳定性
- 多 tab 切换时的 webviewId 路由
- 并发导航竞态测试

#### 3.3 CGEvent 系统测试流程

```
1. OWLUITest 启动（独立可执行文件）
2. 初始化 Mojo + 启动 Host
3. 创建 NSWindow + OWLRemoteLayerView
4. NSApp.activate + makeKeyAndOrderFront
5. 等待页面加载
6. CGEvent 注入 -> 验证 JS 中的状态变化
7. kill Host + exit
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `Package.swift` | 已完成(Phase 0) | 7 个 targets |
| `ViewModels/BrowserViewModel.swift` | 修改 | MockConfig + launch() 运行时覆盖 |
| `Services/OWLBridgeSwift.swift` | 已完成(Phase 0) | 幂等守卫 |
| `Tests/Unit/OWLUnitTests.swift` | 扩展 | ViewModel 单元测试 |
| `Tests/OWLBrowserTests.swift` | 扩展 | 新增管道测试用例 |
| `UITest/OWLUITestRunner.swift` | 改进 | 前置检查 + 共享工具 |
| `scripts/resign_for_testing.sh` | 新增 | XCUITest 自动重签脚本 |

### 5. 测试覆盖矩阵

| 测试场景 | L0 C++ | L1 OWLTestBridge | L2 CGEvent | L3 XCUITest |
|---------|:---:|:---:|:---:|:---:|
| Mojo 消息序列化 | x | | | |
| InputTranslator 按键映射 | x | | | |
| Tab 创建/关闭/切换 | | x (MockConfig) | | |
| 连接状态机 | | x (MockConfig) | | |
| JS 执行返回值 | | x | | |
| 键盘输入到 DOM | | x | x | |
| 鼠标点击导航 | | x | x | |
| IME 中文输入 | | x | | |
| Tab 键焦点切换 | | | x | |
| 地址栏输入导航 | | | | x |
| 标签拖拽重排 | | | | x |
| 文件拖入网页 | | x (C-ABI drop) | x (CGEvent drag) | |
| Native-Web 联动拖拽 | | x (C-ABI 验证) | x (系统输入) | |
| 窗口管理/菜单 | | | | x |
| 侧边栏折叠 | | | | x |
| 后退/前进按钮 | | | | x |

### 6. 测试执行命令

```bash
# L0: C++ 单元测试
ninja -C out/owl-host third_party/owl:owl_tests
./out/owl-host/owl_bridge_unittests && ./out/owl-host/owl_client_unittests

# L1: 管道集成测试（主力，CI 必跑）
swift test -F out/owl-host --filter OWLBrowserTests

# L1: ViewModel 单元测试（无需 Host）
swift test --filter OWLUnitTests

# L2: CGEvent 系统测试（需 GUI session）
swift build --product OWLUITest && .build/debug/OWLUITest

# L3: XCUITest（需签名）
scripts/resign_for_testing.sh
xcodebuild test -project OWLBrowser.xcodeproj -scheme OWLBrowserUITests
```

### 7. CI 集成

```yaml
jobs:
  # 每次 push 必跑（无 GUI 要求）
  unit-and-pipeline:
    runs-on: macos-14
    steps:
      - run: ninja -C out/owl-host third_party/owl:owl_tests && ./out/owl-host/owl_bridge_unittests
      - run: swift test --filter OWLUnitTests
      - run: swift test -F out/owl-host --filter OWLBrowserTests

  # 每日/PR 跑（需要 GUI session，独占 runner）
  system-input:
    runs-on: macos-14-gui  # 自定义 runner，有桌面
    steps:
      - run: swift build --product OWLUITest && .build/debug/OWLUITest

  # 签名后启用（需开发者账号）
  xcuitest:
    runs-on: macos-14-gui
    if: ${{ secrets.APPLE_TEAM_ID != '' }}
    steps:
      - run: scripts/resign_for_testing.sh
      - run: xcodebuild test -scheme OWLBrowserUITests
```

### 8. 风险 & 缓解

| 风险 | 严重度 | 缓解 |
|------|--------|------|
| CGEvent 受用户操作干扰 | P1 | 独占 GUI runner + 测试前 ensureForeground 检查 |
| Host 子进程不退出导致 swift test 挂起 | P1 | tearDown 中 kill+waitpid + ProcessGuard atexit 兜底 |
| XCUITest 签名维护成本 | P2 | 自动重签脚本 + CI 集成 |
| Chromium 内容在 AX 树不可见 | P2 | XCUITest 只测原生壳层，Web 内容用 L1 OWLTestBridge |

### 9. 实施计划

| 阶段 | 内容 | 状态 | 依赖 |
|------|------|------|------|
| Phase 0 | OWLBrowserLib 拆分 + Package.swift | 已完成 | 无 |
| Phase A | NSEvent POC 验证 | 已完成(失败) | Phase 0 |
| **Phase B** | MockConfig + ViewModel 单元测试 | 待开发 | Phase 0 |
| **Phase C** | OWLTestBridge 扩展（新增管道测试） | 待开发 | 无 |
| **Phase D** | CGEvent 测试改进（OWLUITest 增强） | 待开发 | Phase B (共享 OWLTestKit 工具) |
| **Phase E** | 签名 + XCUITest（需开发者账号） | 待开发 | 开发者账号 |
| Phase F | CI 集成 | 待开发 | Phase B+C+D |

Phase B/C/D 可并行开发。Phase E 依赖开发者账号注册。

---

## Phase A POC 经验教训

### 已验证的技术事实

1. **`swift test` 进程无法获得 key window** — `NSApp.setActivationPolicy(.regular)` 可以让 `isActive=true`，但窗口始终 `isKeyWindow=false`。`canBecomeKey` override 无效。
2. **SwiftUI 手势系统依赖 key window** — Button、DragGesture 等在非 key window 中不响应。
3. **NSEvent 三种注入方式全部失败** — `sendEvent`（tracking loop 阻塞）、`postEvent`（不驱动 NSApp 事件分发）、`postEvent(mouseUp) + sendEvent(mouseDown)`（非 key window 不路由到 SwiftUI）。
4. **SwiftUI Button 不映射为 NSButton** — 纯 SwiftUI 渲染，NSView 层级中不可见。
5. **`setUp() async throws` + `await MainActor.run` 死锁** — XCTest runner 在主线程等待 async setUp 完成，`MainActor.run` 需要主线程 → 死锁。
6. **NSApp 在 swift test 中需要显式初始化** — 必须先 `_ = NSApplication.shared`。

### 写入记忆的关键经验

- `swift test` 不是正常 GUI app，不能做 UI 自动化
- NSEvent 只适合"app 内部开发期调试"，不能进正式测试架构
- CGEvent 是唯一能在进程外验证系统输入链的方式
- XCUITest 是 Apple 官方 UI 测试路径，签名是必要投入

---

## 评审记录

### v1 评审 (2026-03-30, 3 轮)

原方案基于 NSEvent 进程内注入。经 Claude + Codex + Gemini 3 轮评审修复了 SPM 编译图、Mojo 幂等初始化等问题。

### Phase A POC (2026-03-30)

NSEvent POC 证明进程内注入不可行。Codex 评估确认三层混合是正确方向。

### v2 方案 (2026-03-30)

基于 POC 结论重写为三层混合架构。核心变更：
- 放弃 NSEvent 进程内注入
- L1 OWLTestBridge 作为主力（已验证可工作）
- L2 CGEvent 保留作为系统输入验证
- L3 XCUITest 作为原生壳层测试（需签名）

### v2 Codex 评审 (2026-03-30)

Verdict: REVISE -> 已修复

| 问题 | 修复 |
|------|------|
| P0: 文件拖入网页场景无落点 | 补充到 L1(C-ABI drop 验证) + L2(CGEvent drag) 覆盖矩阵 |
| P1: Phase D 依赖 OWLTestKit | 修正依赖关系：Phase D depends on Phase B |
| P1: 现有 XCUITest 含 web content 测试 | 明确 L3 需先收缩范围，web content 用例迁移到 L1/L2 |

**Final Verdict: APPROVE**
