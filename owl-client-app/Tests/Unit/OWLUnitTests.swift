import XCTest
@testable import OWLBrowserLib

/// ViewModel unit tests using MockConfig — no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class OWLViewModelTests: XCTestCase {

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Helper: create ViewModel with MockConfig on MainActor.
    private func makeVM(
        tabs: [(String, String?)] = [("新标签页", nil)],
        shouldFail: Bool = false,
        failMessage: String = ""
    ) -> BrowserViewModel {
        MainActor.assumeIsolated {
            BrowserViewModel(mockConfig: .init(
                initialTabs: tabs,
                connectionDelay: 0,
                shouldFail: shouldFail,
                failMessage: failMessage
            ))
        }
    }

    // MARK: - AC-B01: MockConfig initialization

    func testMockConfigInitialization() {
        let vm = makeVM()
        MainActor.assumeIsolated {
            XCTAssertEqual(vm.connectionState, .disconnected)
        }
    }

    // MARK: - AC-B02/B03: launch() with MockConfig

    func testLaunchWithMockConfigConnects() {
        let vm = makeVM(tabs: [("Tab 1", nil)])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.connectionState, .connected)
            XCTAssertEqual(vm.tabs.count, 1)
            XCTAssertEqual(vm.tabs.first?.title, "Tab 1")
        }
    }

    func testLaunchWithMockConfigMultipleTabs() {
        let vm = makeVM(tabs: [("Tab A", "https://a.com"), ("Tab B", "https://b.com")])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 2)
            XCTAssertEqual(vm.tabs[0].title, "Tab A")
            XCTAssertEqual(vm.tabs[1].title, "Tab B")
        }
    }

    // MARK: - AC-B06: Connection failure

    func testLaunchWithMockConfigFailure() {
        let vm = makeVM(shouldFail: true, failMessage: "Test failure")
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.connectionState, .failed("Test failure"))
        }
    }

    // MARK: - AC-B04: Create tab

    func testCreateTabInMockMode() {
        let vm = makeVM(tabs: [("Tab 1", nil)])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            vm.createTab(url: "https://example.com")
        }
        pump(0.1)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 2)
        }
    }

    // MARK: - AC-B05: Close last tab auto-creates new

    func testCloseLastTabCreatesNewTab() {
        let vm = makeVM(tabs: [("Tab 1", nil)])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        var originalId: UUID!
        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 1)
            originalId = vm.tabs.first!.id
            vm.closeTab(vm.tabs.first!)
        }
        pump(0.1)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 1, "Should auto-create new tab")
            XCTAssertNotEqual(vm.activeTab?.id, originalId, "Should be a different tab")
        }
    }

    // MARK: - TabViewModel computed properties
    // Note: navigate() calls real C-ABI via OWLBridge, so cannot be unit-tested
    // without Host. These tests verify computed properties and initial state.

    func testDisplayTitleFallbacks() {
        let vm = makeVM(tabs: [("新标签页", nil)])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            // Default: title == "新标签页" → displayTitle falls back to "新标签页"
            XCTAssertEqual(tab.displayTitle, "新标签页")
        }
    }

    func testDisplayTitleWithRealTitle() {
        let vm = makeVM(tabs: [("Example Domain", "https://example.com")])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            XCTAssertEqual(tab.displayTitle, "Example Domain")
        }
    }

    func testIsWelcomePageAndHasRenderSurface() {
        let vm = makeVM(tabs: [("新标签页", nil)])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            // Initially: no URL, not loading → welcome page
            XCTAssertTrue(tab.isWelcomePage)
            XCTAssertFalse(tab.hasRenderSurface)
        }
    }

    func testIsNotWelcomePageWithURL() {
        let vm = makeVM(tabs: [("Tab", "https://example.com")])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            XCTAssertFalse(tab.isWelcomePage)
        }
    }

    // MARK: - Tab activation

    func testActivateTab() {
        let vm = makeVM(tabs: [("Tab A", nil), ("Tab B", nil)])
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]
            vm.activateTab(tabB)
            XCTAssertEqual(vm.activeTab?.id, tabB.id)
        }
    }

    // MARK: - Phase 34: Zoom Control ViewModel Tests

    /// [P0-1] zoomLevel=0.0 → zoomPercent=100 (pow(1.2, 0) * 100 = 100)
    func testZoomPercentAt100() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            // Initial zoom level is 0.0 = 100%
            XCTAssertEqual(tab.zoomPercent, 100)
        }
    }

    /// [P0-1] zoomLevel=1.0 → zoomPercent=120 (pow(1.2, 1.0) * 100 ≈ 120)
    func testZoomPercentZoomIn() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            // Directly set zoomLevel (zoomIn() calls C-ABI which requires Host)
            tab.zoomLevel = 1.0
            XCTAssertEqual(tab.zoomPercent, 120)
        }
    }

    /// [P0-1] zoomLevel=-1.0 → zoomPercent=83 (pow(1.2, -1.0) * 100 ≈ 83.33 → 83)
    func testZoomPercentZoomOut() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            tab.zoomLevel = -1.0
            XCTAssertEqual(tab.zoomPercent, 83)
        }
    }

    /// [P0-1] zoomLevel=0.0 → isDefaultZoom=true
    func testIsDefaultZoomAtZero() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            XCTAssertTrue(tab.isDefaultZoom)
        }
    }

    /// [P0-1] zoomLevel=0.005 → isDefaultZoom=true (within 0.01 threshold)
    func testIsDefaultZoomAtSmallValue() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            // Directly set zoomLevel to a small value within threshold
            tab.zoomLevel = 0.005
        }
        pump(0.1)

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            XCTAssertTrue(tab.isDefaultZoom,
                "zoomLevel=0.005 should be treated as default (within 0.01 threshold)")
        }
    }

    /// [P0-1] zoomLevel=0.02 → isDefaultZoom=false (above 0.01 threshold)
    func testIsNotDefaultZoomAboveThreshold() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            // Directly set zoomLevel above threshold
            tab.zoomLevel = 0.02
        }
        pump(0.1)

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            XCTAssertFalse(tab.isDefaultZoom,
                "zoomLevel=0.02 should NOT be treated as default (above 0.01 threshold)")
        }
    }

    /// [P0-1] zoomPercent at maxZoomLevel boundary (8.8 ≈ 488%)
    func testZoomPercentAtMaxBoundary() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            tab.zoomLevel = 8.8  // maxZoomLevel
            let percent = tab.zoomPercent
            XCTAssertGreaterThanOrEqual(percent, 400,
                "At maxZoomLevel=8.8, zoomPercent should be ≥400%, got: \(percent)")
            XCTAssertLessThanOrEqual(percent, 500,
                "At maxZoomLevel=8.8, zoomPercent should be ≤500% (AC-005), got: \(percent)")
        }
    }

    /// [P0-1] zoomPercent at minZoomLevel boundary (-7.6 ≈ 25%)
    func testZoomPercentAtMinBoundary() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            tab.zoomLevel = -7.6  // minZoomLevel
            let percent = tab.zoomPercent
            XCTAssertGreaterThanOrEqual(percent, 25,
                "At minZoomLevel=-7.6, zoomPercent should be ≥25% (AC-005), got: \(percent)")
            XCTAssertLessThanOrEqual(percent, 30,
                "At minZoomLevel=-7.6, zoomPercent should be ≤30%, got: \(percent)")
        }
    }

    /// [P0-1] isDefaultZoom after setting zoomLevel back to 0.0
    func testIsDefaultZoomAfterReset() {
        let vm = makeVM()
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            tab.zoomLevel = 2.0
            XCTAssertFalse(tab.isDefaultZoom,
                "Should not be default zoom at 2.0")
            tab.zoomLevel = 0.0
            XCTAssertTrue(tab.isDefaultZoom,
                "Should be default zoom after setting back to 0.0")
        }
    }

    // Note: zoomIn()/zoomOut()/resetZoom() call OWLBridge C-ABI via setZoom(),
    // which requires Host process. Their clamping behavior is tested via XCUITest
    // (testZoomInMaxBoundary, testZoomOutMinBoundary) and E2E tests.
}
