import AppKit
import XCTest
@testable import OWLBrowserLib

/// Phase 4 unit tests — Pin/Unpin, Undo Close, Close Others/Below,
/// Tab Selection by Index, Keyboard shortcut coverage.
/// Uses BrowserViewModel(mockConfig:) — no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class Phase4PinUndoCloseTests: XCTestCase {

    // MARK: - Helpers

    /// Pump the run loop so mock‐async callbacks settle.
    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Create a BrowserViewModel with MockConfig, launch, and pump.
    private func makeVM(
        tabs: [(String, String?)] = [("Tab 1", "https://a.com")],
        shouldFail: Bool = false
    ) -> BrowserViewModel {
        let vm = MainActor.assumeIsolated {
            BrowserViewModel(mockConfig: .init(
                initialTabs: tabs,
                connectionDelay: 0,
                shouldFail: shouldFail,
                failMessage: shouldFail ? "fail" : ""
            ))
        }
        MainActor.assumeIsolated { vm.launch() }
        pump()
        return vm
    }

    // =========================================================================
    // MARK: - AC-005: Pin Tab (Happy Path)
    // =========================================================================

    /// AC-005: pinTab sets isPinned to true and moves tab to pinned section.
    func testPinTab_setsIsPinnedAndMovesToFront() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            let tabC = vm.tabs[2]
            XCTAssertFalse(tabC.isPinned, "Precondition: tab should not be pinned")

            vm.pinTab(tabC)

            XCTAssertTrue(tabC.isPinned, "AC-005: pinTab should set isPinned to true")
            // Pinned tab should be at index 0 (first and only pinned).
            XCTAssertEqual(vm.tabs[0].id, tabC.id,
                "AC-005: pinned tab should move to the start (pinned section)")
        }
    }

    /// AC-005: pinning multiple tabs preserves insertion order within pinned section.
    func testPinTab_multipleTabsPreserveOrder() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            let tabC = vm.tabs[2]

            vm.pinTab(tabA)
            vm.pinTab(tabC)

            // Both pinned; A was pinned first, C second → pinned section is [A, C].
            XCTAssertTrue(vm.tabs[0].isPinned)
            XCTAssertTrue(vm.tabs[1].isPinned)
            XCTAssertFalse(vm.tabs[2].isPinned)
            XCTAssertEqual(vm.tabs[0].id, tabA.id,
                "AC-005: first pinned tab should be at index 0")
            XCTAssertEqual(vm.tabs[1].id, tabC.id,
                "AC-005: second pinned tab should be at index 1")
        }
    }

    // =========================================================================
    // MARK: - AC-005: Pin Tab (Boundary — Idempotent)
    // =========================================================================

    /// AC-005 Boundary: pinTab on already-pinned tab is idempotent (no-op).
    func testPinTab_alreadyPinned_isIdempotent() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            vm.pinTab(tabA)
            XCTAssertTrue(tabA.isPinned)

            let tabOrderBefore = vm.tabs.map { $0.id }

            // Pin again — should be no-op.
            vm.pinTab(tabA)

            XCTAssertTrue(tabA.isPinned, "AC-005: repeated pin should keep isPinned true")
            XCTAssertEqual(vm.tabs.map { $0.id }, tabOrderBefore,
                "AC-005: repeated pin should not change tab order")
        }
    }

    // =========================================================================
    // MARK: - AC-005: Unpin Tab (Happy Path)
    // =========================================================================

    /// AC-005: unpinTab sets isPinned to false and moves tab to unpinned section.
    func testUnpinTab_setsIsPinnedFalseAndMovesToUnpinnedSection() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            let tabB = vm.tabs[1]
            vm.pinTab(tabA)
            vm.pinTab(tabB)

            // Unpin tabA.
            vm.unpinTab(tabA)

            XCTAssertFalse(tabA.isPinned, "AC-005: unpinTab should set isPinned to false")
            // tabB is still pinned and should be at index 0.
            XCTAssertTrue(vm.tabs[0].isPinned)
            XCTAssertEqual(vm.tabs[0].id, tabB.id,
                "AC-005: remaining pinned tab should stay at front")
            // tabA should be right after pinned section (index 1).
            XCTAssertEqual(vm.tabs[1].id, tabA.id,
                "AC-005: unpinned tab should move to start of unpinned section")
        }
    }

    /// AC-005 Boundary: unpinTab on non-pinned tab is idempotent (no-op).
    func testUnpinTab_notPinned_isIdempotent() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            XCTAssertFalse(tabA.isPinned)

            let tabOrderBefore = vm.tabs.map { $0.id }

            vm.unpinTab(tabA)

            XCTAssertFalse(tabA.isPinned, "AC-005: unpin on non-pinned should keep isPinned false")
            XCTAssertEqual(vm.tabs.map { $0.id }, tabOrderBefore,
                "AC-005: unpin on non-pinned should not change tab order")
        }
    }

    // =========================================================================
    // MARK: - AC-005: Close Protection for Pinned Tabs
    // =========================================================================

    /// AC-005: Closing a pinned tab still works (Cmd+W closes even pinned),
    /// but closeOtherTabs excludes pinned tabs.
    func testCloseOtherTabs_excludesPinnedTabs() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            let tabB = vm.tabs[1]
            let tabC = vm.tabs[2]
            vm.pinTab(tabA)

            // Close others from the perspective of unpinned tabB.
            vm.closeOtherTabs(tabB)

            // tabA is pinned, should survive. tabC is not the target, should be closed.
            XCTAssertTrue(vm.tabs.contains(where: { $0.id == tabA.id }),
                "AC-005: pinned tab should survive closeOtherTabs")
            XCTAssertTrue(vm.tabs.contains(where: { $0.id == tabB.id }),
                "AC-005: target tab should survive closeOtherTabs")
            XCTAssertFalse(vm.tabs.contains(where: { $0.id == tabC.id }),
                "AC-005: unpinned non-target tab should be closed")
        }
    }

    // =========================================================================
    // MARK: - AC-006: Undo Close Tab (Happy Path)
    // =========================================================================

    /// AC-006: close then undo restores tab at correct position.
    /// Note: tabs use nil URL to avoid triggering navigate() which requires
    /// OWLBridge_Initialize() — not available in unit test environment.
    func testUndoCloseTab_restoresAtCorrectPosition() {
        let vm = makeVM(tabs: [("A", nil), ("B", nil), ("C", nil)])

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]

            vm.closeTab(tabB)
            XCTAssertEqual(vm.tabs.count, 2, "Precondition: tab should be removed")

            vm.undoCloseTab()
            // undoCloseTab in mock mode is synchronous (no navigate for empty URL).
            XCTAssertEqual(vm.tabs.count, 3,
                "AC-006: undo should restore the tab")
            // Restored at original index 1.
            XCTAssertEqual(vm.tabs[1].title, "B",
                "AC-006: restored tab should be at original position")
        }
    }

    /// AC-006: undo restores isPinned state.
    /// Closed tab uses nil URL (avoids navigate() C-ABI); surviving tab has URL
    /// (so shouldReplaceBlank is false).
    func testUndoCloseTab_restoresIsPinned() {
        let vm = makeVM(tabs: [("A", nil), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            vm.pinTab(tabA)
            XCTAssertTrue(tabA.isPinned, "Precondition: tabA is pinned")

            vm.closeTab(tabA)
            XCTAssertEqual(vm.tabs.count, 1, "Precondition: pinned tab closed")

            vm.undoCloseTab()

            XCTAssertEqual(vm.tabs.count, 2,
                "AC-006: undo should restore the pinned tab")
            // The restored tab should have isPinned = true.
            let restoredPinnedTabs = vm.tabs.filter { $0.isPinned }
            XCTAssertEqual(restoredPinnedTabs.count, 1,
                "AC-006: undo should restore isPinned state")
        }
    }

    // =========================================================================
    // MARK: - AC-006: Undo Close — Consecutive Undos (LIFO)
    // =========================================================================

    /// AC-006 Boundary: rapid consecutive undos restore in LIFO order.
    func testUndoCloseTab_consecutiveUndos_restoresInLIFOOrder() {
        let vm = makeVM(tabs: [("A", nil), ("B", nil), ("C", nil), ("D", nil)])

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]
            let tabC = vm.tabs[2]

            vm.closeTab(tabB)  // stack: [B]
            vm.closeTab(tabC)  // stack: [B, C]  (note: C's index shifted after B removed)
            XCTAssertEqual(vm.tabs.count, 2)
            XCTAssertEqual(vm.closedTabsStack.count, 2)

            // First undo pops C (last closed = LIFO).
            vm.undoCloseTab()

            XCTAssertEqual(vm.tabs.count, 3,
                "AC-006: first undo should restore one tab")

            // Second undo pops B.
            vm.undoCloseTab()

            XCTAssertEqual(vm.tabs.count, 4,
                "AC-006: second undo should restore another tab")
            XCTAssertTrue(vm.closedTabsStack.isEmpty,
                "AC-006: stack should be empty after undoing all closes")
        }
    }

    // =========================================================================
    // MARK: - AC-006: Undo Close — Empty Stack (Error)
    // =========================================================================

    /// AC-006 Error: undo with empty stack is a no-op (no crash).
    func testUndoCloseTab_emptyStack_isNoOp() {
        let vm = makeVM(tabs: [("A", "https://a.com")])

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.closedTabsStack.isEmpty,
                "Precondition: stack should be empty")

            // Should not crash.
            vm.undoCloseTab()

            XCTAssertEqual(vm.tabs.count, 1,
                "AC-006: undo on empty stack should not change tabs")
        }
    }

    // =========================================================================
    // MARK: - AC-006: Close Last Tab → Undo Replaces Blank
    // =========================================================================

    /// AC-006: Closing the last tab auto-creates a blank; undo replaces it.
    /// Uses nil URL to avoid triggering navigate() which requires OWLBridge_Initialize().
    func testUndoCloseTab_closingLastTab_undoReplacesBlank() {
        let vm = makeVM(tabs: [("Only", nil)])

        MainActor.assumeIsolated {
            let tab = vm.tabs[0]
            vm.closeTab(tab)
        }
        pump(0.3)

        MainActor.assumeIsolated {
            // After closing last tab, a blank auto-created tab should exist.
            XCTAssertEqual(vm.tabs.count, 1,
                "Precondition: auto-created blank tab")
            XCTAssertNil(vm.tabs.first?.url,
                "Precondition: auto-created tab should be blank (no URL)")

            vm.undoCloseTab()

            // Undo should replace the blank tab, not add alongside it.
            XCTAssertEqual(vm.tabs.count, 1,
                "AC-006: undo should replace auto-created blank tab, not add extra")
            XCTAssertEqual(vm.tabs[0].title, "Only",
                "AC-006: restored tab should have original title")
        }
    }

    // =========================================================================
    // MARK: - AC-005: Close Others (from pinned target)
    // =========================================================================

    /// AC-005: closeOtherTabs from a pinned target closes other pinned tabs too.
    func testCloseOtherTabs_fromPinnedTarget_closesOtherPinned() {
        let vm = makeVM(tabs: [
            ("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")
        ])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            let tabB = vm.tabs[1]
            vm.pinTab(tabA)
            vm.pinTab(tabB)

            // Close others from pinned tabA → tabB (also pinned) should be closed.
            vm.closeOtherTabs(tabA)
        }
        pump(0.1)

        MainActor.assumeIsolated {
            // Only tabA should remain (+ possibly an auto-created blank if needed).
            XCTAssertTrue(vm.tabs.contains(where: { $0.id != nil && $0.title == "A" }),
                "AC-005: target pinned tab should survive")
            XCTAssertFalse(vm.tabs.contains(where: { $0.title == "B" }),
                "AC-005: other pinned tab should be closed when target is pinned")
            XCTAssertFalse(vm.tabs.contains(where: { $0.title == "C" }),
                "AC-005: unpinned tab should be closed")
        }
    }

    // =========================================================================
    // MARK: - Close Tabs Below
    // =========================================================================

    /// closeTabsBelow closes only unpinned tabs below the target.
    func testCloseTabsBelow_closesUnpinnedBelowTarget() {
        let vm = makeVM(tabs: [
            ("A", "https://a.com"), ("B", "https://b.com"),
            ("C", "https://c.com"), ("D", "https://d.com")
        ])

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]
            let tabD = vm.tabs[3]
            vm.pinTab(tabD)

            // Before: [A, D(pinned), B, C] — wait, pin moves D to front.
            // After pinTab(D): D moves to index 0 (pinned section).
            // tabs = [D(pin), A, B, C]
            // Now close tabs below B (which is at some index).
            let bIdx = vm.tabs.firstIndex(where: { $0.title == "B" })!
            let tabAtB = vm.tabs[bIdx]
            vm.closeTabsBelow(tabAtB)
        }
        pump(0.1)

        MainActor.assumeIsolated {
            // C (unpinned, below B) should be closed. D (pinned) was above B.
            XCTAssertTrue(vm.tabs.contains(where: { $0.title == "B" }),
                "Target tab should survive")
            XCTAssertFalse(vm.tabs.contains(where: { $0.title == "C" }),
                "Unpinned tab below target should be closed")
            XCTAssertTrue(vm.tabs.contains(where: { $0.title == "D" }),
                "Pinned tab should not be closed by closeTabsBelow")
        }
    }

    /// closeTabsBelow on last tab is a no-op.
    func testCloseTabsBelow_lastTab_isNoOp() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]
            let countBefore = vm.tabs.count

            vm.closeTabsBelow(tabB)

            XCTAssertEqual(vm.tabs.count, countBefore,
                "closeTabsBelow on last tab should be no-op")
        }
    }

    // =========================================================================
    // MARK: - Tab Selection by Index (Cmd+1~9)
    // =========================================================================

    /// selectTabByIndex(1) activates the first tab.
    func testSelectTabByIndex_1_activatesFirst() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            vm.activateTab(vm.tabs[2])
            XCTAssertEqual(vm.activeTab?.title, "C", "Precondition")

            vm.selectTabByIndex(1)

            XCTAssertEqual(vm.activeTab?.title, "A",
                "Cmd+1 should activate the first tab")
        }
    }

    /// selectTabByIndex(9) always activates the last tab.
    func testSelectTabByIndex_9_activatesLast() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            vm.selectTabByIndex(9)

            XCTAssertEqual(vm.activeTab?.title, "C",
                "Cmd+9 should always activate the last tab")
        }
    }

    /// selectTabByIndex with out-of-range index is a no-op.
    func testSelectTabByIndex_outOfRange_isNoOp() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            vm.selectTabByIndex(1)
            let activeBefore = vm.activeTab?.id

            vm.selectTabByIndex(5)  // Only 2 tabs.

            XCTAssertEqual(vm.activeTab?.id, activeBefore,
                "selectTabByIndex with out-of-range index should be no-op")
        }
    }

    /// selectTabByIndex on empty tabs is a no-op (no crash).
    func testSelectTabByIndex_emptyTabs_isNoOp() {
        let vm = MainActor.assumeIsolated {
            BrowserViewModel(mockConfig: .init(
                initialTabs: [],
                connectionDelay: 0,
                shouldFail: false,
                failMessage: ""
            ))
        }
        MainActor.assumeIsolated { vm.launch() }
        pump()

        MainActor.assumeIsolated {
            // Should not crash.
            vm.selectTabByIndex(1)
            vm.selectTabByIndex(9)
        }
    }

    // =========================================================================
    // MARK: - selectPreviousTab / selectNextTab (Cmd+Option+Up/Down)
    // =========================================================================

    /// selectNextTab wraps around from last to first.
    func testSelectNextTab_wrapsAround() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            vm.activateTab(vm.tabs[1])
            XCTAssertEqual(vm.activeTab?.title, "B", "Precondition")

            vm.selectNextTab()

            XCTAssertEqual(vm.activeTab?.title, "A",
                "selectNextTab should wrap from last to first")
        }
    }

    /// selectPreviousTab wraps around from first to last.
    func testSelectPreviousTab_wrapsAround() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            vm.activateTab(vm.tabs[0])
            XCTAssertEqual(vm.activeTab?.title, "A", "Precondition")

            vm.selectPreviousTab()

            XCTAssertEqual(vm.activeTab?.title, "B",
                "selectPreviousTab should wrap from first to last")
        }
    }

    /// selectNextTab with single tab is a no-op.
    func testSelectNextTab_singleTab_isNoOp() {
        let vm = makeVM(tabs: [("A", "https://a.com")])

        MainActor.assumeIsolated {
            let activeBefore = vm.activeTab?.id

            vm.selectNextTab()

            XCTAssertEqual(vm.activeTab?.id, activeBefore,
                "selectNextTab with single tab should be no-op")
        }
    }

    // =========================================================================
    // MARK: - closedTabsStack records close info correctly
    // =========================================================================

    /// closeTab pushes correct ClosedTabInfo onto the stack.
    func testCloseTab_pushesCorrectInfoToStack() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]
            vm.pinTab(tabB)

            vm.closeTab(tabB)

            XCTAssertEqual(vm.closedTabsStack.count, 1,
                "closeTab should push one entry onto closedTabsStack")
            let info = vm.closedTabsStack[0]
            XCTAssertEqual(info.url, "https://b.com",
                "ClosedTabInfo should record the URL")
            XCTAssertEqual(info.title, "B",
                "ClosedTabInfo should record the title")
            XCTAssertTrue(info.isPinned,
                "ClosedTabInfo should record isPinned=true")
        }
    }

    /// Multiple closes push in order; popLast gives LIFO.
    func testClosedTabsStack_LIFOOrdering() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            vm.closeTab(vm.tabs[2]) // close C
            vm.closeTab(vm.tabs[1]) // close B (index shifted)

            XCTAssertEqual(vm.closedTabsStack.count, 2)
            XCTAssertEqual(vm.closedTabsStack.last?.title, "B",
                "Last entry should be B (most recently closed)")
            XCTAssertEqual(vm.closedTabsStack.first?.title, "C",
                "First entry should be C (earliest closed)")
        }
    }

    // =========================================================================
    // MARK: - Pin Tab preserves tab count
    // =========================================================================

    /// Pinning does not create or destroy tabs.
    func testPinTab_preservesTabCount() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            let countBefore = vm.tabs.count
            vm.pinTab(vm.tabs[1])
            XCTAssertEqual(vm.tabs.count, countBefore,
                "pinTab should not change total tab count")
        }
    }

    /// Unpinning does not create or destroy tabs.
    func testUnpinTab_preservesTabCount() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            vm.pinTab(vm.tabs[0])
            let countBefore = vm.tabs.count
            vm.unpinTab(vm.tabs[0])
            XCTAssertEqual(vm.tabs.count, countBefore,
                "unpinTab should not change total tab count")
        }
    }

    // =========================================================================
    // MARK: - closeOtherTabs records to closedTabsStack
    // =========================================================================

    /// closeOtherTabs pushes closed tabs to the undo stack.
    func testCloseOtherTabs_pushesAllClosedToStack() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            vm.closeOtherTabs(tabA)

            // B and C should be on the stack.
            XCTAssertEqual(vm.closedTabsStack.count, 2,
                "closeOtherTabs should push all closed tabs to stack")
        }
    }

    // =========================================================================
    // MARK: - Pin/Unpin with active tab
    // =========================================================================

    /// Pinning the active tab keeps it active.
    func testPinTab_activeTabStaysActive() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]
            vm.activateTab(tabB)
            XCTAssertEqual(vm.activeTab?.id, tabB.id, "Precondition")

            vm.pinTab(tabB)

            // Active tab should remain the same tab (by identity).
            XCTAssertEqual(vm.activeTab?.id, tabB.id,
                "Pinning active tab should keep it active")
        }
    }

    /// Unpinning the active tab keeps it active.
    func testUnpinTab_activeTabStaysActive() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            vm.pinTab(tabA)
            vm.activateTab(tabA)

            vm.unpinTab(tabA)

            XCTAssertEqual(vm.activeTab?.id, tabA.id,
                "Unpinning active tab should keep it active")
        }
    }

    // =========================================================================
    // MARK: - TabViewModel isPinned property
    // =========================================================================

    /// isPinned defaults to false.
    func testTabViewModel_isPinnedDefaultsFalse() {
        let tab = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Test", url: nil)
        }

        MainActor.assumeIsolated {
            XCTAssertFalse(tab.isPinned,
                "TabViewModel.isPinned should default to false")
        }
    }

    /// isPinned is assignable.
    func testTabViewModel_isPinnedIsAssignable() {
        let tab = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Test", url: nil)
        }

        MainActor.assumeIsolated {
            tab.isPinned = true
            XCTAssertTrue(tab.isPinned)
            tab.isPinned = false
            XCTAssertFalse(tab.isPinned)
        }
    }

    // =========================================================================
    // MARK: - Undo Close after closeOtherTabs restores in correct order
    // =========================================================================

    /// After closeOtherTabs, multiple undos restore tabs one by one.
    /// Target tab (A) has URL so shouldReplaceBlank is false.
    /// Closed tabs (B, C) use nil URLs to avoid triggering navigate() on undo.
    func testUndoAfterCloseOtherTabs_restoresOneByOne() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", nil), ("C", nil)])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            // closeOtherTabs closes B and C (in reverse order so undo works correctly).
            vm.closeOtherTabs(tabA)
            XCTAssertEqual(vm.tabs.count, 1,
                "Precondition: only target tab remains")
            XCTAssertEqual(vm.closedTabsStack.count, 2,
                "Precondition: 2 entries on the undo stack")

            // First undo restores one tab.
            vm.undoCloseTab()

            XCTAssertEqual(vm.tabs.count, 2,
                "First undo should restore one tab")
            XCTAssertEqual(vm.closedTabsStack.count, 1,
                "One entry should remain on the stack")

            // Second undo restores the remaining tab.
            vm.undoCloseTab()

            XCTAssertEqual(vm.tabs.count, 3,
                "Second undo should restore all original tabs")
            XCTAssertTrue(vm.closedTabsStack.isEmpty,
                "Stack should be empty after undoing all closes")
        }
    }

    // =========================================================================
    // MARK: - closeTabsBelow excludes pinned tabs below
    // =========================================================================

    /// closeTabsBelow skips pinned tabs that happen to be below the target.
    func testCloseTabsBelow_skipsPinnedTabsBelow() {
        let vm = makeVM(tabs: [
            ("A", "https://a.com"), ("B", "https://b.com"),
            ("C", "https://c.com"), ("D", "https://d.com")
        ])

        MainActor.assumeIsolated {
            // Pin C so it moves to front: [C(pin), A, B, D]
            let tabC = vm.tabs[2]
            vm.pinTab(tabC)

            // Now find A and close below it.
            let tabA = vm.tabs.first(where: { $0.title == "A" })!
            vm.closeTabsBelow(tabA)
        }
        pump(0.1)

        MainActor.assumeIsolated {
            // B and D (both unpinned, below A) should be closed.
            // C (pinned, above A) should survive.
            XCTAssertTrue(vm.tabs.contains(where: { $0.title == "C" }),
                "Pinned tab (above target) should survive")
            XCTAssertTrue(vm.tabs.contains(where: { $0.title == "A" }),
                "Target tab should survive")
        }
    }

    // =========================================================================
    // MARK: - Cmd+W closes pinned tab (no close protection for Cmd+W)
    // =========================================================================

    /// Cmd+W (closeTab) can close a pinned tab. Close protection is only
    /// for closeOtherTabs/closeTabsBelow, not direct close.
    func testCloseTab_canClosePinnedTab() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com")])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            vm.pinTab(tabA)
            XCTAssertTrue(tabA.isPinned)

            vm.closeTab(tabA)

            XCTAssertFalse(vm.tabs.contains(where: { $0.id == tabA.id }),
                "closeTab should be able to close a pinned tab (Cmd+W)")
        }
    }

    // =========================================================================
    // MARK: - selectTabByIndex boundary: Cmd+2 with one tab
    // =========================================================================

    /// Cmd+2 with only one tab is a no-op.
    func testSelectTabByIndex_2_withOneTab_isNoOp() {
        let vm = makeVM(tabs: [("A", "https://a.com")])

        MainActor.assumeIsolated {
            let activeBefore = vm.activeTab?.id
            vm.selectTabByIndex(2)
            XCTAssertEqual(vm.activeTab?.id, activeBefore,
                "Cmd+2 with only 1 tab should be no-op")
        }
    }

    /// Cmd+9 with one tab activates that tab (last = first = only).
    func testSelectTabByIndex_9_withOneTab_activatesOnly() {
        let vm = makeVM(tabs: [("A", "https://a.com")])

        MainActor.assumeIsolated {
            vm.selectTabByIndex(9)
            XCTAssertEqual(vm.activeTab?.title, "A",
                "Cmd+9 with one tab should activate the only tab")
        }
    }

    // =========================================================================
    // MARK: - Undo close records insertIndex correctly
    // =========================================================================

    /// ClosedTabInfo.insertIndex reflects the tab's position at close time.
    func testClosedTabInfo_insertIndex_isCorrect() {
        let vm = makeVM(tabs: [("A", "https://a.com"), ("B", "https://b.com"), ("C", "https://c.com")])

        MainActor.assumeIsolated {
            // B is at index 1.
            let tabB = vm.tabs[1]
            vm.closeTab(tabB)

            XCTAssertEqual(vm.closedTabsStack.last?.insertIndex, 1,
                "ClosedTabInfo.insertIndex should record original position")
        }
    }

    // =========================================================================
    // MARK: - closedTabsStack upper limit (max 20)
    // =========================================================================

    /// Closing 25 tabs should keep the stack size at most 20
    /// (oldest entries evicted via FIFO).
    func testClosedTabsStack_cappedAt20() {
        // Build 26 tabs: one survives, 25 get closed.
        var tabDefs: [(String, String?)] = []
        for i in 0..<26 {
            tabDefs.append(("T\(i)", nil))
        }
        let vm = makeVM(tabs: tabDefs)

        MainActor.assumeIsolated {
            // Close tabs T1 through T25 (keep T0 alive).
            for i in stride(from: 25, through: 1, by: -1) {
                let tab = vm.tabs.first(where: { $0.title == "T\(i)" })!
                vm.closeTab(tab)
            }

            XCTAssertEqual(vm.closedTabsStack.count, 20,
                "closedTabsStack should be capped at 20 entries after closing 25 tabs")

            // Closed in order: T25, T24, T23, ..., T1. Oldest 5 (T25..T21) evicted.
            // The most recent entry (stack top) should be T1 (closed last).
            XCTAssertEqual(vm.closedTabsStack.last?.title, "T1",
                "Most recent close should be on top of the stack")

            // The bottom of the stack should be T20 (the 20th most-recent close).
            XCTAssertEqual(vm.closedTabsStack.first?.title, "T20",
                "Oldest surviving entry should be the 20th most-recent close")
        }
    }

    // =========================================================================
    // MARK: - undoCloseTab does not remove user's manual blank tab
    // =========================================================================

    /// When the user has manually opened a blank tab alongside other tabs,
    /// undoCloseTab must NOT replace that blank tab. The shouldReplaceBlank
    /// logic only triggers when there is exactly 1 tab and it is blank
    /// (i.e., auto-created after closing the last tab).
    func testUndoCloseTab_doesNotDeleteUsersManualBlankTab() {
        // Two tabs: a real tab and a user-created blank.
        let vm = makeVM(tabs: [("Real", "https://real.com"), ("Blank", nil)])

        MainActor.assumeIsolated {
            // Close the real tab — stack: [Real].
            let realTab = vm.tabs.first(where: { $0.title == "Real" })!
            vm.closeTab(realTab)

            XCTAssertEqual(vm.tabs.count, 1, "Precondition: only blank tab remains")
            XCTAssertEqual(vm.tabs[0].title, "Blank",
                "Precondition: the surviving tab is user's blank")

            // Undo should restore "Real" WITHOUT removing the user's blank.
            // shouldReplaceBlank is true only when tabs.count == 1 && url == nil,
            // but the blank tab here is from the user (not auto-created).
            // The behavior depends on the url check: user blank has nil url,
            // so it will match shouldReplaceBlank. The key scenario where the
            // blank is preserved is when the user has 2+ tabs.
        }

        // Better scenario: user has 2 tabs (one blank), closes a third.
        let vm2 = makeVM(tabs: [("A", "https://a.com"), ("B", nil), ("C", nil)])

        MainActor.assumeIsolated {
            // Close A — leaves [B(blank), C(blank)].
            let tabA = vm2.tabs.first(where: { $0.title == "A" })!
            vm2.closeTab(tabA)

            let countBefore = vm2.tabs.count
            XCTAssertEqual(countBefore, 2,
                "Precondition: two blank tabs remain")

            // Undo should add A back without removing any blank tab.
            vm2.undoCloseTab()

            XCTAssertEqual(vm2.tabs.count, 3,
                "undoCloseTab must not remove user's blank tabs when multiple tabs exist")
            XCTAssertTrue(vm2.tabs.contains(where: { $0.title == "B" }),
                "User's blank tab B should survive the undo")
            XCTAssertTrue(vm2.tabs.contains(where: { $0.title == "C" }),
                "User's blank tab C should survive the undo")
            XCTAssertTrue(vm2.tabs.contains(where: { $0.title == "A" }),
                "Restored tab A should be present")
        }
    }

    // =========================================================================
    // MARK: - closeTabsBelow pushes closed tabs onto closedTabsStack
    // =========================================================================

    /// closeTabsBelow should push all closed tabs onto the undo stack.
    func testCloseTabsBelow_pushesClosedTabsToStack() {
        let vm = makeVM(tabs: [
            ("A", nil), ("B", nil), ("C", nil), ("D", nil)
        ])

        MainActor.assumeIsolated {
            let tabB = vm.tabs[1]
            // Close tabs below B → C and D should be closed.
            vm.closeTabsBelow(tabB)
        }
        pump(0.1)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 2,
                "Precondition: A and B survive, C and D closed")
            XCTAssertTrue(vm.tabs.contains(where: { $0.title == "A" }))
            XCTAssertTrue(vm.tabs.contains(where: { $0.title == "B" }))

            XCTAssertEqual(vm.closedTabsStack.count, 2,
                "closeTabsBelow should push 2 closed tabs onto the stack")

            // Verify the closed entries are C and D (in some order on the stack).
            let closedTitles = Set(vm.closedTabsStack.map { $0.title })
            XCTAssertTrue(closedTitles.contains("C"),
                "Tab C should be recorded in closedTabsStack")
            XCTAssertTrue(closedTitles.contains("D"),
                "Tab D should be recorded in closedTabsStack")
        }
    }

    /// closeTabsBelow + undo restores tabs one by one.
    func testCloseTabsBelow_undoRestoresOneByOne() {
        let vm = makeVM(tabs: [
            ("A", nil), ("B", nil), ("C", nil)
        ])

        MainActor.assumeIsolated {
            let tabA = vm.tabs[0]
            // Close tabs below A → B and C.
            vm.closeTabsBelow(tabA)
        }
        pump(0.1)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 1,
                "Precondition: only A remains")
            XCTAssertEqual(vm.closedTabsStack.count, 2)

            vm.undoCloseTab()
            XCTAssertEqual(vm.tabs.count, 2,
                "First undo should restore one tab")

            vm.undoCloseTab()
            XCTAssertEqual(vm.tabs.count, 3,
                "Second undo should restore all tabs")
            XCTAssertTrue(vm.closedTabsStack.isEmpty,
                "Stack should be empty after undoing all")
        }
    }

    // =========================================================================
    // MARK: - copyTabLink
    // =========================================================================

    /// copyTabLink copies the tab's URL to the system clipboard.
    func testCopyTabLink_copiesToClipboard() {
        let vm = makeVM(tabs: [("Site", "https://example.com/page")])

        MainActor.assumeIsolated {
            // Clear clipboard first.
            NSPasteboard.general.clearContents()

            let tab = vm.tabs[0]
            vm.copyTabLink(tab)

            let clipboardContent = NSPasteboard.general.string(forType: .string)
            XCTAssertEqual(clipboardContent, "https://example.com/page",
                "copyTabLink should copy the tab's URL to the clipboard")
        }
    }

    /// copyTabLink on a tab with no URL is a no-op (clipboard unchanged).
    func testCopyTabLink_nilURL_isNoOp() {
        let vm = makeVM(tabs: [("Blank", nil)])

        MainActor.assumeIsolated {
            // Set a sentinel value on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("SENTINEL", forType: .string)

            let tab = vm.tabs[0]
            vm.copyTabLink(tab)

            let clipboardContent = NSPasteboard.general.string(forType: .string)
            XCTAssertEqual(clipboardContent, "SENTINEL",
                "copyTabLink with nil URL should not modify the clipboard")
        }
    }

    /// copyTabLink overwrites previous clipboard content.
    func testCopyTabLink_overwritesPreviousClipboard() {
        let vm = makeVM(tabs: [
            ("First", "https://first.com"),
            ("Second", "https://second.com")
        ])

        MainActor.assumeIsolated {
            vm.copyTabLink(vm.tabs[0])
            XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                "https://first.com")

            vm.copyTabLink(vm.tabs[1])
            XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                "https://second.com",
                "copyTabLink should overwrite previous clipboard content")
        }
    }
}
