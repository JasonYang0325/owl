import Foundation
import Darwin
import OWLBridge

public enum AppHostError: LocalizedError {
    case hostBinaryNotFound
    case missingWebView
    case navigationFailed(String)
    case evaluateJSException(String)
    case timedOut(String)
    case bridgeError(String)

    public var errorDescription: String? {
        switch self {
        case .hostBinaryNotFound:
            return "OWL Host binary not found. Build out/owl-host first."
        case .missingWebView:
            return "AppHost is not booted (missing webview)."
        case .navigationFailed(let message):
            return "Navigation failed: \(message)"
        case .evaluateJSException(let message):
            return "EvaluateJavaScript exception: \(message)"
        case .timedOut(let operation):
            return "Timed out while waiting for \(operation)"
        case .bridgeError(let message):
            return "OWLBridge error: \(message)"
        }
    }
}

public enum AppHostPermissionType: Int32 {
    case camera = 0
    case microphone = 1
    case geolocation = 2
    case notifications = 3
}

public enum AppHostPermissionStatus: Int32 {
    case granted = 0
    case denied = 1
    case ask = 2
}

private final class LoadSignal {
    private let lock = NSLock()
    private var didFinishLoad = false
    private var loadSuccess = true
    private var currentURL: String = ""

    func reset() {
        lock.lock()
        didFinishLoad = false
        loadSuccess = true
        lock.unlock()
    }

    func onPageInfo(url: String?, isLoading: Int32) {
        lock.lock()
        if let url, !url.isEmpty {
            currentURL = url
        }
        if isLoading == 0 {
            didFinishLoad = true
        }
        lock.unlock()
    }

    func onLoadFinished(success: Int32) {
        lock.lock()
        didFinishLoad = true
        loadSuccess = success != 0
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinishLoad
    }

    var wasSuccessful: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadSuccess
    }

    var lastURL: String {
        lock.lock()
        defer { lock.unlock() }
        return currentURL
    }
}

public final class AppHost {
    private static let initLock = NSLock()
    private static var initialized = false

    public static func discoverHostPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["OWL_HOST_PATH"], FileManager.default.fileExists(atPath: env) {
            return env
        }
        let app = "/Users/xiaoyang/Project/chromium/src/out/owl-host/OWL Host.app/Contents/MacOS/OWL Host"
        if FileManager.default.fileExists(atPath: app) {
            return app
        }
        let bare = "/Users/xiaoyang/Project/chromium/src/out/owl-host/owl_host"
        if FileManager.default.fileExists(atPath: bare) {
            return bare
        }
        return nil
    }

    public static func start(
        hostPath: String? = nil,
        userDataDir: String? = nil,
        devtoolsPort: UInt16 = 0
    ) async throws -> AppHost {
        let resolvedHostPath = hostPath ?? discoverHostPath()
        guard let resolvedHostPath else {
            throw AppHostError.hostBinaryNotFound
        }
        let resolvedUserDataDir = userDataDir
            ?? (NSTemporaryDirectory() + "owl-integration-\(UUID().uuidString)")
        let host = AppHost(hostPath: resolvedHostPath,
                           userDataDir: resolvedUserDataDir,
                           devtoolsPort: devtoolsPort)
        try await host.boot()
        return host
    }

    public let hostPath: String
    public let userDataDir: String
    public let devtoolsPort: UInt16

    private var processGuard: ProcessGuard?
    private var contextId: UInt64 = 0
    public private(set) var webViewId: UInt64 = 0
    private let loadSignal = LoadSignal()

    private init(hostPath: String, userDataDir: String, devtoolsPort: UInt16) {
        self.hostPath = hostPath
        self.userDataDir = userDataDir
        self.devtoolsPort = devtoolsPort
    }

    deinit {
        shutdown()
    }

    public var currentURL: String {
        loadSignal.lastURL
    }

    public func boot() async throws {
        Self.initializeBridgeIfNeeded()

        let (_, pid) = try await launchHost(path: hostPath,
                                            userDataDir: userDataDir,
                                            port: devtoolsPort)
        processGuard = ProcessGuard(pid: pid)
        contextId = try await createBrowserContext()
        webViewId = try await createWebView(contextId: contextId)
        try await setActiveWebView(webViewId)
        registerCallbacks()
    }

    public func shutdown() {
        let wv = webViewId
        if wv != 0 {
            unregisterCallbacks(webViewId: wv)
        }
        webViewId = 0
        contextId = 0
        _ = processGuard?.terminate()
        processGuard = nil
    }

    public func navigateAndWait(_ url: String, timeout: TimeInterval = 15) async throws {
        try await navigate(to: url)
        try await waitForLoad(timeout: timeout)
    }

    public func navigate(to url: String) async throws {
        let wv = try requireWebView()
        loadSignal.reset()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            url.withCString { cURL in
                OWLBridge_Navigate(wv, cURL, { success, _, errMsg, ctx in
                    let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                        as! CheckedContinuation<Void, Error>
                    if success == 0 {
                        let error = errMsg.map { String(cString: $0) } ?? "unknown"
                        cont.resume(throwing: AppHostError.navigationFailed(error))
                        return
                    }
                    cont.resume()
                }, ctx)
            }
        }
    }

    public func waitForLoad(timeout: TimeInterval = 15) async throws {
        let ok = await WaitHelper.waitUntil(timeout: timeout) { [loadSignal] in
            loadSignal.isFinished
        }
        guard ok else {
            throw AppHostError.timedOut("page load")
        }
        if !loadSignal.wasSuccessful {
            throw AppHostError.navigationFailed("main-frame load finished with failure")
        }
    }

    public func evaluateJS(_ expression: String, timeout: TimeInterval = 10) async throws -> String {
        let wv = try requireWebView()

        final class Box {
            let lock = NSLock()
            var continuation: CheckedContinuation<(String, Int32), Error>?

            init(_ continuation: CheckedContinuation<(String, Int32), Error>) {
                self.continuation = continuation
            }

            func resume(_ result: Result<(String, Int32), Error>) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(with: result)
            }
        }

        let (result, type): (String, Int32) = try await withCheckedThrowingContinuation { cont in
            let box = Box(cont)
            let raw = Unmanaged.passRetained(box).toOpaque()

            expression.withCString { cExpr in
                OWLBridge_EvaluateJavaScript(wv, cExpr, { result, resultType, ctx in
                    guard let ctx else { return }
                    let box = Unmanaged<Box>.fromOpaque(ctx).takeRetainedValue()
                    let value = result.map { String(cString: $0) } ?? ""
                    box.resume(.success((value, resultType)))
                }, raw)
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.resume(.failure(AppHostError.timedOut("EvaluateJavaScript callback")))
            }
        }

        if type == 1 {
            throw AppHostError.evaluateJSException(result)
        }
        return result
    }

    public func typeText(_ text: String) throws {
        let wv = try requireWebView()
        for ch in text {
            let s = String(ch)
            sendKeyEvent(webViewId: wv, type: 0, keyCode: 0, chars: s)
            if ch.asciiValue ?? 0 >= 0x20 {
                sendKeyEvent(webViewId: wv, type: 2, keyCode: 0, chars: s)
            }
            sendKeyEvent(webViewId: wv, type: 1, keyCode: 0, chars: s)
        }
    }

    public func sendKeyEvent(type: Int32, keyCode: Int32, modifiers: UInt32 = 0, chars: String? = nil) throws {
        let wv = try requireWebView()
        sendKeyEvent(webViewId: wv, type: type, keyCode: keyCode, modifiers: modifiers, chars: chars)
    }

    public func find(
        query: String,
        forward: Bool = true,
        matchCase: Bool = false,
        timeout: TimeInterval = 5
    ) async throws -> (requestId: Int32, matches: Int32, activeOrdinal: Int32) {
        final class FindState {
            private let lock = NSLock()
            var requestId: Int32 = 0
            var matches: Int32 = 0
            var activeOrdinal: Int32 = 0
            var receivedFinal = false

            func update(requestId: Int32, matches: Int32, activeOrdinal: Int32) {
                lock.lock()
                self.requestId = requestId
                self.matches = matches
                self.activeOrdinal = activeOrdinal
                self.receivedFinal = true
                lock.unlock()
            }

            var snapshot: (Int32, Int32, Int32, Bool) {
                lock.lock()
                defer { lock.unlock() }
                return (requestId, matches, activeOrdinal, receivedFinal)
            }
        }

        let wv = try requireWebView()
        let state = FindState()
        let stateCtx = Unmanaged.passUnretained(state).toOpaque()
        OWLBridge_SetFindResultCallback(wv, { _, requestId, numMatches, activeOrdinal, finalUpdate, ctx in
            guard finalUpdate != 0, let ctx else { return }
            let state = Unmanaged<FindState>.fromOpaque(ctx).takeUnretainedValue()
            state.update(requestId: requestId, matches: numMatches, activeOrdinal: activeOrdinal)
        }, stateCtx)
        defer {
            OWLBridge_SetFindResultCallback(wv, nil, nil)
        }

        let requestId: Int32 = try await withCheckedThrowingContinuation { cont in
            let raw = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            query.withCString { cQuery in
                OWLBridge_Find(wv, cQuery, forward ? 1 : 0, matchCase ? 1 : 0, { reqId, ctx in
                    let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                        as! CheckedContinuation<Int32, Error>
                    cont.resume(returning: reqId)
                }, raw)
            }
        }

        guard requestId > 0 else {
            throw AppHostError.bridgeError("Find returned invalid request id: \(requestId)")
        }

        let ok = await WaitHelper.waitUntil(timeout: timeout) {
            let (rid, _, _, final) = state.snapshot
            return final && rid == requestId
        }
        guard ok else {
            throw AppHostError.timedOut("find result for request \(requestId)")
        }

        let (_, matches, activeOrdinal, _) = state.snapshot
        return (requestId, matches, activeOrdinal)
    }

    public func setZoomLevel(_ level: Double) async throws {
        let wv = try requireWebView()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let raw = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_SetZoomLevel(wv, level, { ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<Void, Error>
                cont.resume()
            }, raw)
        }
    }

    public func getZoomLevel() async throws -> Double {
        let wv = try requireWebView()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
            let raw = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_GetZoomLevel(wv, { level, ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<Double, Error>
                cont.resume(returning: level)
            }, raw)
        }
    }

    public func bookmarkGetAll() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let raw = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_BookmarkGetAll({ jsonArray, errorMsg, ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<String, Error>
                if let errorMsg {
                    cont.resume(throwing: AppHostError.bridgeError(String(cString: errorMsg)))
                    return
                }
                guard let jsonArray else {
                    cont.resume(throwing: AppHostError.bridgeError("BookmarkGetAll returned null payload"))
                    return
                }
                cont.resume(returning: String(cString: jsonArray))
            }, raw)
        }
    }

    public func bookmarkAdd(
        title: String,
        url: String,
        parentId: String? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let raw = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            title.withCString { cTitle in
                url.withCString { cURL in
                    if let parentId {
                        parentId.withCString { cParent in
                            OWLBridge_BookmarkAdd(cTitle, cURL, cParent, { json, errorMsg, ctx in
                                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                                    as! CheckedContinuation<String, Error>
                                if let errorMsg {
                                    cont.resume(throwing: AppHostError.bridgeError(String(cString: errorMsg)))
                                    return
                                }
                                guard let json else {
                                    cont.resume(throwing: AppHostError.bridgeError("BookmarkAdd returned null payload"))
                                    return
                                }
                                cont.resume(returning: String(cString: json))
                            }, raw)
                        }
                    } else {
                        OWLBridge_BookmarkAdd(cTitle, cURL, nil, { json, errorMsg, ctx in
                            let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                                as! CheckedContinuation<String, Error>
                            if let errorMsg {
                                cont.resume(throwing: AppHostError.bridgeError(String(cString: errorMsg)))
                                return
                            }
                            guard let json else {
                                cont.resume(throwing: AppHostError.bridgeError("BookmarkAdd returned null payload"))
                                return
                            }
                            cont.resume(returning: String(cString: json))
                        }, raw)
                    }
                }
            }
        }
    }

    public func bookmarkRemove(id: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            let raw = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            id.withCString { cId in
                OWLBridge_BookmarkRemove(cId, { success, errorMsg, ctx in
                    let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                        as! CheckedContinuation<Bool, Error>
                    if let errorMsg {
                        cont.resume(throwing: AppHostError.bridgeError(String(cString: errorMsg)))
                        return
                    }
                    cont.resume(returning: success != 0)
                }, raw)
            }
        }
    }

    public func setPermission(
        origin: String,
        type: AppHostPermissionType,
        status: AppHostPermissionStatus
    ) {
        origin.withCString { cOrigin in
            OWLBridge_PermissionSet(cOrigin, Int32(type.rawValue), Int32(status.rawValue))
        }
    }

    public func getPermission(
        origin: String,
        type: AppHostPermissionType
    ) async throws -> AppHostPermissionStatus {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AppHostPermissionStatus, Error>) in
            let raw = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            origin.withCString { cOrigin in
                OWLBridge_PermissionGet(cOrigin, Int32(type.rawValue), { status, errorMsg, ctx in
                    let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                        as! CheckedContinuation<AppHostPermissionStatus, Error>
                    if let errorMsg {
                        cont.resume(throwing: AppHostError.bridgeError(String(cString: errorMsg)))
                        return
                    }
                    guard let permissionStatus = AppHostPermissionStatus(rawValue: Int32(status)) else {
                        cont.resume(throwing: AppHostError.bridgeError("Unknown permission status: \(status)"))
                        return
                    }
                    cont.resume(returning: permissionStatus)
                }, raw)
            }
        }
    }

    public func resetPermission(origin: String, type: AppHostPermissionType) {
        origin.withCString { cOrigin in
            OWLBridge_PermissionReset(cOrigin, Int32(type.rawValue))
        }
    }

    private func sendKeyEvent(
        webViewId: UInt64,
        type: Int32,
        keyCode: Int32,
        modifiers: UInt32 = 0,
        chars: String? = nil
    ) {
        let ts = ProcessInfo.processInfo.systemUptime
        chars?.withCString { cstr in
            OWLBridge_SendKeyEvent(webViewId, type, keyCode, modifiers, cstr, cstr, ts)
        } ?? OWLBridge_SendKeyEvent(webViewId, type, keyCode, modifiers, nil, nil, ts)
    }

    private func registerCallbacks() {
        let wv = webViewId
        let ctx = Unmanaged.passUnretained(loadSignal).toOpaque()

        OWLBridge_SetPageInfoCallback(wv, { _, _, url, isLoading, _, _, ctx in
            guard let ctx else { return }
            let signal = Unmanaged<LoadSignal>.fromOpaque(ctx).takeUnretainedValue()
            let value = url.map { String(cString: $0) }
            signal.onPageInfo(url: value, isLoading: isLoading)
        }, ctx)

        OWLBridge_SetLoadFinishedCallback(wv, { _, success, ctx in
            guard let ctx else { return }
            let signal = Unmanaged<LoadSignal>.fromOpaque(ctx).takeUnretainedValue()
            signal.onLoadFinished(success: success)
        }, ctx)
    }

    private func unregisterCallbacks(webViewId: UInt64) {
        OWLBridge_SetPageInfoCallback(webViewId, nil, nil)
        OWLBridge_SetLoadFinishedCallback(webViewId, nil, nil)
    }

    private func requireWebView() throws -> UInt64 {
        guard webViewId != 0 else {
            throw AppHostError.missingWebView
        }
        return webViewId
    }

    private static func initializeBridgeIfNeeded() {
        initLock.lock()
        if initialized {
            initLock.unlock()
            return
        }
        initialized = true
        initLock.unlock()

        let initialize = {
            setenv("OWL_ENABLE_TEST_JS", "1", 1)
            OWLBridge_Initialize()
        }
        if Thread.isMainThread {
            initialize()
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            initialize()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func launchHost(path: String, userDataDir: String, port: UInt16) async throws -> (UInt64, pid_t) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(UInt64, pid_t), Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            path.withCString { pathPtr in
                userDataDir.withCString { dirPtr in
                    OWLBridge_LaunchHost(pathPtr, dirPtr, port, { pipe, pid, errMsg, ctx in
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

    private func createBrowserContext() async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_CreateBrowserContext(nil, 0, { contextId, errMsg, ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<UInt64, Error>
                if let errMsg {
                    cont.resume(throwing: NSError(
                        domain: "OWLBridge", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                } else {
                    cont.resume(returning: contextId)
                }
            }, ctx)
        }
    }

    private func createWebView(contextId: UInt64) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_CreateWebView(contextId, { webViewId, errMsg, ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<UInt64, Error>
                if let errMsg {
                    cont.resume(throwing: NSError(
                        domain: "OWLBridge", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                } else {
                    cont.resume(returning: webViewId)
                }
            }, ctx)
        }
    }

    private func setActiveWebView(_ webViewId: UInt64) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let ctx = Unmanaged.passRetained(cont as AnyObject).toOpaque()
            OWLBridge_SetActiveWebView(webViewId, { errMsg, ctx in
                let cont = Unmanaged<AnyObject>.fromOpaque(ctx!).takeRetainedValue()
                    as! CheckedContinuation<Void, Error>
                if let errMsg {
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
