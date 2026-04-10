/// OWL Browser Download XCUITest — end-to-end download manager verification.
///
/// Tests the full stack: local HTTP server → Chromium content layer download →
/// Host DownloadManager → Bridge callback → Swift DownloadViewModel → SwiftUI rendering.
///
/// Each test navigates to a local test server page that auto-triggers a download
/// (via <meta http-equiv="refresh">), then verifies the native download panel UI.
///
/// Run: xcodebuild test -project OWLBrowser.xcodeproj -scheme OWLBrowserUITests -only-testing:OWLDownloadUITests
import XCTest

final class OWLDownloadUITests: XCTestCase {

    var app: XCUIApplication!
    var server: TestDownloadHTTPServer!

    /// Unique suffix for this test run to avoid filename collisions across parallel runs.
    private let runID = UUID().uuidString.prefix(8)

    // MARK: - File names (owl_test_ prefix for isolation)

    private var smallFilename: String { "owl_test_small_\(runID).bin" }
    private var smallFilename2: String { "owl_test_small2_\(runID).bin" }
    private var slowFilename: String { "owl_test_slow_\(runID).bin" }
    private var errorFilename: String { "owl_test_error_\(runID).bin" }

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        continueAfterFailure = false

        // 1. Start test HTTP server with routes.
        server = TestDownloadHTTPServer()

        // Small file (instant download) — 1 KB
        server.addBinaryRoute(
            path: "/download/small",
            filename: smallFilename,
            sizeBytes: 1024
        )
        // Second small file for AC-006 (multi-download list)
        server.addBinaryRoute(
            path: "/download/small2",
            filename: smallFilename2,
            sizeBytes: 1024
        )
        // Slow file (throttled) — 100 KB at 2 KB/chunk with 50ms delay = ~2.5s total
        server.addBinaryRoute(
            path: "/download/slow",
            filename: slowFilename,
            sizeBytes: 100_000,
            throttle: 2048
        )
        // Error route: sends headers claiming 50 KB but delivers only 512 bytes
        server.addErrorRoute(
            path: "/download/error",
            filename: errorFilename,
            advertisedSize: 50000
        )

        // Auto-download pages (meta refresh redirect to download URL)
        server.addAutoDownloadPage(path: "/auto-small", downloadPath: "/download/small")
        server.addAutoDownloadPage(path: "/auto-small2", downloadPath: "/download/small2")
        server.addAutoDownloadPage(path: "/auto-slow", downloadPath: "/download/slow")
        server.addAutoDownloadPage(path: "/auto-error", downloadPath: "/download/error")

        let port = try server.start()
        NSLog("[OWLDownloadUITests] Server started on port \(port)")

        // 2. Launch or activate app.
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
        // Stop server.
        server?.stop()
        server = nil

        // Clean up test files from ~/Downloads (only owl_test_ prefix).
        let downloads = NSHomeDirectory() + "/Downloads"
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: downloads) {
            for file in files where file.hasPrefix("owl_test_") {
                try? fm.removeItem(atPath: downloads + "/" + file)
            }
        }
    }

    // MARK: - Helpers

    /// Navigate via address bar — types URL and presses Enter.
    private func navigate(to url: String) {
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText(url + "\n")
    }

    /// Open the download sidebar panel by clicking the download toolbar button.
    private func openDownloadPanel() {
        let btn = app.buttons["sidebarDownloadButton"]
        if btn.waitForExistence(timeout: 5) {
            btn.click()
        }
        // Wait for the panel to appear.
        let panel = app.otherElements["downloadSidebarPanel"]
        _ = panel.waitForExistence(timeout: 5)
    }

    /// Find the first element whose accessibility identifier starts with the given prefix.
    private func firstElement(prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        ).firstMatch
    }

    /// All elements whose accessibility identifier starts with the given prefix.
    private func allElements(prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        )
    }

    /// Trigger a small (instant) download via auto-redirect page.
    private func triggerSmallDownload() {
        navigate(to: "http://localhost:\(server.port)/auto-small")
    }

    /// Trigger a second small download (different filename).
    private func triggerSmallDownload2() {
        navigate(to: "http://localhost:\(server.port)/auto-small2")
    }

    /// Trigger a slow (throttled) download via auto-redirect page.
    private func triggerSlowDownload() {
        navigate(to: "http://localhost:\(server.port)/auto-slow")
    }

    /// Trigger an error download (headers sent, connection closed early).
    private func triggerErrorDownload() {
        navigate(to: "http://localhost:\(server.port)/auto-error")
    }

    // MARK: - AC-001: Download triggered, row appears in panel

    /// AC-001: Click download link triggers download; download row appears in panel.
    func testAC001_DownloadTriggered_RowAppears() {
        triggerSmallDownload()
        openDownloadPanel()

        let row = firstElement(prefix: "downloadRow_")
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "AC-001: Download row should appear in panel after triggering download")

        // Verify the filename label contains the expected file name.
        let filename = firstElement(prefix: "downloadFilename_")
        XCTAssertTrue(filename.waitForExistence(timeout: 5),
                      "AC-001: Filename label should exist in the download row")
        let filenameValue = filename.label
        XCTAssertTrue(filenameValue.contains("owl_test_small_"),
                      "AC-001: Filename should contain 'owl_test_small_' but was '\(filenameValue)'")
    }

    // MARK: - AC-002: Progress display

    /// AC-002: During download, filename and status text are visible.
    func testAC002_ProgressDisplay() {
        triggerSlowDownload()
        openDownloadPanel()

        // Filename label should appear.
        let filename = firstElement(prefix: "downloadFilename_")
        XCTAssertTrue(filename.waitForExistence(timeout: 15),
                      "AC-002: Download filename should be visible")

        // Verify filename text contains the expected slow download name.
        let filenameValue = filename.label
        XCTAssertTrue(filenameValue.contains("owl_test_slow_"),
                      "AC-002: Filename should contain 'owl_test_slow_' but was '\(filenameValue)'")

        // Status text (speed / size) should be visible.
        let status = firstElement(prefix: "downloadStatus_")
        XCTAssertTrue(status.waitForExistence(timeout: 5),
                      "AC-002: Download status text should be visible")

        // Verify status text is non-empty and contains progress format indicators.
        let statusValue = status.label
        XCTAssertFalse(statusValue.isEmpty,
                       "AC-002: Status text should not be empty")
        XCTAssertTrue(statusValue.contains("/") || statusValue.contains("B/s") || statusValue.contains("KB") || statusValue.contains("MB"),
                      "AC-002: Status should contain progress format ('/' or 'B/s' or size unit) but was '\(statusValue)'")
    }

    // MARK: - AC-003: Pause and Resume

    /// AC-003: Pause button pauses download; resume button resumes it.
    func testAC003_PauseResume() {
        triggerSlowDownload()
        openDownloadPanel()

        // Wait for pause button to appear (download is in progress).
        let pauseBtn = firstElement(prefix: "downloadPause_")
        XCTAssertTrue(pauseBtn.waitForExistence(timeout: 15),
                      "AC-003: Pause button should appear for in-progress download")

        pauseBtn.click()

        // After pause, verify status element contains "已暂停".
        let status = firstElement(prefix: "downloadStatus_")
        XCTAssertTrue(status.waitForExistence(timeout: 5),
                      "AC-003: Status element should exist after pausing")
        let pausedStatusValue = status.label
        XCTAssertTrue(pausedStatusValue.contains("已暂停"),
                      "AC-003: Status should contain '已暂停' after pausing but was '\(pausedStatusValue)'")

        // Resume button should appear.
        let resumeBtn = firstElement(prefix: "downloadResume_")
        XCTAssertTrue(resumeBtn.waitForExistence(timeout: 5),
                      "AC-003: Resume button should appear after pausing")

        resumeBtn.click()

        // After resume, pause button should reappear (download resumed).
        let pauseBtnAgain = firstElement(prefix: "downloadPause_")
        XCTAssertTrue(pauseBtnAgain.waitForExistence(timeout: 5),
                      "AC-003: Pause button should reappear after resuming, confirming download resumed")
    }

    // MARK: - AC-004: Cancel download

    /// AC-004: Cancel button cancels download; status shows "已取消".
    func testAC004_CancelDownload() {
        triggerSlowDownload()
        openDownloadPanel()

        // Wait for cancel button.
        let cancelBtn = firstElement(prefix: "downloadCancel_")
        XCTAssertTrue(cancelBtn.waitForExistence(timeout: 15),
                      "AC-004: Cancel button should appear for in-progress download")

        cancelBtn.click()

        // Verify the status element text contains "已取消".
        let status = firstElement(prefix: "downloadStatus_")
        XCTAssertTrue(status.waitForExistence(timeout: 5),
                      "AC-004: Status element should exist after cancelling")
        let statusValue = status.label
        XCTAssertTrue(statusValue.contains("已取消"),
                      "AC-004: Status should contain '已取消' after cancelling but was '\(statusValue)'")
    }

    // MARK: - AC-005: Open / Show in Finder buttons (existence only)

    /// AC-005: After download completes, "打开" and Finder buttons exist.
    /// Note: Does NOT verify system behavior (NSWorkspace), only button presence.
    func testAC005_OpenFinderButtonsExist() {
        triggerSmallDownload()
        openDownloadPanel()

        // Wait for the open button to appear (download must complete first).
        let openBtn = firstElement(prefix: "downloadOpen_")
        XCTAssertTrue(openBtn.waitForExistence(timeout: 20),
                      "AC-005: Open ('打开') button should appear after download completes")

        // Finder button should also exist.
        let finderBtn = firstElement(prefix: "downloadFinder_")
        XCTAssertTrue(finderBtn.exists,
                      "AC-005: Finder button should appear after download completes")
    }

    // MARK: - AC-006: Download history list (multiple downloads)

    /// AC-006: After multiple downloads, the panel shows multiple rows.
    func testAC006_HistoryListMultipleDownloads() {
        triggerSmallDownload()
        openDownloadPanel()

        // Wait for first row.
        let firstRow = firstElement(prefix: "downloadRow_")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15),
                      "AC-006: First download row should appear")

        // Trigger second download.
        triggerSmallDownload2()

        // Wait for at least 2 rows.
        let rows = allElements(prefix: "downloadRow_")
        let secondRow = rows.element(boundBy: 1)
        XCTAssertTrue(secondRow.waitForExistence(timeout: 15),
                      "AC-006: At least 2 download rows should appear")
        XCTAssertGreaterThanOrEqual(rows.count, 2,
                      "AC-006: Download panel should show at least 2 entries")
    }

    // MARK: - AC-007: Error display

    /// AC-007: Download error shows error message in status text.
    func testAC007_ErrorDisplay() {
        triggerErrorDownload()
        openDownloadPanel()

        // Wait for the download status element to appear.
        let status = firstElement(prefix: "downloadStatus_")
        XCTAssertTrue(status.waitForExistence(timeout: 15),
                      "AC-007: Status element should exist for error download")

        // Verify the status text contains a specific error keyword.
        let statusValue = status.label
        XCTAssertTrue(
            statusValue.contains("失败") || statusValue.contains("中断") || statusValue.contains("错误"),
            "AC-007: Status should contain error keyword ('失败', '中断', or '错误') but was '\(statusValue)'"
        )
    }

    // MARK: - AC-008: Clear completed records

    /// AC-008: Clear button removes completed/cancelled/failed downloads.
    func testAC008_ClearCompletedRecords() {
        triggerSmallDownload()
        openDownloadPanel()

        // Wait for download to complete (open button appears).
        let openBtn = firstElement(prefix: "downloadOpen_")
        XCTAssertTrue(openBtn.waitForExistence(timeout: 20),
                      "AC-008: Wait for download to complete")

        // Verify the download row exists BEFORE clearing.
        let rowBeforeClear = firstElement(prefix: "downloadRow_")
        XCTAssertTrue(rowBeforeClear.exists,
                      "AC-008: Download row should exist before clearing")

        // Clear button should be visible.
        let clearBtn = app.buttons["downloadClearButton"]
        XCTAssertTrue(clearBtn.waitForExistence(timeout: 5),
                      "AC-008: Clear button should appear when completed downloads exist")

        clearBtn.click()

        // After clearing, verify the row no longer exists.
        let rowAfterClear = firstElement(prefix: "downloadRow_")
        let emptyState = app.staticTexts["downloadEmptyState"]
        // Wait a moment for UI to update.
        let rowGone = !rowAfterClear.waitForExistence(timeout: 3)
        let emptyShown = emptyState.waitForExistence(timeout: 3)
        XCTAssertTrue(rowGone || emptyShown,
                      "AC-008: Download row should not exist after clearing")
    }

    // MARK: - Supplementary: Empty state

    /// Empty state should appear when no downloads exist.
    func testEmptyState_DisplaysWhenNoDownloads() {
        openDownloadPanel()

        // If there are no prior downloads, empty state should show.
        // If prior tests left downloads, this might not be empty — so we
        // clear first if the clear button is available.
        let clearBtn = app.buttons["downloadClearButton"]
        if clearBtn.waitForExistence(timeout: 3) {
            clearBtn.click()
        }

        let emptyState = app.staticTexts["downloadEmptyState"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5),
                      "Empty state ('暂无下载记录') should appear when no downloads exist")
    }
}
