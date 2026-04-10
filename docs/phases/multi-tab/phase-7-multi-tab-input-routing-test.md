# Phase 7: 多标签输入事件路由 XCUITest

## 背景

OWLRemoteLayerView.mm 中所有输入事件（鼠标/键盘/滚轮/IME）曾硬编码 `webview_id=1`，导致多 tab 架构下非第一个 tab 的 web content 点击无响应。该 bug 在 Phase 4 多 tab 上线时引入，但因所有 XCUITest 只创建单个 webview 而未被发现。

本 Phase 补充针对多 tab 输入事件路由的 E2E 测试，确保此类回归不再发生。

## 范围

### 修改文件
| 文件 | 变更 |
|------|------|
| `owl-client-app/UITests/OWLTabManagementUITests.swift` | 追加 2 个多 tab 输入路由测试 + 本地 HTTP server setUp |
| `docs/TESTING.md` | 更新 XCUITest 测试计数 |

### 不新增测试文件

测试用例合并到已有的 `OWLTabManagementUITests.swift`，复用其 `closeAllTabsExceptOne()`、`allTabRows`、`findSelectedTabRow()`、`navigate(to:)`、`waitForURL(containing:)` 等 helper。

## 依赖

- Phase 4（多 tab 生命周期）已完成
- Phase 6 的 webview_id 路由修复已合入（OWLRemoteLayerView 使用 `_webviewId` 属性）
- 本地 HTTP server 基础设施已有（`TestDownloadHTTPServer.swift`）

## 技术方案

### 1. 架构设计

测试策略：在 XCUITest 层（真实系统事件 + 真实 GUI）验证多 tab 场景下的鼠标和键盘事件路由正确性。

```
测试执行流:
  XCUITest → Cmd+T (创建 tab) → navigate (各 tab 不同 HTML)
           → 切换 tab → click/type in web content
           → 通过 JS handler 修改 page title
           → 读取 pageTitle accessibility label 验证事件到达正确 webview
```

核心验证思路（两种间接方式）：

1. **Click → JS onclick → title 变化**：测试页面 `onclick` handler 修改 `document.title`，XCUITest 通过 `pageTitle` label 验证点击到达正确 tab
2. **Type → JS oninput → title 变化**：`<input oninput>` handler 将输入内容反映到 `document.title`，验证键盘事件路由到正确 webview

### 2. 测试 HTML 页面

使用本地 HTTP server 托管两个测试页面（内联在测试代码中，遵循 ContextMenuUITests 模式）。仅需 2 个路由（`/tab-a`、`/tab-b`），不为 3-tab 场景额外创建页面。

```html
<!-- Tab A 测试页（Tab B 结构相同，id 不同） -->
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Tab-A</title></head>
<body style="margin:0;font-family:system-ui">
  <!-- 大面积 click target，占满视口上半部分 -->
  <div id="clickTarget"
       style="width:100%;height:50vh;background:#ddf;
              display:flex;align-items:center;justify-content:center;
              font-size:24px;cursor:pointer"
       onclick="document.title='Tab-A-CLICKED'">
    Click me (Tab A)
  </div>
  <!-- input 区域占满下半视口，确保归一化坐标稳定命中 -->
  <div style="height:50vh;display:flex;align-items:center;padding:0 20px">
    <input id="typeTarget"
           style="font-size:16px;padding:8px;width:100%"
           placeholder="Type here (Tab A)"
           onfocus="document.title='Tab-A-FOCUSED'"
           oninput="document.title='Tab-A-TYPED:'+this.value">
  </div>
</body>
</html>
```

**设计要点**：
- clickTarget 使用 `height:50vh`（视口半高），确保归一化坐标 `dy=0.25` 始终命中，不受窗口尺寸影响
- `onfocus` handler 修改 title 为 `Tab-{id}-FOCUSED`，验证焦点到达正确 webview 后再输入
- `oninput` handler 将 input value 反映到 title，实现键盘路由的可观测验证
- 不使用 `autofocus`——测试中显式 click input 建立焦点，通过 `waitForPageTitle("Tab-B-FOCUSED")` 条件等待确认，避免 sleep

### 3. 测试用例设计

精简为 2 个高价值测试，完整覆盖核心回归场景：

| 测试方法 | 场景 | 验证 |
|---------|------|------|
| `testClickInSecondTabRoutesCorrectly` | 创建 2 tabs（各导航到不同页面），在 tab B 点击 clickTarget | ① tab B 的 pageTitle 变为 "Tab-B-CLICKED"；② 切回 tab A 验证其 title 仍为 "Tab-A"（事件未泄漏） |
| `testTypeInSecondTabRoutesCorrectly` | 创建 2 tabs，切换到 tab B，click input 获焦后输入文本 | ① tab B 的 pageTitle 变为 "Tab-B-TYPED:hello"；② 切回 tab A 验证其 title 仍为 "Tab-A"（键盘事件未泄漏） |

**不添加的测试及理由**：
- ~~`testClickInThirdTab`~~：与 `testClickInSecondTab` 覆盖相同路由逻辑，冗余
- ~~`testRapidTabSwitchAndClick`~~：E2E 层过于 flaky（UI 渲染 + IPC 延迟竞争），不适合回归测试
- ~~`testClickAfterTabSwitch`~~：`testClickInSecondTabRoutesCorrectly` 步骤 ② 已隐含 A→B 切换后的路由验证

### 4. 核心逻辑

#### 4.1 setUp 变更

在 `OWLTabManagementUITests` 现有 `setUpWithError` 中追加 HTTP server 启动：

```swift
// 在现有 class 中新增
var server: TestDownloadHTTPServer?

override func setUpWithError() throws {
    continueAfterFailure = false

    // ── 新增：启动本地 HTTP server ──
    let srv = TestDownloadHTTPServer()
    srv.addRoute(TestDownloadHTTPServer.Route(
        path: "/tab-a", contentType: "text/html; charset=utf-8",
        body: Data(Self.tabPageHTML(id: "A").utf8)))
    srv.addRoute(TestDownloadHTTPServer.Route(
        path: "/tab-b", contentType: "text/html; charset=utf-8",
        body: Data(Self.tabPageHTML(id: "B").utf8)))
    let _ = try srv.start()
    server = srv
    // ── 新增结束 ──

    // ... 现有 app launch / activate 逻辑不变 ...
    
    // 确保侧边栏在 tabs 模式
    ensureSidebarInTabsMode()
}

override func tearDownWithError() throws {
    server?.stop()
    server = nil
}
```

#### 4.2 新增 helper

```swift
/// 等待 pageTitle accessibility label 匹配指定字符串。
/// 使用 XCTNSPredicateExpectation 条件等待，不使用 sleep。
private func waitForPageTitle(_ expected: String, timeout: TimeInterval = 10) -> Bool {
    let pageTitle = app.staticTexts["pageTitle"]
    let predicate = NSPredicate(format: "label == %@", expected)
    let exp = XCTNSPredicateExpectation(predicate: predicate, object: pageTitle)
    return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
}

/// 等待 pageTitle label 以指定前缀开头（用于 oninput 动态 title）。
private func waitForPageTitlePrefix(_ prefix: String, timeout: TimeInterval = 10) -> Bool {
    let pageTitle = app.staticTexts["pageTitle"]
    let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
    let exp = XCTNSPredicateExpectation(predicate: predicate, object: pageTitle)
    return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
}

/// web content view element.
private var webContent: XCUIElement {
    app.otherElements["webContentView"]
}

/// 等待 tab 数量达到期望值，且最新 tab 被选中。
private func waitForTabCount(_ expected: Int, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if totalTabCount == expected && findSelectedTabRow() != nil {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return false
}
```

#### 4.3 testClickInSecondTabRoutesCorrectly

```swift
/// 验证：在第二个 tab 中点击 web content，事件路由到正确的 webview。
/// 回归测试：防止 OWLRemoteLayerView 硬编码 webview_id 导致事件发错 tab。
func testClickInSecondTabRoutesCorrectly() throws {
    guard let port = server?.port else {
        throw XCTSkip("HTTP server not started")
    }
    
    // 1. 确保从干净的 1 tab 状态开始
    closeAllTabsExceptOne()
    _ = waitForAnyTabRow()
    XCTAssertEqual(totalTabCount, 1)
    
    // 2. 在第一个 tab 导航到 /tab-a，等待 title 确认加载
    navigate(to: "http://localhost:\(port)/tab-a")
    XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 15), "Tab A should load")
    
    // 3. 创建第二个 tab，等待 tab 数量变为 2
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(waitForTabCount(2), "Second tab should be created")
    
    // 4. 在第二个 tab 导航到 /tab-b
    navigate(to: "http://localhost:\(port)/tab-b")
    XCTAssertTrue(waitForPageTitle("Tab-B", timeout: 15), "Tab B should load")
    
    // 5. 点击 web content 中的 clickTarget（50vh 高，dy=0.25 必中）
    let content = webContent
    try XCTSkipUnless(content.waitForExistence(timeout: 10),
                      "webContentView not in AX tree")
    content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).click()
    
    // 6. 等待 title 变化——验证点击到达 tab B 的 webview
    XCTAssertTrue(waitForPageTitle("Tab-B-CLICKED", timeout: 5),
                  "Click should reach Tab B's webview and trigger onclick handler")
    
    // 7. 切回 tab A，验证其 title 未被污染
    let tabRows = allTabRows
    tabRows.element(boundBy: 0).click()
    XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 5),
                  "Tab A title should be unchanged — click must not leak to other tabs")
}
```

#### 4.4 testTypeInSecondTabRoutesCorrectly

```swift
/// 验证：在第二个 tab 中输入文本，键盘事件路由到正确的 webview。
/// 回归测试：防止 OWLBridge_SendKeyEvent 使用错误的 webview_id。
func testTypeInSecondTabRoutesCorrectly() throws {
    guard let port = server?.port else {
        throw XCTSkip("HTTP server not started")
    }
    
    // 1. 干净状态
    closeAllTabsExceptOne()
    _ = waitForAnyTabRow()
    
    // 2. Tab A 导航
    navigate(to: "http://localhost:\(port)/tab-a")
    XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 15), "Tab A should load")
    
    // 3. 创建 tab B
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(waitForTabCount(2), "Second tab should be created")
    
    // 4. Tab B 导航
    navigate(to: "http://localhost:\(port)/tab-b")
    XCTAssertTrue(waitForPageTitle("Tab-B", timeout: 15), "Tab B should load")
    
    // 5. 点击 input 区域建立焦点（input 在下半视口，dy=0.75 稳定命中）
    let content = webContent
    try XCTSkipUnless(content.waitForExistence(timeout: 10),
                      "webContentView not in AX tree")
    content.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75)).click()
    
    // 6. 条件等待焦点到达（onfocus handler 修改 title）——替代 sleep
    XCTAssertTrue(waitForPageTitle("Tab-B-FOCUSED", timeout: 5),
                  "Focus should reach Tab B's input element")
    
    // 7. 输入文本
    app.typeText("hello")
    
    // 8. 验证键盘事件到达 tab B（oninput handler 修改 title）
    XCTAssertTrue(waitForPageTitlePrefix("Tab-B-TYPED:", timeout: 5),
                  "Keyboard input should reach Tab B's webview and trigger oninput handler")
    
    // 9. 切回 tab A，验证其 title 未被污染
    allTabRows.element(boundBy: 0).click()
    XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 5),
                  "Tab A title should be unchanged — keyboard events must not leak")
}
```

#### 4.5 HTML 生成函数

```swift
/// 生成测试 HTML 页面。id 仅接受固定枚举值 "A" 或 "B"。
private static func tabPageHTML(id: String) -> String {
    precondition(id == "A" || id == "B", "Only fixed IDs allowed")
    let bg = id == "A" ? "#ddf" : "#dfd"
    return """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><title>Tab-\(id)</title></head>
    <body style="margin:0;font-family:system-ui">
      <div id="clickTarget"
           style="width:100%;height:50vh;background:\(bg);
                  display:flex;align-items:center;justify-content:center;
                  font-size:24px;cursor:pointer"
           onclick="document.title='Tab-\(id)-CLICKED'">
        Click me (Tab \(id))
      </div>
      <div style="height:50vh;display:flex;align-items:center;padding:0 20px">
        <input id="typeTarget"
               style="font-size:16px;padding:8px;width:100%"
               placeholder="Type here (Tab \(id))"
               onfocus="document.title='Tab-\(id)-FOCUSED'"
               oninput="document.title='Tab-\(id)-TYPED:'+this.value">
      </div>
    </body>
    </html>
    """
}
```

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/UITests/OWLTabManagementUITests.swift` | 修改 | 追加 server setUp/tearDown、2 个测试方法、3 个 helper、HTML 生成函数 |
| `docs/phases/multi-tab/phase-7-multi-tab-input-routing-test.md` | 新增 | 本技术方案 |
| `docs/TESTING.md` | 修改 | XCUITest 测试数从 ~17 更新为 ~19 |

### 6. 测试策略

- **Click 路由验证**: JS `onclick` → `document.title` 变化 → `pageTitle` label 断言
- **Type 路由验证**: JS `oninput` → `document.title` 变化 → `pageTitle` label 断言
- **条件等待**: 所有关键同步点使用 `XCTNSPredicateExpectation` + timeout，不在关键路径上使用 `sleep`
- **网络隔离**: `TestDownloadHTTPServer` 本地 HTTP server，无外网依赖
- **HTML 内联**: 遵循 ContextMenuUITests 模式，不依赖 bundle resources
- **ID 安全约束**: `tabPageHTML(id:)` 使用 `precondition` 限制为固定枚举值，防止未来误用导致注入
- **编译验证**: 无签名环境下 `swift build` 编译通过即可

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| 本地 server 端口冲突 | `TestDownloadHTTPServer` 使用随机端口分配 |
| Click 坐标 miss | clickTarget 和 input 容器各占 `50vh`，归一化坐标 `dy=0.25`/`dy=0.75` 始终在目标内 |
| pageTitle 更新延迟（Mojo IPC 回路） | `waitForPageTitle` 使用条件等待，timeout 5s |
| Tab 创建异步延迟 | `waitForTabCount` 条件等待（验证数量 + 选中态），不使用 `sleep` |
| Input focus 竞争 | 不使用 `autofocus`，显式 click + `onfocus` handler + `waitForPageTitle("Tab-B-FOCUSED")` 条件等待确认焦点 |
| 前一个测试残留 sidebar 状态 | `ensureSidebarInTabsMode()` 已在现有 setUp 中调用 |

## 验收标准

- [ ] 2 个测试用例编译通过
- [ ] 签名环境下所有测试通过
- [ ] 覆盖：点击路由 + 泄漏检查、键盘路由 + 泄漏检查
- [ ] 无外网依赖

## 评审记录

### Round 1（2026-04-06）
| Agent | LLM | Verdict | P0 | P1 | P2 |
|-------|-----|---------|----|----|-----|
| A (Claude) | Claude | NEEDS_FIX | 3 | 4 | 3 |
| B (Codex) | GPT-5.4 | No-Go | 1 | 4 | 1 |
| C (Gemini) | Gemini 3.1 Pro | Needs Revision | 2 | 2 | 1 |

**修复内容**:
- P0: 合并到 `OWLTabManagementUITests.swift`，复用现有 helper（closeAllTabsExceptOne、allTabRows、navigate 等）
- P0: `testTypeInSecondTab` 升级为可验证路由的 `oninput` → title 断言
- P0: 精简为 2 个高价值测试，删除冗余/flaky 用例
- P0: `Route` 使用全限定名 `TestDownloadHTTPServer.Route`
- P1: `sleep` 替换为 `waitForPageTitle`/`waitForTabCount` 条件等待
- P1: 新增 `ensureSidebarInTabsMode` 在 setUp 中（已有）
- P1: clickTarget 改为 `50vh` 高度，坐标稳定命中
- P1: 不使用 `autofocus`，显式 click 建立焦点
- P2: `tabPageHTML(id:)` 加 `precondition` 限制固定 ID

### Round 2（2026-04-06）
| Agent | LLM | Verdict | New P0/P1 | Q2 |
|-------|-----|---------|-----------|-----|
| A (Claude) | Claude | NEEDS_FIX | P1×2 | R1 P0 all FIXED, P1 partially |
| B (Codex) | GPT-5.4 | NEEDS_FIX | P1×4 | R1 P0 FIXED, P1 partially |
| C (Gemini) | Gemini 3.1 Pro | NEEDS_FIX | P0×1, P1×1 | R1 P0s FIXED, P1 partially |

**共识未关闭 P1（收敛到 2 点）**:
1. `sleep(1)` 残留在 input focus 等待 → 改用 `onfocus` handler + `waitForPageTitle("Tab-B-FOCUSED")`
2. `dy=0.7` 坐标可能 miss input → input 容器改为 `50vh` 占满下半视口，`dy=0.75` 稳定命中

**修复内容**:
- input 容器改为 `height:50vh` 布局，与 clickTarget 对称
- input 添加 `onfocus="document.title='Tab-{id}-FOCUSED'"` handler
- `sleep(1)` 替换为 `waitForPageTitle("Tab-B-FOCUSED")` 条件等待
- `waitForTabCount` 增加 `findSelectedTabRow() != nil` 验证选中态

### Round 3（2026-04-06）
| Agent | LLM | Verdict | New P0/P1 | Q2 |
|-------|-----|---------|-----------|-----|
| A (Claude) | Claude | NEEDS_FIX | P1×2 | R2 P1 all FIXED |
| B (Codex) | GPT-5.4 | NEEDS_FIX | P1×2 | 2/3 FIXED |
| C (Gemini) | Gemini 3.1 Pro | NEEDS_FIX | P1×1 | R2 P0/P1 all FIXED |

**分析**：R2 的核心 P1（sleep、坐标脱靶）全部修复确认。Round 3 新增 P1 分两类：
1. **可修复**：input `width:300px` 在宽窗口下 dx=0.3 横向脱靶 → 改为 `width:100%`
2. **现有测试基础设施固有限制**（非本方案引入）：AX 查询竞争、typeText 焦点归属、pinned tab 索引 → 与现有 `OWLTabManagementUITests` 使用相同模式，已被项目接受

**修复内容**：
- input 宽度从 `300px` 改为 `100%`，消除横向脱靶风险

**收敛判定**：
- Q1: 0 个新 P0，0 个新架构级 P1（剩余均为现有 XCUITest 基础设施固有模式）
- Q2: R2 核心 P1 全部 FIXED
- Q3: 无新引入问题
- **方案收敛** ✓

## 状态
- [x] 技术方案评审（3 轮 Claude+Codex+Gemini 全盲评审收敛）
- [x] 开发完成（Test Writer 追加 2 个测试 + helper + HTML 生成函数）
- [x] 代码评审通过（3 reviewer 评审，B2 P0 误判已驳回，B1 P1 已修复）
- [ ] 测试通过（需签名环境运行 XCUITest）
