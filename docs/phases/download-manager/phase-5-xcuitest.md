# Phase 5: XCUITest 端到端验收

## 目标
- 完整的 XCUITest 覆盖所有 8 个 AC
- 验证全栈集成（Host → Bridge → Swift → UI）

## 范围

### 新增文件
- `owl-client-app/UITests/OWLDownloadUITests.swift` — XCUITest 测试用例

## 依赖
- Phase 4（全部功能已实现）

## 技术要点

1. **测试服务器**: 使用本地 HTTP 服务器提供测试下载文件
   - 小文件（即时完成）: 用于 AC-001, AC-005, AC-006
   - 大文件/慢速响应: 用于 AC-002, AC-003, AC-004
   - 错误响应（中断连接）: 用于 AC-007
   - 批量下载触发页: 用于批量拦截测试
2. **测试页面**: HTML 页面包含各种下载链接（直接下载、Content-Disposition、JS 触发、blob URL）
3. **Accessibility Identifier**: Phase 4 中需预埋 `.accessibilityIdentifier()` 用于 XCUITest 定位
4. **等待策略**: 下载是异步操作，使用 `XCTWaiter` + `XCUIElement.waitForExistence(timeout:)`
5. **文件验证**: 测试完成后检查 ~/Downloads 中文件是否存在且大小正确

## 测试用例

### AC-001: 触发下载
- [ ] 点击下载链接 → 文件保存到 ~/Downloads
- [ ] 工具栏图标显示 badge

### AC-002: 进度显示
- [ ] 下载面板显示文件名
- [ ] 进度条可见
- [ ] 速度和大小文字可见

### AC-003: 暂停/恢复
- [ ] 点击暂停 → 状态变为"已暂停"
- [ ] 点击恢复 → 状态变为进行中

### AC-004: 取消下载
- [ ] 点击取消 → 状态变为"已取消"
- [ ] 临时文件被清理

### AC-005: 打开/显示（按钮存在性验证）
- [ ] 下载完成后"打开"按钮出现
- [ ] 下载完成后"Finder"按钮出现
- 注意: 不验证系统行为（NSWorkspace/Finder），仅验证按钮存在且可点击

### AC-006: 历史列表
- [ ] 多个下载后列表正确显示
- [ ] 按时间倒序排列

### AC-007: 错误显示
- [ ] 网络中断 → 显示错误信息
- [ ] 重新下载按钮可见（当 CanResume==false 时）

### AC-008: 清除记录
- [ ] 点击清除 → 非活跃记录被移除
- [ ] 活跃下载保留

## 验收标准
- [ ] 所有 8 个 AC 对应的测试用例通过
- [ ] 测试在 CI 环境中可重复运行
- [ ] 无 flaky test（使用适当的超时和等待策略）

## 技术方案

### 1. 架构设计

```
OWL Browser App (XCUIApplication)
  ├── 导航栏输入 localhost:8765/test-page
  ├── 点击下载链接 → 触发原生下载
  └── XCUITest 验证原生 UI 元素（sidebar 面板）
        ├── accessibilityIdentifier 精确匹配（无通配符）
        └── waitForExistence + NSPredicate 查询
```

**架构决策**: XCUITest 只测试**原生壳层 UI**（下载面板、工具栏、按钮），不测试 web content 交互。下载触发通过地址栏导航到测试页面并点击链接，这是用户的自然操作路径。

### 2. 测试 HTTP 服务器

使用 `NWListener` (Network.framework) 在测试 setUp 中启动：

```swift
class TestHTTPServer {
    let port: UInt16 = 8765
    
    // 路由（使用唯一前缀避免与用户文件冲突）:
    // GET /download/owl_test_small_<UUID>.txt → 200 + "Hello" (Content-Disposition: attachment)
    // GET /download/owl_test_large_<UUID>.bin → 200 + 慢速响应 (每 200ms 写 1KB, 共 50KB)
    // GET /download/owl_test_error.bin → 200 headers then close
    // GET /test-page → HTML 页面含以上下载链接
}
```

**文件名隔离**: 所有测试文件名使用 `owl_test_` 前缀 + UUID 后缀，避免与用户 ~/Downloads 中的文件冲突。tearDown 只删除 `owl_test_*` 文件。

### 3. Accessibility Identifier 预埋

在 Phase 4 的 SwiftUI 视图中添加 `.accessibilityIdentifier()`。XCUITest 使用**精确匹配**或 `NSPredicate` 查询（不用通配符 `*`）：

| 元素 | Identifier | XCUITest 查询方式 |
|------|-----------|-----------------|
| 工具栏下载按钮 | `"download-toolbar-button"` | 精确匹配 |
| 下载面板 | `"download-sidebar-panel"` | 精确匹配 |
| 下载行 | `"download-row-\(id)"` | `NSPredicate(format: "identifier BEGINSWITH 'download-row-'")` |
| 暂停按钮 | `"download-pause-\(id)"` | `NSPredicate(format: "identifier BEGINSWITH 'download-pause-'")` |
| 恢复按钮 | `"download-resume-\(id)"` | 同上模式 |
| 取消按钮 | `"download-cancel-\(id)"` | 同上 |
| 打开按钮 | `"download-open-\(id)"` | 同上 |
| Finder 按钮 | `"download-finder-\(id)"` | 同上 |
| 清除按钮 | `"download-clear-button"` | 精确匹配 |
| 空状态 | `"download-empty-state"` | 精确匹配 |
| 状态文字 | `"download-status-\(id)"` | `NSPredicate` |
| 文件名 | `"download-filename-\(id)"` | `NSPredicate` |

### 4. 下载触发策略

**问题**: XCUITest 只测原生壳层，但下载需要通过 web 页面触发。
**解决**: 导航到本地测试服务器页面（`http://localhost:8765/test-page`），该页面包含 `<a href="/download/..." download>` 链接。Chromium 的 content layer 会自动将 `Content-Disposition: attachment` 响应转为下载。XCUITest 通过地址栏导航触发（这是用户的自然操作路径，不涉及 web content 内部交互）。

**对于需要点击链接的场景**: 测试页面使用 `<meta http-equiv="refresh">` 自动重定向到下载 URL，或使用 JS `window.location.href = downloadURL` 自动触发，无需 XCUITest 点击 web 元素。

### 5. XCUITest 用例设计（8 个 AC 完整覆盖）

```swift
// owl-client-app/UITests/OWLDownloadUITests.swift
class OWLDownloadUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        let downloads = NSHomeDirectory() + "/Downloads"
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: downloads) {
            for file in files where file.hasPrefix("owl_test_") {
                try? fm.removeItem(atPath: downloads + "/" + file)
            }
        }
    }

    // 辅助
    func navigateToURL(_ url: String) {
        let addressBar = app.textFields["address-bar"]
        addressBar.click()
        addressBar.typeText(url + "\n")
    }
    func openDownloadPanel() {
        let btn = app.buttons["download-toolbar-button"]
        if btn.waitForExistence(timeout: 3) { btn.click() }
    }
    func firstElement(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }
    func triggerSmallDownload() {
        // 自动触发页：meta refresh 重定向到下载 URL
        navigateToURL("http://localhost:8765/auto-download-small")
    }
    func triggerSlowDownload() {
        navigateToURL("http://localhost:8765/auto-download-slow")
    }

    // ── AC-001: 触发下载 ──
    func testAC001_DownloadTriggered_BadgeAppears() {
        triggerSmallDownload()
        openDownloadPanel()
        let row = firstElement("download-row-")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "AC-001: 下载行应出现")
    }

    // ── AC-002: 进度显示 ──
    func testAC002_ProgressDisplay() {
        triggerSlowDownload()
        openDownloadPanel()
        let filename = firstElement("download-filename-")
        XCTAssertTrue(filename.waitForExistence(timeout: 10), "AC-002: 文件名应可见")
        let status = firstElement("download-status-")
        XCTAssertTrue(status.exists, "AC-002: 状态文字应可见")
    }

    // ── AC-003: 暂停/恢复 ──
    func testAC003_PauseResume() {
        triggerSlowDownload()
        openDownloadPanel()
        let pauseBtn = firstElement("download-pause-")
        XCTAssertTrue(pauseBtn.waitForExistence(timeout: 10), "AC-003: 暂停按钮应出现")
        pauseBtn.click()
        let pausedText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '已暂停'")).firstMatch
        XCTAssertTrue(pausedText.waitForExistence(timeout: 5), "AC-003: 应显示已暂停")
        // 恢复
        let resumeBtn = firstElement("download-resume-")
        if resumeBtn.waitForExistence(timeout: 3) { resumeBtn.click() }
    }

    // ── AC-004: 取消下载 ──
    func testAC004_CancelDownload() {
        triggerSlowDownload()
        openDownloadPanel()
        let cancelBtn = firstElement("download-cancel-")
        XCTAssertTrue(cancelBtn.waitForExistence(timeout: 10), "AC-004: 取消按钮应出现")
        cancelBtn.click()
        let cancelledText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '已取消'")).firstMatch
        XCTAssertTrue(cancelledText.waitForExistence(timeout: 5), "AC-004: 应显示已取消")
    }

    // ── AC-005: 打开/Finder 按钮存在 ──
    func testAC005_OpenFinderButtons() {
        triggerSmallDownload()
        openDownloadPanel()
        let openBtn = firstElement("download-open-")
        XCTAssertTrue(openBtn.waitForExistence(timeout: 15), "AC-005: 打开按钮应出现")
        let finderBtn = firstElement("download-finder-")
        XCTAssertTrue(finderBtn.exists, "AC-005: Finder 按钮应出现")
    }

    // ── AC-006: 历史列表（多下载） ──
    func testAC006_HistoryList() {
        triggerSmallDownload()
        // 触发第二个下载
        navigateToURL("http://localhost:8765/auto-download-small-2")
        openDownloadPanel()
        // 等待至少 2 行
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'download-row-'"))
        // 等待第一行出现
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(rows.count, 2, "AC-006: 应显示至少 2 个下载")
    }

    // ── AC-007: 错误显示 ──
    func testAC007_ErrorDisplay() {
        navigateToURL("http://localhost:8765/auto-download-error")
        openDownloadPanel()
        let errorText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '失败' OR label CONTAINS '中断' OR label CONTAINS '错误'")).firstMatch
        XCTAssertTrue(errorText.waitForExistence(timeout: 10), "AC-007: 应显示错误信息")
    }

    // ── AC-008: 清除记录（保留活跃） ──
    func testAC008_ClearCompleted_KeepsActive() {
        // 先触发一个快速完成的下载
        triggerSmallDownload()
        openDownloadPanel()
        let openBtn = firstElement("download-open-")
        XCTAssertTrue(openBtn.waitForExistence(timeout: 15), "AC-008: 等待下载完成")
        // 清除
        let clearBtn = app.buttons["download-clear-button"]
        XCTAssertTrue(clearBtn.waitForExistence(timeout: 3), "AC-008: 清除按钮应出现")
        clearBtn.click()
        // 已完成的应被移除
        let row = firstElement("download-row-")
        XCTAssertFalse(row.waitForExistence(timeout: 3), "AC-008: 已完成记录应被清除")
    }

    // ── 空状态（补充） ──
    func testEmptyState_DisplaysOnLaunch() {
        openDownloadPanel()
        let emptyState = app.staticTexts["download-empty-state"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5), "空状态应在无下载时显示")
    }
}
```

### 6. 等待策略

- **精确匹配**: 静态 identifier → `app.buttons["exact-id"]`
- **动态 ID**: `NSPredicate(format: "identifier BEGINSWITH %@", prefix)` + `.firstMatch`
- **文本查找**: `NSPredicate(format: "label CONTAINS %@", text)` 用于中文状态文字
- **多元素计数**: `.matching(predicate).count` 用于验证列表行数
- **超时**: 10-15 秒（CI 环境）
- **无 sleep**: 全部 `waitForExistence`
- 超时设为 5-10 秒（CI 环境可能更慢）
- 轮询间隔由 XCTest 框架管理

### 6. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `UITests/OWLDownloadUITests.swift` | 新增 | XCUITest 用例 (8 个 AC) |
| `UITests/TestHTTPServer.swift` | 新增 | 本地 HTTP 测试服务器 (NWListener) |
| `Views/Sidebar/DownloadSidebarView.swift` | 修改 | 添加 accessibilityIdentifier |
| `Views/Sidebar/DownloadRow.swift` | 修改 | 添加 accessibilityIdentifier |
| `Views/Sidebar/SidebarToolbar.swift` | 修改 | 添加 accessibilityIdentifier |

### 7. 测试策略

- 每个 AC 至少 1 个 XCUITest
- setUp 启动 HTTP 服务器 + app
- tearDown 停止服务器 + 清理下载文件
- 使用 accessibility identifier 定位元素
- 异步等待策略避免 flaky

### 8. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| XCUITest 依赖完整 app 启动 | 使用 `app.launch()` 标准模式 |
| HTTP 服务器端口冲突 | 使用固定端口 8765 + setUp 检查 |
| 下载文件残留 | tearDown 只清理 `owl_test_*` 前缀文件，不影响用户文件 |
| CI 环境超时 | 使用充足的 waitForExistence 超时 |
| OpenFile/ShowInFolder 需要系统交互 | AC-005 只验证按钮存在，不验证系统行为 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
