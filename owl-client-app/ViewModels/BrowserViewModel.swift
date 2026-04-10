import Foundation
import SwiftUI

// Conditionally import OWLBridge — when not available, use mock mode
#if canImport(OWLBridge)
import OWLBridge
// C-ABI mode: use OWLBridge_* functions (no ObjC++ classes on main thread)
private let useMockMode = false
#else
private let useMockMode = true
#endif

// Context for C callback (must be class for Unmanaged)
private final class LaunchContext: @unchecked Sendable {
    let vm: BrowserViewModel
    let gen: UInt
    init(vm: BrowserViewModel, gen: UInt) { self.vm = vm; self.gen = gen }
}

// Free function for C callback (no closure capture).
// C-ABI guarantees this fires on main thread via dispatch_get_main_queue().
// Use MainActor.assumeIsolated to tell Swift we're already on main thread.
private func launchHostCallback(sessionPipe: UInt64, pid: pid_t,
                                 errMsg: UnsafePointer<CChar>?, ctx: UnsafeMutableRawPointer?) {
    let rawCtx = ctx!
    let pipe = sessionPipe; let cpid = pid
    let err = errMsg.map { String(cString: $0) }
    let lctx = Unmanaged<LaunchContext>.fromOpaque(rawCtx).takeRetainedValue()
    // Dispatch to MainActor since C callback is on main thread but Swift doesn't know.
    Task { @MainActor in
        let vm = lctx.vm
        guard lctx.gen == vm.launchGeneration else { return }
        if let err {
            vm.connectionState = .failed(err)
            return
        }
        NSLog("%@", "[OWL] Host launched (PID=\(cpid)), pipe=\(pipe). Creating session...")
        vm.hostPID = cpid
        vm.sessionPipe = pipe
        vm.handleHostLaunched(sessionId: pipe)
    }
}

package enum SidebarMode: Equatable {
    case tabs
    case bookmarks
    case history
    case downloads
}

package enum ConnectionState: Equatable {
    case disconnected
    case launching
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

// MARK: - Closed Tab Info (for undo-close)

package struct ClosedTabInfo {
    let url: String
    let title: String
    let isPinned: Bool
    let insertIndex: Int
}

@MainActor
package class BrowserViewModel: NSObject, ObservableObject {
    @Published package var connectionState: ConnectionState = .disconnected
    @Published package var tabs: [TabViewModel] = []
    @Published package var activeTab: TabViewModel?
    @Published package var rightPanel: RightPanel = .none
    @Published package var sidebarMode: SidebarMode = .tabs
    package let bookmarkVM = BookmarkViewModel()
    package let historyVM = HistoryViewModel()
    package let downloadVM = DownloadViewModel()
    package let permissionVM = PermissionViewModel()
    package let securityVM = SecurityViewModel()
    package let consoleVM = ConsoleViewModel()
    package let sessionService = SessionRestoreService()
    package private(set) var contextMenuHandler: ContextMenuHandler?
    package var webviewId: UInt64 = 0
    /// Phase 2: webview_id → TabViewModel routing table for multi-tab support.
    private var webviewIdMap: [UInt64: TabViewModel] = [:]
    package let navigationEventRing = NavigationEventRing()
    private let cliServer = CLISocketServer()

    // MARK: - Phase 4: Closed tabs stack + pending restore queue
    package var closedTabsStack: [ClosedTabInfo] = []
    /// Queue of pending restores — each entry maps to one createTab callback.
    private var pendingRestoreQueue: [ClosedTabInfo] = []
    /// Number of pending createTab calls that should mark the new tab as auto-created blank.
    private var pendingAutoBlankCount: Int = 0

    // MARK: - MockConfig (for ViewModel unit tests without Host)

    package struct MockConfig {
        package var initialTabs: [(title: String, url: String?)]
        package var connectionDelay: TimeInterval
        package var shouldFail: Bool
        package var failMessage: String

        package init(
            initialTabs: [(title: String, url: String?)] = [("新标签页", nil)],
            connectionDelay: TimeInterval = 0,
            shouldFail: Bool = false,
            failMessage: String = ""
        ) {
            self.initialTabs = initialTabs
            self.connectionDelay = connectionDelay
            self.shouldFail = shouldFail
            self.failMessage = failMessage
        }
    }

    private var mockConfig: MockConfig?

    /// True if running in mock mode (compile-time OR runtime override).
    private var isMockMode: Bool { mockConfig != nil || useMockMode }

    /// Test-only initializer: inject MockConfig to bypass Host launch.
    package convenience init(mockConfig: MockConfig) {
        self.init()
        self.mockConfig = mockConfig
    }

    #if canImport(OWLBridge)
    private var session: OWLBridgeSession?
    private var browserContext: OWLBridgeBrowserContext?
    private var tabManager: OWLTabManager?
    #endif
    fileprivate var hostPID: pid_t = 0
    fileprivate var sessionPipe: UInt64 = 0
    fileprivate var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private let maxReconnectAttempts = 3
    fileprivate var launchGeneration: UInt = 0
    private var hasLaunched = false  // guards against .task{} re-trigger

    /// Deferred initialization entry point — called from ContentView.task {}.
    /// Initializes Mojo runtime (after SwiftUI window exists) then launches host.
    func initializeAndLaunch() async {
        guard !hasLaunched else { return }
        hasLaunched = true

        #if canImport(OWLBridge)
        OWLBridgeSwift.initialize()
        PermissionBridge.shared.register(permissionVM: permissionVM)
        SSLBridge.shared.registerGlobal(securityVM: securityVM)
        #endif

        // Wire up session restore provider.
        sessionService.tabStateProvider = { [weak self] in
            guard let self else { return [] }
            return self.tabs.compactMap { tab -> SessionTab? in
                // Skip blank/welcome tabs with no URL.
                guard let url = tab.url, !url.isEmpty else { return nil }
                return SessionTab(
                    url: url,
                    title: tab.title,
                    isPinned: tab.isPinned,
                    isActive: tab.id == self.activeTab?.id
                )
            }
        }

        await bookmarkVM.loadAll()

        // Wire up history navigation callback
        historyVM.onNavigate = { [weak self] url in
            if let tab = self?.activeTab {
                tab.navigate(to: url)
            }
        }

        // Start CLI socket server
        let router = CLICommandRouter(browser: self)
        cliServer.start(router: router)

        launch()
    }

    func launch() {
        // Runtime mock override — MockConfig takes priority over compile-time flag
        if mockConfig != nil {
            NSLog("%@", "[OWL] launch() → mockConfig override")
            launchMock()
            return
        }
        NSLog("%@", "[OWL] launch() called, useMockMode=\(useMockMode)")
        if useMockMode {
            NSLog("%@", "[OWL] → launchMock")
            launchMock()
        } else {
            #if canImport(OWLBridge)
            NSLog("%@", "[OWL] → launchReal")
            launchReal()
            #else
            NSLog("%@", "[OWL] → no OWLBridge, fallback mock")
            launchMock()
            #endif
        }
    }

    package func shutdown() {
        // Save session synchronously before teardown.
        sessionService.cancelPendingSave()
        sessionService.saveCurrentState()

        cliServer.stop()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        #if canImport(OWLBridge)
        // Clear callbacks for all webviews before shutdown.
        for wvId in webviewIdMap.keys {
            clearCallbacks(wvId)
        }
        webviewIdMap.removeAll()
        session?.shutdown { }
        cleanupSession()
        #endif
    }

    // MARK: - Mock Mode

    private func launchMock() {
        let config = mockConfig ?? MockConfig()
        connectionState = .launching
        if config.shouldFail {
            connectionState = .failed(config.failMessage)
            return
        }
        Task { @MainActor [weak self] in
            if config.connectionDelay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(config.connectionDelay * 1000)))
            }
            for tab in config.initialTabs {
                self?.createMockTab(title: tab.title, url: tab.url)
            }
            self?.connectionState = .connected
        }
    }

    // MARK: - Tab Management

    func createTab(url: String? = nil) {
        if isMockMode {
            createMockTab(title: url ?? "新标签页", url: url)
        } else {
            #if canImport(OWLBridge)
            guard browserContextId > 0 else { return }
            if let url { pendingURLQueue.append(url) }
            let ctxId = browserContextId
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wvId: UInt64
                do {
                    wvId = try await bridgeCreateWebView(ctxId)
                } catch {
                    NSLog("%@", "[OWL] CreateWebView failed: \(error.localizedDescription)")
                    return
                }
                NSLog("%@", "[OWL] Web view created (id=\(wvId))")
                let tab = TabViewModel.mock(title: "新标签页", url: nil)
                tab.webviewId = wvId
                // Mark as auto-created blank if this tab was created to replace the last closed tab.
                if self.pendingAutoBlankCount > 0 {
                    tab.isAutoCreatedBlank = true
                    self.pendingAutoBlankCount -= 1
                }
                self.tabs.append(tab)
                self.webviewIdMap[wvId] = tab
                self.webviewId = wvId
                self.registerAllCallbacks(wvId)
                self.activateTab(tab)
                // Navigate if URL was provided (FIFO: consume the oldest pending URL).
                if !self.pendingURLQueue.isEmpty {
                    let pendingURL = self.pendingURLQueue.removeFirst()
                    tab.navigate(to: pendingURL)
                }
            }
            #endif
        }
    }

    /// Phase 3 Multi-tab: Create a new tab from a Host-initiated new-tab request.
    /// Inserts at `insertIndex` (clamped to bounds). If `foreground`, activates
    /// the new tab; otherwise it opens in background.
    private func createTabForNewTabRequest(url: String, insertIndex: Int, foreground: Bool) {
        #if canImport(OWLBridge)
        guard browserContextId > 0 else { return }
        // Enqueue the URL + insertion metadata for the CreateWebView callback.
        pendingNewTabRequests.append(PendingTabRequest(
            url: url, insertIndex: insertIndex, foreground: foreground))
        let ctxId = browserContextId
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wvId: UInt64
            do {
                wvId = try await bridgeCreateWebView(ctxId)
            } catch {
                NSLog("%@", "[OWL] CreateWebView (new tab request) failed: \(error.localizedDescription)")
                // Pop the pending request on failure.
                if !self.pendingNewTabRequests.isEmpty {
                    self.pendingNewTabRequests.removeFirst()
                }
                return
            }
            guard !self.pendingNewTabRequests.isEmpty else { return }
            let request = self.pendingNewTabRequests.removeFirst()

            NSLog("%@", "[OWL] Web view created for new tab request (id=\(wvId)) url=\(request.url)")
            let tab = TabViewModel.mock(title: "新标签页", url: nil)
            tab.webviewId = wvId

            // Insert at the requested position (clamped to valid range).
            let idx = min(max(request.insertIndex, 0), self.tabs.count)
            self.tabs.insert(tab, at: idx)
            self.webviewIdMap[wvId] = tab
            self.registerAllCallbacks(wvId)

            if request.foreground {
                self.activateTab(tab)
            }

            // Navigate to the target URL.
            tab.navigate(to: request.url)
        }
        #endif
    }

    func closeTab(_ tabVM: TabViewModel) {
        // Phase 4: Push to closed tabs stack for undo.
        let insertIndex = tabs.firstIndex(where: { $0.id == tabVM.id }) ?? tabs.count
        let closedInfo = ClosedTabInfo(
            url: tabVM.url ?? "",
            title: tabVM.title,
            isPinned: tabVM.isPinned,
            insertIndex: insertIndex
        )
        closedTabsStack.append(closedInfo)
        if closedTabsStack.count > 20 {
            closedTabsStack.removeFirst()
        }

        // Remove from deferred activation queue to prevent stale callbacks.
        pendingDeferredActivations.removeAll { $0.id == tabVM.id }

        if isMockMode {
            tabs.removeAll { $0.id == tabVM.id }
            if activeTab?.id == tabVM.id {
                activeTab = tabs.first
            }
            if tabs.isEmpty {
                createTab()
                tabs.last?.isAutoCreatedBlank = true
            }
        } else {
            #if canImport(OWLBridge)
            let wvId = tabVM.webviewId
            let isDeferred = tabVM.isDeferred
            // Only clear callbacks and destroy if this tab has a real WebView.
            if !isDeferred && wvId != 0 {
                clearCallbacks(wvId)
                webviewIdMap.removeValue(forKey: wvId)
            }
            // Remove from tabs array.
            tabs.removeAll { $0.id == tabVM.id }
            // If this was the active tab, switch to another.
            if activeTab?.id == tabVM.id {
                activeTab = tabs.first
                if let newActive = activeTab, !newActive.isDeferred {
                    webviewId = newActive.webviewId
                    OWLBridge_SetActiveWebView(newActive.webviewId, nil, nil)
                }
            }
            // Destroy the webview in the bridge (only if real).
            if !isDeferred && wvId != 0 {
                OWLBridge_DestroyWebView(wvId, nil, nil)
            }
            // If no tabs left, create a new one (marked as auto-created blank).
            if tabs.isEmpty {
                pendingAutoBlankCount += 1
                createTab()
            }
            // Schedule save after tab close.
            sessionService.scheduleSave()
            #endif
        }
    }

    func activateTab(_ tabVM: TabViewModel) {
        if isMockMode {
            activeTab = tabVM
            // Handle deferred tab in mock mode.
            if tabVM.isDeferred {
                tabVM.isDeferred = false
                if let url = tabVM.url, !url.isEmpty {
                    tabVM.navigate(to: url)
                }
            }
        } else {
            #if canImport(OWLBridge)
            // Handle deferred tab: create real WebView, then activate on completion.
            if tabVM.isDeferred {
                guard browserContextId > 0 else { return }
                activeTab = tabVM  // Set active immediately for UI responsiveness.
                // De-duplicate: skip if this tab is already queued for activation.
                if pendingDeferredActivations.contains(where: { $0.id == tabVM.id }) { return }
                // Enqueue tab reference before CreateWebView; consumed FIFO in the callback.
                pendingDeferredActivations.append(tabVM)
                let ctxId = browserContextId
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let wvId: UInt64
                    do {
                        wvId = try await bridgeCreateWebView(ctxId)
                    } catch {
                        NSLog("%@", "[OWL] CreateWebView (deferred activate) failed: \(error.localizedDescription)")
                        // Discard the queued entry on failure.
                        if !self.pendingDeferredActivations.isEmpty {
                            self.pendingDeferredActivations.removeFirst()
                        }
                        return
                    }
                    guard !self.pendingDeferredActivations.isEmpty else {
                        NSLog("%@", "[OWL] CreateWebView (deferred activate): no pending activation")
                        return
                    }
                    let tab = self.pendingDeferredActivations.removeFirst()
                    let deferredURL = tab.url
                    NSLog("%@", "[OWL] Deferred tab activated (wvId=\(wvId))")
                    tab.webviewId = wvId
                    tab.isDeferred = false
                    self.webviewIdMap[wvId] = tab
                    self.webviewId = wvId
                    self.registerAllCallbacks(wvId)
                    OWLBridge_SetActiveWebView(wvId, nil, nil)
                    self.contextMenuHandler?.tabViewModel = tab
                    // Navigate to the stored URL.
                    if let url = deferredURL, !url.isEmpty {
                        tab.navigate(to: url)
                    }
                }
            } else {
                activeTab = tabVM
                webviewId = tabVM.webviewId
                OWLBridge_SetActiveWebView(tabVM.webviewId, nil, nil)
                // Update context menu handler's tab reference.
                contextMenuHandler?.tabViewModel = tabVM
            }
            #endif
        }
        // Persist active tab change for crash recovery.
        sessionService.scheduleSave()
    }

    func togglePanel(_ panel: RightPanel) {
        withAnimation(.spring(response: 0.35)) {
            rightPanel = rightPanel == panel ? .none : panel
        }
    }

    func toggleSidebarMode(_ mode: SidebarMode? = nil) {
        withAnimation(.spring(response: 0.35)) {
            if let mode {
                sidebarMode = sidebarMode == mode ? .tabs : mode
            } else {
                sidebarMode = sidebarMode == .tabs ? .bookmarks : .tabs
            }
        }
    }

    // MARK: - Phase 4: Pin / Unpin

    /// Pin a tab — idempotent: no-op if already pinned.
    /// Moves the tab to the end of the pinned section with animation.
    func pinTab(_ tabVM: TabViewModel) {
        guard !tabVM.isPinned else { return }
        withAnimation(.spring(response: 0.3)) {
            guard let idx = tabs.firstIndex(where: { $0.id == tabVM.id }) else { return }
            tabs.remove(at: idx)
            tabVM.isPinned = true
            // Insert after the last pinned tab.
            let pinnedEnd = tabs.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
            tabs.insert(tabVM, at: pinnedEnd)
        }
        sessionService.scheduleSave()
    }

    /// Unpin a tab — idempotent: no-op if not pinned.
    /// Moves the tab to the start of the unpinned section with animation.
    func unpinTab(_ tabVM: TabViewModel) {
        guard tabVM.isPinned else { return }
        withAnimation(.spring(response: 0.3)) {
            guard let idx = tabs.firstIndex(where: { $0.id == tabVM.id }) else { return }
            tabs.remove(at: idx)
            tabVM.isPinned = false
            // Insert at the start of unpinned section (= after last pinned).
            let pinnedEnd = tabs.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
            tabs.insert(tabVM, at: pinnedEnd)
        }
        sessionService.scheduleSave()
    }

    // MARK: - Phase 4: Undo Close Tab

    /// Undo the most recently closed tab (Cmd+Shift+T).
    /// Restores URL, isPinned, and position. If a blank auto-created tab exists
    /// (because closing the last tab triggered auto-create), replaces it.
    func undoCloseTab() {
        guard !closedTabsStack.isEmpty else { return }

        // In real mode, verify browserContextId before consuming the record.
        if !isMockMode {
            #if canImport(OWLBridge)
            guard browserContextId > 0 else { return }
            #endif
        }

        let info = closedTabsStack.removeLast()

        // Check if auto-created blank tab should be replaced.
        let shouldReplaceBlank = tabs.count == 1
            && tabs.first?.isAutoCreatedBlank == true

        if isMockMode {
            let tab = TabViewModel.mock(title: info.title, url: info.url.isEmpty ? nil : info.url)
            tab.isPinned = info.isPinned
            let idx = min(info.insertIndex, tabs.count)
            if shouldReplaceBlank {
                tabs.removeAll()
            }
            tabs.insert(tab, at: min(idx, tabs.count))
            activateTab(tab)
            if !info.url.isEmpty {
                tab.navigate(to: info.url)
            }
        } else {
            #if canImport(OWLBridge)
            // Enqueue restore info for the CreateWebView callback.
            pendingRestoreQueue.append(info)
            let ctxId = browserContextId
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wvId: UInt64
                do {
                    wvId = try await bridgeCreateWebView(ctxId)
                } catch {
                    NSLog("%@", "[OWL] CreateWebView (undo close) failed: \(error.localizedDescription)")
                    if !self.pendingRestoreQueue.isEmpty {
                        self.pendingRestoreQueue.removeFirst()
                    }
                    return
                }
                guard !self.pendingRestoreQueue.isEmpty else { return }
                let restoreInfo = self.pendingRestoreQueue.removeFirst()

                let tab = TabViewModel.mock(title: restoreInfo.title, url: nil)
                tab.webviewId = wvId
                tab.isPinned = restoreInfo.isPinned

                // Replace auto-created blank if applicable.
                let replaceBlank = self.tabs.count == 1
                    && self.tabs.first?.isAutoCreatedBlank == true
                if replaceBlank, let blankTab = self.tabs.first {
                    let blankWvId = blankTab.webviewId
                    self.clearCallbacks(blankWvId)
                    self.webviewIdMap.removeValue(forKey: blankWvId)
                    self.tabs.removeAll()
                    OWLBridge_DestroyWebView(blankWvId, nil, nil)
                }

                let idx = min(restoreInfo.insertIndex, self.tabs.count)
                self.tabs.insert(tab, at: idx)
                self.webviewIdMap[wvId] = tab
                self.webviewId = wvId
                self.registerAllCallbacks(wvId)
                self.activateTab(tab)

                if !restoreInfo.url.isEmpty {
                    tab.navigate(to: restoreInfo.url)
                }
            }
            #endif
        }
    }

    // MARK: - Phase 4: Close Others / Close Below

    /// Close all tabs except the given one. Pinned tabs are excluded from closure
    /// (unless the target itself is pinned, in which case other pinned tabs are also closed).
    func closeOtherTabs(_ tabVM: TabViewModel) {
        let tabsToClose = tabs.filter { tab in
            guard tab.id != tabVM.id else { return false }
            // Exclude pinned tabs from "close others" unless target is pinned.
            if tab.isPinned && !tabVM.isPinned { return false }
            return true
        }
        // Push in reverse order so undo restores in correct order.
        for tab in tabsToClose.reversed() {
            closeTab(tab)
        }
    }

    /// Close all tabs below the given one. Pinned tabs are excluded.
    func closeTabsBelow(_ tabVM: TabViewModel) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabVM.id }) else { return }
        let tabsToClose = Array(tabs[(idx + 1)...]).filter { !$0.isPinned }
        for tab in tabsToClose.reversed() {
            closeTab(tab)
        }
    }

    // MARK: - Phase 4: Tab Selection by Index

    /// Select tab by 1-based index. Cmd+9 always selects the last tab.
    func selectTabByIndex(_ index: Int) {
        guard !tabs.isEmpty else { return }
        if index == 9 {
            activateTab(tabs[tabs.count - 1])
        } else {
            let idx = index - 1
            guard idx >= 0, idx < tabs.count else { return }
            activateTab(tabs[idx])
        }
    }

    /// Select the previous tab (wraps around).
    func selectPreviousTab() {
        guard tabs.count > 1, let current = activeTab,
              let idx = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let newIdx = idx == 0 ? tabs.count - 1 : idx - 1
        activateTab(tabs[newIdx])
    }

    /// Select the next tab (wraps around).
    func selectNextTab() {
        guard tabs.count > 1, let current = activeTab,
              let idx = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let newIdx = idx == tabs.count - 1 ? 0 : idx + 1
        activateTab(tabs[newIdx])
    }

    /// Copy the URL of the given tab to the clipboard.
    func copyTabLink(_ tabVM: TabViewModel) {
        guard let url = tabVM.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    // MARK: - Mock Helpers

    fileprivate func createMockTab(title: String, url: String?) {
        let tab = TabViewModel.mock(title: title, url: url)
        tabs.append(tab)
        activeTab = tab
    }

    // MARK: - Real Mode
    #if canImport(OWLBridge)
    /// Context ID stored after CreateBrowserContext so createTab can use it.
    private var browserContextId: UInt64 = 0
    /// URLs to navigate after CreateWebView completes (FIFO queue).
    /// Appended before calling OWLBridge_CreateWebView, consumed in the callback.
    /// Using a queue (instead of a single variable) prevents a race where rapid
    /// createTab calls overwrite each other's pending URL.
    private var pendingURLQueue: [String] = []

    /// Phase 3 Multi-tab: Pending new tab requests (FIFO queue).
    /// Each entry holds URL + insertion position + foreground flag.
    ///
    /// Ordering assumption: OWLBridge_CreateWebView callbacks arrive in the
    /// same order as the calls were issued. This holds because all calls
    /// travel over a single Mojo pipe (guaranteed in-order delivery) and
    /// the host processes them sequentially on one IO thread. If this
    /// assumption ever breaks (e.g., multiple pipes or threads), this FIFO
    /// must be replaced with a keyed map (e.g., request-id → PendingTabRequest).
    private struct PendingTabRequest {
        let url: String
        let insertIndex: Int
        let foreground: Bool
    }
    private var pendingNewTabRequests: [PendingTabRequest] = []

    /// Deferred tab activations (FIFO queue).
    /// Enqueued before `OWLBridge_CreateWebView` in `activateTab`, consumed in the callback.
    /// Same ordering assumption as `pendingNewTabRequests`.
    private var pendingDeferredActivations: [TabViewModel] = []

    // MARK: - Box<CheckedContinuation> C-ABI Helpers

    /// Type-erased box for passing CheckedContinuation through C void* context.
    /// Using a dedicated Box class (instead of Unmanaged<AnyObject>) ensures the
    /// continuation is always resumed exactly once and prevents retain leaks when
    /// the C callback fires.
    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Wrap OWLBridge_CreateWebView in async/await using Box<CheckedContinuation>.
    /// Returns the created webview ID on success, throws on error.
    nonisolated private func bridgeCreateWebView(_ browserContextId: UInt64) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_CreateWebView(browserContextId, { wvId, errMsg, ctx in
                let box = Unmanaged<Box<CheckedContinuation<UInt64, Error>>>.fromOpaque(ctx!).takeRetainedValue()
                if let errMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLBridge", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                } else {
                    box.value.resume(returning: wvId)
                }
            }, ctx)
        }
    }

    /// Wrap OWLBridge_CreateBrowserContext in async/await using Box<CheckedContinuation>.
    /// Returns the created browser context ID on success, throws on error.
    nonisolated private func bridgeCreateBrowserContext() async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_CreateBrowserContext(nil, 0, { ctxId, errMsg, ctx in
                let box = Unmanaged<Box<CheckedContinuation<UInt64, Error>>>.fromOpaque(ctx!).takeRetainedValue()
                if let errMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLBridge", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errMsg)]))
                } else {
                    box.value.resume(returning: ctxId)
                }
            }, ctx)
        }
    }

    func handleHostLaunched(sessionId: UInt64) {
        #if canImport(OWLBridge)
        NSLog("%@", "[OWL] Creating browser context via C-ABI...")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ctxId: UInt64
            do {
                ctxId = try await bridgeCreateBrowserContext()
            } catch {
                self.connectionState = .failed(error.localizedDescription)
                return
            }
            NSLog("%@", "[OWL] Browser context created (id=\(ctxId)).")
            self.browserContextId = ctxId
            self.reconnectAttempt = 0
            Task { await self.downloadVM.loadAll() }
            self.connectionState = .connected

            // Check for saved session to restore.
            // OWL_CLEAN_SESSION=1: skip restore, start fresh (used by XCUITest).
            let cleanSession = ProcessInfo.processInfo.environment["OWL_CLEAN_SESSION"] == "1"
            if !cleanSession,
               let sessionData = self.sessionService.load(), !sessionData.tabs.isEmpty {
                self.restoreSession(sessionData)
            } else {
                // No session or clean session — create a fresh tab.
                self.createTab()
            }
        }
        #else
        connectionState = .connected
        reconnectAttempt = 0
        // Check for saved session in mock mode too.
        let cleanSession = ProcessInfo.processInfo.environment["OWL_CLEAN_SESSION"] == "1"
        if !cleanSession,
           let sessionData = sessionService.load(), !sessionData.tabs.isEmpty {
            restoreSession(sessionData)
        } else {
            createMockTab(title: "新标签页", url: nil)
        }
        #endif
    }

    /// Restore tabs from saved session data.
    /// Creates TabViewModels in deferred state (no real WebView).
    /// The active tab is fully activated (creates WebView + navigates).
    private func restoreSession(_ sessionData: SessionData) {
        NSLog("%@", "[OWL] Restoring session: \(sessionData.tabs.count) tabs")
        var activeIndex: Int? = nil

        for (index, savedTab) in sessionData.tabs.enumerated() {
            let tab = TabViewModel.mock(title: savedTab.title, url: savedTab.url)
            tab.isPinned = savedTab.isPinned
            tab.isDeferred = true
            tab.webviewId = 0  // No real WebView yet.
            tab.updateCachedHost()
            tabs.append(tab)
            if savedTab.isActive {
                activeIndex = index
            }
        }

        // Activate the previously active tab (or the first one).
        let targetIndex = activeIndex ?? 0
        guard targetIndex < tabs.count else { return }
        let targetTab = tabs[targetIndex]
        // activateTab will detect isDeferred and create a real WebView.
        activateTab(targetTab)
    }

    /// Register all per-webview C-ABI callbacks in one place.
    /// Called once per webview from the CreateWebView completion handler.
    /// Phase 2: callbacks route via webviewIdMap instead of activeTab.
    private func registerAllCallbacks(_ wvId: UInt64) {
        #if canImport(OWLBridge)
        // Page info callback: title, URL, loading state, navigation state.
        OWLBridge_SetPageInfoCallback(wvId, { webviewId, title, url, loading, back, fwd, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let titleStr = title.map { String(cString: $0) }
            let urlStr = url.map { String(cString: $0) }
            let isLoading = loading != 0
            let canBack = back != 0
            let canFwd = fwd != 0
            Task { @MainActor in
                guard let tab = vm.webviewIdMap[webviewId] else { return }
                let oldURL = tab.url
                if let titleStr { tab.title = titleStr }
                if let urlStr, urlStr.hasPrefix("http") { tab.url = urlStr }
                let wasLoading = tab.isLoading
                tab.isLoading = isLoading
                if wasLoading && !isLoading {
                    tab.completeNavigation(success: true)
                }
                tab.canGoBack = canBack
                tab.canGoForward = canFwd
                tab.updateCachedHost()
                NSLog("%@", "[OWL] PageInfo wv=\(webviewId): title=\(tab.title) url=\(tab.url ?? "nil") loading=\(isLoading)")
                // Schedule session save when URL changes.
                if tab.url != oldURL {
                    vm.sessionService.scheduleSave()
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Render surface callback for CALayerHost contextId.
        OWLBridge_SetRenderSurfaceCallback(wvId, { webviewId, ctxId, pw, ph, scale, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            Task { @MainActor in
                guard let tab = vm.webviewIdMap[webviewId] else { return }
                tab.caContextId = ctxId
                tab.renderPixelWidth = pw
                tab.renderPixelHeight = ph
                tab.renderScaleFactor = scale
                NSLog("%@", "[OWL] Render surface wv=\(webviewId): contextId=\(ctxId) size=\(pw)x\(ph) scale=\(scale)")
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Zoom changed callback.
        OWLBridge_SetZoomChangedCallback(wvId, { webviewId, newLevel, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            Task { @MainActor in
                vm.webviewIdMap[webviewId]?.zoomLevel = newLevel
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Find result callback.
        OWLBridge_SetFindResultCallback(wvId, { webviewId, requestId, numMatches, activeOrdinal, finalUpdate, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let rid = requestId
            let matches = numMatches
            let ordinal = activeOrdinal
            let isFinal = finalUpdate != 0
            Task { @MainActor in
                vm.webviewIdMap[webviewId]?.handleFindResult(requestId: rid, matches: Int(matches),
                                                              activeOrdinal: Int(ordinal), isFinal: isFinal)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Navigation started callback (Phase 2).
        OWLBridge_SetNavigationStartedCallback(wvId, { webviewId, navId, url, userInit, redirect, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let urlStr = String(cString: url!)
            Task { @MainActor in
                guard let tab = vm.webviewIdMap[webviewId] else { return }
                if redirect != 0 {
                    tab.onNavigationRedirected(navigationId: navId, url: urlStr)
                    vm.navigationEventRing.append(NavigationEventRecord(
                        navigationId: navId, eventType: "redirected", url: urlStr))
                } else {
                    tab.onNavigationStarted(navigationId: navId, url: urlStr,
                                            isUserInitiated: userInit != 0)
                    vm.navigationEventRing.append(NavigationEventRecord(
                        navigationId: navId, eventType: "started", url: urlStr))
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Navigation committed callback (Phase 2).
        OWLBridge_SetNavigationCommittedCallback(wvId, { webviewId, navId, url, status, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let urlStr = String(cString: url!)
            Task { @MainActor in
                guard let tab = vm.webviewIdMap[webviewId] else { return }
                tab.onNavigationCommitted(navigationId: navId, url: urlStr, httpStatus: status)
                vm.consoleVM.onNavigation(url: urlStr)
                vm.navigationEventRing.append(NavigationEventRecord(
                    navigationId: navId, eventType: "committed", url: urlStr,
                    httpStatus: status))
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Navigation error callback (Phase 2).
        OWLBridge_SetNavigationErrorCallback(wvId, { webviewId, navId, url, code, desc, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let urlStr = String(cString: url!)
            let descStr = String(cString: desc!)
            Task { @MainActor in
                guard let tab = vm.webviewIdMap[webviewId] else { return }
                tab.onNavigationFailed(navigationId: navId, url: urlStr,
                                       errorCode: code, errorDescription: descStr)
                vm.navigationEventRing.append(NavigationEventRecord(
                    navigationId: navId, eventType: "failed", url: urlStr,
                    errorCode: code))
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // HTTP Auth callback (per-webview, Phase 3).
        OWLBridge_SetAuthRequiredCallback(wvId, { webviewId, url, realm, scheme, authId, isProxy, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let urlStr = url.map { String(cString: $0) } ?? ""
            let realmStr = realm.map { String(cString: $0) } ?? ""
            let schemeStr = scheme.map { String(cString: $0) } ?? ""
            let proxy = isProxy != 0
            Task { @MainActor in
                guard let tab = vm.webviewIdMap[webviewId] else {
                    // No matching tab — cancel the auth challenge.
                    OWLBridge_RespondToAuth(authId, nil, nil)
                    return
                }
                // Calculate failure count from previous challenges on same domain+realm.
                let prevCount = tab.authChallenge?.failureCount ?? 0
                let count = (tab.authChallenge != nil) ? prevCount + 1 : 0
                tab.authChallenge = AuthChallenge(
                    authId: authId, url: urlStr, realm: realmStr,
                    scheme: schemeStr, isProxy: proxy, failureCount: count)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Console message callback (per-webview, Phase 2).
        OWLBridge_SetConsoleMessageCallback(wvId, { webviewId, level, message, source, line, timestamp, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let msgStr = message.map { String(cString: $0) } ?? ""
            let srcStr = source.map { String(cString: $0) } ?? ""
            let lvl = level
            let ln = Int(line)
            let ts = timestamp
            Task { @MainActor in
                let consoleLevel = ConsoleLevel(rawValue: Int(lvl)) ?? .info
                let date = Date(timeIntervalSince1970: ts)
                vm.consoleVM.addMessage(level: consoleLevel, message: msgStr,
                                        source: srcStr, line: ln, timestamp: date)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Phase 3 Multi-tab: New tab requested callback (per-webview).
        OWLBridge_SetNewTabRequestedCallback(wvId, { webviewId, url, foreground, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            let urlStr = url.map { String(cString: $0) } ?? ""
            let isForeground = foreground != 0
            Task { @MainActor in
                guard !urlStr.isEmpty else { return }
                NSLog("%@", "[OWL] NewTabRequested from wv=\(webviewId): url=\(urlStr) foreground=\(isForeground)")
                // Find the source tab to determine insertion index.
                let sourceIndex = vm.tabs.firstIndex(where: { $0.webviewId == webviewId })
                let insertIndex = sourceIndex.map { $0 + 1 } ?? vm.tabs.count
                vm.createTabForNewTabRequest(url: urlStr, insertIndex: insertIndex, foreground: isForeground)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Phase 3 Multi-tab: Close requested callback (per-webview).
        OWLBridge_SetCloseRequestedCallback(wvId, { webviewId, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            Task { @MainActor in
                NSLog("%@", "[OWL] CloseRequested for wv=\(webviewId)")
                guard let tab = vm.webviewIdMap[webviewId] else { return }
                vm.closeTab(tab)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Load finished callback (deterministic page-load-complete signal).
        OWLBridge_SetLoadFinishedCallback(wvId, { webviewId, success, ctx in
            let vm = Unmanaged<BrowserViewModel>.fromOpaque(ctx!).takeUnretainedValue()
            Task { @MainActor in
                guard let tab = vm.webviewIdMap[webviewId] else { return }
                tab.completeNavigation(success: success != 0)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Per-webview security state callback.
        SSLBridge.shared.registerSecurityState(webviewId: wvId)

        // Context menu callback (per-webview).
        let cmHandler = ContextMenuHandler(webviewId: wvId)
        cmHandler.tabViewModel = webviewIdMap[wvId]
        contextMenuHandler = cmHandler
        ContextMenuBridge.register(webviewId: wvId, handler: cmHandler)

        // History push callback (global, not per-webview — only register once).
        HistoryBridge.shared.register(historyVM: historyVM)

        // Download push callback (global, not per-webview — only register once).
        DownloadBridge.shared.register(downloadVM: downloadVM)
        #endif
    }

    /// Clear per-webview callbacks (set nil) before destroying.
    /// Note: global callbacks (Auth/SSL/Permission) are NOT cleared here —
    /// they are shared across all webviews and must not be reset per-tab.
    private func clearCallbacks(_ wvId: UInt64) {
        #if canImport(OWLBridge)
        OWLBridge_SetPageInfoCallback(wvId, nil, nil)
        OWLBridge_SetRenderSurfaceCallback(wvId, nil, nil)
        OWLBridge_SetZoomChangedCallback(wvId, nil, nil)
        OWLBridge_SetFindResultCallback(wvId, nil, nil)
        OWLBridge_SetNavigationStartedCallback(wvId, nil, nil)
        OWLBridge_SetNavigationCommittedCallback(wvId, nil, nil)
        OWLBridge_SetNavigationErrorCallback(wvId, nil, nil)
        OWLBridge_SetConsoleMessageCallback(wvId, nil, nil)
        OWLBridge_SetSecurityStateCallback(wvId, nil, nil)
        OWLBridge_SetContextMenuCallback(wvId, nil, nil)
        OWLBridge_SetCopyImageResultCallback(wvId, nil, nil)
        OWLBridge_SetUnhandledKeyCallback(wvId, nil, nil)
        OWLBridge_SetCursorChangeCallback(wvId, nil, nil)
        OWLBridge_SetCaretRectCallback(wvId, nil, nil)
        OWLBridge_SetNewTabRequestedCallback(wvId, nil, nil)
        OWLBridge_SetCloseRequestedCallback(wvId, nil, nil)
        OWLBridge_SetLoadFinishedCallback(wvId, nil, nil)
        #endif
    }

    private func launchReal() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        cleanupSession()

        launchGeneration += 1
        let currentGeneration = launchGeneration
        connectionState = .launching

        let hostPath = hostBinaryPath()
        guard FileManager.default.fileExists(atPath: hostPath) else {
            NSLog("%@", "[OWL] Host binary not found: \(hostPath)")
            connectionState = .failed("Host not found: \(hostPath)")
            return
        }

        NSLog("%@", "[OWL] launchReal: launching \(hostPath)")

        let ctx = LaunchContext(vm: self, gen: currentGeneration)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        let cdpPort = UInt16(ProcessInfo.processInfo.environment["OWL_CDP_PORT"] ?? "") ?? 0
        hostPath.withCString { pathCStr in
            userDataDir().withCString { dirCStr in
                OWLBridge_LaunchHost(pathCStr, dirCStr, cdpPort,
                    launchHostCallback, ctxPtr)
            }
        }
        // No optimistic UI — wait for C callback to set .connected
        // after OWLBridgeSession + BrowserContext are fully created.
    }

    private func cleanupSession() {
        session?.delegate = nil
        session = nil
        browserContext = nil
        terminateHost()
    }

    private func terminateHost() {
        guard hostPID > 0 else { return }
        let pid = hostPID
        hostPID = 0
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        guard reconnectAttempt <= maxReconnectAttempts else {
            connectionState = .failed("重连失败（已尝试 \(maxReconnectAttempts) 次）")
            return
        }
        connectionState = .reconnecting(attempt: reconnectAttempt)
        let delay = pow(2.0, Double(reconnectAttempt))
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.launch() }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hostBinaryPath() -> String {
        let buildDir = ProcessInfo.processInfo.environment["OWL_HOST_DIR"]
            ?? "/Users/xiaoyang/Project/chromium/src/out/owl-host"
        // Phase 24b: .app bundle 优先（启用多进程 GPU）
        let appBundlePath = buildDir + "/OWL Host.app/Contents/MacOS/OWL Host"
        if FileManager.default.fileExists(atPath: appBundlePath) {
            return appBundlePath
        }
        // Fallback: bare executable (dev/test, no multi-process GPU)
        let buildPath = buildDir + "/owl_host"
        if FileManager.default.fileExists(atPath: buildPath) { return buildPath }
        // Production: OWL Host embedded in client Frameworks
        return Bundle.main.bundlePath +
            "/Contents/Frameworks/OWL Host.app/Contents/MacOS/OWL Host"
    }

    private func userDataDir() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("OWLBrowser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func setupTabManager() {
        guard let browserContext else { return }
        let manager = OWLTabManager(browserContext: browserContext, contentView: nil)
        manager.delegate = self
        self.tabManager = manager
        createTab()
    }
    #endif
}

// MARK: - OWLBridge Delegate Conformance
#if canImport(OWLBridge)
extension BrowserViewModel: OWLTabManagerDelegate {
    nonisolated package func tabManager(_ manager: OWLTabManager, didCreate tab: OWLTab) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tabVM = TabViewModel(tab: tab)
            self.tabs.append(tabVM)
        }
    }

    nonisolated package func tabManager(_ manager: OWLTabManager, didActivate tab: OWLTab) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeTab = self.tabs.first { $0.id == tab.tabId }
        }
    }

    nonisolated package func tabManager(_ manager: OWLTabManager, didClose tab: OWLTab) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.tabs.removeAll { $0.id == tab.tabId }
            if self.activeTab?.id == tab.tabId {
                self.activeTab = self.tabs.first
            }
        }
    }
}

extension BrowserViewModel: OWLSessionDelegate {
    nonisolated package func sessionDidDisconnect() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cleanupSession()
            self.scheduleReconnect()
        }
    }
    nonisolated package func sessionDidShutdown() {
        Task { @MainActor [weak self] in
            self?.connectionState = .failed("浏览器引擎已关闭")
        }
    }
}
#endif

// MARK: - BrowserControl (CLI IPC)

extension BrowserViewModel: BrowserControl {
    package var activeWebviewId: UInt64 { webviewId }

    package func pageInfo(tab: Int?) -> [String: String] {
        // tab index selection is reserved for multi-tab — currently use active tab
        guard let activeTab else {
            return ["title": "", "url": "", "loading": "false"]
        }
        return [
            "title": activeTab.title,
            "url": activeTab.url ?? "",
            "loading": activeTab.isLoading ? "true" : "false",
            "can_go_back": activeTab.canGoBack ? "true" : "false",
            "can_go_forward": activeTab.canGoForward ? "true" : "false",
        ]
    }

    package func cliNavigate(url: String) {
        guard let activeTab else { return }
        activeTab.navigate(to: url)
    }

    package func cliGoBack() {
        activeTab?.goBack()
    }

    package func cliGoForward() {
        activeTab?.goForward()
    }

    package func cliReload() {
        activeTab?.reload()
    }

    package func navStatus() -> [String: String] {
        guard let tab = activeTab else {
            return ["state": "idle"]
        }

        let state: String
        if tab.navigationError != nil {
            state = "error"
        } else if tab.isLoading {
            state = "loading"
        } else {
            state = "idle"
        }

        var result: [String: String] = [
            "state": state,
            "progress": String(tab.loadingProgress),
            "url": tab.url ?? "",
            "navigation_id": String(tab.currentNavigationId),
        ]

        if let error = tab.navigationError {
            result["error_code"] = String(error.errorCode)
            result["error_description"] = error.errorDescription
        }

        return result
    }

    package func navEvents(limit: Int) -> [NavigationEventRecord] {
        navigationEventRing.recent(limit: limit)
    }

    package func consoleMessages(level: String?, limit: Int) -> [[String: String]] {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Filter to only message items from the console VM's display items
        let messageItems: [ConsoleMessageItem] = consoleVM.displayItems.compactMap {
            if case .message(let msg) = $0 { return msg }
            return nil
        }

        // Apply level filter if specified
        let filtered: [ConsoleMessageItem]
        if let level {
            let targetLevel: ConsoleLevel?
            switch level.lowercased() {
            case "error": targetLevel = .error
            case "warning": targetLevel = .warning
            case "info": targetLevel = .info
            case "verbose": targetLevel = .verbose
            default: targetLevel = nil
            }
            if let targetLevel {
                filtered = messageItems.filter { $0.level == targetLevel }
            } else {
                filtered = messageItems
            }
        } else {
            filtered = messageItems
        }

        // Take the most recent N messages (tail)
        let clampedLimit = max(1, min(1000, limit))
        let sliced = filtered.suffix(clampedLimit)

        return sliced.map { msg in
            let levelStr: String
            switch msg.level {
            case .verbose: levelStr = "verbose"
            case .info: levelStr = "info"
            case .warning: levelStr = "warning"
            case .error: levelStr = "error"
            }
            return [
                "level": levelStr,
                "message": msg.message,
                "source": msg.source,
                "line": String(msg.line),
                "timestamp": iso8601Formatter.string(from: msg.timestamp),
            ]
        }
    }
}
