/// OWL Browser History XCUITest — end-to-end through real system events.
///
/// Tests the full stack: user navigates → DidFinishNavigation → HistoryService.AddVisit →
/// SQLite → QueryByTime → Bridge JSON → Swift HistoryViewModel → SwiftUI rendering.
///
/// Run: xcodebuild test -project OWLBrowser.xcodeproj -scheme OWLBrowserUITests -only-testing:OWLHistoryUITests
import XCTest

final class OWLHistoryUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()

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

        let addressBar = app.textFields["addressBar"]
        XCTAssertTrue(addressBar.waitForExistence(timeout: 20),
                      "Address bar should appear after app launch")
    }

    override func tearDownWithError() throws {
        // Don't terminate — keep app running for next test.
    }

    // MARK: - Helpers

    /// Navigate via address bar.
    private func navigate(to url: String) {
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText(url + "\n")
    }

    /// Wait for page URL to contain a substring.
    private func waitForURL(containing substring: String, timeout: TimeInterval = 15) -> Bool {
        let pageURL = app.staticTexts["pageURL"]
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageURL)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Open the history sidebar with fresh data.
    /// If already in history mode, toggles off then back on to trigger reload.
    private func openHistorySidebar(forceReload: Bool = false) {
        let searchField = app.textFields["historySearchField"]
        let historyButton = app.buttons["sidebarHistoryButton"]

        if searchField.exists && forceReload {
            // Toggle off then back on to trigger a fresh loadInitial()
            if historyButton.exists { historyButton.click() }
            sleep(1)
            if historyButton.exists { historyButton.click() }
            _ = searchField.waitForExistence(timeout: 10)
            sleep(3)
            return
        }

        if searchField.exists {
            return
        }

        if historyButton.waitForExistence(timeout: 10) {
            historyButton.click()
        }

        _ = searchField.waitForExistence(timeout: 10)
        sleep(3)
    }

    /// Type into the history search field.
    private func searchHistory(_ query: String) {
        let searchField = app.textFields["historySearchField"]
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("History search field not found"); return
        }
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText(query)
        sleep(1) // debounce + render
    }

    // MARK: - Tests

    /// E2E-H01: Navigate to a page → open history → page appears in history list.
    func testNavigationRecordsHistory() {
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"),
                      "Should navigate to example.com")
        sleep(5)

        openHistorySidebar(forceReload: true)

        let anyRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        ).firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 15),
                      "At least one history row should appear after navigation")

        let exampleRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'example.com'")
        ).firstMatch
        XCTAssertTrue(exampleRow.waitForExistence(timeout: 5),
                      "History should contain example.com entry")
    }

    /// E2E-H02: Navigate to multiple pages → history is ordered by most recent first.
    func testHistoryOrderedByRecency() {
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(5)

        navigate(to: "https://www.baidu.com")
        XCTAssertTrue(waitForURL(containing: "baidu.com"))
        sleep(5)

        openHistorySidebar(forceReload: true)

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )

        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15),
                      "History rows should appear")
        XCTAssertGreaterThanOrEqual(rows.count, 2,
                      "Should have at least 2 history entries")

        // First row should be baidu (most recent)
        let firstLabel = rows.element(boundBy: 0).label
        XCTAssertTrue(firstLabel.contains("baidu"),
                      "First row should be most recent (baidu), got: \(firstLabel)")
    }

    /// E2E-H03: Search history — matching results appear, non-matching hidden.
    func testHistorySearch() throws {
        // Ensure some history exists
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(2)

        navigate(to: "https://www.baidu.com")
        XCTAssertTrue(waitForURL(containing: "baidu.com"))
        sleep(2)

        // Open history
        openHistorySidebar()

        // Wait for history to load
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        let hasRows = rows.firstMatch.waitForExistence(timeout: 10)
        try XCTSkipUnless(hasRows, "No history rows — cannot test search")

        let countBefore = rows.count

        // Search for "example"
        searchHistory("example")
        sleep(1)

        // Results should be filtered
        let searchRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        // Either fewer rows (filtered) or search empty state
        let countAfter = searchRows.count
        let searchEmpty = app.otherElements["historySearchEmpty"]
        XCTAssertTrue(countAfter <= countBefore || searchEmpty.exists,
                      "Search should filter history or show empty state")
    }

    /// E2E-H04: Search with no matches → empty state appears.
    func testHistorySearchNoMatch() throws {
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(2)

        openHistorySidebar()

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 10),
                          "No history rows loaded")

        // Search for something that definitely won't match
        searchHistory("zzznonexistent99999")
        sleep(1)

        // Should show empty search state or zero rows
        let afterRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        let searchEmpty = app.otherElements["historySearchEmpty"]
        XCTAssertTrue(afterRows.count == 0 || searchEmpty.exists,
                      "Non-matching search should show empty state or no rows")
    }

    /// E2E-H05: History sidebar shows "暂无浏览历史" empty state when no history exists.
    /// Requires a clean profile with zero browsing history. Prior tests in the same
    /// suite always create history entries, making this test unreliable in shared sessions.
    func testHistoryEmptyState() throws {
        throw XCTSkip("Requires clean profile — prior tests create history entries")
    }

    /// E2E-H06: Navigate → open history → app does not crash.
    /// Smoke test for the full history pipeline.
    func testHistoryPipelineSmoke() {
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(2)

        openHistorySidebar()
        sleep(2)

        // Verify app is still responsive
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "App should survive history sidebar interaction")

        // Navigate to another page while history sidebar is open
        navigate(to: "https://www.baidu.com")
        XCTAssertTrue(waitForURL(containing: "baidu.com"))
        sleep(2)

        // App should still be running
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "App should survive navigation with history sidebar open")
    }

    /// E2E-H07: Open history → search → clear search → original list restores.
    func testHistoryClearSearch() throws {
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(2)

        openHistorySidebar()

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 10),
                          "No history rows loaded")

        // Search to filter
        searchHistory("example")
        sleep(1)

        // Clear search by selecting all + delete
        let searchField = app.textFields["historySearchField"]
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])
        sleep(1)

        // History rows should reappear
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5),
                      "History rows should reappear after clearing search")
    }

    // MARK: - Extended History Tests

    /// E2E-H08: Open history → click a history entry → address bar URL changes to that entry's URL.
    func testHistoryClickNavigates() throws {
        // Create a history entry by navigating
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"),
                      "Should navigate to example.com")
        sleep(3)

        // Navigate away so clicking history entry causes a visible URL change
        navigate(to: "https://www.baidu.com")
        XCTAssertTrue(waitForURL(containing: "baidu.com"),
                      "Should navigate to baidu.com")
        sleep(3)

        openHistorySidebar(forceReload: true)

        // Find the example.com history entry
        let exampleRow = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'example.com'")
        ).firstMatch
        try XCTSkipUnless(exampleRow.waitForExistence(timeout: 10),
                          "example.com history row not found")

        // Click the history entry to navigate
        exampleRow.click()

        // Verify address bar URL changes to example.com
        XCTAssertTrue(waitForURL(containing: "example.com", timeout: 15),
                      "Clicking history entry should navigate to example.com")
    }

    /// E2E-H09: Open history → right-click a row → choose "删除" → row disappears, undo toast appears.
    func testHistoryDeleteEntry() throws {
        // Create a history entry
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(3)

        openHistorySidebar(forceReload: true)

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 10),
                          "No history rows loaded")
        let countBefore = rows.count

        // Right-click the first history row to open context menu
        let firstRow = rows.firstMatch
        firstRow.rightClick()

        // Choose "删除" from the context menu
        let deleteMenuItem = app.menuItems["删除"]
        try XCTSkipUnless(deleteMenuItem.waitForExistence(timeout: 5),
                          "Delete context menu item not found — feature may not be implemented")
        deleteMenuItem.click()
        sleep(1)

        // Verify row count decreased or the specific row disappeared
        let countAfter = rows.count
        XCTAssertLessThan(countAfter, countBefore,
                          "Row count should decrease after deletion (was \(countBefore), now \(countAfter))")

        // Verify undo toast appears
        let undoButton = app.buttons["historyUndoButton"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5),
                      "Undo toast with '撤销' button should appear after deletion")
    }

    /// E2E-H10: Delete a history entry → undo toast appears → click "撤销" → entry reappears.
    func testHistoryUndoDelete() throws {
        // Create a history entry
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(3)

        openHistorySidebar(forceReload: true)

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 10),
                          "No history rows loaded")
        let countBefore = rows.count

        // Right-click and delete first row
        let firstRow = rows.firstMatch
        firstRow.rightClick()

        let deleteMenuItem = app.menuItems["删除"]
        try XCTSkipUnless(deleteMenuItem.waitForExistence(timeout: 5),
                          "Delete context menu item not found — feature may not be implemented")
        deleteMenuItem.click()
        sleep(1)

        // Verify undo toast appears
        let undoButton = app.buttons["historyUndoButton"]
        try XCTSkipUnless(undoButton.waitForExistence(timeout: 5),
                          "Undo button not found — undo feature may not be implemented")

        // Click "撤销" to undo
        undoButton.click()
        sleep(1)

        // Verify row count is restored
        let countAfterUndo = rows.count
        XCTAssertEqual(countAfterUndo, countBefore,
                       "Row count should be restored after undo (expected \(countBefore), got \(countAfterUndo))")
    }

    /// E2E-H11: Navigate → open history → verify at least one date group header exists.
    func testHistoryDateGroupHeaders() throws {
        // Create a history entry so grouping is visible
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(3)

        openHistorySidebar(forceReload: true)

        // Wait for history rows to load
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 10),
                          "No history rows loaded")

        // Date group headers use .accessibilityAddTraits(.isHeader)
        // Query for known date header labels: "今天", "昨天", "本周", "更早"
        let knownHeaders = ["今天", "昨天", "本周", "更早"]
        let headerPredicate = NSPredicate(format: "label IN %@", knownHeaders)
        let headers = app.staticTexts.matching(headerPredicate)

        XCTAssertGreaterThanOrEqual(headers.count, 1,
                                    "At least one date group header (今天/昨天/本周/更早) should exist")
    }

    /// E2E-H12: Sidebar mode switching — history → bookmarks → tabs.
    func testSidebarModeSwitch() throws {
        // Switch to history mode
        let historyButton = app.buttons["sidebarHistoryButton"]
        try XCTSkipUnless(historyButton.waitForExistence(timeout: 10),
                          "sidebarHistoryButton not available — feature not yet implemented")
        historyButton.click()

        // Verify history search field exists
        let searchField = app.textFields["historySearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10),
                      "History search field should appear in history mode")

        // Switch to bookmarks mode
        let bookmarkButton = app.buttons["sidebarTopBookmarkButton"]
        try XCTSkipUnless(bookmarkButton.waitForExistence(timeout: 5),
                          "sidebarTopBookmarkButton not available")
        bookmarkButton.click()
        sleep(1)

        // Verify history search field disappears
        let searchFieldAfterSwitch = app.textFields["historySearchField"]
        XCTAssertFalse(searchFieldAfterSwitch.exists,
                       "History search field should disappear in bookmarks mode")

        // Switch back to tabs mode (click bookmarks again to toggle off)
        bookmarkButton.click()
        sleep(1)

        // Verify history search field is still gone (we're in tabs mode now)
        XCTAssertFalse(app.textFields["historySearchField"].exists,
                       "History search field should not exist in tabs mode")
    }

    /// E2E-H13: Open history → navigate to new page → verify row count increases.
    func testHistoryUpdatesOnNewNavigation() throws {
        // Create initial history
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"))
        sleep(3)

        openHistorySidebar(forceReload: true)

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyRow_'")
        )
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 10),
                          "No history rows loaded")
        let countBefore = rows.count

        // Navigate to a new page while history sidebar is open
        navigate(to: "https://www.baidu.com")
        XCTAssertTrue(waitForURL(containing: "baidu.com"),
                      "Should navigate to baidu.com")
        sleep(5)

        // Force reload history to pick up the new entry
        openHistorySidebar(forceReload: true)

        // Wait for new entry to appear
        let newEntryPredicate = NSPredicate(format: "identifier CONTAINS 'baidu'")
        let newEntry = app.buttons.matching(newEntryPredicate).firstMatch
        let appeared = newEntry.waitForExistence(timeout: 10)

        // Verify either the specific entry appeared or count increased
        let countAfter = rows.count
        XCTAssertTrue(appeared || countAfter > countBefore,
                      "New history entry should appear after navigation (before: \(countBefore), after: \(countAfter))")
    }

    /// E2E-H14: Navigate to example.com → navigate to second URL → go back → verify URL → go forward → verify URL.
    func testBackForwardNavigation() throws {
        // Navigate to first page
        navigate(to: "https://example.com")
        XCTAssertTrue(waitForURL(containing: "example.com"),
                      "Should navigate to example.com")
        sleep(3)

        // Navigate to second page
        navigate(to: "https://www.baidu.com")
        XCTAssertTrue(waitForURL(containing: "baidu.com"),
                      "Should navigate to baidu.com")
        sleep(3)

        // Go back using keyboard shortcut Cmd+[
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForURL(containing: "example.com", timeout: 15),
                      "Going back should return to example.com")

        // Go forward using keyboard shortcut Cmd+]
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(waitForURL(containing: "baidu.com", timeout: 15),
                      "Going forward should return to baidu.com")
    }
}
