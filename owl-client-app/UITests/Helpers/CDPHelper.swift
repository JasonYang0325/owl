import Foundation

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
        disconnect()  // 清理之前的连接（如有）
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
        disconnect()  // 清理之前的连接（如有）
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
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let num = value as? NSNumber { return num.stringValue }
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
        guard let ws = self.ws else { return }
        while true {
            guard let message = try? await ws.receive() else { break }
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
    /// 注意：不使用 JSONSerialization（String 不是合法 top-level JSON 对象，会抛 NSException）
    static func jsonEncode(_ s: String) -> String {
        var result = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if c.value < 0x20 {
                    result += String(format: "\\u%04x", c.value)
                } else {
                    result += String(c)
                }
            }
        }
        result += "\""
        return result
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
