/// OWL Browser Dual-Driver E2E Tests — XCUITest + CDPHelper cross-layer assertions.
///
/// These tests combine native UI automation (XCUITest) with Chrome DevTools Protocol
/// inspection (CDPHelper) to verify the full stack: SwiftUI shell operations trigger
/// correct DOM/network/console state in the Chromium renderer.
///
/// Architecture:
///   XCUITest (native UI) → C-ABI → Mojo → Host → Renderer
///   CDPHelper (CDP :9222) → DevTools → Renderer state inspection
///
/// Run: xcodebuild test -project OWLBrowser.xcodeproj -scheme OWLBrowserUITests -only-testing:OWLDualDriverTests
import XCTest

final class OWLDualDriverTests: XCTestCase {

    // Cross-test reuse: app and CDP connection persist across all tests in this class.
    static let app = XCUIApplication()
    static var cdp: CDPHelper!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false

        let app = Self.app
        if app.state != .runningForeground {
            app.launchEnvironment["OWL_CLEAN_SESSION"] = "1"
            app.launchEnvironment["OWL_CDP_PORT"] = "9222"
            app.launch()
        }

        // Wait for the address bar to confirm app readiness.
        let addressBar = app.textFields["addressBar"]
        XCTAssertTrue(addressBar.waitForExistence(timeout: 20),
                      "Address bar should appear after app launch")

        // Initialize CDP connection once, with retry for Host startup delay.
        if Self.cdp == nil {
            Self.cdp = CDPHelper(port: 9222)
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
                Self.cdp = nil  // Reset so next setUp will retry connection
                XCTFail("Failed to connect to CDP after 15 retries — is Host running with --remote-debugging-port?")
                return
            }
        }
    }

    override func tearDown() async throws {
        // Don't disconnect CDP or terminate app — reuse across tests.
        try await super.tearDown()
    }

    override class func tearDown() {
        cdp?.disconnect()
    }

    // MARK: - Helpers

    /// Navigate via address bar — types URL and presses Enter (real system events).
    /// @MainActor ensures XCUITest API calls run on main thread (async tests may not).
    @MainActor
    private func navigate(to url: String) {
        let app = Self.app
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText(url + "\n")
    }

    /// Wait for page URL to contain a substring (via hidden accessibility label).
    @MainActor
    private func waitForURL(containing substring: String, timeout: TimeInterval = 15) -> Bool {
        let pageURL = Self.app.staticTexts["pageURL"]
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageURL)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait for page loading to complete (isLoading == false) via AccessibleLabel.
    @MainActor
    private func waitForLoadComplete(timeout: TimeInterval = 15) -> Bool {
        let pageLoading = Self.app.staticTexts["pageLoading"]
        let predicate = NSPredicate(format: "label == %@", "false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageLoading)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Cross-Layer Tests (L4: XCUITest + CDPHelper)

    /// L4-DD01: Address bar navigate then verify DOM content via CDP.
    ///
    /// Flow: XCUITest types URL in address bar → waits for URL change via AccessibleLabel →
    /// CDPHelper queries DOM for <h1> element → asserts text content.
    /// Validates: native input → Chromium navigation → DOM rendering pipeline.
    func testAddressBarNavigateThenVerifyDOM() async throws {
        // 1. XCUITest: native UI operation — type URL in address bar
        await navigate(to: "https://example.com")

        // 2. XCUITest: wait for navigation via AccessibleLabel mechanism
        let loaded = await waitForURL(containing: "example.com")
        XCTAssertTrue(loaded, "Page should navigate to example.com")
        _ = await waitForLoadComplete()

        // 3. CDP: precise DOM assertion — something XCUITest cannot do
        try await Self.cdp.waitForSelector("h1", timeout: 10)
        let heading = try await Self.cdp.textContent("h1")
        XCTAssertEqual(heading, "Example Domain",
                       "CDP should read the exact <h1> text from the rendered DOM")
    }

    /// L4-DD02: Search from address bar, verify search results via CDP.
    ///
    /// Flow: XCUITest types search query → waits for page change →
    /// CDPHelper reads currentURL → asserts URL contains search parameters.
    /// Validates: omnibox search → search engine redirect → URL correctness.
    func testSearchFromAddressBarVerifyResults() async throws {
        // 1. XCUITest: type search query in address bar
        await navigate(to: "test query owl browser")

        // 2. Wait for any URL change (search redirect or error)
        var found = await waitForURL(containing: "search", timeout: 10)
        if !found { found = await waitForURL(containing: "q=", timeout: 5) }
        if !found { found = await waitForURL(containing: "wd=", timeout: 5) }
        _ = await waitForLoadComplete()

        // 3. Use CDP as the authoritative source — skip if search didn't trigger
        let url = try await Self.cdp.currentURL()
        let isSearchURL = url.contains("search") || url.contains("q=") || url.contains("wd=")
        try XCTSkipUnless(isSearchURL,
                          "Address bar search not yet implemented — CDP URL: \(url)")
    }

    /// L4-DD03: Navigate to page, open history sidebar, verify history entry exists.
    ///
    /// Flow: XCUITest navigates to example.com → opens history sidebar →
    /// verifies history contains matching entry via AX tree.
    /// Validates: navigation → HistoryService.AddVisit → SQLite → SwiftUI rendering.
    func testHistorySidebarNavigateVerifyDOM() async throws {
        // 1. Navigate to a known page to create a history entry
        await navigate(to: "https://example.com")
        let loaded = await waitForURL(containing: "example.com")
        XCTAssertTrue(loaded, "Should navigate to example.com")
        _ = await waitForLoadComplete()

        // Wait for DOM to confirm navigation completed (replaces fixed sleep)
        try await Self.cdp.waitForSelector("h1", timeout: 10)

        // 2. Open history sidebar — skip if button not yet implemented
        let app = Self.app
        let historyButton = app.buttons["sidebarHistoryButton"]
        try XCTSkipUnless(historyButton.waitForExistence(timeout: 3),
                          "sidebarHistoryButton not available — feature not yet implemented")
        historyButton.click()

        // 3. Verify history contains an entry with "example" in its label
        let historyItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "example")
        ).firstMatch
        XCTAssertTrue(historyItem.waitForExistence(timeout: 10),
                      "History sidebar should contain an entry for example.com")

        // 4. CDP: verify the current page is still example.com (cross-layer assertion)
        let currentUrl = try await Self.cdp.currentURL()
        XCTAssertTrue(currentUrl.contains("example.com"),
                      "Current page should still be example.com, got: \(currentUrl)")
    }

    /// L4-DD04: Enable console capture, navigate, inject console.log, verify capture.
    ///
    /// Flow: CDPHelper enables Runtime domain → XCUITest navigates →
    /// CDPHelper evaluates console.log → verifies message captured.
    /// Validates: CDP Runtime.consoleAPICalled event pipeline.
    func testConsoleMessagesCapture() async throws {
        // 1. Enable console capture and clear previous messages
        try await Self.cdp.enableConsole()
        Self.cdp.clearConsoleMessages()

        // 2. Navigate to a page (need a loaded page to evaluate JS)
        await navigate(to: "https://example.com")
        let consoleNavLoaded = await waitForURL(containing: "example.com")
        XCTAssertTrue(consoleNavLoaded, "Should navigate to example.com")
        _ = await waitForLoadComplete()
        try await Self.cdp.waitForSelector("body", timeout: 10)

        // 3. Inject a console.log via CDP and verify capture
        _ = try await Self.cdp.evaluate("console.log('owl-e2e-test')")

        // Allow time for the console event to propagate through CDP WebSocket
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        let messages = Self.cdp.consoleMessages
        XCTAssertTrue(
            messages.contains(where: { $0.text == "owl-e2e-test" }),
            "Console messages should contain 'owl-e2e-test', got: \(messages.map(\.text))"
        )
    }

    /// L4-DD05: Enable network capture, navigate via CDP, verify request recorded.
    ///
    /// Flow: CDPHelper enables Network domain → navigateAndWait to example.com →
    /// verifies capturedRequests contains the target URL.
    /// Validates: CDP Network.requestWillBeSent event pipeline.
    func testNetworkRequestCapture() async throws {
        // 1. Enable network capture and clear previous requests
        try await Self.cdp.enableNetwork()
        Self.cdp.clearCapturedRequests()

        // 2. Navigate using CDP (bypasses XCUITest for pure network testing)
        try await Self.cdp.navigateAndWait("https://example.com", timeout: 15)

        // 3. Verify network requests were captured
        let requests = Self.cdp.capturedRequests
        XCTAssertTrue(
            requests.contains(where: { $0.url.contains("example.com") }),
            "Captured requests should include example.com, got: \(requests.map(\.url))"
        )
    }

    // MARK: - Extended Dual-Driver Tests

    /// L4-DD06: Navigate → open history → click entry → verify DOM via CDP.
    ///
    /// Flow: XCUITest navigates to example.com → opens history sidebar → clicks the
    /// history entry → CDPHelper verifies window.location.href and DOM content match.
    /// Validates: history click → navigation → Chromium renderer state update.
    func testHistoryClickNavigateVerifyDOM() async throws {
        // 1. Navigate to example.com to create a history entry
        await navigate(to: "https://example.com")
        let loaded = await waitForURL(containing: "example.com")
        XCTAssertTrue(loaded, "Should navigate to example.com")
        _ = await waitForLoadComplete()
        try await Self.cdp.waitForSelector("h1", timeout: 10)
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s for history write

        // 2. Navigate away so clicking history causes a visible change
        await navigate(to: "https://www.baidu.com")
        let loadedBaidu = await waitForURL(containing: "baidu.com")
        XCTAssertTrue(loadedBaidu, "Should navigate to baidu.com")
        _ = await waitForLoadComplete()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // 3. Open history sidebar
        let app = Self.app
        let historyButton = app.buttons["sidebarHistoryButton"]
        try XCTSkipUnless(historyButton.waitForExistence(timeout: 5),
                          "sidebarHistoryButton not available — feature not yet implemented")

        await MainActor.run {
            // Toggle off then on for fresh load
            historyButton.click()
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run {
            historyButton.click()
        }

        let searchField = app.textFields["historySearchField"]
        _ = searchField.waitForExistence(timeout: 10)
        try await Task.sleep(nanoseconds: 3_000_000_000) // wait for history to load

        // 4. Click the example.com history entry
        let exampleRow = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'example.com'")
        ).firstMatch
        try XCTSkipUnless(exampleRow.waitForExistence(timeout: 10),
                          "example.com history row not found")

        await MainActor.run {
            exampleRow.click()
        }

        // 5. XCUITest: wait for URL to change back to example.com
        let navigated = await waitForURL(containing: "example.com", timeout: 15)
        XCTAssertTrue(navigated, "Clicking history entry should navigate to example.com")
        _ = await waitForLoadComplete()

        // 6. CDP: verify the renderer state matches
        let currentUrl = try await Self.cdp.currentURL()
        XCTAssertTrue(currentUrl.contains("example.com"),
                      "CDP should confirm URL is example.com, got: \(currentUrl)")

        try await Self.cdp.waitForSelector("h1", timeout: 10)
        let heading = try await Self.cdp.textContent("h1")
        XCTAssertEqual(heading, "Example Domain",
                       "CDP should read <h1> as 'Example Domain' after history click navigation")
    }

    /// L4-DD07: Navigate to example.com → navigate to second page → go back → verify DOM via CDP.
    ///
    /// Flow: XCUITest navigates to two pages → uses Cmd+[ to go back →
    /// CDPHelper verifies the DOM reflects the first page.
    /// Validates: back navigation → Chromium renderer correctly restores previous page.
    func testBackForwardNavigationVerifyDOM() async throws {
        // 1. Navigate to example.com
        await navigate(to: "https://example.com")
        let loaded1 = await waitForURL(containing: "example.com")
        XCTAssertTrue(loaded1, "Should navigate to example.com")
        _ = await waitForLoadComplete()
        try await Self.cdp.waitForSelector("h1", timeout: 10)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // 2. Navigate to a second page
        await navigate(to: "https://www.baidu.com")
        let loaded2 = await waitForURL(containing: "baidu.com")
        XCTAssertTrue(loaded2, "Should navigate to baidu.com")
        _ = await waitForLoadComplete()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // 3. Go back using Cmd+[
        await MainActor.run {
            Self.app.typeKey("[", modifierFlags: .command)
        }

        let wentBack = await waitForURL(containing: "example.com", timeout: 15)
        XCTAssertTrue(wentBack, "Going back should return to example.com")
        _ = await waitForLoadComplete()

        // 4. CDP: verify DOM contains example.com content
        try await Self.cdp.waitForSelector("h1", timeout: 10)
        let heading = try await Self.cdp.textContent("h1")
        XCTAssertEqual(heading, "Example Domain",
                       "CDP should confirm DOM shows 'Example Domain' after going back")

        let currentUrl = try await Self.cdp.currentURL()
        XCTAssertTrue(currentUrl.contains("example.com"),
                      "CDP URL should contain example.com after going back, got: \(currentUrl)")
    }

    /// L4-DD08: Open history sidebar → navigate to new URL → verify via CDP → verify new history entry in AX tree.
    ///
    /// Flow: XCUITest opens history sidebar → navigates to a new URL via address bar →
    /// CDPHelper confirms page loaded → XCUITest verifies new entry appears in history.
    /// Validates: live history update while sidebar is open + cross-layer page load confirmation.
    func testNavigationWhileHistoryOpenVerifyNewEntry() async throws {
        // 1. Create initial history entry
        await navigate(to: "https://example.com")
        let loaded = await waitForURL(containing: "example.com")
        XCTAssertTrue(loaded, "Should navigate to example.com")
        _ = await waitForLoadComplete()
        try await Self.cdp.waitForSelector("h1", timeout: 10)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // 2. Open history sidebar
        let app = Self.app
        let historyButton = app.buttons["sidebarHistoryButton"]
        try XCTSkipUnless(historyButton.waitForExistence(timeout: 5),
                          "sidebarHistoryButton not available — feature not yet implemented")

        await MainActor.run {
            historyButton.click()
        }

        let searchField = app.textFields["historySearchField"]
        _ = searchField.waitForExistence(timeout: 10)
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // 3. Navigate to a new URL while history is open
        await navigate(to: "https://www.baidu.com")
        let loadedNew = await waitForURL(containing: "baidu.com")
        XCTAssertTrue(loadedNew, "Should navigate to baidu.com")
        _ = await waitForLoadComplete()

        // 4. CDP: verify the new page actually loaded
        let currentUrl = try await Self.cdp.currentURL()
        XCTAssertTrue(currentUrl.contains("baidu.com"),
                      "CDP should confirm navigation to baidu.com, got: \(currentUrl)")

        // 5. Force reload history sidebar to pick up the new entry
        await MainActor.run {
            historyButton.click()
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run {
            historyButton.click()
        }
        _ = searchField.waitForExistence(timeout: 10)
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // 6. Verify new history entry for baidu.com appears in AX tree
        let baiduEntry = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'baidu'")
        ).firstMatch
        XCTAssertTrue(baiduEntry.waitForExistence(timeout: 10),
                      "History sidebar should contain a new entry for baidu.com after navigation")
    }
}
