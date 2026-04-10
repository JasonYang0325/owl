import XCTest
@testable import OWLBrowserLib

/// Bookmark ViewModel unit tests — Phase 1 书签 CRUD + 侧边栏模式切换
/// Uses MockConfig, no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class BookmarkViewModelTests: XCTestCase {

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - Helpers

    /// Create a BookmarkViewModel with mock data.
    private func makeBookmarkVM(
        bookmarks: [BookmarkItem] = []
    ) -> BookmarkViewModel {
        MainActor.assumeIsolated {
            BookmarkViewModel(mockConfig: .init(bookmarks: bookmarks))
        }
    }

    /// Create a BrowserViewModel with mock data (for sidebar tests).
    private func makeBrowserVM(
        tabs: [(String, String?)] = [("新标签页", nil)]
    ) -> BrowserViewModel {
        MainActor.assumeIsolated {
            BrowserViewModel(mockConfig: .init(
                initialTabs: tabs,
                connectionDelay: 0,
                shouldFail: false,
                failMessage: ""
            ))
        }
    }

    /// Convenience: sample bookmark items for tests.
    private var sampleBookmarks: [BookmarkItem] {
        [
            BookmarkItem(id: "bk-1", title: "Apple", url: "https://apple.com", parent_id: nil),
            BookmarkItem(id: "bk-2", title: "Google", url: "https://google.com", parent_id: nil),
            BookmarkItem(id: "bk-3", title: "GitHub", url: "https://github.com", parent_id: nil),
        ]
    }

    // MARK: - AC-VM-001: loadAll() 获取所有书签

    /// AC-VM-001: Happy path — loadAll() populates bookmarks array from mock data.
    func testLoadAll_mockMode() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.bookmarks.count, 3, "Should have 3 bookmarks after loadAll()")
            XCTAssertEqual(vm.bookmarks[0].title, "Apple")
            XCTAssertEqual(vm.bookmarks[1].title, "Google")
            XCTAssertEqual(vm.bookmarks[2].title, "GitHub")
        }
    }

    /// AC-VM-001: Edge case — loadAll() with empty mock returns empty array.
    func testLoadAll_emptyMock() {
        let vm = makeBookmarkVM(bookmarks: [])

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.bookmarks.isEmpty, "Should have 0 bookmarks when mock is empty")
        }
    }

    // MARK: - AC-VM-002: addCurrentPage(title:url:) 添加书签

    /// AC-VM-002: Happy path — add a new page, verify it appears and isBookmarked returns true.
    func testAddCurrentPage_success() {
        let vm = makeBookmarkVM(bookmarks: [])

        var result = false
        MainActor.assumeIsolated {
            Task {
                result = await vm.addCurrentPage(title: "Example", url: "https://example.com")
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(result, "addCurrentPage should return true on success")
            XCTAssertEqual(vm.bookmarks.count, 1, "Should have 1 bookmark after adding")
            XCTAssertTrue(vm.isBookmarked(url: "https://example.com"),
                "isBookmarked should return true for added URL")
        }
    }

    /// AC-VM-002: Edge case — add with empty title.
    func testAddCurrentPage_emptyTitle() {
        let vm = makeBookmarkVM(bookmarks: [])

        var result = false
        MainActor.assumeIsolated {
            Task {
                result = await vm.addCurrentPage(title: "", url: "https://example.com")
            }
        }
        pump()

        MainActor.assumeIsolated {
            // Empty title is still allowed (the URL is the meaningful part)
            XCTAssertTrue(result, "addCurrentPage with empty title should still succeed")
            XCTAssertEqual(vm.bookmarks.count, 1)
        }
    }

    /// AC-VM-002: Edge case — add with empty URL should fail or be rejected.
    func testAddCurrentPage_emptyURL() {
        let vm = makeBookmarkVM(bookmarks: [])

        var result = false
        MainActor.assumeIsolated {
            Task {
                result = await vm.addCurrentPage(title: "No URL", url: "")
            }
        }
        pump()

        MainActor.assumeIsolated {
            // Empty URL is invalid — implementation may reject or accept.
            // We verify the return value is consistent with the bookmarks array.
            if result {
                XCTAssertFalse(vm.bookmarks.isEmpty,
                    "If returned true, bookmarks should contain the item")
            } else {
                XCTAssertTrue(vm.bookmarks.isEmpty,
                    "If returned false, bookmarks should remain empty")
            }
        }
    }

    /// AC-VM-002: Verify adding to a pre-populated list appends correctly.
    func testAddCurrentPage_appendsToExisting() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            Task {
                _ = await vm.addCurrentPage(title: "New Site", url: "https://newsite.com")
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.bookmarks.count, 4,
                "Should have 4 bookmarks after loading 3 + adding 1")
            XCTAssertTrue(vm.isBookmarked(url: "https://newsite.com"))
        }
    }

    // MARK: - AC-VM-003: removeBookmark(id:) 删除书签

    /// AC-VM-003: Happy path — remove an existing bookmark by ID.
    func testRemoveBookmark_success() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        var result = false
        MainActor.assumeIsolated {
            Task {
                result = await vm.removeBookmark(id: "bk-2")
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(result, "removeBookmark should return true for existing ID")
            XCTAssertEqual(vm.bookmarks.count, 2, "Should have 2 bookmarks after removal")
            XCTAssertFalse(vm.isBookmarked(url: "https://google.com"),
                "isBookmarked should return false after removal")
            // Remaining bookmarks should be intact
            XCTAssertTrue(vm.isBookmarked(url: "https://apple.com"))
            XCTAssertTrue(vm.isBookmarked(url: "https://github.com"))
        }
    }

    /// AC-VM-003: Error path — remove with non-existent ID.
    func testRemoveBookmark_nonexistent() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        var result = false
        MainActor.assumeIsolated {
            Task {
                result = await vm.removeBookmark(id: "bk-999")
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(result,
                "removeBookmark should return false for non-existent ID")
            XCTAssertEqual(vm.bookmarks.count, 3,
                "Bookmarks array should be unchanged after failed removal")
        }
    }

    /// AC-VM-003: Edge case — remove with empty ID.
    func testRemoveBookmark_emptyId() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        var result = false
        MainActor.assumeIsolated {
            Task {
                result = await vm.removeBookmark(id: "")
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(result,
                "removeBookmark with empty ID should return false")
            XCTAssertEqual(vm.bookmarks.count, 3,
                "Bookmarks should be unchanged")
        }
    }

    // MARK: - AC-VM-004: isBookmarked(url:) 状态查询

    /// AC-VM-004: Happy path — URL exists in bookmarks.
    func testIsBookmarked_exists() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.isBookmarked(url: "https://apple.com"),
                "Should return true for bookmarked URL")
        }
    }

    /// AC-VM-004: URL does not exist in bookmarks.
    func testIsBookmarked_notExists() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.isBookmarked(url: "https://unknown.com"),
                "Should return false for non-bookmarked URL")
        }
    }

    /// AC-VM-004: Edge case — nil URL.
    func testIsBookmarked_nilURL() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.isBookmarked(url: nil),
                "Should return false for nil URL")
        }
    }

    /// AC-VM-004: Edge case — empty string URL.
    func testIsBookmarked_emptyURL() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.isBookmarked(url: ""),
                "Should return false for empty URL string")
        }
    }

    // MARK: - bookmarkId(for:) 辅助方法

    /// AC-VM-004 (auxiliary): bookmarkId returns correct ID for bookmarked URL.
    func testBookmarkId_exists() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.bookmarkId(for: "https://google.com"), "bk-2",
                "Should return the correct bookmark ID")
        }
    }

    /// AC-VM-004 (auxiliary): bookmarkId returns nil for non-bookmarked URL.
    func testBookmarkId_notExists() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNil(vm.bookmarkId(for: "https://unknown.com"),
                "Should return nil for non-bookmarked URL")
        }
    }

    /// AC-VM-004 (auxiliary): bookmarkId returns nil for nil URL.
    func testBookmarkId_nilURL() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNil(vm.bookmarkId(for: nil),
                "Should return nil for nil URL")
        }
    }

    // MARK: - AC-VM-005: BrowserViewModel.sidebarMode 切换

    /// AC-VM-005: Default sidebar mode should be .tabs.
    func testSidebarMode_defaultIsTabs() {
        let vm = makeBrowserVM()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.sidebarMode, .tabs,
                "Default sidebarMode should be .tabs")
        }
    }

    /// AC-VM-005: toggleSidebarMode switches from .tabs to .bookmarks.
    func testSidebarMode_toggleToBookmarks() {
        let vm = makeBrowserVM()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.sidebarMode, .tabs)
            vm.toggleSidebarMode()
            XCTAssertEqual(vm.sidebarMode, .bookmarks,
                "After first toggle, sidebarMode should be .bookmarks")
        }
    }

    /// AC-VM-005: toggleSidebarMode toggles back from .bookmarks to .tabs.
    func testSidebarMode_toggleBackToTabs() {
        let vm = makeBrowserVM()

        MainActor.assumeIsolated {
            vm.toggleSidebarMode()  // .tabs → .bookmarks
            vm.toggleSidebarMode()  // .bookmarks → .tabs
            XCTAssertEqual(vm.sidebarMode, .tabs,
                "After two toggles, sidebarMode should return to .tabs")
        }
    }

    /// AC-VM-005: Multiple rapid toggles maintain consistency.
    func testSidebarMode_multipleToggles() {
        let vm = makeBrowserVM()

        MainActor.assumeIsolated {
            for _ in 0..<5 {
                vm.toggleSidebarMode()
            }
            // 5 toggles from .tabs: tabs→bk→tabs→bk→tabs→bk = .bookmarks (odd count)
            XCTAssertEqual(vm.sidebarMode, .bookmarks,
                "After 5 toggles from .tabs, should be .bookmarks")

            vm.toggleSidebarMode()  // 6th toggle
            XCTAssertEqual(vm.sidebarMode, .tabs,
                "After 6 toggles from .tabs, should be .tabs")
        }
    }

    // MARK: - BrowserViewModel.bookmarkVM integration

    /// AC-VM-005 (auxiliary): BrowserViewModel exposes a bookmarkVM instance.
    func testBrowserVM_hasBookmarkVM() {
        let vm = makeBrowserVM()

        MainActor.assumeIsolated {
            XCTAssertNotNil(vm.bookmarkVM,
                "BrowserViewModel should have a non-nil bookmarkVM")
        }
    }

    // MARK: - Phase 2 StarButton 集成场景

    /// AC-002, AC-003: 点击空心星添加书签 → 实心蓝色 → 再点击移除 → 回到空心灰色
    /// 模拟 StarButton 的完整 toggle 流程：add → isBookmarked true → remove → isBookmarked false
    func testStarToggle_addThenRemove() {
        let vm = makeBookmarkVM(bookmarks: [])
        let testURL = "https://example.com"
        let testTitle = "Example"

        // Step 1: 模拟点击空心星 → 添加书签
        var addResult = false
        MainActor.assumeIsolated {
            Task {
                addResult = await vm.addCurrentPage(title: testTitle, url: testURL)
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(addResult, "addCurrentPage should succeed")
            XCTAssertTrue(vm.isBookmarked(url: testURL),
                "AC-002: After adding, star should be filled (isBookmarked == true)")
        }

        // Step 2: 获取 bookmarkId，模拟点击实心星 → 移除书签
        var removeResult = false
        MainActor.assumeIsolated {
            guard let bookmarkId = vm.bookmarkId(for: testURL) else {
                XCTFail("bookmarkId should exist for just-added URL")
                return
            }
            Task {
                removeResult = await vm.removeBookmark(id: bookmarkId)
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(removeResult, "removeBookmark should succeed")
            XCTAssertFalse(vm.isBookmarked(url: testURL),
                "AC-003: After removing, star should be empty (isBookmarked == false)")
        }
    }

    /// AC-001, AC-008: 多个 URL 各自独立的书签状态（模拟 Tab 切换场景）
    /// Tab 切换后，星标状态应根据当前 URL 正确更新
    func testStarToggle_multipleURLs() {
        let vm = makeBookmarkVM(bookmarks: [])
        let urlA = "https://apple.com"
        let urlB = "https://google.com"
        let urlC = "https://github.com"

        // 添加 URL A 和 URL B 的书签，URL C 不添加
        MainActor.assumeIsolated {
            Task {
                _ = await vm.addCurrentPage(title: "Apple", url: urlA)
                _ = await vm.addCurrentPage(title: "Google", url: urlB)
            }
        }
        pump()

        // 模拟 Tab 切换：检查各 URL 的星标状态是否独立正确
        MainActor.assumeIsolated {
            // 切换到 Tab A → 星标实心
            XCTAssertTrue(vm.isBookmarked(url: urlA),
                "AC-008: Tab A (apple.com) should show filled star")
            // 切换到 Tab B → 星标实心
            XCTAssertTrue(vm.isBookmarked(url: urlB),
                "AC-008: Tab B (google.com) should show filled star")
            // 切换到 Tab C → 星标空心
            XCTAssertFalse(vm.isBookmarked(url: urlC),
                "AC-008: Tab C (github.com) should show empty star")
        }

        // 移除 URL A 的书签，验证不影响 URL B
        MainActor.assumeIsolated {
            guard let idA = vm.bookmarkId(for: urlA) else {
                XCTFail("bookmarkId should exist for URL A")
                return
            }
            Task {
                _ = await vm.removeBookmark(id: idA)
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.isBookmarked(url: urlA),
                "AC-001: After removal, Tab A should show empty star")
            XCTAssertTrue(vm.isBookmarked(url: urlB),
                "AC-008: Tab B should still show filled star (independent)")
            XCTAssertFalse(vm.isBookmarked(url: urlC),
                "AC-008: Tab C should still show empty star")
        }
    }

    /// AC-STAR-001: 空 URL 时星标应为灰色禁用状态（isBookmarked 返回 false）
    func testStarToggle_emptyURL() {
        let vm = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            // 空字符串 URL
            XCTAssertFalse(vm.isBookmarked(url: ""),
                "AC-STAR-001: Empty URL should not be bookmarked (star disabled)")
            // nil URL
            XCTAssertFalse(vm.isBookmarked(url: nil),
                "AC-STAR-001: Nil URL should not be bookmarked (star disabled)")
            // bookmarkId 也应为 nil
            XCTAssertNil(vm.bookmarkId(for: ""),
                "AC-STAR-001: bookmarkId for empty URL should be nil")
            XCTAssertNil(vm.bookmarkId(for: nil),
                "AC-STAR-001: bookmarkId for nil URL should be nil")
        }
    }

    // MARK: - Phase 3 侧边栏书签面板集成

    /// AC-004, AC-SIDE-001: 切换到 bookmarks 模式后调用 loadAll，验证书签加载
    /// 模拟侧边栏书签按钮切换面板 + 书签列表加载
    func testSidebarBookmarks_loadAllOnSwitch() {
        // BrowserViewModel 用于验证模式切换
        let browserVM = makeBrowserVM()
        // 独立 BookmarkViewModel（带 mock 数据）用于验证 loadAll
        let bookmarkVM = makeBookmarkVM(bookmarks: sampleBookmarks)

        MainActor.assumeIsolated {
            // 初始状态：侧边栏在 tabs 模式
            XCTAssertEqual(browserVM.sidebarMode, .tabs,
                "AC-004: Initial sidebar mode should be .tabs")

            // 切换到 bookmarks 模式（模拟点击侧边栏书签按钮）
            browserVM.toggleSidebarMode()
            XCTAssertEqual(browserVM.sidebarMode, .bookmarks,
                "AC-004: After toggle, sidebar should switch to .bookmarks")
        }

        // 切换后触发 loadAll（模拟 BookmarkSidebarView.onAppear 行为）
        MainActor.assumeIsolated {
            XCTAssertTrue(bookmarkVM.bookmarks.isEmpty,
                "Precondition: bookmarks should be empty before loadAll")
            Task { await bookmarkVM.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(bookmarkVM.bookmarks.count, 3,
                "AC-SIDE-001: After loadAll, bookmarks should be loaded (3 items)")
            XCTAssertFalse(bookmarkVM.isLoading,
                "AC-SIDE-001: isLoading should be false after load completes")
            XCTAssertEqual(bookmarkVM.bookmarks[0].title, "Apple")
            XCTAssertEqual(bookmarkVM.bookmarks[1].title, "Google")
            XCTAssertEqual(bookmarkVM.bookmarks[2].title, "GitHub")
        }
    }

    /// AC-006, AC-007: 删除书签后验证列表实时更新（bookmarks 数组减少）
    func testSidebarBookmarks_deleteUpdatesLive() {
        let bookmarkVM = makeBookmarkVM(bookmarks: sampleBookmarks)

        // 先加载全部
        MainActor.assumeIsolated {
            Task { await bookmarkVM.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(bookmarkVM.bookmarks.count, 3,
                "Precondition: should start with 3 bookmarks")
        }

        // 模拟右键删除书签（AC-006）
        var deleteResult = false
        MainActor.assumeIsolated {
            Task {
                deleteResult = await bookmarkVM.removeBookmark(id: "bk-2")
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(deleteResult,
                "AC-006: removeBookmark should return true for existing bookmark")
            XCTAssertEqual(bookmarkVM.bookmarks.count, 2,
                "AC-007: After deletion, bookmarks array should update in real-time (2 remaining)")
            XCTAssertFalse(bookmarkVM.isBookmarked(url: "https://google.com"),
                "AC-007: Deleted bookmark should no longer appear")
            // 验证剩余书签完整
            XCTAssertTrue(bookmarkVM.isBookmarked(url: "https://apple.com"),
                "AC-007: Non-deleted bookmarks should remain intact")
            XCTAssertTrue(bookmarkVM.isBookmarked(url: "https://github.com"),
                "AC-007: Non-deleted bookmarks should remain intact")
        }
    }

    /// AC-005, AC-007: 通过 addCurrentPage 添加后 bookmarks 数组增加
    /// 模拟在 StarButton 添加书签后，侧边栏面板实时反映变化
    func testSidebarBookmarks_addFromStarUpdatesLive() {
        let bookmarkVM = makeBookmarkVM(bookmarks: sampleBookmarks)

        // 加载初始书签
        MainActor.assumeIsolated {
            Task { await bookmarkVM.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(bookmarkVM.bookmarks.count, 3,
                "Precondition: should start with 3 bookmarks")
        }

        // 模拟通过星标按钮添加新书签
        var addResult = false
        MainActor.assumeIsolated {
            Task {
                addResult = await bookmarkVM.addCurrentPage(
                    title: "MDN Web Docs", url: "https://developer.mozilla.org")
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(addResult,
                "AC-005: addCurrentPage should succeed")
            XCTAssertEqual(bookmarkVM.bookmarks.count, 4,
                "AC-007: After adding via star, bookmarks array should update in real-time (4 items)")
            XCTAssertTrue(bookmarkVM.isBookmarked(url: "https://developer.mozilla.org"),
                "AC-007: Newly added bookmark should be immediately visible")
        }
    }

    /// AC-SIDE-004, AC-SIDE-005: 切回 tabs 模式再切回 bookmarks，bookmarks 数据不丢失
    func testSidebarBookmarks_switchBackPreservesBookmarks() {
        let browserVM = makeBrowserVM()
        let bookmarkVM = makeBookmarkVM(bookmarks: sampleBookmarks)

        // 加载书签数据
        MainActor.assumeIsolated {
            Task { await bookmarkVM.loadAll() }
        }
        pump()

        // 切换到 bookmarks 模式
        MainActor.assumeIsolated {
            browserVM.toggleSidebarMode()
            XCTAssertEqual(browserVM.sidebarMode, .bookmarks)
            XCTAssertEqual(bookmarkVM.bookmarks.count, 3,
                "Precondition: should have 3 bookmarks loaded")
        }

        // 切回 tabs 模式（AC-SIDE-004）
        MainActor.assumeIsolated {
            browserVM.toggleSidebarMode()
            XCTAssertEqual(browserVM.sidebarMode, .tabs,
                "AC-SIDE-004: Should switch back to .tabs mode")
            // 书签数据在 ViewModel 中保持不变，不因模式切换而丢失
            XCTAssertEqual(bookmarkVM.bookmarks.count, 3,
                "AC-SIDE-004: Bookmarks data should persist even after switching to tabs mode")
        }

        // 再切回 bookmarks 模式（AC-SIDE-005）
        MainActor.assumeIsolated {
            browserVM.toggleSidebarMode()
            XCTAssertEqual(browserVM.sidebarMode, .bookmarks,
                "AC-SIDE-005: Should switch back to .bookmarks mode")
        }

        // 验证数据保持完整（无需重新 loadAll，ViewModel 保留状态）
        MainActor.assumeIsolated {
            XCTAssertEqual(bookmarkVM.bookmarks.count, 3,
                "AC-SIDE-004/005: Bookmarks data should be preserved after switching modes")
            XCTAssertTrue(bookmarkVM.isBookmarked(url: "https://apple.com"),
                "AC-SIDE-005: Apple bookmark should still exist")
            XCTAssertTrue(bookmarkVM.isBookmarked(url: "https://google.com"),
                "AC-SIDE-005: Google bookmark should still exist")
            XCTAssertTrue(bookmarkVM.isBookmarked(url: "https://github.com"),
                "AC-SIDE-005: GitHub bookmark should still exist")
        }
    }
}
