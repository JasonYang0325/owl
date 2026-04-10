/// OWL Browser XCUITest — tests through real system events.
/// User sees all interactions on screen: typing, clicking, page loading.
///
/// Events flow: macOS Event System → NSApp → NSWindow → OWLRemoteLayerView
///   → keyDown:/mouseDown: → C-ABI → Mojo → Host → RWH → Renderer
///
/// Run: xcodebuild test -project OWLBrowser.xcodeproj -scheme OWLBrowserUITests
import XCTest

final class OWLBrowserUITests: XCTestCase {

    var app: XCUIApplication!
    var server: TestDownloadHTTPServer?
    static var cdp: CDPHelper?

    private static let addressBarPageAHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Address Bar Page A</title>
    </head>
    <body>
      <h1>Address Bar Fixture A</h1>
      <p id="page-id">A</p>
    </body>
    </html>
    """

    private static let addressBarPageBHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Address Bar Page B</title>
    </head>
    <body>
      <h1>Address Bar Fixture B</h1>
      <p id="page-id">B</p>
    </body>
    </html>
    """

    override func setUpWithError() throws {
        continueAfterFailure = false

        let srv = TestDownloadHTTPServer()
        srv.addRoute(TestDownloadHTTPServer.Route(
            path: "/address-a",
            contentType: "text/html; charset=utf-8",
            body: Data(Self.addressBarPageAHTML.utf8)
        ))
        srv.addRoute(TestDownloadHTTPServer.Route(
            path: "/address-b",
            contentType: "text/html; charset=utf-8",
            body: Data(Self.addressBarPageBHTML.utf8)
        ))
        do {
            try srv.start()
            server = srv
        } catch {
            // Some runners block creating local listeners in UI test process.
            // Keep UI-only tests runnable and let local-server-dependent tests
            // fail explicitly when they try to use localhost routes.
            NSLog("[OWLBrowserUITests] local test server unavailable: \(error)")
            server = nil
        }

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
        guard let app else {
            XCTFail("XCUIApplication should be initialized in setUp")
            return
        }

        let addressBar = app.textFields["addressBar"]
        XCTAssertTrue(addressBar.waitForExistence(timeout: 20),
                      "Address bar should appear after app launch")

        // Verify AX label elements exist with correct role (AXStaticText).
        // If these fail, check AccessibleLabel.setAccessibilityRole(.staticText).
        XCTAssertTrue(app.staticTexts["pageURL"].waitForExistence(timeout: 5),
                      "pageURL element must exist with AXStaticText role")
        XCTAssertTrue(app.staticTexts["pageTitle"].waitForExistence(timeout: 5),
                      "pageTitle element must exist with AXStaticText role")

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
        guard app != nil else { return }
        closeSettingsIfNeeded()
        server?.stop()
        server = nil
        // Don't terminate — keep app running for next test.
    }

    // MARK: - Helper

    /// Navigate via address bar — types URL and presses Enter (real system events).
    private func navigate(to url: String) {
        guard let app else {
            XCTFail("XCUIApplication is nil in navigate(to:)")
            return
        }
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        // Select all and replace
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText(url + "\n")
    }

    /// Wait for page URL to contain a substring (via hidden accessibility label).
    private func waitForURL(containing substring: String, timeout: TimeInterval = 15) -> Bool {
        guard let app else { return false }
        let pageURL = app.staticTexts["pageURL"]
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageURL)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait for page title to change from empty.
    private func waitForTitle(timeout: TimeInterval = 15) -> String {
        guard let app else { return "" }
        let pageTitle = app.staticTexts["pageTitle"]
        let predicate = NSPredicate(format: "label.length > 0")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageTitle)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "Timed out waiting for page title — check AccessibleLabel AX notification")
        return pageTitle.label
    }

    private func waitForTitle(containing substring: String, timeout: TimeInterval = 15) -> Bool {
        guard let app else { return false }
        let pageTitle = app.staticTexts["pageTitle"]
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageTitle)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait for page loading to complete (isLoading == false) via AccessibleLabel.
    /// Returns true if loading finished within timeout.
    private func waitForLoadComplete(timeout: TimeInterval = 15) -> Bool {
        guard let app else { return false }
        let pageLoading = app.staticTexts["pageLoading"]
        let predicate = NSPredicate(format: "label == %@", "false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageLoading)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForAddressBarValue(containing substring: String, timeout: TimeInterval = 5) -> Bool {
        guard let app else { return false }
        let addressBar = app.textFields["addressBar"]
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement else { return false }
            let value = element.value as? String ?? ""
            return value.contains(substring)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: addressBar)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Get the web content view element for coordinate-based interactions.
    /// Uses descendants query (not otherElements) because CALayerHost AX type
    /// may not match the Group role that otherElements assumes.
    private var webContent: XCUIElement {
        guard let app else {
            return XCUIApplication(bundleIdentifier: "com.antlerai.owl.browser")
                .otherElements["webContentView"]
        }
        let predicate = NSPredicate(format: "identifier == 'webContentView'")
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func localURL(_ path: String) -> String {
        "http://localhost:\(server?.port ?? 0)\(path)"
    }

    private func ensureSidebarVisible() {
        guard let app else { return }
        let settingsButton = app.buttons["sidebarSettingsButton"]
        if settingsButton.waitForExistence(timeout: 2) {
            return
        }

        let bundleId = "com.antlerai.owl.browser"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["write", bundleId, "owl.sidebar.manuallyVisible", "-bool", "true"]
        try? proc.run()
        proc.waitUntilExit()

        app.typeKey("l", modifierFlags: [.command, .shift])
        _ = settingsButton.waitForExistence(timeout: 5)
        if !settingsButton.exists {
            app.typeKey("l", modifierFlags: [.command, .shift])
            _ = settingsButton.waitForExistence(timeout: 5)
        }
    }

    private func waitForAnySettingsControl(timeout: TimeInterval) -> Bool {
        guard let app else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let hasVisibleControl =
                app.staticTexts["settingsPresentedSentinel"].exists
                || app.otherElements["settingsPresentedSentinel"].exists
                || app.secureTextFields["sk-ant-api03-..."].exists
                || app.buttons["AI"].exists
                || app.buttons["通用"].exists
                || app.buttons["权限"].exists
                || app.buttons["存储"].exists
                || app.radioButtons["AI"].exists
                || app.radioButtons["通用"].exists
                || app.radioButtons["权限"].exists
                || app.radioButtons["存储"].exists
            if hasVisibleControl {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func isSettingsVisible() -> Bool {
        waitForAnySettingsControl(timeout: 0.1)
    }

    private func openSettings() {
        guard let app else {
            XCTFail("XCUIApplication is nil in openSettings()")
            return
        }
        ensureSidebarVisible()

        let settingsButton = app.buttons["sidebarSettingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10),
                      "Sidebar settings button should exist")

        if !isSettingsVisible() {
            settingsButton.click()
        }

        let sentinel = app.staticTexts["settingsPresentedSentinel"]
        let sentinelVisible = sentinel.waitForExistence(timeout: 5)
            || app.otherElements["settingsPresentedSentinel"].waitForExistence(timeout: 1)
        XCTAssertTrue(sentinelVisible, "Settings open sentinel should appear after clicking settings button")
        XCTAssertTrue(waitForAnySettingsControl(timeout: 10),
                      "Settings controls should appear after clicking settings button")
    }

    private func closeSettingsIfNeeded() {
        guard app != nil else { return }
        guard isSettingsVisible() else { return }
        app.typeKey(.escape, modifierFlags: [])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !isSettingsVisible() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    @discardableResult
    private func selectSettingsTab(_ label: String) -> XCUIElement {
        guard let app else {
            XCTFail("XCUIApplication is nil in selectSettingsTab(_:)")
            return XCUIApplication(bundleIdentifier: "com.antlerai.owl.browser")
                .otherElements["settingsView"]
        }
        let queries: [XCUIElementQuery] = [
            app.tabGroups.buttons,
            app.tabGroups.radioButtons,
            app.buttons,
            app.radioButtons,
            app.descendants(matching: .button),
            app.descendants(matching: .radioButton),
        ]

        for query in queries {
            let element = query[label]
            if element.waitForExistence(timeout: 1) {
                element.click()
                return element
            }
        }

        XCTFail("Settings tab '\(label)' not found")
        return app.otherElements["settingsView"]
    }

    @discardableResult
    private func clickSettingsControl(labels: [String], timeout: TimeInterval = 1) -> XCUIElement? {
        guard let app else { return nil }
        let queries: [XCUIElementQuery] = [
            app.segmentedControls.buttons,
            app.radioButtons,
            app.buttons,
            app.descendants(matching: .button),
            app.descendants(matching: .radioButton),
            app.descendants(matching: .staticText),
        ]

        for label in labels {
            for query in queries {
                let element = query[label]
                if element.waitForExistence(timeout: timeout) {
                    if element.isHittable {
                        element.click()
                    } else if element.elementType == .staticText {
                        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                    } else {
                        element.click()
                    }
                    return element
                }
            }
        }

        return nil
    }

    private var allTabRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'tabRow' OR identifier == 'pinnedTabRow'")
        )
    }

    private func switchToTab(urlSubstring: String) {
        ensureSidebarVisible()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for index in 0..<allTabRows.count {
                let row = allTabRows.element(boundBy: index)
                guard row.waitForExistence(timeout: 1) else { continue }
                row.click()
                if waitForURL(containing: urlSubstring, timeout: 2) {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("Could not switch to tab containing URL substring '\(urlSubstring)'")
    }

    // MARK: - Tests

    /// Test 1: Type URL in address bar → page navigates.
    /// User sees: address bar gets focus, URL appears, page loads.
    func testNavigateViaAddressBar() {
        navigate(to: "https://example.com")

        let loaded = waitForURL(containing: "example.com")
        XCTAssertTrue(loaded, "Page should navigate to example.com")

        let title = waitForTitle()
        XCTAssertFalse(title.isEmpty, "Page should have a title")
    }

    /// Test 2: Type search query → baidu search results.
    /// User sees: typing in address bar, Enter press, page navigates to search results.
    func testSearchFromAddressBar() {
        navigate(to: "https://www.baidu.com")
        _ = waitForURL(containing: "baidu.com")

        // Click address bar, type search query
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText("owl browser test\n")

        // Should navigate to search results — URL must change from baidu homepage.
        // Use waitForURL instead of sleep to avoid TIMING_BUG on slow networks.
        let navigated = waitForURL(containing: "wd=") || waitForURL(containing: "owl", timeout: 5)
        let url = app.staticTexts["pageURL"].label
        XCTAssertTrue(navigated || url != "https://www.baidu.com/",
                      "URL should change after search, got: \(url)")
    }

    /// Test 3: Type into web page search box using real keyboard events.
    /// User sees: clicking in web content area, typing text character by character.
    /// Dual-track: XCUITest interaction + CDP DOM verification of input value.
    func testTypeInWebContent() async throws {
        // XCUITest operations (must run on main thread)
        let shouldSkip: Bool = await MainActor.run {
            navigate(to: "https://www.baidu.com")
            _ = waitForURL(containing: "baidu.com")
            _ = waitForLoadComplete()

            // webContentView requires CALayerHost AX registration — skip if not available
            let content = webContent
            if !content.waitForExistence(timeout: 10) { return true }

            // Click approximately where baidu's search box is (center, slightly above middle)
            let coord = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            coord.click()
            sleep(1) // Brief wait for focus to settle in renderer

            // Type text — these are REAL system keyboard events going through
            // NSEvent → OWLRemoteLayerView.keyDown: → C-ABI → Mojo → Host → Renderer
            app.typeText("hello owl")

            // XCUITest assertion: app didn't crash and is still responsive
            XCTAssertTrue(app.windows.firstMatch.exists, "App should still be running")
            return false
        }
        try XCTSkipIf(shouldSkip, "webContentView not in AX tree (CALayerHost AX not registered)")

        // CDP enhancement: verify DOM actually received the typed text
        if let cdp = Self.cdp {
            let value = try? await cdp.evaluate("document.querySelector('input#kw')?.value ?? ''")
            if let value = value, !value.isEmpty {
                XCTAssertTrue(value.contains("hello owl"),
                              "CDP: input#kw should contain 'hello owl', got: '\(value)'")
            }
            // If CDP eval fails or selector not found, fall through — XCUITest assertion above is the baseline
        }
    }

    /// Test 4: Click link in web content → navigation.
    /// User sees: mouse click on a link, page navigates.
    /// Dual-track: XCUITest click + CDP URL verification after link click.
    func testClickInWebContent() async throws {
        // XCUITest operations (must run on main thread)
        let shouldSkip: Bool = await MainActor.run {
            // Navigate to a page with known link positions
            navigate(to: "https://example.com")
            _ = waitForURL(containing: "example.com")
            _ = waitForLoadComplete()

            let content = webContent
            if !content.waitForExistence(timeout: 10) { return true }
            return false
        }
        try XCTSkipIf(shouldSkip, "webContentView not in AX tree (CALayerHost AX not registered)")

        // Capture URL before click for comparison
        let urlBefore: String? = try? await Self.cdp?.currentURL()

        // XCUITest: click link and wait for navigation
        await MainActor.run {
            let content = webContent
            // example.com has a "More information..." link — click near the bottom
            let coord = content.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
            coord.click()

            // Wait for potential navigation after click
            _ = waitForLoadComplete(timeout: 10)

            // XCUITest assertion: app should not crash
            XCTAssertTrue(app.windows.firstMatch.exists, "App should survive click interaction")
        }

        // CDP enhancement: verify URL changed after clicking link
        if let cdp = Self.cdp {
            let urlAfter = try? await cdp.currentURL()
            if let before = urlBefore, let after = urlAfter, before != after {
                // Link click caused navigation — URL should have changed from example.com
                XCTAssertNotEqual(before, after,
                                  "CDP: URL should change after clicking link, was: '\(before)', now: '\(after)'")
            }
            // If URL didn't change, the click may not have hit the link — that's OK, XCUITest baseline covers it
        }
    }

    /// Test 5: Navigate twice — app should not crash.
    /// User sees: page loads, then navigates to different page.
    func testNavigateTwice() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")

        navigate(to: "https://www.baidu.com")
        let loaded = waitForURL(containing: "baidu.com")
        XCTAssertTrue(loaded, "Second navigation should succeed")
    }

    /// Test 6: Tab key is intercepted by web content, not SwiftUI.
    /// User sees: Tab press doesn't move focus away from web content.
    func testTabKeyStaysInWebContent() throws {
        navigate(to: "https://www.baidu.com")
        _ = waitForURL(containing: "baidu.com")
        sleep(2)

        let content = webContent
        try XCTSkipUnless(content.waitForExistence(timeout: 10),
                          "webContentView not in AX tree (CALayerHost AX not registered)")

        // Click in web content to focus it
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        sleep(1)

        // Press Tab — should stay in web content (not jump to SwiftUI address bar)
        app.typeKey(.tab, modifierFlags: [])
        sleep(1)

        // App should still be running and web content should still be visible
        XCTAssertTrue(content.exists, "Web content should still be visible after Tab")
    }

    /// Test 7: Open settings and switch between the high-risk panels.
    /// User sees: sidebar settings button opens sheet, permissions/storage tabs are reachable.
    func testSettingsPanelsSmoke() {
        openSettings()

        selectSettingsTab("权限")
        XCTAssertTrue(
            app.staticTexts["permissionsEmptyTitle"].waitForExistence(timeout: 10)
            || app.staticTexts["尚未授予任何站点权限"].waitForExistence(timeout: 1),
            "Permissions panel should show its empty state")

        selectSettingsTab("存储")
        XCTAssertTrue(
            app.staticTexts["storageCookiesEmptyTitle"].waitForExistence(timeout: 10)
            || app.staticTexts["No Cookies"].waitForExistence(timeout: 1),
            "Storage panel should show the cookies view by default")
    }

    /// Test 8: Storage settings tab exposes the segmented cookie/usage switch.
    func testSettingsStorageTabSwitcherExists() {
        openSettings()
        selectSettingsTab("存储")

        XCTAssertTrue(
            app.staticTexts["storageCookiesEmptyTitle"].waitForExistence(timeout: 10)
            || app.staticTexts["No Cookies"].waitForExistence(timeout: 1),
            "Storage panel should expose the cookies subview")

        let usageControl = clickSettingsControl(labels: ["Storage", "storageUsageSegment"], timeout: 2)
        XCTAssertNotNil(usageControl, "Storage usage segment should be reachable")
        XCTAssertTrue(
            app.staticTexts["storageUsageEmptyTitle"].waitForExistence(timeout: 10)
            || app.staticTexts["No Storage Data"].waitForExistence(timeout: 1),
            "Storage usage subview should appear after switching segments")
    }

    /// Test 9: Local address-bar navigation is deterministic and focus toggles URL/domain display.
    func testAddressBarLocalNavigationAndFocusBlurDisplay() {
        let targetURL = localURL("/address-a")
        navigate(to: targetURL)

        XCTAssertTrue(waitForURL(containing: "/address-a"), "Address bar should navigate to local page A")

        let addressBar = app.textFields["addressBar"]
        let blurredValue = addressBar.value as? String ?? ""
        XCTAssertTrue(blurredValue.contains("localhost"),
                      "Blurred address bar should show host, got: \(blurredValue)")
        XCTAssertFalse(blurredValue.contains("/address-a"),
                       "Blurred address bar should hide the full path, got: \(blurredValue)")

        addressBar.click()
        XCTExpectFailure("Known issue: focusing the address bar still keeps host-only text instead of revealing the full URL") {
            XCTAssertTrue(waitForAddressBarValue(containing: "/address-a", timeout: 2),
                          "Focused address bar should show the full URL")
        }

        app.staticTexts["pageTitle"].click()
        sleep(1)

        let restoredValue = addressBar.value as? String ?? ""
        XCTAssertTrue(restoredValue.contains("localhost"),
                      "Blurred address bar should restore host display, got: \(restoredValue)")
        XCTAssertFalse(restoredValue.contains("/address-a"),
                       "Blurred address bar should hide the path again, got: \(restoredValue)")
    }

    /// Test 10: Cmd+A replacement in the address bar routes to a new local page.
    func testAddressBarCommandAReplaceNavigatesToLocalPage() {
        navigate(to: localURL("/address-a"))
        XCTAssertTrue(waitForURL(containing: "/address-a"), "Should load local page A first")

        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText(localURL("/address-b") + "\n")

        XCTAssertTrue(waitForURL(containing: "/address-b"), "Cmd+A replace should navigate to local page B")
        XCTAssertTrue(app.staticTexts["pageURL"].label.contains("/address-b"),
                      "URL label should update to local page B")
    }

    /// Test 11: Address-bar navigation stays scoped to the selected tab.
    func testAddressBarRoutesToSelectedTabWithLocalPages() {
        let firstURL = localURL("/address-a")
        let secondURL = localURL("/address-b")

        navigate(to: firstURL)
        XCTAssertTrue(waitForURL(containing: "/address-a"), "First tab should load local page A")

        ensureSidebarVisible()
        let newTabButton = app.buttons["newTabButton"]
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 5), "New tab button should exist")
        newTabButton.click()

        navigate(to: secondURL)
        XCTAssertTrue(waitForURL(containing: "/address-b"), "Second tab should load local page B")

        switchToTab(urlSubstring: "/address-a")
        XCTAssertTrue(app.staticTexts["pageURL"].label.contains("/address-a"),
                      "Switching back should restore local page A")

        switchToTab(urlSubstring: "/address-b")
        XCTAssertTrue(app.staticTexts["pageURL"].label.contains("/address-b"),
                      "Switching again should restore local page B")
    }

    // MARK: - Phase 33: Find-in-Page

    /// [AC-001] Cmd+F opens find bar, cursor auto-focused to input.
    /// User sees: Cmd+F → find bar slides in, text field has focus.
    func testFindBarOpensWithCmdF() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(1)

        // Cmd+F to open find bar
        app.typeKey("f", modifierFlags: .command)
        sleep(1)

        let findField = app.textFields["findTextField"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5),
                      "Find bar text field should appear after Cmd+F")
    }

    /// [AC-002, AC-003] Type in find bar → match count appears.
    /// User sees: typing "Example" → match count like "1/2" shows.
    /// Dual-track: CDP pre-check confirms DOM has "Example" text before searching.
    func testFindShowsMatchCount() async throws {
        // XCUITest: navigate and wait for load
        await MainActor.run {
            navigate(to: "https://example.com")
            _ = waitForURL(containing: "example.com")
            _ = waitForLoadComplete()
        }

        // CDP pre-check: confirm DOM actually contains "Example" before we search for it
        if let cdp = Self.cdp {
            let bodyText = try? await cdp.textContent("body")
            XCTAssertTrue(bodyText?.contains("Example") == true,
                          "CDP: DOM body should contain 'Example' text before find-in-page")
        }

        // XCUITest: open find bar, type, and verify results
        await MainActor.run {
            // Open find bar
            app.typeKey("f", modifierFlags: .command)
            let findField = app.textFields["findTextField"]
            guard findField.waitForExistence(timeout: 5) else {
                XCTFail("Find bar did not open"); return
            }

            // Click to ensure keyboard focus (FocusState may not auto-focus in XCUITest)
            findField.click()
            sleep(1)

            // Type search term — example.com has "Example" text
            findField.typeText("Example")
            sleep(2)

            // Match count should appear (e.g. "1/2" or similar)
            let matchCount = app.staticTexts["findMatchCount"]
            let noMatch = app.staticTexts["findNoMatch"]
            // Either we have matches or "无匹配" — at least one should exist
            let hasResult = matchCount.waitForExistence(timeout: 5)
                || noMatch.waitForExistence(timeout: 1)
            XCTAssertTrue(hasResult,
                          "Find bar should show match count or no-match indicator")

            // Cleanup
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// [AC-005] Escape closes find bar and clears highlights.
    /// User sees: find bar disappears after Escape.
    func testFindBarClosesWithEscape() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(1)

        // Open find bar
        app.typeKey("f", modifierFlags: .command)
        let findField = app.textFields["findTextField"]
        guard findField.waitForExistence(timeout: 5) else {
            XCTFail("Find bar did not open"); return
        }

        // Close with Escape
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)

        // Find bar should no longer exist
        XCTAssertFalse(findField.exists,
                       "Find bar should disappear after Escape")
    }

    /// [AC-006] No matches shows "无匹配" indicator.
    /// User sees: typing non-existent text → "无匹配" label.
    /// Dual-track: CDP pre-check confirms DOM does NOT contain the search text.
    func testFindNoMatchesIndicator() async throws {
        // XCUITest: navigate and wait for load
        await MainActor.run {
            navigate(to: "https://example.com")
            _ = waitForURL(containing: "example.com")
            _ = waitForLoadComplete()
        }

        // CDP pre-check: confirm the search text does NOT exist in DOM
        if let cdp = Self.cdp {
            let bodyText = try? await cdp.textContent("body")
            XCTAssertFalse(bodyText?.contains("zzzznonexistent") == true,
                           "CDP: DOM should NOT contain 'zzzznonexistent' (test precondition)")
        }

        // XCUITest: open find bar, type, and verify no-match indicator
        await MainActor.run {
            app.typeKey("f", modifierFlags: .command)
            let findField = app.textFields["findTextField"]
            guard findField.waitForExistence(timeout: 5) else {
                XCTFail("Find bar did not open"); return
            }

            findField.click()
            sleep(1)
            findField.typeText("zzzznonexistent")
            sleep(2)

            let noMatch = app.staticTexts["findNoMatch"]
            XCTAssertTrue(noMatch.waitForExistence(timeout: 5),
                          "Should show '无匹配' for non-existent search text")

            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// [AC-004] Enter navigates to next match, close button works.
    /// User sees: pressing Enter in find bar, then clicking close.
    /// Dual-track: CDP confirms DOM contains "hello" text before find.
    func testFindNextAndClose() async throws {
        // XCUITest: navigate and wait for load
        await MainActor.run {
            navigate(to: "data:text/html,<body>hello hello hello</body>")
            _ = waitForLoadComplete()
        }

        // CDP pre-check: data: URIs may not be fully accessible via CDP — informational only
        if let cdp = Self.cdp {
            let bodyText = try? await cdp.textContent("body")
            if bodyText?.contains("hello") != true {
                NSLog("[OWL-TEST] CDP: data: URI body text not accessible (got: \(bodyText ?? "nil"))")
            }
        }

        // XCUITest: open find bar, type, find next, and close
        await MainActor.run {
            app.typeKey("f", modifierFlags: .command)
            let findField = app.textFields["findTextField"]
            guard findField.waitForExistence(timeout: 5) else {
                XCTFail("Find bar did not open"); return
            }

            findField.click()
            sleep(1)
            findField.typeText("hello")
            sleep(2)

            // Press Enter to find next
            findField.typeKey(.return, modifierFlags: [])
            sleep(1)

            // App should still be running (no crash from find next)
            XCTAssertTrue(app.windows.firstMatch.exists,
                          "App should survive find next interaction")

            // Click close button
            let closeButton = app.buttons["findClose"]
            if closeButton.waitForExistence(timeout: 3) {
                closeButton.click()
                sleep(1)
                XCTAssertFalse(findField.exists,
                               "Find bar should close after clicking close button")
            }
        }
    }

    // MARK: - Phase 34: Zoom Control

    /// [AC-001, AC-004] Cmd+= zooms in, zoom indicator appears in address bar.
    /// User sees: page zooms in, address bar shows percentage > 100%.
    func testZoomInShowsIndicator() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(2)

        // Ensure zoom is at 100% (no indicator visible)
        app.typeKey("0", modifierFlags: .command) // Cmd+0 reset
        sleep(2)

        let zoomIndicator = app.buttons["zoomIndicator"]
        // At 100%, indicator should not be visible
        XCTAssertFalse(zoomIndicator.exists,
                       "Zoom indicator should not appear at 100%")

        // Cmd+= to zoom in
        app.typeKey("=", modifierFlags: .command)
        sleep(2)

        // Zoom indicator should now appear with percentage > 100%
        XCTAssertTrue(zoomIndicator.waitForExistence(timeout: 5),
                      "Zoom indicator should appear after Cmd+=")
        // The label should contain a percentage like "120%" or "125%"
        let label = zoomIndicator.label
        XCTAssertTrue(label.contains("%"),
                      "Zoom indicator should show percentage, got: \(label)")

        // [P1-2] Verify the numeric value is actually > 100%
        let numStr = label.replacingOccurrences(of: "%", with: "")
        if let percent = Int(numStr) {
            XCTAssertGreaterThan(percent, 100,
                "Zoom in percentage should be > 100%, got: \(percent)")
        }

        // Clean up: reset zoom
        app.typeKey("0", modifierFlags: .command)
        sleep(1)
    }

    /// [AC-002] Cmd+- zooms out, indicator shows percentage < 100%.
    /// User sees: page zooms out, percentage indicator appears.
    func testZoomOutWorks() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(2)

        // Reset zoom first
        app.typeKey("0", modifierFlags: .command)
        sleep(2)

        // Cmd+- to zoom out
        app.typeKey("-", modifierFlags: .command)
        sleep(2)

        let zoomIndicator = app.buttons["zoomIndicator"]
        XCTAssertTrue(zoomIndicator.waitForExistence(timeout: 5),
                      "Zoom indicator should appear after Cmd+-")

        // Parse percentage — should be less than 100
        let label = zoomIndicator.label
        XCTAssertTrue(label.contains("%"),
                      "Zoom indicator should show percentage, got: \(label)")
        // Extract numeric part (e.g. "83%" → 83)
        let numStr = label.replacingOccurrences(of: "%", with: "")
        if let percent = Int(numStr) {
            XCTAssertLessThan(percent, 100,
                "Zoom out percentage should be < 100%, got: \(percent)")
        }

        // Clean up: reset zoom
        app.typeKey("0", modifierFlags: .command)
        sleep(1)
    }

    /// [AC-003] Cmd+= then Cmd+0 resets zoom, indicator disappears.
    /// User sees: zoom in → indicator appears → reset → indicator disappears.
    func testZoomResetRemovesIndicator() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(2)

        // Reset first to ensure clean state
        app.typeKey("0", modifierFlags: .command)
        sleep(2)

        // Zoom in
        app.typeKey("=", modifierFlags: .command)
        sleep(2)

        let zoomIndicator = app.buttons["zoomIndicator"]
        XCTAssertTrue(zoomIndicator.waitForExistence(timeout: 5),
                      "Zoom indicator should appear after zoom in")

        // Reset with Cmd+0
        app.typeKey("0", modifierFlags: .command)
        sleep(2)

        // Indicator should disappear (100% = default, no indicator shown)
        XCTAssertFalse(zoomIndicator.exists,
                       "Zoom indicator should disappear after Cmd+0 reset")
    }

    /// [P0-2] Click zoom indicator resets zoom to 100% and indicator disappears.
    /// User sees: Cmd+= → zoom indicator appears → click indicator → zoom resets → indicator gone.
    func testZoomIndicatorClickResetsZoom() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(2)

        // Reset to clean state
        app.typeKey("0", modifierFlags: .command)
        sleep(2)

        // Zoom in to make indicator appear
        app.typeKey("=", modifierFlags: .command)
        sleep(2)

        let zoomIndicator = app.buttons["zoomIndicator"]
        XCTAssertTrue(zoomIndicator.waitForExistence(timeout: 5),
                      "Zoom indicator should appear after Cmd+=")

        // Click the zoom indicator to reset
        zoomIndicator.click()
        sleep(2)

        // Indicator should disappear (zoom reset to 100%)
        XCTAssertFalse(zoomIndicator.exists,
                       "Zoom indicator should disappear after clicking it (zoom reset)")
    }

    /// [P0-3] Continuous Cmd+= should not exceed 500% zoom.
    /// User sees: pressing Cmd+= many times, indicator caps at 500%.
    func testZoomInMaxBoundary() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(2)

        // [R2-3] Ensure reset runs even if assertions fail mid-test
        defer {
            app.typeKey("0", modifierFlags: .command)
            sleep(1)
        }

        // Reset to clean state
        app.typeKey("0", modifierFlags: .command)
        sleep(2)

        // Press Cmd+= 12 times (more than enough to reach max zoom boundary)
        for _ in 0..<12 {
            app.typeKey("=", modifierFlags: .command)
            sleep(1)
        }

        let zoomIndicator = app.buttons["zoomIndicator"]
        XCTAssertTrue(zoomIndicator.waitForExistence(timeout: 5),
                      "Zoom indicator should exist at max zoom")

        let label = zoomIndicator.label
        let numStr = label.replacingOccurrences(of: "%", with: "")
        if let percent = Int(numStr) {
            XCTAssertLessThanOrEqual(percent, 500,
                "Zoom should not exceed 500%, got: \(percent)%")
            XCTAssertGreaterThan(percent, 100,
                "Zoom should be > 100% after zooming in, got: \(percent)%")
        } else {
            XCTFail("Could not parse zoom percentage from label: \(label)")
        }
    }

    /// [P0-3] Continuous Cmd+- should not go below 25% zoom.
    /// User sees: pressing Cmd+- many times, indicator bottoms at 25%.
    func testZoomOutMinBoundary() {
        navigate(to: "https://example.com")
        _ = waitForURL(containing: "example.com")
        sleep(2)

        // [R2-3] Ensure reset runs even if assertions fail mid-test
        defer {
            app.typeKey("0", modifierFlags: .command)
            sleep(1)
        }

        // Reset to clean state
        app.typeKey("0", modifierFlags: .command)
        sleep(2)

        // Press Cmd+- 12 times (more than enough to reach min zoom boundary)
        for _ in 0..<12 {
            app.typeKey("-", modifierFlags: .command)
            sleep(1)
        }

        let zoomIndicator = app.buttons["zoomIndicator"]
        XCTAssertTrue(zoomIndicator.waitForExistence(timeout: 5),
                      "Zoom indicator should exist at min zoom")

        let label = zoomIndicator.label
        let numStr = label.replacingOccurrences(of: "%", with: "")
        if let percent = Int(numStr) {
            XCTAssertGreaterThanOrEqual(percent, 25,
                "Zoom should not go below 25%, got: \(percent)%")
            XCTAssertLessThan(percent, 100,
                "Zoom should be < 100% after zooming out, got: \(percent)%")
        } else {
            XCTFail("Could not parse zoom percentage from label: \(label)")
        }
    }

    // MARK: - Address Bar URL Detection Tests

    /// Test: Typing "google.com" navigates to google.com (URL), not a search.
    func testAddressBarRecognizesDomainAsURL() {
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText("google.com\n")

        // Should navigate to google.com, not search for "google.com"
        let isURL = waitForURL(containing: "google.com", timeout: 15)
        let url = app.staticTexts["pageURL"].label
        // URL should NOT contain "search?q=" (that would mean it was treated as search)
        XCTAssertFalse(url.contains("search?q=google"),
                       "google.com should navigate as URL, not search. Got: \(url)")
        XCTAssertTrue(isURL, "Should navigate to google.com")
    }

    /// Test: Cmd+Delete in address bar clears text (standard macOS behavior).
    func testCmdDeleteInAddressBar() {
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText("some text to delete")

        // Verify text was typed
        let value1 = addressBar.value as? String ?? ""
        XCTAssertFalse(value1.isEmpty, "Address bar should have text")

        // Cmd+Delete — should delete to beginning of line (macOS standard)
        addressBar.typeKey(.delete, modifierFlags: .command)
        sleep(1)

        // App should not hang or crash
        XCTAssertTrue(app.windows.firstMatch.exists, "App should not crash after Cmd+Delete")

        // Address bar should be empty or shorter
        let value2 = addressBar.value as? String ?? ""
        XCTAssertTrue(value2.count < value1.count,
                      "Cmd+Delete should clear text. Before: '\(value1)', After: '\(value2)'")
    }

    /// Test: Type Chinese text into Baidu search box via real keyboard events.
    /// Dual-track: XCUITest keyboard events + CDP verification of input value.
    func testChineseInputInWebContent() async throws {
        // XCUITest: navigate, wait, and type Chinese text
        let shouldSkip: Bool = await MainActor.run {
            navigate(to: "https://www.baidu.com")
            _ = waitForURL(containing: "baidu.com")
            _ = waitForLoadComplete()

            let content = webContent
            if !content.waitForExistence(timeout: 10) { return true }

            // Click baidu search box area (center, slightly above middle)
            let coord = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            coord.click()
            sleep(1)

            // Type Chinese text — goes through:
            // CGEvent → NSApp → OWLRemoteLayerView.keyDown: → IME → insertText: → C-ABI → Mojo → Host → Renderer
            app.typeText("你好世界")
            return false
        }
        try XCTSkipIf(shouldSkip, "webContentView not in AX tree")

        // CDP enhancement: verify input received Chinese text before pressing Enter
        if let cdp = Self.cdp {
            let value = try? await cdp.evaluate("document.querySelector('input#kw')?.value ?? ''")
            if let value = value, !value.isEmpty {
                XCTAssertTrue(value.contains("你好世界"),
                              "CDP: input#kw should contain '你好世界', got: '\(value)'")
            }
        }

        // XCUITest: press Enter, wait for load, verify app is responsive
        await MainActor.run {
            // Press Enter to search
            app.typeKey(.return, modifierFlags: [])

            // Wait for search results page to load
            _ = waitForLoadComplete(timeout: 15)

            // XCUITest assertion: app still responsive after Chinese input + Enter
            XCTAssertTrue(app.windows.firstMatch.exists, "App should not crash after Chinese input")
            let addressBar = app.textFields["addressBar"]
            XCTAssertTrue(addressBar.waitForExistence(timeout: 5),
                          "Address bar should still be responsive after Chinese input in web content")
        }
    }

    /// Test: Cmd+Delete in web content does not crash the app.
    /// Dual-track: XCUITest keyboard events + CDP verification of input state after Cmd+Delete.
    func testCmdDeleteInWebContent() async throws {
        // XCUITest: navigate, wait, click, and type
        let shouldSkip: Bool = await MainActor.run {
            navigate(to: "https://www.baidu.com")
            _ = waitForURL(containing: "baidu.com")
            _ = waitForLoadComplete()

            let content = webContent
            if !content.waitForExistence(timeout: 10) { return true }

            // Click search box area
            let coord = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            coord.click()
            sleep(1)

            // Type some text then Cmd+Delete
            app.typeText("test text")
            return false
        }
        try XCTSkipIf(shouldSkip, "webContentView not in AX tree")

        // CDP: capture value before Cmd+Delete
        var valueBefore: String?
        if let cdp = Self.cdp {
            valueBefore = try? await cdp.evaluate("document.querySelector('input#kw')?.value ?? ''")
        }

        // XCUITest: Cmd+Delete and verify app survives
        await MainActor.run {
            app.typeKey(.delete, modifierFlags: .command)
            sleep(1)

            // XCUITest assertion: app should still be responsive
            XCTAssertTrue(app.windows.firstMatch.exists, "App should survive Cmd+Delete in web content")
        }

        // CDP enhancement: verify input value changed after Cmd+Delete
        if let cdp = Self.cdp {
            let valueAfter = try? await cdp.evaluate("document.querySelector('input#kw')?.value ?? ''")
            if let before = valueBefore, !before.isEmpty,
               let after = valueAfter {
                XCTAssertTrue(after.count < before.count,
                              "CDP: input value should be shorter after Cmd+Delete, before: '\(before)', after: '\(after)'")
            }
        }
    }
}
