import Foundation
import SwiftUI

#if canImport(OWLBridge)
import OWLBridge
#endif

// Phase 33: Find-in-Page state.
package struct FindState {
    let query: String
    let activeOrdinal: Int  // 1-based
    let totalMatches: Int

    init(query: String = "", activeOrdinal: Int = 0, totalMatches: Int = 0) {
        self.query = query
        self.activeOrdinal = activeOrdinal
        self.totalMatches = totalMatches
    }
}

@MainActor
package class TabViewModel: ObservableObject, Identifiable {
    package let id: UUID
    package var webviewId: UInt64 = 1
    private let usesBridge: Bool

    /// Phase 2: pinned tab (stays at the left, cannot be closed by normal close).
    @Published var isPinned: Bool = false
    /// Phase 2: deferred tab (created but webview not yet loaded, for session restore).
    @Published var isDeferred: Bool = false
    /// Phase 4: set by closeTab when auto-creating a blank tab after closing the last tab.
    /// Used by undoCloseTab to decide whether to replace this blank tab.
    var isAutoCreatedBlank: Bool = false

    @Published var title: String
    @Published var url: String?
    // Tracks the most recently requested URL from navigate().
    // Updated synchronously so XCUITest can verify navigation was triggered
    // without waiting for Chromium to commit the page.
    @Published var pendingURL: String?
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    #if canImport(OWLBridge)
    private var tab: OWLTab?

    init(tab: OWLTab) {
        self.usesBridge = true
        self.tab = tab
        self.id = tab.tabId as UUID
        self.title = tab.title ?? "新标签页"
        self.url = tab.url
    }
    #endif

    // Mock initializer
    private init(id: UUID, title: String, url: String?) {
        self.usesBridge = false
        self.id = id
        self.title = title
        self.url = url
    }

    static func mock(title: String, url: String?) -> TabViewModel {
        TabViewModel(id: UUID(), title: title, url: url)
    }

    @Published private(set) var cachedHost: String?

    var displayTitle: String {
        if !title.isEmpty && title != "新标签页" { return title }
        if let host = cachedHost { return host }
        return "新标签页"
    }

    var displayDomain: String? { cachedHost }

    func updateCachedHost() {
        cachedHost = url.flatMap { URL(string: $0)?.host }
    }

    // Render surface from Host compositor (CALayerHost contextId).
    @Published var caContextId: UInt32 = 0
    @Published var renderPixelWidth: UInt32 = 0
    @Published var renderPixelHeight: UInt32 = 0
    @Published var renderScaleFactor: Float = 2.0

    var isWelcomePage: Bool { url == nil && !isLoading }
    var hasRenderSurface: Bool { caContextId != 0 }

    // MARK: - Viewport Sync

    func updateViewport(dipWidth: CGFloat, dipHeight: CGFloat, scale: CGFloat) {
        #if canImport(OWLBridge)
        guard usesBridge else { return }
        guard dipWidth > 0, dipHeight > 0, scale > 0 else { return }

        let w = UInt32(clamping: Int(dipWidth.rounded()))
        let h = UInt32(clamping: Int(dipHeight.rounded()))
        let s = Float(scale)

        OWLBridge_UpdateViewGeometry(webviewId, w, h, s, { errMsg, ctx in
            if let errMsg {
                NSLog("%@", "[OWL] UpdateViewGeometry failed: \(String(cString: errMsg))")
            }
        }, nil)
        #endif
    }

    // MARK: - Navigation (real mode)

    func navigate(to input: String) {
        #if canImport(OWLBridge)
        guard usesBridge else {
            simulateMockNavigation(to: input)
            return
        }

        // Normalize fullwidth/CJK periods to ASCII period for URL detection.
        let normalized = input
            .replacingOccurrences(of: "\u{3002}", with: ".")  // 。→ .
            .replacingOccurrences(of: "\u{FF0E}", with: ".")  // ．→ .
            .replacingOccurrences(of: "\u{FF61}", with: ".")  // ｡ → .

        // Canonicalize URL via C-ABI.
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr: String
        let hasScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://")
        if hasScheme {
            // Explicit scheme — use as-is (handles localhost, IP, etc.)
            urlStr = trimmed
        } else if OWLBridgeSwift.inputLooksLikeURL(trimmed) {
            urlStr = "https://\(trimmed)"
        } else {
            urlStr = "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        }

        isLoading = true
        pendingURL = urlStr
        url = urlStr
        updateCachedHost()
        NSLog("%@", "[OWL] TabVM.navigate: url=\(urlStr) isWelcomePage=\(isWelcomePage) isLoading=\(isLoading)")

        // Navigate via C-ABI.
        // PageInfo and RenderSurface callbacks are registered once in
        // BrowserViewModel.registerAllCallbacks — no per-navigate setup needed.
        urlStr.withCString { cStr in
            OWLBridge_Navigate(webviewId, cStr, { success, status, errMsg, ctx in
                // Navigation initiated — real updates come via PageInfoCallback.
                if success == 0 {
                    let err = errMsg.map { String(cString: $0) } ?? "Navigation failed"
                    NSLog("%@", "[OWL] Navigate failed: \(err)")
                }
            }, nil)
        }
        #else
        simulateMockNavigation(to: input)
        #endif
    }

    func goBack() {
        #if canImport(OWLBridge)
        if usesBridge {
            tab?.webView.goBack { }
        } else {
            canGoBack = false
        }
        #else
        canGoBack = false
        #endif
    }

    func goForward() {
        #if canImport(OWLBridge)
        if usesBridge {
            tab?.webView.goForward { }
        }
        #endif
    }

    func reload() {
        #if canImport(OWLBridge)
        if usesBridge {
            tab?.webView.reload { }
        }
        #endif
    }

    func stop() {
        #if canImport(OWLBridge)
        if usesBridge {
            tab?.webView.stop { }
        }
        #endif
        isLoading = false
        // Stop clears progress and slow loading, but does NOT show error page.
        fakeProgressTask?.cancel()
        slowLoadingTask?.cancel()
        loadingProgress = 0.0
        isSlowLoading = false
    }

    // MARK: - Navigation State Machine (Phase 2 Navigation Events)

    @Published var loadingProgress: Double = 0.0
    @Published var navigationError: NavigationError? = nil
    @Published var isSlowLoading: Bool = false
    package private(set) var currentNavigationId: Int64 = 0
    private var fakeProgressTask: Task<Void, Never>? = nil
    private var slowLoadingTask: Task<Void, Never>? = nil

    /// Called when a non-redirect navigation starts. Resets error and starts fake progress.
    func onNavigationStarted(navigationId: Int64, url: String, isUserInitiated: Bool) {
        fakeProgressTask?.cancel()
        slowLoadingTask?.cancel()
        currentNavigationId = navigationId
        navigationError = nil
        loadingProgress = 0.1
        isSlowLoading = false

        // Fake progress: slowly crawl from 0.1 to ~0.5
        fakeProgressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.loadingProgress < 0.5 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, self.currentNavigationId == navigationId else { return }
                self.loadingProgress += 0.02
            }
        }

        // Slow loading timer: show banner after 5 seconds
        slowLoadingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.currentNavigationId == navigationId else { return }
            if self.isLoading { self.isSlowLoading = true }
        }
    }

    /// Called when a redirect navigation starts. Does NOT reset progress or error.
    func onNavigationRedirected(navigationId: Int64, url: String) {
        // Redirect: update currentNavigationId but keep progress and slow loading state.
        currentNavigationId = navigationId
    }

    /// Called when navigation commits (response headers received).
    func onNavigationCommitted(navigationId: Int64, url: String, httpStatus: Int32) {
        guard currentNavigationId == navigationId else { return }
        // Jump progress to 0.6 on commit
        if loadingProgress < 0.6 {
            loadingProgress = 0.6
        }
        // Continue slow crawl from 0.6 to ~0.9
        fakeProgressTask?.cancel()
        fakeProgressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.loadingProgress < 0.9 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, self.currentNavigationId == navigationId else { return }
                self.loadingProgress += 0.02
            }
        }
    }

    /// Called when navigation fails. Sets error (unless ERR_ABORTED).
    func onNavigationFailed(navigationId: Int64, url: String,
                            errorCode: Int32, errorDescription: String) {
        guard currentNavigationId == navigationId else { return }
        fakeProgressTask?.cancel()
        slowLoadingTask?.cancel()
        loadingProgress = 0.0
        isSlowLoading = false

        let error = NavigationError(
            navigationId: navigationId,
            url: url,
            errorCode: errorCode,
            errorDescription: errorDescription
        )
        // ERR_ABORTED (-3): user stopped loading — don't show error page.
        if !error.isAborted {
            navigationError = error
        }
    }

    /// Called when page finishes loading (via PageInfo isLoading=false transition).
    func completeNavigation(success: Bool) {
        fakeProgressTask?.cancel()
        slowLoadingTask?.cancel()
        isSlowLoading = false
        isLoading = false  // Backup: ensure loading state is cleared

        if success {
            loadingProgress = 1.0
            // Fade out after 300ms, then reset to 0.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.navigationError = nil
                self.loadingProgress = 0.0
            }
        } else {
            loadingProgress = 0.0
        }
    }

    // MARK: - HTTP Auth (Phase 3)

    @Published var authChallenge: AuthChallenge? = nil

    // MARK: - Zoom Control (Phase 34)

    @Published var zoomLevel: Double = 0.0  // 0.0 = 100%

    var zoomPercent: Int {
        Int(round(pow(1.2, zoomLevel) * 100))
    }
    var isDefaultZoom: Bool { abs(zoomLevel) < 0.01 }

    private let zoomStep = 1.0        // pow(1.2, 1.0) ≈ 1.2x, ±20% per step
    private let minZoomLevel = -7.6   // ≈ 25%
    private let maxZoomLevel = 8.8    // ≈ 500%

    func zoomIn() {
        let newLevel = min(zoomLevel + zoomStep, maxZoomLevel)
        setZoom(newLevel)
    }

    func zoomOut() {
        let newLevel = max(zoomLevel - zoomStep, minZoomLevel)
        setZoom(newLevel)
    }

    func resetZoom() { setZoom(0.0) }

    private func setZoom(_ level: Double) {
        #if canImport(OWLBridge)
        if usesBridge {
            OWLBridge_SetZoomLevel(webviewId, level, { ctx in
                // ack, no-op
            }, nil)
        } else {
            zoomLevel = level  // Mock mode
        }
        #else
        zoomLevel = level  // Mock mode
        #endif
    }

    // MARK: - Find-in-Page (Phase 33)

    @Published var findState: FindState?
    @Published var isFindBarVisible: Bool = false
    private var activeFindRequestId: Int32 = 0
    func showFindBar() { isFindBarVisible = true }

    func hideFindBar() {
        isFindBarVisible = false
        activeFindRequestId = 0  // Invalidate all in-flight FindReply
        stopFinding()
        findState = nil
    }

    func find(query: String, forward: Bool = true, matchCase: Bool = false) {
        guard !query.isEmpty else {
            activeFindRequestId = 0
            stopFinding()
            findState = FindState()
            return
        }
        #if canImport(OWLBridge)
        findState = FindState(query: query)
        guard usesBridge else { return }

        query.withCString { cStr in
            OWLBridge_Find(webviewId, cStr, forward ? 1 : 0, matchCase ? 1 : 0, { requestId, ctx in
                let vm = Unmanaged<TabViewModel>.fromOpaque(ctx!).takeUnretainedValue()
                Task { @MainActor in
                    vm.activeFindRequestId = requestId
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        #endif
    }

    func findNext() {
        guard let q = findState?.query, !q.isEmpty else { return }
        find(query: q, forward: true)
    }
    func findPrevious() {
        guard let q = findState?.query, !q.isEmpty else { return }
        find(query: q, forward: false)
    }

    func stopFinding() {
        #if canImport(OWLBridge)
        guard usesBridge else { return }
        OWLBridge_StopFinding(webviewId, OWLBridgeStopFindAction_ClearSelection)
        #endif
    }

    private func simulateMockNavigation(to input: String) {
        isLoading = true
        let mockURL = input.hasPrefix("http") ? input : "https://\(input)"
        pendingURL = mockURL
        url = mockURL
        updateCachedHost()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.title = self?.cachedHost ?? input
            self?.isLoading = false
            self?.canGoBack = true
        }
    }

    /// Handle find result forwarded from BrowserViewModel's centralized callback.
    func handleFindResult(requestId: Int32, matches: Int,
                          activeOrdinal: Int, isFinal: Bool) {
        guard isFindBarVisible else { return }
        guard requestId == activeFindRequestId else { return }
        guard isFinal else { return }

        findState = FindState(
            query: findState?.query ?? "",
            activeOrdinal: activeOrdinal,
            totalMatches: matches
        )
    }

    #if canImport(OWLBridge)
    func updatePageInfo(_ info: OWLPageInfo) {
        title = info.title ?? displayTitle
        url = info.url
        isLoading = info.isLoading
        canGoBack = info.canGoBack
        canGoForward = info.canGoForward
    }

    func updateLoadFinished(success: Bool) {
        isLoading = false
    }
    #endif
}
