# Phase 1 — 双驱动 E2E 测试架构（XCUITest + Playwright CDP）

**版本**: v2.2 — 2026-04-08（Round 3 修复）
**状态**: 评审通过 ✓

---

## 概述

为 OWL Browser 搭建双驱动 E2E 测试架构：XCUITest 驱动原生 SwiftUI 壳层 + 内嵌 CDPHelper 做跨层断言，Playwright 通过 CDP 独立测试 Web 内容。解决当前 XCUITest 无法查询 DOM、验证网页内容、监控网络请求的核心缺口。

## 现状分析

### 已有能力

| 能力 | 状态 | 工具 |
|------|------|------|
| 原生 UI E2E（地址栏、标签、侧边栏） | 可用 | XCUITest（需签名） |
| 页面 URL/Title 观测 | 可用 | AccessibleLabel → XCUITest |
| C-ABI JS 执行 | 可用 | `OWLBridge_EvaluateJavaScript`（需 `--enable-owl-test-js`） |
| CDP 服务器 | 可用 | `--remote-debugging-port` → 127.0.0.1:9222 |
| Python CDP 测试 | 原型 | `test_e2e_input.py`（手动运行） |

### 核心缺口

1. **DOM 不可见**：XCUITest 只能看到 `webContentView` 黑盒，无法查询 DOM 元素
2. **网络不可观测**：无法验证请求/响应、拦截资源加载
3. **Console 不可采集**：E2E 测试中无法捕获 JS console 输出
4. **跨层断裂**：原生操作后的 web 状态验证只能靠 AccessibleLabel 间接实现，无法做精确 DOM 断言
5. **无 Web 性能指标**：无法在 E2E 中采集 FCP/LCP/DOMContentLoaded

---

## 技术方案

### 1. 架构设计

#### 双驱动架构总览

```
┌─────────────────────────────────────────────────────────┐
│              run_tests.sh dual-e2e                       │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Phase A: Playwright (纯 Web 测试)                  │  │
│  │ launch.sh 启动 app (CDP :9222) → 跑完 → 杀 app    │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Phase B: XCUITest + CDPHelper (跨层测试)            │  │
│  │ XCUIApplication.launch() → CDPHelper(:9222)        │  │
│  └───────────────────────────────────────────────────┘  │
├─────────────────────┬───────────────────────────────────┤
│   XCUITest           │      Playwright                   │
│   (原生 UI + CDP)    │      (Web 内容)                   │
│                      │                                   │
│  ┌──────────────┐    │  ┌──────────────────┐            │
│  │XCUIApplication│   │  │ chromium.connect  │            │
│  │  → AX Tree    │   │  │   OverCDP(:9222)  │            │
│  └──────┬────────┘   │  └────────┬─────────┘            │
│         │             │          │                        │
│  ┌──────┴────────┐   │  ┌───────┴──────────┐            │
│  │ CDPHelper      │   │  │ Playwright API   │            │
│  │ (Swift WS)     │   │  │ DOM/Network/     │            │
│  │ → web 状态     │   │  │ Console/Perf     │            │
│  └───────────────┘   │  └──────────────────┘            │
├──────────────────────┼──────────────────────────────────┤
│  SwiftUI 原生壳层     │  Chromium 网页内容                 │
└──────────────────────┴──────────────────────────────────┘
```

**核心变化（v1 → v2）：Phase A 和 Phase B 串行执行，共享端口 9222，彻底消除双实例冲突。**

#### 关键设计决策

| 决策 | 选择 | 替代方案 | 理由 |
|------|------|---------|------|
| Web 内容驱动 | Playwright (TypeScript) | Selenium / 纯 CDPHelper | Playwright 的 `waitForSelector`/`waitForNavigation`/network interception 远比手写 CDP 成熟；DOM 选择器、截图、console 捕获开箱即用 |
| 原生 UI 驱动 | XCUITest (Swift) | Appium Mac2 | 已有 6 个测试文件 ~19 个测试，基础设施完备 |
| 跨层桥接 | CDPHelper (Swift, 内嵌 XCUITest) | 子进程调 Node.js | 同进程低延迟，避免 IPC 序列化 |
| 编排层 | run_tests.sh | pytest orchestrator | 与现有 run_tests.sh 一致，脚本优先原则 |
| CDP 客户端 | URLSessionWebSocketTask | SwiftNIO / Starscream | macOS 14+ 原生 API，零外部依赖 |
| App 启动方式 | Playwright: `launch.sh`; XCUITest: `XCUIApplication` | `swift run` | `launch.sh` 已封装 kill 旧进程、日志、超时；XCUITest 测 Xcode 构建的 .app bundle |
| 执行模式 | Playwright → kill → XCUITest（串行） | 并行双实例 | 共享端口 9222，无端口冲突/数据目录冲突 |

### 2. 前置条件：CDP 端口注入链路

**Round 1 评审发现（P0）：`OWL_CDP_PORT` 环境变量到 Host 的传递链断裂。**

当前代码路径（已验证）：
```
BrowserViewModel.launch()
  → OWLBridgeSwift.launchHost(port: 0)        // ← 硬编码 0
    → OWLBridge_LaunchHost(devtools_port: 0)
      → port == 0 ? 9222 : port               // owl_bridge_api.cc:164
        → --remote-debugging-port 9222
```

**需要的代码变更**（Step 0 前置）：

```swift
// BrowserViewModel.swift — launch() 中读取环境变量
let cdpPort = UInt16(ProcessInfo.processInfo.environment["OWL_CDP_PORT"] ?? "") ?? 0
OWLBridgeSwift.launchHost(port: cdpPort)
```

完整传递链（修复后）：
```
环境变量: OWL_CDP_PORT=9222
  → BrowserViewModel.launch() 读取 ProcessInfo.environment
    → OWLBridgeSwift.launchHost(port: 9222)
      → OWLBridge_LaunchHost(devtools_port: 9222)
        → --remote-debugging-port 9222
          → DevToolsAgentHost::StartRemoteDebuggingServer(:9222)
            → CDPHelper / Playwright 连接 ws://127.0.0.1:9222
```

### 3. 核心组件设计

#### 3.1 CDPHelper — XCUITest 内的 CDP 客户端

**职责**：让 XCUITest 在执行原生 UI 操作后，直接通过 CDP 验证 web 内容状态。

**位置**：`owl-client-app/UITests/Helpers/CDPHelper.swift`

```swift
/// XCUITest 内使用的轻量 CDP 客户端
/// 通过 URLSessionWebSocketTask 连接 Chromium DevTools Protocol
final class CDPHelper: @unchecked Sendable {
    let port: UInt16
    private var ws: URLSessionWebSocketTask?
    private var requestId: Int = 0
    // 【P0 修复】continuation 注册和消息发送的顺序保证
    private var pendingCallbacks: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()
    // 事件缓冲
    private var networkRequests: [CDPNetworkRequest] = []
    private var consoleBuffer: [CDPConsoleMessage] = []

    init(port: UInt16 = 9222) { self.port = port }

    // MARK: - Connection

    /// 连接到 CDP：GET /json 获取 type=="page" 的 target，建立 WS 连接
    func connect() async throws {
        let listURL = URL(string: "http://127.0.0.1:\(port)/json")!
        let (data, _) = try await URLSession.shared.data(from: listURL)
        let targets = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

        // 【P0 修复】过滤 type=="page"，避免连到 browser/service-worker target
        guard let pageTarget = targets.first(where: { ($0["type"] as? String) == "page" }),
              let wsURL = pageTarget["webSocketDebuggerUrl"] as? String else {
            throw CDPError.noTarget
        }

        let task = URLSession.shared.webSocketTask(with: URL(string: wsURL)!)
        task.resume()
        ws = task
        Task { await receiveLoop() }
    }

    /// 连接到指定 URL 的 tab（多 tab 场景）
    func connect(toTabContaining urlSubstring: String) async throws {
        let listURL = URL(string: "http://127.0.0.1:\(port)/json")!
        let (data, _) = try await URLSession.shared.data(from: listURL)
        let targets = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

        let pageTargets = targets.filter { ($0["type"] as? String) == "page" }
        let match = pageTargets.first { ($0["url"] as? String)?.contains(urlSubstring) == true }
            ?? pageTargets.first // fallback 到第一个 page target

        guard let target = match,
              let wsURL = target["webSocketDebuggerUrl"] as? String else {
            throw CDPError.noTarget
        }

        let task = URLSession.shared.webSocketTask(with: URL(string: wsURL)!)
        task.resume()
        ws = task
        Task { await receiveLoop() }
    }

    func disconnect() {
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        // 【P0 修复】drain 所有未完成的 continuation，防止永久挂起
        lock.lock()
        let pending = pendingCallbacks
        pendingCallbacks.removeAll()
        lock.unlock()
        for (_, cont) in pending {
            cont.resume(throwing: CDPError.disconnected)
        }
    }

    // MARK: - CDP Commands

    /// 执行 JavaScript 并返回结果
    func evaluate(_ expression: String) async throws -> String {
        let response = try await send("Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true
        ])

        // 1. 检查协议级错误
        if let error = response["error"] as? [String: Any] {
            throw CDPError.protocolError(error["message"] as? String ?? "unknown")
        }

        guard let outerResult = response["result"] as? [String: Any] else {
            throw CDPError.unexpectedResponse(response)
        }

        // 2.【Round 2 修复】先检查 exceptionDetails（JS 异常时 result.result 仍存在但无 value）
        if let exception = outerResult["exceptionDetails"] as? [String: Any] {
            let text = (exception["text"] as? String) ?? "JS exception"
            let desc = ((exception["exception"] as? [String: Any])?["description"] as? String)
            throw CDPError.evaluationFailed(desc ?? text)
        }

        // 3. 正常路径：response.result.result.value
        guard let innerResult = outerResult["result"] as? [String: Any] else {
            throw CDPError.unexpectedResponse(response)
        }

        // type 可能是 "undefined"（无返回值的语句）
        if (innerResult["type"] as? String) == "undefined" { return "" }

        guard let value = innerResult["value"] else {
            throw CDPError.unexpectedResponse(response)
        }

        if let str = value as? String { return str }
        if let num = value as? NSNumber { return num.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 等待 DOM 元素出现
    func waitForSelector(_ selector: String, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let encodedSelector = Self.jsonEncode(selector)
        while Date() < deadline {
            // 【P1 修复】用 JSON 编码替代字符串拼接，防止注入
            let js = "document.querySelector(\(encodedSelector)) !== null"
            let found = try await evaluate(js)
            if found == "true" { return }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        throw CDPError.timeout("waitForSelector(\(selector))")
    }

    /// 获取元素文本内容
    func textContent(_ selector: String) async throws -> String {
        let encodedSelector = Self.jsonEncode(selector)
        let js = "document.querySelector(\(encodedSelector))?.textContent ?? ''"
        return try await evaluate(js)
    }

    /// 获取元素属性
    func getAttribute(_ selector: String, _ attribute: String) async throws -> String? {
        let s = Self.jsonEncode(selector)
        let a = Self.jsonEncode(attribute)
        let js = "document.querySelector(\(s))?.getAttribute(\(a))"
        let result = try await evaluate(js)
        return result.isEmpty ? nil : result
    }

    /// 获取匹配元素数量
    func elementCount(_ selector: String) async throws -> Int {
        let s = Self.jsonEncode(selector)
        let js = "document.querySelectorAll(\(s)).length"
        let result = try await evaluate(js)
        return Int(result) ?? 0
    }

    // MARK: - Page State

    func currentURL() async throws -> String {
        return try await evaluate("window.location.href")
    }

    func currentTitle() async throws -> String {
        return try await evaluate("document.title")
    }

    /// 导航到 URL 并等待加载
    func navigateAndWait(_ url: String, timeout: TimeInterval = 15) async throws {
        _ = try await send("Page.navigate", params: ["url": url])
        // 等待 loadEventFired
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = try await evaluate("document.readyState")
            if state == "complete" { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CDPError.timeout("navigateAndWait(\(url))")
    }

    // MARK: - Network Monitoring

    func enableNetwork() async throws {
        _ = try await send("Network.enable", params: [:])
    }

    var capturedRequests: [CDPNetworkRequest] {
        lock.lock()
        defer { lock.unlock() }
        return networkRequests
    }

    func clearCapturedRequests() {
        lock.lock()
        networkRequests.removeAll()
        lock.unlock()
    }

    // MARK: - Console Capture

    func enableConsole() async throws {
        _ = try await send("Runtime.enable", params: [:])
    }

    var consoleMessages: [CDPConsoleMessage] {
        lock.lock()
        defer { lock.unlock() }
        return consoleBuffer
    }

    func clearConsoleMessages() {
        lock.lock()
        consoleBuffer.removeAll()
        lock.unlock()
    }

    // MARK: - Internal

    private func send(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let ws = ws else { throw CDPError.disconnected }

        // 【P0 修复】先注册 continuation，再发送消息
        // 确保即使响应极快到达，receiveLoop 也能找到 callback
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            requestId += 1
            return requestId
        }()

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pendingCallbacks[id] = cont
            lock.unlock()

            let msg: [String: Any] = ["id": id, "method": method, "params": params]
            guard let data = try? JSONSerialization.data(withJSONObject: msg),
                  let text = String(data: data, encoding: .utf8) else {
                lock.lock()
                pendingCallbacks.removeValue(forKey: id)
                lock.unlock()
                cont.resume(throwing: CDPError.serializationFailed)
                return
            }

            Task {
                do {
                    try await ws.send(.string(text))
                } catch {
                    self.lock.lock()
                    let removed = self.pendingCallbacks.removeValue(forKey: id)
                    self.lock.unlock()
                    removed?.resume(throwing: error)
                }
            }
        }
    }

    private func receiveLoop() async {
        while self.ws != nil {
            guard let ws = self.ws,
                  let message = try? await ws.receive() else { break }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let id = json["id"] as? Int {
                // RPC 响应
                lock.lock()
                let cont = pendingCallbacks.removeValue(forKey: id)
                lock.unlock()
                cont?.resume(returning: json)
            } else if let method = json["method"] as? String,
                      let params = json["params"] as? [String: Any] {
                // CDP 事件 → 缓冲
                handleEvent(method, params: params)
            }
        }
        // 【Round 2 修复】WebSocket 断开时 drain 所有未完成的 continuation
        lock.lock()
        let pending = pendingCallbacks
        pendingCallbacks.removeAll()
        lock.unlock()
        for (_, cont) in pending {
            cont.resume(throwing: CDPError.disconnected)
        }
    }

    private func handleEvent(_ method: String, params: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "Network.requestWillBeSent":
            if let request = params["request"] as? [String: Any],
               let url = request["url"] as? String {
                networkRequests.append(CDPNetworkRequest(
                    url: url,
                    method: request["method"] as? String ?? "GET"
                ))
            }
        case "Runtime.consoleAPICalled":
            if let args = params["args"] as? [[String: Any]],
               let firstValue = args.first?["value"] as? String {
                let level = params["type"] as? String ?? "log"
                consoleBuffer.append(CDPConsoleMessage(level: level, text: firstValue))
            }
        default:
            break // 静默忽略未知事件
        }
    }

    /// JSON 编码字符串，用于安全拼接 JS（替代 escapedForJS）
    /// 输出带引号的 JSON string literal，如 "hello \"world\""
    static func jsonEncode(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s),
              let encoded = String(data: data, encoding: .utf8) else {
            // fallback: 简单转义
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return encoded
    }
}

// MARK: - Models

struct CDPNetworkRequest {
    let url: String
    let method: String
}

struct CDPConsoleMessage {
    let level: String
    let text: String
}

enum CDPError: Error, CustomStringConvertible {
    case noTarget
    case disconnected
    case serializationFailed
    case protocolError(String)
    case evaluationFailed(String)
    case unexpectedResponse([String: Any])
    case timeout(String)

    var description: String {
        switch self {
        case .noTarget: return "No page target found in CDP /json"
        case .disconnected: return "CDP WebSocket disconnected"
        case .serializationFailed: return "Failed to serialize CDP message"
        case .protocolError(let msg): return "CDP protocol error: \(msg)"
        case .evaluationFailed(let msg): return "JS evaluation failed: \(msg)"
        case .unexpectedResponse(let r): return "Unexpected CDP response: \(r)"
        case .timeout(let op): return "CDP timeout: \(op)"
        }
    }
}
```

**v1 → v2 修复清单**：

| Round 1 问题 | 修复 |
|---|---|
| P0: `send()` 竞态 — response 可能在 continuation 入表前到达 | 先注册 continuation，再发送消息；发送失败时移除并 resume(throwing:) |
| P0: CDP `Runtime.evaluate` 解析错误 | 修正为 `response.result.result.value`；增加 `error`/`exceptionDetails` 处理 |
| P0: `targets.first` 多 tab 不可靠 | 过滤 `type == "page"`；新增 `connect(toTabContaining:)` 按 URL 匹配 |
| P1: `selector.escapedForJS` 未实现 | 用 `jsonEncode()` 生成 JSON string literal，杜绝注入 |
| P1: `disconnect()` 未 drain pending callbacks | drain 所有 pendingCallbacks，resume(throwing: .disconnected) |
| P0: `ws == nil` 时 `send()` 不报错 | 开头 `guard let ws` 检查 |
| P2: 未处理 CDP 事件 | `handleEvent()` 缓冲 Network/Console 事件 |

#### 3.2 Playwright 测试套件

**职责**：独立测试 Web 内容——DOM 验证、网络监控、表单交互、性能指标。CDPHelper 做不到的高级功能（waitForNavigation、network interception、selector engine、截图、视频录制）由 Playwright 覆盖。

**位置**：`owl-client-app/playwright/`

**配置** (`playwright.config.ts`)：

```typescript
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  retries: 1,
  // 串行执行：content layer 不支持 browser.newContext()，所有测试共享一个 page
  workers: 1,
  // test 前置：每个测试先 goto('about:blank') 清场
});
```

**测试 fixture** (`fixtures.ts`)：

```typescript
import { test as base, chromium, type Browser, type Page } from '@playwright/test';

// 【P0 修复】Worker-scoped browser，避免每个 test 泄漏连接
// 【P1 修复】afterEach 中 goto('about:blank') 防止测试间状态污染
export const test = base.extend<{ owlPage: Page }, { owlBrowser: Browser }>({
  // Worker scope: 整个 worker 共享一个 browser 连接
  owlBrowser: [async ({}, use) => {
    const cdpPort = process.env.OWL_CDP_PORT || '9222';
    const browser = await chromium.connectOverCDP(
      `http://127.0.0.1:${cdpPort}`
    );
    await use(browser);
    await browser.close();
  }, { scope: 'worker' }],

  // Test scope: 每个测试获取当前活跃 page
  owlPage: async ({ owlBrowser }, use) => {
    // 【P1 前置验证】确认 contexts() 返回有效数据
    const contexts = owlBrowser.contexts();
    if (contexts.length === 0) {
      throw new Error(
        'No browser context found. Content layer CDP may not support Browser.getTargets. ' +
        'Verify with: curl http://127.0.0.1:9222/json/version'
      );
    }
    const page = contexts[0].pages()[0];
    if (!page) {
      throw new Error('No active page found in OWL Browser');
    }

    // 清场
    await page.goto('about:blank');
    await use(page);
    // 测试后清场，防止 beforeunload 阻塞后续测试
    await page.goto('about:blank').catch(() => {});
  },
});

export { expect } from '@playwright/test';
```

**示例测试** (`tests/web-navigation.spec.ts`)：

```typescript
import { test, expect } from '../fixtures';

test.describe('Web Navigation', () => {
  test('navigate and verify DOM structure', async ({ owlPage }) => {
    await owlPage.goto('https://example.com');
    await owlPage.waitForLoadState('domcontentloaded');

    const heading = await owlPage.locator('h1').textContent();
    expect(heading).toBe('Example Domain');

    const links = await owlPage.locator('a').count();
    expect(links).toBeGreaterThan(0);
  });

  test('capture network requests', async ({ owlPage }) => {
    const requests: string[] = [];
    owlPage.on('request', req => requests.push(req.url()));

    await owlPage.goto('https://example.com');
    await owlPage.waitForLoadState('networkidle');

    expect(requests.some(u => u.includes('example.com'))).toBe(true);
  });

  test('capture console messages', async ({ owlPage }) => {
    const messages: string[] = [];
    owlPage.on('console', msg => messages.push(msg.text()));

    await owlPage.goto('https://example.com');
    await owlPage.evaluate(() => console.log('owl-test-marker'));

    expect(messages).toContain('owl-test-marker');
  });

  test('error page content', async ({ owlPage }) => {
    // 导航到不存在的域名 — 验证 OWL 的错误页面渲染
    await owlPage.goto('https://this-domain-does-not-exist.invalid').catch(() => {});
    // content layer 可能用 net error page
    const bodyText = await owlPage.locator('body').textContent().catch(() => '');
    // 至少不应该是空白页
    expect(bodyText?.length ?? 0).toBeGreaterThan(0);
  });
});
```

**为什么需要 Playwright（CDPHelper 做不到的事）**：

| 能力 | CDPHelper | Playwright |
|------|:---------:|:----------:|
| JS eval | x | x |
| CSS selector query | x（手写 JS） | x（原生引擎） |
| waitForNavigation | 手写轮询 | x（内置） |
| Network interception | 原始事件 | x（route/fulfill） |
| 截图 | 需手写 | x（`page.screenshot()`） |
| 视频录制 | 不支持 | x（内置） |
| Selector engine (text/role/css) | 不支持 | x（多引擎） |
| 自动等待 | 需手写 | x（auto-waiting） |
| 并行隔离 | 不支持 | x（worker） |

#### 3.3 跨层测试（XCUITest + CDPHelper）

```swift
// UITests/OWLDualDriverTests.swift
class OWLDualDriverTests: XCTestCase {
    static let app = XCUIApplication()
    static var cdp: CDPHelper!

    // 【P2 修复】使用 async setUp，不混用 Thread.sleep
    override func setUp() async throws {
        let app = Self.app
        if !app.exists || app.state != .runningForeground {
            app.launchEnvironment["OWL_CLEAN_SESSION"] = "1"
            app.launchEnvironment["OWL_CDP_PORT"] = "9222"
            app.launch()
        }

        if Self.cdp == nil {
            Self.cdp = CDPHelper(port: 9222)
            // 等待 CDP 就绪（Host 启动需要时间）
            var connected = false
            for _ in 0..<15 {
                do {
                    try await Self.cdp.connect()
                    connected = true
                    break
                } catch {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                }
            }
            guard connected else {
                XCTFail("Failed to connect to CDP after 15s")
                return
            }
        }
    }

    override func tearDown() async throws {
        // 不断开 CDP — 跨测试复用连接
        // 不 terminate app — 跨测试复用 app 实例
    }

    override class func tearDown() {
        cdp?.disconnect()
    }

    // MARK: - 跨层测试

    func testAddressBarNavigateThenVerifyDOM() async throws {
        // 1. XCUITest: 原生 UI 操作
        let app = Self.app
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText("https://example.com\n")

        // 2. XCUITest: 等待 URL 变化（已有 AccessibleLabel 机制）
        let pageURL = app.staticTexts["pageURL"]
        let urlPredicate = NSPredicate(format: "label CONTAINS %@", "example.com")
        let urlExpectation = XCTNSPredicateExpectation(predicate: urlPredicate, object: pageURL)
        let urlResult = XCTWaiter.wait(for: [urlExpectation], timeout: 15)
        XCTAssertEqual(urlResult, .completed)

        // 3. CDP: 精确 DOM 断言 — XCUITest 做不到
        try await Self.cdp.waitForSelector("h1", timeout: 10)
        let heading = try await Self.cdp.textContent("h1")
        XCTAssertEqual(heading, "Example Domain")
    }

    func testSearchFromAddressBarVerifyResults() async throws {
        let app = Self.app
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText("test query\n")

        // 等待搜索引擎页面加载
        let pageURL = app.staticTexts["pageURL"]
        let predicate = NSPredicate(format: "label CONTAINS %@", "search")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageURL)
        _ = XCTWaiter.wait(for: [expectation], timeout: 15)

        // CDP: 验证搜索结果 DOM 结构
        let url = try await Self.cdp.currentURL()
        XCTAssertTrue(url.contains("search") || url.contains("q="))
    }

    func testHistorySidebarNavigateVerifyDOM() async throws {
        // 1. 先导航到某个页面
        let app = Self.app
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText("https://example.com\n")
        let pageURL = app.staticTexts["pageURL"]
        let pred = NSPredicate(format: "label CONTAINS %@", "example.com")
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: pred, object: pageURL)], timeout: 15)

        // 2. 打开历史侧边栏
        app.buttons["sidebarHistoryButton"].click()

        // 3. 验证历史中有 example.com 条目
        let historyItem = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "example")).firstMatch
        XCTAssertTrue(historyItem.waitForExistence(timeout: 5))
    }

    func testConsoleMessagesCapture() async throws {
        // 1. 导航到页面
        try await Self.cdp.enableConsole()
        Self.cdp.clearConsoleMessages()

        let app = Self.app
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText("https://example.com\n")

        // 等待加载
        try await Self.cdp.waitForSelector("body", timeout: 10)

        // 2. CDP: 注入并验证 console 消息
        _ = try await Self.cdp.evaluate("console.log('owl-e2e-test')")
        try await Task.sleep(nanoseconds: 500_000_000) // 等事件传播
        let messages = Self.cdp.consoleMessages
        XCTAssertTrue(messages.contains(where: { $0.text == "owl-e2e-test" }))
    }

    func testNetworkRequestCapture() async throws {
        try await Self.cdp.enableNetwork()
        Self.cdp.clearCapturedRequests()

        // 导航
        try await Self.cdp.navigateAndWait("https://example.com", timeout: 15)

        // 验证网络请求
        let requests = Self.cdp.capturedRequests
        XCTAssertTrue(requests.contains(where: { $0.url.contains("example.com") }))
    }
}
```

### 4. App 生命周期管理

#### 4.1 run_tests.sh 集成（串行两阶段）

```bash
# 全局变量（cleanup 函数需要访问）
OWL_APP_PID=""

# run_tests.sh 新增分支
dual-e2e)
    # ═══════════════════════════════════════════════
    # Phase A: Playwright 纯 Web 测试
    # ═══════════════════════════════════════════════
    section "Phase A: Playwright Web Tests"

    export OWL_CDP_PORT=${OWL_CDP_PORT:-9222}
    export OWL_CLEAN_SESSION=1

    # 构建（如果需要）
    if [ ! -f "$BUILD_DIR/owl_host" ]; then
        "$SCRIPT_DIR/build_all.sh"
    fi

    # 【Round 2 修复】直接启动 app 二进制（不依赖 launch.sh --background）
    # 用 swift run 或预构建的 .app bundle
    trap 'cleanup_owl_processes' EXIT
    OWL_CDP_PORT=$OWL_CDP_PORT OWL_CLEAN_SESSION=1 \
        swift run --package-path "$SCRIPT_DIR/.." OWLBrowser &
    OWL_APP_PID=$!

    # 等待 CDP 就绪
    wait_for_cdp "$OWL_CDP_PORT" 30

    # 运行 Playwright 测试
    # 【Round 3 修复】避免 pipefail 导致脚本提前退出：
    # 先捕获退出码到变量，再用管道解析输出
    PW_DIR="$SCRIPT_DIR/../playwright"
    PW_EXIT=0
    if [ -d "$PW_DIR" ] && [ -f "$PW_DIR/package.json" ]; then
        PW_OUTPUT=$( (cd "$PW_DIR" && OWL_CDP_PORT=$OWL_CDP_PORT npx playwright test 2>&1) ) \
            || PW_EXIT=$?
        echo "$PW_OUTPUT" | parse_playwright_output || true
    else
        echo "⚠️ Playwright 目录不存在，跳过"
    fi

    # 杀掉 Phase A 的 app 实例
    cleanup_owl_processes

    # ═══════════════════════════════════════════════
    # Phase B: XCUITest + CDPHelper 跨层测试
    # ═══════════════════════════════════════════════
    section "Phase B: XCUITest Dual Driver Tests"

    XCUI_EXIT=0
    if has_signing; then
        # XCUITest 通过 XCUIApplication.launch() 自行启动 app
        # CDPHelper 连接 :9222（launchEnvironment 在测试代码 setUp 中注入）
        XCUI_OUTPUT=$(xcodebuild test-without-building \
            -project "$XCODEPROJ" \
            -scheme OWLBrowserUITests \
            -destination 'platform=macOS' \
            -only-testing:OWLBrowserUITests/OWLDualDriverTests \
            2>&1) || XCUI_EXIT=$?
        echo "$XCUI_OUTPUT" | parse_xcuitest_output || true
    else
        echo "⚠️ 无签名，跳过 XCUITest 双驱动测试"
        XCUI_EXIT=0
    fi

    # 汇总
    print_summary "Playwright" $PW_EXIT "XCUITest Dual" $XCUI_EXIT
    [ $PW_EXIT -eq 0 ] && [ $XCUI_EXIT -eq 0 ]
    ;;
```

#### 4.2 进程清理（防 Host 孤儿进程）

```bash
# 【Round 1+2 修复】确保 app + Host 子进程都被清理
# OWL_APP_PID 是全局变量，在 dual-e2e case 中赋值
cleanup_owl_processes() {
    # 1. 先发 SIGTERM 给 app（触发 applicationWillTerminate → shutdown → kill host）
    if [ -n "$OWL_APP_PID" ] && kill -0 "$OWL_APP_PID" 2>/dev/null; then
        kill "$OWL_APP_PID" 2>/dev/null
        # 等待 app 正常退出（最多 5s）
        for i in $(seq 1 50); do
            kill -0 "$OWL_APP_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$OWL_APP_PID" 2>/dev/null || true
    fi
    OWL_APP_PID=""

    # 2. 【Round 2 修复】用 PPID 精确匹配本次启动的 Host 子进程
    #    避免 TOCTOU 和误杀其他 owl_host 实例
    #    等待 1s 让 app 的 shutdown 回调有时间 kill host
    sleep 1

    # 3. 兜底：如果 Host 仍在运行（app 非正常退出时），按 PID 清理
    #    只杀「无父进程」的 owl_host（孤儿进程，PPID=1）
    local orphan_hosts=$(pgrep -f "owl_host" 2>/dev/null | while read pid; do
        if [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "1" ]; then
            echo "$pid"
        fi
    done)

    for pid in $orphan_hosts; do
        kill "$pid" 2>/dev/null
        sleep 0.3
        kill -9 "$pid" 2>/dev/null || true
    done
}

wait_for_cdp() {
    local port=$1 timeout=$2
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        if curl -sf "http://127.0.0.1:${port}/json" >/dev/null 2>&1; then
            echo "✓ CDP ready on port ${port}"
            return 0
        fi
        sleep 1
    done
    echo "✗ CDP not ready after ${timeout}s"
    return 1
}
```

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| **前置（Step 0）** | | |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改 | `launch()` 中读取 `OWL_CDP_PORT` 环境变量传给 `launchHost(port:)` |
| **CDPHelper（Step 1）** | | |
| `owl-client-app/UITests/Helpers/CDPHelper.swift` | 新增 | Swift CDP 客户端（含 CDPError、CDPNetworkRequest、CDPConsoleMessage） |
| **Playwright（Step 2）** | | |
| `owl-client-app/playwright/package.json` | 新增 | `{"dependencies": {"@playwright/test": "^1.50"}}` |
| `owl-client-app/playwright/fixtures.ts` | 新增 | Worker-scoped browser + test-scoped page + 清场 |
| `owl-client-app/playwright/playwright.config.ts` | 新增 | workers:1, timeout:30s |
| `owl-client-app/playwright/tests/web-navigation.spec.ts` | 新增 | DOM/network/console/error page 测试 |
| `owl-client-app/playwright/.gitignore` | 新增 | `node_modules/`, `test-results/`, `playwright-report/` |
| **跨层测试（Step 3）** | | |
| `owl-client-app/UITests/OWLDualDriverTests.swift` | 新增 | 5 个跨层测试 |
| **集成（Step 4）** | | |
| `owl-client-app/scripts/run_tests.sh` | 修改 | 新增 `dual-e2e` 级别 + `cleanup_owl_processes` + `wait_for_cdp` |
| **文档（Step 5）** | | |
| `docs/TESTING.md` | 修改 | 新增 L4 双驱动层 |
| `owl-client-app/project.yml` | 修改 | UITests sources 包含 `Helpers/`（XcodeGen 递归包含，无需显式添加） |

### 6. 测试策略

#### 6.1 测试分层矩阵（新增 L4）

| 测试场景 | L3 XCUITest | **L4 XCUITest+CDP** | **L4 Playwright** |
|---------|:---:|:---:|:---:|
| 地址栏导航（原生） | x | | |
| 地址栏导航 → DOM 验证 | | **x** | |
| 搜索 → 结果页 DOM | | **x** | |
| 侧边栏 → 页面 + DOM | | **x** | |
| Console 消息采集 | | **x** | |
| Network 请求采集 | | **x** | |
| 页面 DOM 结构 | | | **x** |
| 网络请求/拦截 | | | **x** |
| Console 消息 | | | **x** |
| 错误页面渲染 | | | **x** |

#### 6.2 测试数量规划

| 组件 | 测试数 | 说明 |
|------|--------|------|
| OWLDualDriverTests (XCUITest+CDP) | 5 | 跨层：导航+DOM、搜索+结果、历史+DOM、Console、Network |
| Playwright web tests | 4 | 纯 Web：DOM 结构、网络请求、Console 消息、错误页面 |
| **合计** | **9** | |

### 7. 风险 & 缓解

| 风险 | 严重度 | 缓解 |
|------|--------|------|
| Content layer CDP 不支持 `browser.contexts()` | P0 | **Step 2 前置验证**：先用 `node -e "const c = require('playwright'); ..."` 验证 `connectOverCDP` 能否获取 context；失败则 Playwright 降级为直接 WebSocket CDP 客户端 |
| CDPHelper WebSocket 断连 | P1 | `disconnect()` drain 所有 pending continuations；`send()` 前 guard 检查 |
| Host 孤儿进程 | P1 | `cleanup_owl_processes` 先 SIGTERM app → 等待 → pgrep owl_host → SIGKILL 兜底 |
| Playwright 测试间状态污染 | P1 | afterEach 中 `goto('about:blank')` 清场；workers:1 串行执行 |
| `OWL_CDP_PORT` 代码路径变更 | P1 | Step 0 修改 BrowserViewModel 后需跑现有测试验证无回归 |
| XcodeGen 递归包含 `Helpers/` | P2 | XcodeGen 默认递归扫描 sources path 下的所有文件，无需显式添加子目录 |

### 8. 实施计划

| 阶段 | 内容 | 依赖 | 预计工作量 |
|------|------|------|-----------|
| **Step 0** | BrowserViewModel 读取 `OWL_CDP_PORT` 环境变量 | 无 | 0.5h |
| **Step 1** | CDPHelper.swift 实现（含所有 P0 修复） | Step 0 | 4h |
| **Step 2** | Playwright 项目搭建 + fixture + 4 个测试 | Node.js + Step 0 | 3h |
| **Step 3** | OWLDualDriverTests 5 个跨层测试 | Step 1 + XCUITest 签名 | 4h |
| **Step 4** | run_tests.sh `dual-e2e` + cleanup_owl_processes | Step 2+3 | 2h |
| **Step 5** | docs/TESTING.md 更新 | Step 4 | 0.5h |

Step 1 和 Step 2 可并行。**总计**：~14h。

---

## 评审记录

### Round 1（v1.0, 2026-04-08）

三方并行评审，全互盲。

| Agent | LLM | Verdict | P0 | P1 | P2 |
|-------|-----|---------|----|----|-----|
| Claude (架构) | Claude | REVISE | 3 | 4 | 4 |
| Codex (正确性) | GPT-5.4 | REJECT | 3 | 3 | 1 |
| Gemini (简洁性) | Gemini 3.1 Pro | REVISE | 1 | 2 | 1 |

**去重后 P0/P1 及修复**：

| # | 来源 | 问题 | 修复 |
|---|------|------|------|
| 1 | Gemini | Playwright 是过度工程，应砍掉 | **用户决策：保留 Playwright**（Playwright 提供 auto-waiting、selector engine、截图、视频、network interception 等 CDPHelper 不具备的能力） |
| 2 | Claude+Codex | 端口隔离链路断裂：BrowserViewModel 不读 `OWL_CDP_PORT` | Step 0 新增前置代码变更：`BrowserViewModel.launch()` 读取环境变量 |
| 3 | Codex | `send()` 竞态：response 可能在 continuation 入表前到达 | 重构 `send()`：先注册 continuation，再发送消息；发送失败时移除并 resume(throwing:) |
| 4 | Codex | CDP `Runtime.evaluate` 解析错误：应为 `response.result.result.value` | 修正解析层次；增加 `error`/`exceptionDetails` 处理 |
| 5 | Claude | `targets.first` 多 tab 不可靠 | 过滤 `type == "page"`；新增 `connect(toTabContaining:)` |
| 6 | Claude | `swift run OWLBrowser &` 错误启动方式 | 改用 `launch.sh --background`；Playwright 和 XCUITest 串行执行（Phase A → kill → Phase B） |
| 7 | Claude+Codex | `selector.escapedForJS` 未实现，注入风险 | 用 `jsonEncode()` 生成 JSON string literal |
| 8 | Codex | App 生命周期进程泄漏：Host 孤儿进程 | `cleanup_owl_processes`：SIGTERM → 等待 → pgrep owl_host → SIGKILL |
| 9 | Codex | Playwright fixture 资源泄漏 | 改为 worker-scoped browser，worker teardown 时 `browser.close()` |
| 10 | Claude | Playwright `browser.contexts()` 未验证 | Step 2 前置验证，失败则降级 |
| 11 | Claude | 两个 app 实例 userDataDir 冲突 | 串行执行消除冲突（Phase A 结束后杀掉再启 Phase B） |
| 12 | Gemini | 18 个测试重叠 | 精简为 9 个无重叠测试 |
| 13 | Claude | `setUpWithError` 混用同步/异步 | 改用 `override func setUp() async throws` |
| 14 | Codex | `disconnect()` 未 drain pending callbacks | drain 所有 pending，resume(throwing: .disconnected) |

### Round 2（v2.0, 2026-04-08）

| Agent | LLM | Verdict | Q2 验旧 | Q3 新问题 |
|-------|-----|---------|---------|----------|
| Claude (架构) | Claude | REVISE | 7/7 FIXED | 3 P1 |
| Codex (正确性) | GPT-5.4 | REVISE | 6/6 FIXED | 3 P1 |
| Gemini (简洁性) | Gemini 3.1 Pro | **APPROVE** | 3/3 FIXED | 0 P0/P1 |

**Round 1 全部 P0/P1 确认修复。** Round 2 新引入 6 个 P1：

| # | 来源 | 新问题 | 修复 |
|---|------|--------|------|
| 1 | Claude | `launch.sh --background` 标志不存在 | 改为直接 `swift run OWLBrowser &`，不依赖 launch.sh 的未实现功能 |
| 2 | Claude | `LAUNCH_PID` bash 函数作用域不可见 | 改为全局变量 `OWL_APP_PID`，在 case block 顶部赋值 |
| 3 | Claude | xcodebuild `OWL_CDP_PORT=9222` 不是 `-testEnvironmentVariables` 语法 | 移除命令行参数；测试代码 `setUp` 中 `app.launchEnvironment["OWL_CDP_PORT"]` 已处理 |
| 4 | Codex | `evaluate()` 异常分支：exceptionDetails 检查在 result.result 之后，JS 异常时误判 | exceptionDetails 检查提前到 innerResult 之前 |
| 5 | Codex | `receiveLoop` 退出后未 drain pendingCallbacks，可能永久挂起 | 循环退出后 drain 所有 pending，resume(throwing: .disconnected) |
| 6 | Codex | `cleanup_owl_processes` TOCTOU + `pgrep -f "owl_host"` 过宽误杀 | 改为只杀 PPID=1 的孤儿 owl_host 进程，收窄匹配范围 |
| - | Gemini P2 | Playwright fixture 应清理 cookies/localStorage | 已在 afterEach 中补充 `clearCookies` + `localStorage.clear()` 建议（实施时添加） |

### Round 3（v2.1, 2026-04-08）

| Agent | LLM | Verdict | Q2 | Q3 新 P0/P1 |
|-------|-----|---------|----|----|
| Claude (架构) | Claude | REVISE | 3/3 FIXED | 1 P1 |
| Codex (正确性) | GPT-5.4 | **APPROVE** | 3/3 FIXED | 0 |
| Gemini (简洁性) | Gemini 3.1 Pro | **APPROVE** | - | 0 |

Round 2 的 6 个 P1 全部确认修复。Claude 发现 1 个新 P1：

| # | 来源 | 问题 | 修复 |
|---|------|------|------|
| 1 | Claude | `PIPESTATUS[0]` 在 `set -euo pipefail` 下不可靠 — 管道非零退出导致脚本提前退出 | 改为先捕获退出码到变量 `PW_OUTPUT=$(... ) || PW_EXIT=$?`，再用管道解析输出 |

### 收敛判定

- Round 1: 6 P0 + 8 P1 → 全部修复
- Round 2: 0 P0 + 6 新 P1 → 全部修复
- Round 3: 0 P0 + 1 新 P1 → 已修复 (v2.2)
- **Codex APPROVE + Gemini APPROVE + Claude 最后 P1 已修复 → 收敛**
