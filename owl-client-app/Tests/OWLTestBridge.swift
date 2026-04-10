/// Async/await wrappers around OWLBridge C-ABI for testing.
/// These wrappers follow the existing OWLBridgeSwift pattern:
/// CheckedContinuation + Unmanaged.passRetained(cont as AnyObject).
/// Gate: OWL_ENABLE_TEST_JS env var (set in setUp, launcher maps to
/// --enable-owl-test-js for Host process).
import Foundation
import OWLBridge
import Darwin

// MARK: - Setup / Teardown

enum OWLTestBridge {

    /// Full initialization sequence: Initialize → Launch Host → Create Context → Create WebView.
    /// Returns webview ID. Sets OWL_ENABLE_TEST_JS env var so launcher enables
    /// Host-side --enable-owl-test-js gate.
    /// Call on main thread before async setUp.
    static func initializeOnMainThread() {
        setenv("OWL_ENABLE_TEST_JS", "1", 1)
        OWLBridge_Initialize()
    }

    private static var hostPID: pid_t = 0

    static func setUp(hostPath: String, userDataDir: String) async throws -> UInt64 {

        let (_, pid) = try await launchHost(path: hostPath, userDataDir: userDataDir)
        hostPID = pid
        // LaunchHost internally connects the session via Mojo invitation.
        // No separate ConnectSession call needed.
        let ctxId = try await createBrowserContext()
        let webviewId = try await createWebView(contextId: ctxId)

        // Register load-finished callback for waitForLoad.
        OWLBridge_SetPageInfoCallback(webviewId, { _, _, url, loading, canBack, canFwd, ctx in
            guard let ctx else { return }
            let state = Unmanaged<PageLoadState>.fromOpaque(ctx).takeUnretainedValue()
            state.canGoBack = canBack != 0
            state.canGoForward = canFwd != 0
            // Track URL changes as "load finished" signal (more reliable than is_loading
            // which stays true while subresources load on complex pages like baidu.com).
            if let url {
                let u = String(cString: url)
                if u != state.currentURL {
                    state.currentURL = u
                    state.urlChanged = true
                }
            }
            if loading == 0 {
                state.loadFinished = true
            }
        }, Unmanaged.passUnretained(pageLoadState).toOpaque())

        return webviewId
    }

    /// Kill Host child process so test runner can exit cleanly.
    static func shutdown() {
        let pid = hostPID
        guard pid > 0 else { return }

        // Already exited (or no longer a child) — nothing to do.
        if reapIfExited(pid) {
            hostPID = 0
            return
        }

        // Try graceful termination first.
        if kill(pid, SIGTERM) == -1 && errno == ESRCH {
            hostPID = 0
            return
        }
        let termDeadline = Date().addingTimeInterval(2.0)
        while Date() < termDeadline {
            if reapIfExited(pid) {
                hostPID = 0
                return
            }
            usleep(50_000)
        }

        // Hard kill fallback to avoid indefinite hangs in swift test.
        _ = kill(pid, SIGKILL)
        let killDeadline = Date().addingTimeInterval(2.0)
        while Date() < killDeadline {
            if reapIfExited(pid) {
                hostPID = 0
                return
            }
            usleep(50_000)
        }

        hostPID = 0
    }

    // MARK: - Navigation

    static func navigate(_ webviewId: UInt64, url: String) async throws {
        pageLoadState.urlChanged = false
        pageLoadState.loadFinished = false

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            url.withCString { urlPtr in
                OWLBridge_Navigate(webviewId, urlPtr, { success, _, errMsg, ctx in
                    let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                        as! CheckedContinuation<Void, Error>
                    if success == 0, let errMsg {
                        cont.resume(throwing: NSError(
                            domain: "OWLBridge", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                    } else {
                        cont.resume()
                    }
                }, ctx)
            }
        }
    }

    /// Wait until URL changes or load finishes (whichever comes first).
    static func waitForLoad(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !pageLoadState.urlChanged && !pageLoadState.loadFinished && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
        }
        // Settle time for renderer
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Quick wait — just sleep for a fixed duration. For data: URLs and simple pages.
    static func quickWait() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
    }

    // MARK: - JavaScript Evaluation

    /// Execute JavaScript and return (result JSON, resultType).
    /// resultType: 0=success, 1=exception.
    /// Timeout: 10s (guards against never-resolving Promises and Mojo disconnect).
    static func evaluateJS(_ webviewId: UInt64, _ expression: String,
                           timeout: TimeInterval = 10) async -> (String, Int32) {
        // Use JSCallbackBox (reference type) for Unmanaged safety.
        final class Box {
            var continuation: CheckedContinuation<(String, Int32), Never>?
            let lock = NSLock()
            func resume(result: String, resultType: Int32) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: (result, resultType))
            }
        }

        return await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            expression.withCString { cstr in
                let raw = Unmanaged.passRetained(box).toOpaque()
                OWLBridge_EvaluateJavaScript(webviewId, cstr, { result, resultType, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    let r = result.map { String(cString: $0) } ?? ""
                    box.resume(result: r, resultType: resultType)
                }, raw)
            }

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.resume(result: "Timeout", resultType: 1)
            }
        }
    }

    /// Convenience: evaluate JS and return result string (assumes success).
    static func evalJS(_ webviewId: UInt64, _ expression: String) async -> String {
        let (result, _) = await evaluateJS(webviewId, expression)
        return result
    }

    // MARK: - Input Events

    static func sendKeyEvent(_ webviewId: UInt64, type: Int32, keyCode: Int32,
                             modifiers: UInt32 = 0, chars: String? = nil) {
        let ts = ProcessInfo.processInfo.systemUptime
        chars?.withCString { cstr in
            OWLBridge_SendKeyEvent(webviewId, type, keyCode, modifiers, cstr, cstr, ts)
        } ?? OWLBridge_SendKeyEvent(webviewId, type, keyCode, modifiers, nil, nil, ts)
    }

    static func sendMouseEvent(_ webviewId: UInt64, type: Int32, button: Int32,
                               x: Float, y: Float, clickCount: Int32 = 1) {
        let ts = ProcessInfo.processInfo.systemUptime
        OWLBridge_SendMouseEvent(webviewId, type, button, x, y, 0, 0, 0, clickCount, ts)
    }

    /// Type a string character by character through the full OWL input pipeline.
    static func typeText(_ webviewId: UInt64, _ text: String) {
        for ch in text {
            let str = String(ch)
            // RawKeyDown (type=0)
            sendKeyEvent(webviewId, type: 0, keyCode: 0, chars: str)
            // Char (type=2) — only for printable chars
            if ch.asciiValue ?? 0 >= 0x20 {
                sendKeyEvent(webviewId, type: 2, keyCode: 0, chars: str)
            }
            // KeyUp (type=1)
            sendKeyEvent(webviewId, type: 1, keyCode: 0, chars: str)
        }
    }

    // MARK: - IME (Phase 31)

    /// Send IME composition (marked text) via C-ABI.
    static func imeSetComposition(_ webviewId: UInt64, text: String,
                                   selStart: Int32 = 0, selEnd: Int32? = nil,
                                   replStart: Int32 = -1, replEnd: Int32 = -1) {
        let end = selEnd ?? Int32(text.utf8.count)
        text.withCString { cstr in
            OWLBridge_ImeSetComposition(webviewId, cstr, selStart, end, replStart, replEnd)
        }
    }

    /// Send IME commit text via C-ABI.
    static func imeCommitText(_ webviewId: UInt64, text: String,
                               replStart: Int32 = -1, replEnd: Int32 = -1) {
        text.withCString { cstr in
            OWLBridge_ImeCommitText(webviewId, cstr, replStart, replEnd)
        }
    }

    /// Send IME finish composing via C-ABI.
    static func imeFinishComposing(_ webviewId: UInt64) {
        OWLBridge_ImeFinishComposing(webviewId)
    }

    // MARK: - Cursor Observation

    static var lastCursorType: Int32 = 0

    static func registerCursorCallback(_ webviewId: UInt64) {
        let nullCtx: UnsafeMutableRawPointer? = nil
        OWLBridge_SetCursorChangeCallback(webviewId, { _, cursorType, _ in
            OWLTestBridge.lastCursorType = cursorType
        }, nullCtx)
    }

    // MARK: - Navigation State
    //
    // Note: GoBack/GoForward/Reload/Stop have no C-ABI functions in owl_bridge_api.h.
    // They exist only on OWLBridgeWebView (ObjC++ Mojo layer). For E2E integration tests,
    // JS History API is the only available path to trigger navigation actions.

    /// Whether the browser can navigate back (from PageInfoCallback).
    static var canGoBack: Bool { pageLoadState.canGoBack }

    /// Whether the browser can navigate forward (from PageInfoCallback).
    static var canGoForward: Bool { pageLoadState.canGoForward }

    /// Go back and wait for navigation to complete (signal-based, not fixed sleep).
    static func goBackAndWait(_ webviewId: UInt64, timeout: TimeInterval = 5) async throws {
        pageLoadState.urlChanged = false
        pageLoadState.loadFinished = false
        _ = await evalJS(webviewId, "history.back()")
        try await waitForLoad(timeout: timeout)
    }

    /// Go forward and wait for navigation to complete (signal-based, not fixed sleep).
    static func goForwardAndWait(_ webviewId: UInt64, timeout: TimeInterval = 5) async throws {
        pageLoadState.urlChanged = false
        pageLoadState.loadFinished = false
        _ = await evalJS(webviewId, "history.forward()")
        try await waitForLoad(timeout: timeout)
    }

    /// Reload and wait for page to finish loading (signal-based).
    static func reloadAndWait(_ webviewId: UInt64, timeout: TimeInterval = 10) async throws {
        pageLoadState.urlChanged = false
        pageLoadState.loadFinished = false
        _ = await evalJS(webviewId, "location.reload()")
        try await waitForLoad(timeout: timeout)
    }

    /// Trigger browser back navigation via history.back() (fire-and-forget).
    static func goBack(_ webviewId: UInt64) async {
        _ = await evalJS(webviewId, "history.back()")
    }

    /// Trigger browser forward navigation via history.forward() (fire-and-forget).
    static func goForward(_ webviewId: UInt64) async {
        _ = await evalJS(webviewId, "history.forward()")
    }

    /// Trigger page reload via location.reload() (fire-and-forget).
    static func reload(_ webviewId: UInt64) async {
        _ = await evalJS(webviewId, "location.reload()")
    }

    /// Extract the page's visible text content.
    static func getPageContent(_ webviewId: UInt64) async -> String {
        return await evalJS(webviewId, "document.body?.innerText || ''")
    }

    /// Get the current page URL via JS.
    static func getCurrentURL(_ webviewId: UInt64) async -> String {
        return await evalJS(webviewId, "window.location.href")
    }

    // MARK: - Find-in-Page (Phase 33)

    /// Find text in the web view. Returns request_id (0 = no match / stub mode).
    /// Uses CheckedContinuation + OWLBridge_Find C-ABI callback.
    static func find(_ webviewId: UInt64, query: String,
                     forward: Bool = true, matchCase: Bool = false) async -> Int32 {
        final class Box {
            var continuation: CheckedContinuation<Int32, Never>?
            let lock = NSLock()
            func resume(requestId: Int32) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: requestId)
            }
        }

        return await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            query.withCString { cstr in
                let raw = Unmanaged.passRetained(box).toOpaque()
                OWLBridge_Find(webviewId, cstr,
                               forward ? 1 : 0,
                               matchCase ? 1 : 0,
                               { requestId, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    box.resume(requestId: requestId)
                }, raw)
            }

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.resume(requestId: 0)
            }
        }
    }

    /// Stop finding in the web view. Fire-and-forget.
    static func stopFinding(_ webviewId: UInt64) {
        OWLBridge_StopFinding(webviewId, OWLBridgeStopFindAction_ClearSelection)
    }

    /// Find result state (set by find result callback).
    static var lastFindMatches: Int32 = 0
    static var lastFindOrdinal: Int32 = 0
    static var lastFindRequestId: Int32 = 0
    static var findResultReceived = false

    /// Register find result callback. Call once after webview creation.
    static func registerFindResultCallback(_ webviewId: UInt64) {
        let nullCtx: UnsafeMutableRawPointer? = nil
        OWLBridge_SetFindResultCallback(webviewId, { _, requestId, numMatches, activeOrdinal, finalUpdate, _ in
            // Only record final updates to avoid intermediate noise.
            guard finalUpdate != 0 else { return }
            OWLTestBridge.lastFindRequestId = requestId
            OWLTestBridge.lastFindMatches = numMatches
            OWLTestBridge.lastFindOrdinal = activeOrdinal
            OWLTestBridge.findResultReceived = true
        }, nullCtx)
    }

    /// Reset find result state before a new find operation.
    static func resetFindState() {
        lastFindMatches = 0
        lastFindOrdinal = 0
        lastFindRequestId = 0
        findResultReceived = false
    }

    /// Wait until a find result callback has been received (with timeout).
    static func waitForFindResult(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !findResultReceived && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
        }
    }

    // MARK: - Zoom Control (Phase 34)

    /// Set zoom level for a web view. Callback fires on completion (ack).
    /// level: 0.0 = 100%, positive = zoom in, negative = zoom out.
    static func setZoomLevel(_ webviewId: UInt64, level: Double) async {
        final class Box {
            var continuation: CheckedContinuation<Void, Never>?
            let lock = NSLock()
            func resume() {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume()
            }
        }

        await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            let raw = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_SetZoomLevel(webviewId, level, { ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.resume()
            }, raw)

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.resume()
            }
        }
    }

    /// Get current zoom level for a web view.
    /// Returns: zoom level (0.0 = 100%).
    static func getZoomLevel(_ webviewId: UInt64) async -> Double {
        final class Box {
            var continuation: CheckedContinuation<Double, Never>?
            let lock = NSLock()
            func resume(level: Double) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: level)
            }
        }

        return await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            let raw = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_GetZoomLevel(webviewId, { level, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.resume(level: level)
            }, raw)

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.resume(level: 0.0)
            }
        }
    }

    // MARK: - Zoom Changed Callback (Phase 34) [P1-3]

    static var zoomChangedReceived = false
    static var lastZoomChangedLevel: Double = 0.0

    static func registerZoomChangedCallback(_ webviewId: UInt64) {
        let nullCtx: UnsafeMutableRawPointer? = nil
        OWLBridge_SetZoomChangedCallback(webviewId, { _, newLevel, _ in
            OWLTestBridge.lastZoomChangedLevel = newLevel
            OWLTestBridge.zoomChangedReceived = true
        }, nullCtx)
    }

    static func resetZoomChangedState() {
        zoomChangedReceived = false
        lastZoomChangedLevel = 0.0
    }

    static func waitForZoomChanged(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !zoomChangedReceived && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Bookmarks (Phase 35)

    /// Get all bookmarks as a JSON array string.
    /// Returns: JSON string (e.g. "[{\"id\":\"1\",\"title\":\"...\",\"url\":\"...\"}]")
    /// or empty string on error.
    static func bookmarkGetAll() async -> String {
        final class Box {
            var continuation: CheckedContinuation<String, Never>?
            let lock = NSLock()
            func resume(result: String) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: result)
            }
        }

        return await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            let raw = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_BookmarkGetAll({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    let _ = String(cString: errorMsg)
                    box.resume(result: "")
                } else if let jsonArray {
                    box.resume(result: String(cString: jsonArray))
                } else {
                    box.resume(result: "")
                }
            }, raw)

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.resume(result: "")
            }
        }
    }

    /// Add a bookmark. Returns the bookmark JSON string on success, or empty string on error.
    static func bookmarkAdd(title: String, url: String,
                            parentId: String? = nil) async -> String {
        final class Box {
            var continuation: CheckedContinuation<String, Never>?
            let lock = NSLock()
            func resume(result: String) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: result)
            }
        }

        return await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            let raw = Unmanaged.passRetained(box).toOpaque()

            let callAdd: (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { titlePtr, urlPtr, rawCtx in
                if let parentId {
                    parentId.withCString { pidPtr in
                        OWLBridge_BookmarkAdd(titlePtr, urlPtr, pidPtr, { json, errorMsg, ctx in
                            let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                            if let errorMsg {
                                let _ = String(cString: errorMsg)
                                box.resume(result: "")
                            } else if let json {
                                box.resume(result: String(cString: json))
                            } else {
                                box.resume(result: "")
                            }
                        }, rawCtx)
                    }
                } else {
                    OWLBridge_BookmarkAdd(titlePtr, urlPtr, nil, { json, errorMsg, ctx in
                        let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                        if let errorMsg {
                            let _ = String(cString: errorMsg)
                            box.resume(result: "")
                        } else if let json {
                            box.resume(result: String(cString: json))
                        } else {
                            box.resume(result: "")
                        }
                    }, rawCtx)
                }
            }

            title.withCString { titlePtr in
                url.withCString { urlPtr in
                    callAdd(titlePtr, urlPtr, raw)
                }
            }

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.resume(result: "")
            }
        }
    }

    /// Remove a bookmark by ID. Returns true on success.
    static func bookmarkRemove(id: String) async -> Bool {
        final class Box {
            var continuation: CheckedContinuation<Bool, Never>?
            let lock = NSLock()
            func resume(result: Bool) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: result)
            }
        }

        return await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            let raw = Unmanaged.passRetained(box).toOpaque()
            id.withCString { idPtr in
                OWLBridge_BookmarkRemove(idPtr, { success, errorMsg, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    box.resume(result: success != 0)
                }, raw)
            }

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.resume(result: false)
            }
        }
    }

    /// Update a bookmark's title and/or URL. Returns true on success.
    static func bookmarkUpdate(id: String, title: String? = nil,
                               url: String? = nil) async -> Bool {
        final class Box {
            var continuation: CheckedContinuation<Bool, Never>?
            let lock = NSLock()
            func resume(result: Bool) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: result)
            }
        }

        return await withCheckedContinuation { cont in
            let box = Box()
            box.continuation = cont

            let raw = Unmanaged.passRetained(box).toOpaque()

            id.withCString { idPtr in
                let titlePtr: UnsafePointer<CChar>? = nil
                let urlPtr: UnsafePointer<CChar>? = nil

                // Use nested withCString only for non-nil values.
                func doUpdate(_ tPtr: UnsafePointer<CChar>?,
                              _ uPtr: UnsafePointer<CChar>?) {
                    OWLBridge_BookmarkUpdate(idPtr, tPtr, uPtr, { success, errorMsg, ctx in
                        let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                        box.resume(result: success != 0)
                    }, raw)
                }

                if let title, let url {
                    title.withCString { t in
                        url.withCString { u in
                            doUpdate(t, u)
                        }
                    }
                } else if let title {
                    title.withCString { t in
                        doUpdate(t, urlPtr)
                    }
                } else if let url {
                    url.withCString { u in
                        doUpdate(titlePtr, u)
                    }
                } else {
                    doUpdate(titlePtr, urlPtr)
                }
            }

            // Timeout guard
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.resume(result: false)
            }
        }
    }

    // MARK: - Private

    private static let pageLoadState = PageLoadState()

    private static func reapIfExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return true
        }
        if result == -1 && errno == ECHILD {
            // Not our child anymore or already reaped.
            return true
        }
        return false
    }

    private static func launchHost(path: String, userDataDir: String) async throws -> (UInt64, pid_t) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(UInt64, pid_t), Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            path.withCString { p in
                userDataDir.withCString { d in
                    OWLBridge_LaunchHost(p, d, 9222, { pipe, pid, errMsg, ctx in
                        let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                            as! CheckedContinuation<(UInt64, pid_t), Error>
                        if let errMsg {
                            cont.resume(throwing: NSError(
                                domain: "OWLBridge", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                        } else {
                            cont.resume(returning: (pipe, pid))
                        }
                    }, ctx)
                }
            }
        }
    }

    private static func createBrowserContext() async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_CreateBrowserContext(nil, 0, { ctxId, errMsg, ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<UInt64, Error>
                if let errMsg {
                    cont.resume(throwing: NSError(
                        domain: "OWLBridge", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                } else {
                    cont.resume(returning: ctxId)
                }
            }, ctx)
        }
    }

    private static func createWebView(contextId: UInt64) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_CreateWebView(contextId, { wvId, errMsg, ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<UInt64, Error>
                if let errMsg {
                    cont.resume(throwing: NSError(
                        domain: "OWLBridge", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                } else {
                    cont.resume(returning: wvId)
                }
            }, ctx)
        }
    }
}

// MARK: - Page Load State (shared mutable for callback)

private final class PageLoadState: @unchecked Sendable {
    var loadFinished = false
    var urlChanged = false
    var currentURL = ""
    var canGoBack = false
    var canGoForward = false
}
