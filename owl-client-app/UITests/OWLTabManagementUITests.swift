/// OWL Browser Tab Management XCUITest — end-to-end through real system events.
///
/// Tests Phase 4 tab management acceptance criteria:
///   AC-001: Create 2 tabs -> sidebar displays 2 rows
///   AC-002: Switch tab -> highlight changes
///   AC-003: Close tab -> row disappears from list
///   AC-005: Pin tab -> pinned section displays
///   AC-006: Undo close -> tab restores
///   AC-009: Existing functionality (address bar, navigation) unaffected
///
/// UI elements tested:
///   TabRowView       -> accessibilityIdentifier "tabRow"
///   PinnedTabRow     -> accessibilityIdentifier "pinnedTabRow"
///   NewTabButton     -> accessibilityIdentifier "newTabButton"
///   AddressBar       -> accessibilityIdentifier "addressBar"
///
/// Keyboard shortcuts:
///   Cmd+T      -> new tab
///   Cmd+W      -> close active tab
///   Cmd+Shift+T -> undo close tab
///
/// Run: xcodebuild test -project OWLBrowser.xcodeproj -scheme OWLBrowserUITests -only-testing:OWLTabManagementUITests
import XCTest

final class OWLTabManagementUITests: XCTestCase {

    var app: XCUIApplication!
    var server: TestDownloadHTTPServer?
    static var cdp: CDPHelper?

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        continueAfterFailure = false

        // ── 启动本地 HTTP server（多 tab 输入路由测试用） ──
        let srv = TestDownloadHTTPServer()
        srv.addRoute(TestDownloadHTTPServer.Route(
            path: "/tab-a", contentType: "text/html; charset=utf-8",
            body: Data(Self.tabPageHTML(id: "A").utf8)))
        srv.addRoute(TestDownloadHTTPServer.Route(
            path: "/tab-b", contentType: "text/html; charset=utf-8",
            body: Data(Self.tabPageHTML(id: "B").utf8)))
        let _ = try srv.start()
        server = srv

        app = XCUIApplication()

        // If the app is already running (launched externally via `swift run`),
        // activate it. Otherwise launch it fresh.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.antlerai.owl.browser")
        if let existing = running.first {
            existing.activate()
            app.activate()
        } else {
            app.launchEnvironment["OWL_ENABLE_TEST_JS"] = "1"
            app.launchEnvironment["OWL_CLEAN_SESSION"] = "1"
            app.launch()
        }

        // Wait for app to be ready.
        let addressBar = app.textFields["addressBar"]
        XCTAssertTrue(addressBar.waitForExistence(timeout: 20),
                      "Address bar should appear after app launch")

        // Ensure sidebar is visible (may have been manually hidden with Cmd+Shift+L).
        ensureSidebarVisible()

        // Ensure sidebar is in tabs mode (not history/bookmarks/downloads).
        // If the history search field is visible, click a sidebar mode toggle to get back to tabs.
        ensureSidebarInTabsMode()

        // CDP connection (once per test suite, non-blocking fallback)
        if Self.cdp == nil {
            Self.cdp = CDPHelper(port: 9222)
            // Attempt connection — Host may not be ready yet
            Task {
                for _ in 0..<10 {
                    do { try await Self.cdp?.connect(); break }
                    catch { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                }
            }
            // Bridge async→sync: wait for connection attempt to settle
            Thread.sleep(forTimeInterval: 3)
        }
    }

    override func tearDownWithError() throws {
        // Don't terminate -- keep app running for next test.
        server?.stop()
        server = nil
    }

    // MARK: - Helpers

    /// Navigate via address bar -- types URL and presses Enter (real system events).
    private func navigate(to url: String) {
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText(url + "\n")
    }

    /// Wait for page loading to complete (isLoading == false) via AccessibleLabel.
    private func waitForLoadComplete(timeout: TimeInterval = 15) -> Bool {
        let pageLoading = app.staticTexts["pageLoading"]
        let predicate = NSPredicate(format: "label == %@", "false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageLoading)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait for page URL to contain a substring (via hidden accessibility label).
    private func waitForURL(containing substring: String, timeout: TimeInterval = 15) -> Bool {
        let pageURL = app.staticTexts["pageURL"]
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageURL)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Ensure sidebar is visible (may be hidden via Cmd+Shift+L toggle).
    /// The sidebar visibility is persisted in @AppStorage("owl.sidebar.manuallyVisible").
    private func ensureSidebarVisible() {
        // Force sidebar visible via UserDefaults.
        let bundleId = "com.antlerai.owl.browser"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["write", bundleId, "owl.sidebar.manuallyVisible", "-bool", "true"]
        try? proc.run()
        proc.waitUntilExit()

        // If still no tab rows visible, toggle sidebar with keyboard shortcut.
        if !allTabRows.firstMatch.waitForExistence(timeout: 3)
            && !allPinnedTabRows.firstMatch.waitForExistence(timeout: 1) {
            app.typeKey("l", modifierFlags: [.command, .shift])
            sleep(1)
            // Toggle twice to ensure "on" state if we happened to toggle it off.
            if !allTabRows.firstMatch.waitForExistence(timeout: 2) {
                app.typeKey("l", modifierFlags: [.command, .shift])
                sleep(1)
            }
        }
    }

    /// Ensure sidebar is showing the tabs list (not history/bookmarks/downloads).
    private func ensureSidebarInTabsMode() {
        // If historySearchField or downloadSidebarPanel is visible, the sidebar is not in tabs mode.
        let historySearch = app.textFields["historySearchField"]
        let downloadPanel = app.otherElements["downloadSidebarPanel"]
        if historySearch.exists {
            // Toggle history off -> back to tabs
            let historyButton = app.buttons["sidebarHistoryButton"]
            if historyButton.exists { historyButton.click() }
            sleep(1)
        } else if downloadPanel.exists {
            let downloadButton = app.buttons["sidebarDownloadButton"]
            if downloadButton.exists { downloadButton.click() }
            sleep(1)
        }
        // Bookmarks: check for bookmark-specific UI
        let bookmarkButton = app.buttons["sidebarBookmarkButton"]
        // If bookmark mode is active, the sidebar shows bookmarks. Check by looking for
        // absence of tabRow elements. We just toggle bookmark button to reset.
        // Simple heuristic: if no tabRow and no pinnedTabRow exist, try toggling.
        let tabRows = allTabRows
        if tabRows.count == 0 && allPinnedTabRows.count == 0 {
            if bookmarkButton.exists { bookmarkButton.click() }
            sleep(1)
        }
    }

    /// All unpinned tab rows in the sidebar.
    /// Uses descendants(matching: .any) instead of otherElements to avoid
    /// assuming the SwiftUI accessibility element type (which can vary).
    private var allTabRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'tabRow'")
        )
    }

    /// All pinned tab rows in the sidebar.
    private var allPinnedTabRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'pinnedTabRow'")
        )
    }

    /// Total number of visible tab rows (pinned + unpinned).
    private var totalTabCount: Int {
        allTabRows.count + allPinnedTabRows.count
    }

    /// Wait for at least one tab row to appear in the sidebar.
    private func waitForAnyTabRow(timeout: TimeInterval = 10) -> Bool {
        let tabRow = allTabRows.firstMatch
        let pinnedRow = allPinnedTabRows.firstMatch
        return tabRow.waitForExistence(timeout: timeout)
            || pinnedRow.waitForExistence(timeout: timeout)
    }

    /// Find the tab row that currently has "selected" value (the active tab).
    private func findSelectedTabRow() -> XCUIElement? {
        // Check unpinned tabs
        for i in 0..<allTabRows.count {
            let row = allTabRows.element(boundBy: i)
            if (row.value as? String) == "selected" {
                return row
            }
        }
        // Check pinned tabs
        for i in 0..<allPinnedTabRows.count {
            let row = allPinnedTabRows.element(boundBy: i)
            if (row.value as? String) == "selected" {
                return row
            }
        }
        return nil
    }

    /// Close all tabs except one by pressing Cmd+W repeatedly, then ensure a clean state.
    /// After this, exactly one tab should remain (the auto-created blank).
    private func closeAllTabsExceptOne() {
        // Press Cmd+W until only one tab remains.
        var attempts = 0
        while totalTabCount > 1 && attempts < 20 {
            app.typeKey("w", modifierFlags: .command)
            sleep(1)
            attempts += 1
        }
    }

    /// 等待 pageTitle accessibility label 匹配指定字符串。
    private func waitForPageTitle(_ expected: String, timeout: TimeInterval = 10) -> Bool {
        let pageTitle = app.staticTexts["pageTitle"]
        let predicate = NSPredicate(format: "label == %@", expected)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: pageTitle)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    /// 等待 pageTitle label 以指定前缀开头。
    private func waitForPageTitlePrefix(_ prefix: String, timeout: TimeInterval = 10) -> Bool {
        let pageTitle = app.staticTexts["pageTitle"]
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: pageTitle)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    /// web content view element.
    private var webContent: XCUIElement {
        app.descendants(matching: .any)["webContentView"]
    }

    /// 等待 tab 数量达到期望值，且有 tab 被选中。
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

    // MARK: - AC-001: Create 2 tabs -> sidebar displays 2 rows

    /// AC-001: After creating 2 tabs, the sidebar should display 2 tab rows.
    /// User sees: Cmd+T twice -> 2 rows visible in sidebar.
    func testCreateTwoTabsShowsTwoRows() {
        // Start from a known state: close all but one tab.
        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        let initialCount = totalTabCount
        XCTAssertEqual(initialCount, 1,
                       "AC-001: Should start with exactly 1 tab after cleanup")

        // Create a new tab with Cmd+T
        app.typeKey("t", modifierFlags: .command)
        sleep(2)

        XCTAssertEqual(totalTabCount, 2,
                       "AC-001: After Cmd+T, should have 2 tab rows in sidebar")

        // Verify both rows are visible in the sidebar
        let tabRows = allTabRows
        XCTAssertTrue(tabRows.element(boundBy: 0).exists,
                      "AC-001: First tab row should be visible")
        XCTAssertTrue(tabRows.element(boundBy: 1).exists
                      || allPinnedTabRows.firstMatch.exists,
                      "AC-001: Second tab row should be visible")
    }

    // MARK: - AC-002: Switch tab -> highlight changes

    /// AC-002: Clicking a different tab row changes which tab is highlighted.
    /// User sees: create 2 tabs, click on the first, highlight moves.
    func testSwitchTabChangesHighlight() {
        // Ensure we have at least 2 tabs.
        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        // Navigate first tab to a known page for identification.
        navigate(to: "data:text/html,<title>Tab One</title>")
        sleep(2)

        // Create second tab.
        app.typeKey("t", modifierFlags: .command)
        sleep(2)

        // The second (new) tab should now be active.
        let tabRows = allTabRows
        guard tabRows.count >= 2 else {
            XCTFail("AC-002: Expected at least 2 tab rows, got \(tabRows.count)")
            return
        }

        // The newly created tab (second row or last) should be selected.
        let lastRow = tabRows.element(boundBy: tabRows.count - 1)
        XCTAssertEqual(lastRow.value as? String, "selected",
                       "AC-002: Newly created tab should be selected (active)")

        // Click on the first tab row to switch.
        let firstRow = tabRows.element(boundBy: 0)
        firstRow.click()
        sleep(1)

        // First row should now be selected, last should not be.
        XCTAssertEqual(firstRow.value as? String, "selected",
                       "AC-002: After clicking first tab, it should be selected")
        // Re-query the last row since the UI may have re-rendered.
        let updatedLastRow = allTabRows.element(boundBy: allTabRows.count - 1)
        XCTAssertNotEqual(updatedLastRow.value as? String, "selected",
                          "AC-002: After clicking first tab, the last tab should not be selected")
    }

    // MARK: - AC-003: Close tab -> row disappears from list

    /// AC-003: Closing a tab removes its row from the sidebar.
    /// User sees: Cmd+W -> tab row disappears.
    func testCloseTabRemovesRow() {
        // Ensure 2 tabs.
        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        app.typeKey("t", modifierFlags: .command)
        sleep(2)

        let countBefore = totalTabCount
        XCTAssertEqual(countBefore, 2,
                       "AC-003: Should have 2 tabs before closing")

        // Close the active tab with Cmd+W.
        app.typeKey("w", modifierFlags: .command)
        sleep(2)

        // When closing the last tab, a new blank tab is auto-created,
        // so closing goes 2 -> 1 (not 2 -> 0).
        let countAfter = totalTabCount
        XCTAssertEqual(countAfter, 1,
                       "AC-003: After closing one of two tabs, should have 1 tab remaining")
    }

    // MARK: - AC-005: Pin tab -> pinned section displays

    /// AC-005: Pinning a tab moves it to the pinned section.
    /// User sees: right-click tab -> "固定标签页" -> tab appears in pinned area.
    func testPinTabShowsInPinnedSection() {
        // Ensure we have at least 1 tab.
        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        // Navigate to a page so the tab has a meaningful title.
        navigate(to: "data:text/html,<title>Pin Me</title>")
        sleep(2)

        // Before pinning, no pinned rows should exist.
        let pinnedBefore = allPinnedTabRows.count
        XCTAssertEqual(pinnedBefore, 0,
                       "AC-005: No pinned tabs should exist initially")

        // Right-click the tab row to open context menu.
        let tabRow = allTabRows.firstMatch
        guard tabRow.waitForExistence(timeout: 5) else {
            XCTFail("AC-005: No tab row found to right-click")
            return
        }
        tabRow.rightClick()
        sleep(1)

        // Click "固定标签页" in the context menu.
        let pinMenuItem = app.menuItems["固定标签页"]
        guard pinMenuItem.waitForExistence(timeout: 3) else {
            // Dismiss menu if pin item not found.
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("AC-005: '固定标签页' menu item not found in tab context menu")
            return
        }
        pinMenuItem.click()
        sleep(1)

        // After pinning, the pinnedTabRow should appear.
        let pinnedAfter = allPinnedTabRows.count
        XCTAssertEqual(pinnedAfter, 1,
                       "AC-005: One pinned tab should appear after pinning")

        // The regular tab row count should decrease by 1.
        let unpinnedAfter = allTabRows.count
        XCTAssertEqual(unpinnedAfter, 0,
                       "AC-005: Unpinned tab count should decrease after pinning")

        // Cleanup: unpin the tab via context menu.
        let pinnedRow = allPinnedTabRows.firstMatch
        pinnedRow.rightClick()
        sleep(1)
        let unpinMenuItem = app.menuItems["取消固定标签页"]
        if unpinMenuItem.waitForExistence(timeout: 3) {
            unpinMenuItem.click()
            sleep(1)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: - AC-006: Undo close -> tab restores

    /// AC-006: Cmd+Shift+T restores the most recently closed tab.
    /// User sees: close tab -> Cmd+Shift+T -> tab reappears in sidebar.
    func testUndoCloseRestoresTab() {
        // Ensure 2 tabs with distinct pages.
        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        navigate(to: "data:text/html,<title>Keep Me</title>")
        sleep(2)

        app.typeKey("t", modifierFlags: .command)
        sleep(2)

        navigate(to: "data:text/html,<title>Close Me</title>")
        sleep(2)

        let countWith2 = totalTabCount
        XCTAssertEqual(countWith2, 2,
                       "AC-006: Should have 2 tabs before closing")

        // Close the active (second) tab.
        app.typeKey("w", modifierFlags: .command)
        sleep(2)

        let countAfterClose = totalTabCount
        XCTAssertEqual(countAfterClose, 1,
                       "AC-006: Should have 1 tab after closing")

        // Undo close with Cmd+Shift+T.
        app.typeKey("t", modifierFlags: [.command, .shift])
        sleep(3)

        let countAfterUndo = totalTabCount
        XCTAssertEqual(countAfterUndo, 2,
                       "AC-006: Should have 2 tabs after undo close (Cmd+Shift+T)")
    }

    // MARK: - AC-009: Existing functionality unaffected

    /// AC-009: After tab operations, address bar navigation still works.
    /// User sees: create/close tabs -> navigate via address bar -> page loads.
    func testExistingNavigationUnaffected() {
        // Create a tab.
        app.typeKey("t", modifierFlags: .command)
        sleep(2)

        // Close it.
        app.typeKey("w", modifierFlags: .command)
        sleep(1)

        // Navigate via address bar -- should still work.
        navigate(to: "https://example.com")
        let loaded = waitForURL(containing: "example.com")
        XCTAssertTrue(loaded,
                      "AC-009: Navigation should still work after tab create/close operations")

        // App should be responsive.
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "AC-009: App should remain responsive after tab operations + navigation")
    }

    /// AC-009: Find-in-page still works after tab operations.
    /// User sees: Cmd+F -> find bar appears, Escape -> find bar disappears.
    func testFindInPageStillWorks() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(1)

        // Open find bar
        app.typeKey("f", modifierFlags: .command)
        let findField = app.textFields["findTextField"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5),
                      "AC-009: Find bar should still open after tab operations")

        // Close find bar
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)
        XCTAssertFalse(findField.exists,
                       "AC-009: Find bar should close with Escape")
    }

    /// AC-009: Zoom controls still work after tab operations.
    /// User sees: Cmd+= -> zoom indicator appears, Cmd+0 -> indicator disappears.
    func testZoomStillWorks() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(2)

        // Reset zoom first.
        app.typeKey("0", modifierFlags: .command)
        sleep(1)

        // Zoom in.
        app.typeKey("=", modifierFlags: .command)
        sleep(2)

        let zoomIndicator = app.buttons["zoomIndicator"]
        XCTAssertTrue(zoomIndicator.waitForExistence(timeout: 5),
                      "AC-009: Zoom indicator should appear after Cmd+=")

        // Reset zoom.
        app.typeKey("0", modifierFlags: .command)
        sleep(1)
        XCTAssertFalse(zoomIndicator.exists,
                       "AC-009: Zoom indicator should disappear after Cmd+0")
    }

    // MARK: - Supplementary: Pin + Undo interaction

    /// Supplementary: Pin a tab, close it, undo -> restored tab should be pinned.
    func testUndoCloseRestoresPinnedState() {
        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        // Create a second tab so we have something left after closing.
        app.typeKey("t", modifierFlags: .command)
        sleep(2)

        // Navigate the first tab and pin it via context menu.
        let firstTabRow = allTabRows.element(boundBy: 0)
        guard firstTabRow.waitForExistence(timeout: 5) else {
            XCTFail("No first tab row found")
            return
        }
        firstTabRow.click()
        sleep(1)

        navigate(to: "data:text/html,<title>Pinned Tab</title>")
        sleep(2)

        // Right-click to pin.
        // Re-query since the row may have re-rendered after navigation.
        let tabRowToPin = allTabRows.element(boundBy: 0)
        tabRowToPin.rightClick()
        sleep(1)
        let pinItem = app.menuItems["固定标签页"]
        guard pinItem.waitForExistence(timeout: 3) else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Pin menu item not found")
            return
        }
        pinItem.click()
        sleep(1)

        XCTAssertEqual(allPinnedTabRows.count, 1,
                       "Should have 1 pinned tab")

        // Close the pinned tab (it should be active).
        let pinnedRow = allPinnedTabRows.firstMatch
        pinnedRow.click()
        sleep(1)
        app.typeKey("w", modifierFlags: .command)
        sleep(2)

        XCTAssertEqual(allPinnedTabRows.count, 0,
                       "After closing pinned tab, no pinned rows should remain")

        // Undo close.
        app.typeKey("t", modifierFlags: [.command, .shift])
        sleep(3)

        // The restored tab should reappear in the pinned section.
        XCTAssertEqual(allPinnedTabRows.count, 1,
                       "Undo close should restore the pinned tab to the pinned section")

        // Cleanup: unpin the restored tab.
        let restoredPinned = allPinnedTabRows.firstMatch
        if restoredPinned.exists {
            restoredPinned.rightClick()
            sleep(1)
            let unpinItem = app.menuItems["取消固定标签页"]
            if unpinItem.waitForExistence(timeout: 3) {
                unpinItem.click()
                sleep(1)
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }
    }

    // MARK: - Supplementary: Multiple tabs creation via NewTabButton

    /// Supplementary: Click the "添加标签页" button in the sidebar to create a tab.
    func testNewTabButtonCreatesTab() {
        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        let countBefore = totalTabCount
        XCTAssertEqual(countBefore, 1,
                       "Should start with 1 tab")

        // Click the new tab button in the sidebar.
        let newTabButton = app.buttons["newTabButton"]
        guard newTabButton.waitForExistence(timeout: 5) else {
            XCTFail("New tab button not found in sidebar")
            return
        }
        newTabButton.click()
        sleep(2)

        XCTAssertEqual(totalTabCount, 2,
                       "Clicking new tab button should create a second tab")
    }

    // MARK: - Phase 7: Multi-tab input routing

    /// Phase 7: 验证在第二个 tab 中点击 web content，事件路由到正确的 webview。
    /// 回归测试：防止 OWLRemoteLayerView 硬编码 webview_id 导致事件发错 tab。
    ///
    /// Dual-track: XCUITest verifies title change + CDP verifies document.title directly.
    func testClickInSecondTabRoutesCorrectly() async throws {
        guard let port = server?.port else {
            throw XCTSkip("HTTP server not started")
        }

        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()
        XCTAssertEqual(totalTabCount, 1)

        navigate(to: "http://localhost:\(port)/tab-a")
        XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 15), "Tab A should load")
        _ = waitForLoadComplete()

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForTabCount(2), "Second tab should be created")

        navigate(to: "http://localhost:\(port)/tab-b")
        XCTAssertTrue(waitForPageTitle("Tab-B", timeout: 15), "Tab B should load")
        _ = waitForLoadComplete()

        let content = webContent
        try XCTSkipUnless(content.waitForExistence(timeout: 10),
                          "webContentView not in AX tree")
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).click()

        XCTAssertTrue(waitForPageTitle("Tab-B-CLICKED", timeout: 5),
                      "Click should reach Tab B's webview and trigger onclick handler")

        // CDP cross-layer assertion: verify document.title via DevTools protocol
        if let cdp = Self.cdp {
            do {
                // Connect to Tab B's target for precise DOM verification
                try await cdp.connect(toTabContaining: "tab-b")
                let title = try await cdp.currentTitle()
                XCTAssertTrue(title.contains("CLICKED"),
                              "CDP: document.title should contain 'CLICKED', got: \(title)")
            } catch {
                // CDP verification failed — original XCUITest assertion remains authoritative
            }
        }

        let tabRows = allTabRows
        tabRows.element(boundBy: 0).click()
        XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 5),
                      "Tab A title should be unchanged — click must not leak to other tabs")
    }

    /// Phase 7: 验证在第二个 tab 中输入文本，键盘事件路由到正确的 webview。
    /// 回归测试：防止 OWLBridge_SendKeyEvent 使用错误的 webview_id。
    ///
    /// Dual-track: XCUITest verifies title change + CDP verifies input.value directly.
    func testTypeInSecondTabRoutesCorrectly() async throws {
        guard let port = server?.port else {
            throw XCTSkip("HTTP server not started")
        }

        closeAllTabsExceptOne()
        _ = waitForAnyTabRow()

        navigate(to: "http://localhost:\(port)/tab-a")
        XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 15), "Tab A should load")
        _ = waitForLoadComplete()

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForTabCount(2), "Second tab should be created")

        navigate(to: "http://localhost:\(port)/tab-b")
        XCTAssertTrue(waitForPageTitle("Tab-B", timeout: 15), "Tab B should load")
        _ = waitForLoadComplete()

        let content = webContent
        try XCTSkipUnless(content.waitForExistence(timeout: 10),
                          "webContentView not in AX tree")
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75)).click()

        XCTAssertTrue(waitForPageTitle("Tab-B-FOCUSED", timeout: 5),
                      "Focus should reach Tab B's input element")

        app.typeText("hello")

        XCTAssertTrue(waitForPageTitle("Tab-B-TYPED:hello", timeout: 5),
                      "Keyboard input should reach Tab B's webview and trigger oninput handler")

        // CDP cross-layer assertion: verify input.value via DevTools protocol
        if let cdp = Self.cdp {
            do {
                // Connect to Tab B's target for precise DOM verification
                try await cdp.connect(toTabContaining: "tab-b")
                let inputValue = try await cdp.evaluate("document.querySelector('#typeTarget')?.value ?? ''")
                XCTAssertTrue(inputValue.contains("hello"),
                              "CDP: input.value should contain 'hello', got: \(inputValue)")
            } catch {
                // CDP verification failed — original XCUITest assertion remains authoritative
            }
        }

        allTabRows.element(boundBy: 0).click()
        XCTAssertTrue(waitForPageTitle("Tab-A", timeout: 5),
                      "Tab A title should be unchanged — keyboard events must not leak")
    }

    // MARK: - Test HTML Generation

    /// 生成测试 HTML 页面。id 仅接受 "A" 或 "B"。
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
}
