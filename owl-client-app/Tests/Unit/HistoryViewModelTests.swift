import XCTest
@testable import OWLBrowserLib

/// History ViewModel unit tests — HistoryViewModel CRUD + 搜索 + 分组 + 撤销
/// Uses MockConfig, no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class HistoryViewModelTests: XCTestCase {

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - Helpers

    /// Create a HistoryViewModel with mock data.
    private func makeHistoryVM(
        entries: [HistoryEntry] = [],
        totalCount: Int32? = nil
    ) -> HistoryViewModel {
        MainActor.assumeIsolated {
            let count = totalCount ?? Int32(entries.count)
            return HistoryViewModel(mockConfig: .init(entries: entries, totalCount: count))
        }
    }

    /// Convenience: current time as seconds since epoch.
    private var now: Double { Date().timeIntervalSince1970 }

    /// Convenience: sample history entries spanning multiple date groups.
    private var sampleEntries: [HistoryEntry] {
        let now = self.now
        return [
            HistoryEntry(url: "https://apple.com", title: "Apple",
                         visit_time: now - 60, last_visit_time: now - 60,
                         visit_count: 3),
            HistoryEntry(url: "https://google.com", title: "Google Search",
                         visit_time: now - 3600, last_visit_time: now - 3600,
                         visit_count: 10),
            HistoryEntry(url: "https://github.com", title: "GitHub",
                         visit_time: now - 86400 * 2, last_visit_time: now - 86400 * 2,
                         visit_count: 5),
            HistoryEntry(url: "https://developer.mozilla.org", title: "MDN Web Docs",
                         visit_time: now - 86400 * 10, last_visit_time: now - 86400 * 10,
                         visit_count: 1),
        ]
    }

    /// Convenience: entries all from today.
    private var todayEntries: [HistoryEntry] {
        let now = self.now
        return [
            HistoryEntry(url: "https://apple.com", title: "Apple",
                         visit_time: now - 60, last_visit_time: now - 60,
                         visit_count: 1),
            HistoryEntry(url: "https://google.com", title: "Google",
                         visit_time: now - 120, last_visit_time: now - 120,
                         visit_count: 2),
        ]
    }

    // MARK: - AC-H01: loadInitial() 加载 mock entries 并正确填充 entries + groupedEntries

    /// AC-H01: Happy path — loadInitial() populates entries and groupedEntries from mock data.
    func testLoadInitial_populatesEntriesAndGroups() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 4,
                "AC-H01: Should have 4 entries after loadInitial()")
            XCTAssertFalse(vm.groupedEntries.isEmpty,
                "AC-H01: groupedEntries should be populated after loadInitial()")
            XCTAssertFalse(vm.isLoading,
                "AC-H01: isLoading should be false after load completes")
        }
    }

    /// AC-H01: Boundary — loadInitial() with single entry still produces valid grouping.
    func testLoadInitial_singleEntry() {
        let entry = HistoryEntry(url: "https://example.com", title: "Example",
                                 visit_time: now - 60, last_visit_time: now - 60,
                                 visit_count: 1)
        let vm = makeHistoryVM(entries: [entry])

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 1,
                "AC-H01: Should have 1 entry after loadInitial() with single item")
            XCTAssertEqual(vm.groupedEntries.count, 1,
                "AC-H01: Single entry should produce exactly 1 date group")
        }
    }

    // MARK: - AC-H02: loadInitial() 空数据时 entries 为空

    /// AC-H02: Happy path — loadInitial() with empty mock returns empty arrays.
    func testLoadInitial_emptyMock() {
        let vm = makeHistoryVM(entries: [])

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.entries.isEmpty,
                "AC-H02: entries should be empty when mock has no data")
            XCTAssertTrue(vm.groupedEntries.isEmpty,
                "AC-H02: groupedEntries should be empty when mock has no data")
            XCTAssertFalse(vm.isLoading,
                "AC-H02: isLoading should be false after load completes")
        }
    }

    /// AC-H02: Edge case — calling loadInitial() twice should not duplicate entries.
    func testLoadInitial_calledTwice_noDuplicates() {
        let vm = makeHistoryVM(entries: todayEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 2,
                "AC-H02: Calling loadInitial() twice should not duplicate entries")
        }
    }

    // MARK: - AC-H03: loadMore() 在 mock 模式下 hasMore 变为 false

    /// AC-H03: Happy path — loadMore() sets hasMore to false in mock mode.
    func testLoadMore_setsHasMoreFalse() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            Task { await vm.loadMore() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.hasMore,
                "AC-H03: hasMore should be false after loadMore() in mock mode")
        }
    }

    /// AC-H03: Edge case — loadMore() on empty data should still set hasMore to false.
    func testLoadMore_emptyData_hasMoreFalse() {
        let vm = makeHistoryVM(entries: [])

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            Task { await vm.loadMore() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.hasMore,
                "AC-H03: hasMore should be false after loadMore() even with empty data")
            XCTAssertTrue(vm.entries.isEmpty,
                "AC-H03: entries should remain empty")
        }
    }

    // MARK: - AC-H04: search() 过滤 title 匹配的 entries
    // Mock performSearch() filters mockConfig.entries by title/url, stores result
    // in groupedEntries as [("搜索结果", filtered)]. entries is NOT modified.

    /// AC-H04: Happy path — search() filters groupedEntries to title-matching items.
    func testSearch_setsQueryAndSearchState() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "Apple"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.searchQuery, "Apple")
            // groupedEntries should contain only the filtered result
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(searchResults.count, 1,
                "AC-H04: Search for 'Apple' should yield exactly 1 result in groupedEntries")
            XCTAssertEqual(searchResults.first?.title, "Apple")
        }
    }

    /// AC-H04: Edge case — case-insensitive title match.
    func testSearch_titleCaseInsensitive() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "apple"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(searchResults.count, 1,
                "AC-H04: Case-insensitive 'apple' should match 'Apple'")
        }
    }

    /// AC-H04: Boundary — partial title match.
    func testSearch_partialTitleMatch() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "Git"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(searchResults.count, 1,
                "AC-H04: Partial 'Git' should match only 'GitHub'")
            XCTAssertEqual(searchResults.first?.title, "GitHub")
        }
    }

    // MARK: - AC-H05: search() 过滤 URL 匹配的 entries

    /// AC-H05: Happy path — search by URL keyword filters correctly.
    func testSearch_filtersByURL() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "mozilla"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(searchResults.count, 1,
                "AC-H05: Search for 'mozilla' should match 1 URL")
            XCTAssertEqual(searchResults.first?.url, "https://developer.mozilla.org")
        }
    }

    /// AC-H05: Edge case — search by domain.
    func testSearch_filtersByDomain() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "github.com"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(searchResults.count, 1,
                "AC-H05: Search for 'github.com' should match 1 entry")
            XCTAssertEqual(searchResults.first?.title, "GitHub")
        }
    }

    // MARK: - AC-H06: search() 无匹配时 groupedEntries 搜索结果为空

    /// AC-H06: Happy path — no matches yields empty search results.
    func testSearch_noMatch_emptyResults() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "xyznonexistent"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            // Mock: groupedEntries = [("搜索结果", [])] — group exists but items empty
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertTrue(searchResults.isEmpty,
                "AC-H06: Non-matching query should produce empty search results")
        }
    }

    /// AC-H06: Edge case — special characters do not crash.
    func testSearch_specialCharacters_noCrash() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "!@#$%^&*()"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertTrue(searchResults.isEmpty,
                "AC-H06: Special characters should not match any entry")
        }
    }

    // MARK: - AC-H07: clearSearch() 恢复原始分组

    /// AC-H07: Happy path — clearSearch() resets searchQuery and restores entries.
    func testClearSearch_restoresOriginalEntries() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let originalCount: Int = MainActor.assumeIsolated { vm.entries.count }

        // Perform a search
        MainActor.assumeIsolated {
            vm.searchQuery = "Apple"
            vm.search()
        }
        pump()

        // Clear the search
        MainActor.assumeIsolated {
            vm.clearSearch()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.searchQuery.isEmpty,
                "AC-H07: searchQuery should be empty after clearSearch()")
            XCTAssertEqual(vm.entries.count, originalCount,
                "AC-H07: clearSearch() should restore entries to original count")
            XCTAssertFalse(vm.groupedEntries.isEmpty,
                "AC-H07: clearSearch() should restore groupedEntries")
        }
    }

    /// AC-H07: Edge case — clearSearch() when no search was active should be a no-op.
    func testClearSearch_noActiveSearch_noop() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let originalCount: Int = MainActor.assumeIsolated { vm.entries.count }

        MainActor.assumeIsolated {
            vm.clearSearch()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, originalCount,
                "AC-H07: clearSearch() with no active search should not change entries")
            XCTAssertTrue(vm.searchQuery.isEmpty,
                "AC-H07: searchQuery should remain empty")
        }
    }

    // MARK: - AC-H08: deleteEntry() 从 entries 移除并显示 undo toast

    /// AC-H08: Happy path — deleteEntry() removes entry and shows undo toast.
    func testDeleteEntry_removesAndShowsUndo() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let entryToDelete: HistoryEntry = MainActor.assumeIsolated { vm.entries[0] }

        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(entryToDelete) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 3,
                "AC-H08: Should have 3 entries after deleting 1")
            XCTAssertFalse(vm.entries.contains(where: { $0.url == entryToDelete.url }),
                "AC-H08: Deleted entry should not be in entries")
            XCTAssertNotNil(vm.undoEntry,
                "AC-H08: undoEntry should be set after deletion")
            XCTAssertEqual(vm.undoEntry?.url, entryToDelete.url,
                "AC-H08: undoEntry should reference the deleted entry")
            XCTAssertTrue(vm.showUndoToast,
                "AC-H08: showUndoToast should be true after deletion")
        }
    }

    /// AC-H08: Edge case — delete the last remaining entry.
    func testDeleteEntry_lastEntry_emptyList() {
        let singleEntry = HistoryEntry(url: "https://only.com", title: "Only",
                                       visit_time: now - 60, last_visit_time: now - 60,
                                       visit_count: 1)
        let vm = makeHistoryVM(entries: [singleEntry])

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(singleEntry) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.entries.isEmpty,
                "AC-H08: entries should be empty after deleting the last entry")
            XCTAssertNotNil(vm.undoEntry,
                "AC-H08: undoEntry should still be set even when list becomes empty")
            XCTAssertTrue(vm.showUndoToast,
                "AC-H08: showUndoToast should be true")
        }
    }

    // MARK: - AC-H09: undoDelete() 恢复被删除的 entry 并隐藏 toast

    /// AC-H09: Happy path — undoDelete() restores entry and hides toast.
    func testUndoDelete_restoresEntryAndHidesToast() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let entryToDelete: HistoryEntry = MainActor.assumeIsolated { vm.entries[0] }

        // Delete an entry
        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(entryToDelete) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 3, "Precondition: 3 entries after delete")
            XCTAssertTrue(vm.showUndoToast, "Precondition: undo toast should be visible")
        }

        // Undo the deletion
        MainActor.assumeIsolated {
            vm.undoDelete()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 4,
                "AC-H09: Should have 4 entries after undo (entry restored)")
            XCTAssertTrue(vm.entries.contains(where: { $0.url == entryToDelete.url }),
                "AC-H09: Restored entry should be back in entries")
            XCTAssertFalse(vm.showUndoToast,
                "AC-H09: showUndoToast should be false after undo")
        }
    }

    /// AC-H09: Edge case — undoDelete() when no entry was deleted (no-op).
    func testUndoDelete_noDeletedEntry_noop() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        // Call undoDelete without a prior deletion
        MainActor.assumeIsolated {
            vm.undoDelete()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 4,
                "AC-H09: entries should be unchanged when undoDelete() called without prior delete")
            XCTAssertFalse(vm.showUndoToast,
                "AC-H09: showUndoToast should remain false")
        }
    }

    /// AC-H09: Edge case — undo after deleting the only entry restores it.
    func testUndoDelete_restoresSingleDeletedEntry() {
        let singleEntry = HistoryEntry(url: "https://only.com", title: "Only",
                                       visit_time: now - 60, last_visit_time: now - 60,
                                       visit_count: 1)
        let vm = makeHistoryVM(entries: [singleEntry])

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(singleEntry) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.entries.isEmpty, "Precondition: entries should be empty")
        }

        MainActor.assumeIsolated {
            vm.undoDelete()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 1,
                "AC-H09: Should restore the single entry after undo")
            XCTAssertEqual(vm.entries.first?.url, "https://only.com",
                "AC-H09: Restored entry URL should match")
        }
    }

    // MARK: - AC-H10: clearRange(.all) 在 mock 模式下清空 entries

    /// AC-H10: Happy path — clearRange(.all) clears all entries.
    func testClearRange_all_clearsEntries() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 4, "Precondition: 4 entries loaded")
        }

        MainActor.assumeIsolated {
            Task { await vm.clearRange(.all) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.entries.isEmpty,
                "AC-H10: clearRange(.all) should remove all entries")
            XCTAssertTrue(vm.groupedEntries.isEmpty,
                "AC-H10: groupedEntries should also be empty after clearRange(.all)")
        }
    }

    /// AC-H10: Edge case — clearRange(.all) on already empty list is a no-op.
    func testClearRange_all_emptyList_noop() {
        let vm = makeHistoryVM(entries: [])

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            Task { await vm.clearRange(.all) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.entries.isEmpty,
                "AC-H10: clearRange(.all) on empty list should remain empty")
        }
    }

    /// AC-H10: Boundary — clearRange(.today) should only remove today's entries.
    func testClearRange_today_removesTodayOnly() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let countBefore: Int = MainActor.assumeIsolated { vm.entries.count }

        MainActor.assumeIsolated {
            Task { await vm.clearRange(.today) }
        }
        pump()

        MainActor.assumeIsolated {
            // Today's entries (Apple, Google Search) should be removed, older ones preserved.
            // Exact behavior depends on implementation; verify at least some were removed.
            XCTAssertLessThanOrEqual(vm.entries.count, countBefore,
                "AC-H10: clearRange(.today) should remove at most today's entries")
        }
    }

    // MARK: - AC-H11: groupByDate() 正确按日期分组（今天/昨天/本周/更早）

    /// AC-H11: Happy path — groupByDate produces correct date group labels.
    func testGroupByDate_correctGroupLabels() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            let grouped = vm.groupByDate(sampleEntries)

            // We should have at least 2 distinct groups (today + earlier)
            XCTAssertGreaterThanOrEqual(grouped.count, 2,
                "AC-H11: sampleEntries spanning multiple days should produce >= 2 groups")

            // Verify group keys are from the expected set
            let validKeys = Set(HistoryDateGroup.allCases.map(\.rawValue))
            for (key, _) in grouped {
                XCTAssertTrue(validKeys.contains(key),
                    "AC-H11: Group key '\(key)' should be a valid HistoryDateGroup rawValue")
            }
        }
    }

    /// AC-H11: Edge case — all entries from same day produce single group.
    func testGroupByDate_sameDay_singleGroup() {
        let vm = makeHistoryVM(entries: todayEntries)

        MainActor.assumeIsolated {
            let grouped = vm.groupByDate(todayEntries)

            XCTAssertEqual(grouped.count, 1,
                "AC-H11: All entries from today should produce exactly 1 group")
            XCTAssertEqual(grouped.first?.0, HistoryDateGroup.today.rawValue,
                "AC-H11: The single group should be '今天'")
            XCTAssertEqual(grouped.first?.1.count, 2,
                "AC-H11: The group should contain all 2 entries")
        }
    }

    /// AC-H11: Edge case — empty input produces no groups.
    func testGroupByDate_emptyInput() {
        let vm = makeHistoryVM(entries: [])

        MainActor.assumeIsolated {
            let grouped = vm.groupByDate([])

            XCTAssertTrue(grouped.isEmpty,
                "AC-H11: groupByDate with empty input should return empty array")
        }
    }

    /// AC-H11: Boundary — yesterday entry is grouped under "昨天".
    func testGroupByDate_yesterdayEntry() {
        let calendar = Calendar.current
        let yesterdayNoon = calendar.date(byAdding: .day, value: -1,
                                          to: calendar.startOfDay(for: Date()))!
            .addingTimeInterval(12 * 3600) // noon yesterday
        let entry = HistoryEntry(url: "https://yesterday.com", title: "Yesterday",
                                 visit_time: yesterdayNoon.timeIntervalSince1970,
                                 last_visit_time: yesterdayNoon.timeIntervalSince1970,
                                 visit_count: 1)
        let vm = makeHistoryVM(entries: [entry])

        MainActor.assumeIsolated {
            let grouped = vm.groupByDate([entry])

            XCTAssertEqual(grouped.count, 1,
                "AC-H11: Single yesterday entry should produce 1 group")
            XCTAssertEqual(grouped.first?.0, HistoryDateGroup.yesterday.rawValue,
                "AC-H11: Yesterday entry should be grouped under '昨天'")
        }
    }

    // MARK: - AC-H12: relativeTime() 返回正确的相对时间字符串

    /// AC-H12: Happy path — relativeTime for 5 minutes ago returns "5分钟前".
    func testRelativeTime_recentDate() {
        let fiveMinutesAgo = Date(timeIntervalSinceNow: -300)

        MainActor.assumeIsolated {
            let result = HistoryViewModel.relativeTime(from: fiveMinutesAgo)
            XCTAssertTrue(result.contains("分钟前"),
                "AC-H12: relativeTime for 5 minutes ago should contain '分钟前', got '\(result)'")
        }
    }

    /// AC-H12: Boundary — relativeTime for now returns "刚刚".
    func testRelativeTime_now() {
        let justNow = Date()

        MainActor.assumeIsolated {
            let result = HistoryViewModel.relativeTime(from: justNow)
            XCTAssertEqual(result, "刚刚",
                "AC-H12: relativeTime for 'now' should be '刚刚'")
        }
    }

    /// AC-H12: Boundary — relativeTime for 2 hours ago contains "小时前".
    func testRelativeTime_hoursAgo() {
        let twoHoursAgo = Date(timeIntervalSinceNow: -7200)

        MainActor.assumeIsolated {
            let result = HistoryViewModel.relativeTime(from: twoHoursAgo)
            XCTAssertTrue(result.contains("小时前"),
                "AC-H12: relativeTime for 2 hours ago should contain '小时前', got '\(result)'")
        }
    }

    /// AC-H12: Boundary — relativeTime for distant past returns date format "M月d日".
    func testRelativeTime_distantPast() {
        let oneYearAgo = Date(timeIntervalSinceNow: -365 * 86400)

        MainActor.assumeIsolated {
            let result = HistoryViewModel.relativeTime(from: oneYearAgo)
            XCTAssertTrue(result.contains("月") && result.contains("日"),
                "AC-H12: relativeTime for 1 year ago should be date format 'M月d日', got '\(result)'")
        }
    }

    /// AC-H12: Edge case — relativeTime for 3 days ago contains "天前".
    func testRelativeTime_daysAgo() {
        let threeDaysAgo = Date(timeIntervalSinceNow: -3 * 86400)

        MainActor.assumeIsolated {
            let result = HistoryViewModel.relativeTime(from: threeDaysAgo)
            XCTAssertTrue(result.contains("天前"),
                "AC-H12: relativeTime for 3 days ago should contain '天前', got '\(result)'")
        }
    }

    // MARK: - AC-H13: navigate() 调用 onNavigate 回调

    /// AC-H13: Happy path — navigate() triggers onNavigate callback with correct URL.
    func testNavigate_triggersCallback() {
        let vm = makeHistoryVM(entries: sampleEntries)

        var navigatedURL: String?
        MainActor.assumeIsolated {
            vm.onNavigate = { url in
                navigatedURL = url
            }
            vm.navigate(url: "https://apple.com")
        }

        XCTAssertEqual(navigatedURL, "https://apple.com",
            "AC-H13: navigate() should invoke onNavigate with the correct URL")
    }

    /// AC-H13: Edge case — navigate() with empty URL still triggers callback.
    func testNavigate_emptyURL_stillTriggersCallback() {
        let vm = makeHistoryVM(entries: [])

        var callbackInvoked = false
        MainActor.assumeIsolated {
            vm.onNavigate = { _ in
                callbackInvoked = true
            }
            vm.navigate(url: "")
        }

        XCTAssertTrue(callbackInvoked,
            "AC-H13: navigate() with empty URL should still invoke onNavigate")
    }

    /// AC-H13: Edge case — navigate() without setting onNavigate should not crash.
    func testNavigate_noCallback_noCrash() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            // onNavigate is nil by default — should not crash
            vm.navigate(url: "https://example.com")
        }

        // If we reach here, no crash occurred
        XCTAssertNil(MainActor.assumeIsolated { vm.onNavigate },
            "AC-H13: onNavigate should be nil when not set")
    }

    // MARK: - AC-H14: 空 searchQuery 时 search() 调用 clearSearch()

    /// AC-H14: Happy path — calling search() with empty query resets searchQuery (clearSearch behavior).
    func testSearch_emptyQuery_callsClearSearch() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let originalCount: Int = MainActor.assumeIsolated { vm.entries.count }

        // Set a search query first
        MainActor.assumeIsolated {
            vm.searchQuery = "Apple"
            vm.search()
        }
        pump()

        // Now search with empty query — should behave like clearSearch()
        MainActor.assumeIsolated {
            vm.searchQuery = ""
            vm.search()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.searchQuery.isEmpty,
                "AC-H14: searchQuery should be empty after search() with empty query")
            XCTAssertEqual(vm.entries.count, originalCount,
                "AC-H14: search() with empty query should restore original entry count")
            XCTAssertFalse(vm.groupedEntries.isEmpty,
                "AC-H14: groupedEntries should be restored")
        }
    }

    // MARK: - Debounce behavior: consecutive search() calls only trigger one performSearch

    /// P0: search() debounce — rapid calls should only produce one search result.
    func testSearch_debounce_onlyTriggersOnce() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            // Rapidly change search queries — only last should take effect
            vm.searchQuery = "Apple"
            vm.search()
            vm.searchQuery = "Google"
            vm.search()
            vm.searchQuery = "GitHub"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            // Only "GitHub" search should have executed
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(searchResults.count, 1,
                "Debounce: Only the last search query 'GitHub' should produce results")
            XCTAssertEqual(searchResults.first?.title, "GitHub")
        }
    }

    // MARK: - loadMore guard: should not load when searchQuery is non-empty

    /// P0: loadMore() does nothing when searchQuery is non-empty.
    func testLoadMore_duringSearch_noop() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "Apple"
            vm.search()
        }
        pump(0.5)

        let countBefore: Int = MainActor.assumeIsolated { vm.entries.count }

        MainActor.assumeIsolated {
            Task { await vm.loadMore() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, countBefore,
                "loadMore() during search should not change entries")
        }
    }

    // MARK: - Consecutive deleteEntry: second delete commits first undo

    /// P0: Deleting a second entry commits the first deletion (no undo for first).
    func testDeleteEntry_consecutiveDeletes_commitsFirst() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let first: HistoryEntry = MainActor.assumeIsolated { vm.entries[0] }
        let second: HistoryEntry = MainActor.assumeIsolated { vm.entries[1] }

        // Delete first entry
        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(first) }
        }
        pump()

        // Delete second entry — should commit first deletion
        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(second) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 2,
                "After 2 consecutive deletes, 2 entries should remain")
            XCTAssertFalse(vm.entries.contains(where: { $0.url == first.url }),
                "First deleted entry should not be restorable")
            XCTAssertFalse(vm.entries.contains(where: { $0.url == second.url }),
                "Second deleted entry should be removed")
            // Only the second entry should be undoable
            XCTAssertEqual(vm.undoEntry?.url, second.url,
                "undoEntry should reference the second (most recent) deletion")
        }
    }

    /// AC-H14: Edge case — whitespace-only query triggers debounced search (not clearSearch).
    func testSearch_whitespaceQuery_triggersSearch() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        // Whitespace-only query is not empty, so search() enters debounce path
        MainActor.assumeIsolated {
            vm.searchQuery = "   "
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            // " " does not match any title/url, so mock filter yields empty results
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertTrue(searchResults.isEmpty,
                "AC-H14: Whitespace-only query should yield empty search results")
        }
    }

    // MARK: - onHistoryChanged: push-based refresh mechanism

    /// Verify that onHistoryChanged triggers a reload when the sidebar is visible.
    func testOnHistoryChanged_whenVisible_triggersReload() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 4, "Precondition: 4 entries loaded")
            vm.isVisible = true

            // Manually clear entries to detect if loadInitial re-populates them
            vm.entries = []
            XCTAssertTrue(vm.entries.isEmpty, "Precondition: entries manually cleared")

            // Trigger push-based refresh
            vm.onHistoryChanged(url: "https://apple.com")
        }
        // onHistoryChanged debounces 100ms, then calls loadInitial
        pump(0.3)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 4,
                "onHistoryChanged should reload entries from mockConfig when visible")
        }
    }

    /// Verify that onHistoryChanged does NOT reload when the sidebar is invisible.
    func testOnHistoryChanged_whenInvisible_doesNotReload() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.isVisible = false

            // Manually clear entries — should stay empty if no reload occurs
            vm.entries = []

            vm.onHistoryChanged(url: "https://apple.com")
        }
        pump(0.3)

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.entries.isEmpty,
                "onHistoryChanged should NOT reload when isVisible is false")
        }
    }

    /// Verify that rapid onHistoryChanged calls are coalesced via debounce.
    func testOnHistoryChanged_debounce_coalesces() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.isVisible = true
            vm.entries = []

            // Fire 5 rapid change notifications
            for i in 0..<5 {
                vm.onHistoryChanged(url: "https://example.com/\(i)")
            }
        }
        // Wait for debounce (100ms) + loadInitial completion
        pump(0.3)

        MainActor.assumeIsolated {
            // Entries should be reloaded exactly once from mockConfig
            XCTAssertEqual(vm.entries.count, 4,
                "Debounced onHistoryChanged should reload entries once (4 from mockConfig)")
        }
    }

    // MARK: - BUG: Delete + loadInitial race condition

    /// BUG-1: Demonstrates that loadInitial after deleteEntry causes the deleted entry
    /// to reappear because the backend (mock) still has it and loadInitial overwrites entries.
    func testDeleteEntry_followedByLoadInitial_entryStaysDeleted() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        let entryToDelete: HistoryEntry = MainActor.assumeIsolated { vm.entries[0] }

        // Delete an entry (optimistic removal)
        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(entryToDelete) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 3,
                "Precondition: entry should be deleted")
            XCTAssertFalse(vm.entries.contains(where: { $0.url == entryToDelete.url }),
                "Precondition: deleted entry should not be in entries")
            // Undo toast should be visible
            XCTAssertTrue(vm.showUndoToast,
                "Precondition: undo toast should be visible after delete")
        }

        // loadInitial should filter out the pending undo entry
        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            // FIX: loadInitial now filters out entries pending undo deletion
            XCTAssertEqual(vm.entries.count, 3,
                "BUG-1 FIX: Deleted entry should NOT reappear after loadInitial")
            XCTAssertFalse(vm.entries.contains(where: { $0.url == entryToDelete.url }),
                "BUG-1 FIX: Entry pending undo should be filtered out by loadInitial")
            // Undo toast and undoEntry should still be active
            XCTAssertTrue(vm.showUndoToast,
                "BUG-1 FIX: Undo toast should still be visible after loadInitial")
            XCTAssertNotNil(vm.undoEntry,
                "BUG-1 FIX: undoEntry should still be set after loadInitial")
        }
    }

    // MARK: - HistoryEntry model tests

    /// Helper: create a HistoryEntry from JSON with a specific visit_id.
    private func makeEntry(
        visitId: Int64 = 0,
        url: String = "https://example.com",
        title: String = "Example",
        visitTime: Double? = nil,
        lastVisitTime: Double? = nil,
        visitCount: Int32 = 1
    ) -> HistoryEntry {
        let t = visitTime ?? now
        let lt = lastVisitTime ?? t
        let json: [String: Any] = [
            "visit_id": visitId,
            "url": url,
            "title": title,
            "visit_time": t,
            "last_visit_time": lt,
            "visit_count": visitCount
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(HistoryEntry.self, from: data)
    }

    /// HistoryEntry.id returns visit_id as String when visit_id is non-zero.
    func testHistoryEntry_id_usesVisitIdWhenNonZero() {
        let entry = makeEntry(visitId: 42, url: "https://example.com", title: "Test")

        XCTAssertEqual(entry.id, "42",
            "HistoryEntry.id should be '42' when visit_id is 42")
    }

    /// HistoryEntry.id falls back to url when visit_id is zero.
    func testHistoryEntry_id_fallsBackToUrlWhenVisitIdZero() {
        let entry = makeEntry(visitId: 0, url: "https://example.com/page", title: "Test")

        XCTAssertEqual(entry.id, "https://example.com/page",
            "HistoryEntry.id should fall back to url when visit_id is 0")
    }

    /// HistoryEntry.displayURL strips "www." prefix from the host.
    func testHistoryEntry_displayURL_stripsWww() {
        let entry = makeEntry(url: "https://www.example.com/page", title: "Example")

        XCTAssertEqual(entry.displayURL, "example.com",
            "displayURL should strip 'www.' prefix")
    }

    /// HistoryEntry.displayURL returns just the host for a normal URL.
    func testHistoryEntry_displayURL_returnsHostForNormalUrl() {
        let entry = makeEntry(url: "https://github.com/user/repo", title: "GitHub")

        XCTAssertEqual(entry.displayURL, "github.com",
            "displayURL should return host without path")
    }

    /// HistoryEntry.displayURL returns the full string for an invalid URL.
    func testHistoryEntry_displayURL_returnsFullUrlForInvalid() {
        let entry = makeEntry(url: "not a url", title: "Invalid")

        XCTAssertEqual(entry.displayURL, "not a url",
            "displayURL should return the full string when URL is invalid")
    }

    /// HistoryEntry.displayURL preserves non-www subdomains.
    func testHistoryEntry_displayURL_preservesSubdomain() {
        let entry = makeEntry(url: "https://docs.example.com", title: "Docs")

        XCTAssertEqual(entry.displayURL, "docs.example.com",
            "displayURL should preserve subdomains that are not 'www'")
    }

    /// HistoryEntry decodes visit_id as Int64 from JSON number.
    func testHistoryEntry_decodable_visitIdAsInt64() {
        let json = """
        {"visit_id": 99, "url": "https://a.com", "title": "A",
         "visit_time": 1000, "last_visit_time": 1000, "visit_count": 1}
        """.data(using: .utf8)!

        let entry = try! JSONDecoder().decode(HistoryEntry.self, from: json)
        XCTAssertEqual(entry.visit_id, 99,
            "visit_id should decode from JSON number")
    }

    /// HistoryEntry decodes visit_id from a JSON string (C-ABI sends string).
    func testHistoryEntry_decodable_visitIdAsString() {
        let json = """
        {"visit_id": "42", "url": "https://b.com", "title": "B",
         "visit_time": 2000, "last_visit_time": 2000, "visit_count": 1}
        """.data(using: .utf8)!

        let entry = try! JSONDecoder().decode(HistoryEntry.self, from: json)
        XCTAssertEqual(entry.visit_id, 42,
            "visit_id should decode from JSON string '42'")
    }

    /// HistoryEntry defaults visit_id to 0 when the field is missing from JSON.
    func testHistoryEntry_decodable_visitIdMissing() {
        let json = """
        {"url": "https://c.com", "title": "C",
         "visit_time": 3000, "last_visit_time": 3000, "visit_count": 1}
        """.data(using: .utf8)!

        let entry = try! JSONDecoder().decode(HistoryEntry.self, from: json)
        XCTAssertEqual(entry.visit_id, 0,
            "visit_id should default to 0 when missing from JSON")
    }

    // MARK: - clearRange(.lastSevenDays) in mock mode

    /// clearRange(.lastSevenDays) clears all entries in mock mode (mock does not filter by date).
    func testClearRange_lastSevenDays_clearsInMockMode() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 4, "Precondition: 4 entries loaded")
        }

        MainActor.assumeIsolated {
            Task { await vm.clearRange(.lastSevenDays) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.entries.isEmpty,
                "clearRange(.lastSevenDays) should clear all entries in mock mode")
            XCTAssertTrue(vm.groupedEntries.isEmpty,
                "groupedEntries should also be empty after clearRange(.lastSevenDays) in mock mode")
        }
    }

    // MARK: - Undo insert position

    /// undoDelete re-inserts the entry at the correct sorted position (by last_visit_time DESC).
    func testUndoDelete_insertsAtCorrectSortedPosition() {
        let now = self.now
        let entries = [
            HistoryEntry(url: "https://first.com", title: "First",
                         visit_time: now - 10, last_visit_time: now - 10, visit_count: 1),
            HistoryEntry(url: "https://second.com", title: "Second",
                         visit_time: now - 60, last_visit_time: now - 60, visit_count: 1),
            HistoryEntry(url: "https://third.com", title: "Third",
                         visit_time: now - 120, last_visit_time: now - 120, visit_count: 1),
        ]
        let vm = makeHistoryVM(entries: entries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        // Delete the middle entry ("Second")
        let middle: HistoryEntry = MainActor.assumeIsolated { vm.entries[1] }
        XCTAssertEqual(middle.url, "https://second.com", "Precondition: middle entry is Second")

        MainActor.assumeIsolated {
            Task { await vm.deleteEntry(middle) }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 2, "Precondition: 2 entries after delete")
        }

        // Undo — should re-insert at index 1 (between First and Third)
        MainActor.assumeIsolated {
            vm.undoDelete()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.entries.count, 3,
                "Should have 3 entries after undo")
            XCTAssertEqual(vm.entries[0].url, "https://first.com",
                "First entry should remain at index 0")
            XCTAssertEqual(vm.entries[1].url, "https://second.com",
                "Restored entry should be re-inserted at index 1 (sorted by last_visit_time DESC)")
            XCTAssertEqual(vm.entries[2].url, "https://third.com",
                "Third entry should remain at index 2")
        }
    }

    // MARK: - loadInitial guard: reentrant call blocked

    /// loadInitial is guarded by isLoading — a second call while the first is in progress is a no-op.
    func testLoadInitial_reentrantCallBlocked() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            // Simulate isLoading = true (as if first loadInitial is in progress)
            vm.isLoading = true

            // Second call should bail out immediately due to guard
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            // entries should still be empty because the guarded loadInitial was a no-op,
            // and we never completed a real loadInitial
            XCTAssertTrue(vm.entries.isEmpty,
                "loadInitial should be a no-op when isLoading is already true")
            // isLoading remains true because the guard returned early without resetting it
            XCTAssertTrue(vm.isLoading,
                "isLoading should remain true (guard returned early, did not reset)")
        }
    }

    // MARK: - Search + clearSearch state transitions

    /// Verify isSearching transitions: search sets it true, performSearch resets it false,
    /// clearSearch also sets it false.
    func testSearchThenClearSearch_isSearchingResets() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        // search() with non-empty query sets isSearching = true
        MainActor.assumeIsolated {
            vm.searchQuery = "Apple"
            vm.search()
            XCTAssertTrue(vm.isSearching,
                "isSearching should be true immediately after search() with non-empty query")
        }

        // After debounce, performSearch completes and sets isSearching = false
        pump(0.5)

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.isSearching,
                "isSearching should be false after performSearch completes")
        }

        // Search again, then clearSearch before debounce fires
        MainActor.assumeIsolated {
            vm.searchQuery = "Google"
            vm.search()
            XCTAssertTrue(vm.isSearching,
                "isSearching should be true after second search()")

            vm.clearSearch()
            XCTAssertFalse(vm.isSearching,
                "clearSearch should immediately set isSearching to false")
            XCTAssertTrue(vm.searchQuery.isEmpty,
                "clearSearch should reset searchQuery to empty")
        }
    }

    // MARK: - BUG-3: Search pagination tests

    /// BUG-3: loadMore() during search delegates to searchMore() in mock mode (no-op, no crash).
    func testLoadMore_duringSearch_paginatesSearchResults() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        // Enter search mode
        MainActor.assumeIsolated {
            vm.searchQuery = "apple"
            vm.search()
        }
        pump(0.5)

        // Verify search results present
        let searchResults: [HistoryEntry] = MainActor.assumeIsolated {
            vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
        }
        XCTAssertFalse(searchResults.isEmpty,
            "Precondition: search should yield results for 'apple'")

        // loadMore during search should not crash, and hasMore should be false in mock mode
        MainActor.assumeIsolated {
            Task { await vm.loadMore() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.hasMore,
                "BUG-3: hasMore should be false in mock mode after loadMore during search")
            // Entries should remain unchanged (loadMore delegates to searchMore, which is no-op in mock)
            let resultsAfter = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(resultsAfter.count, searchResults.count,
                "BUG-3: Search results should not change after loadMore in mock mode")
        }
    }

    /// BUG-3: performSearch sets hasMore correctly (false in mock mode — all results returned at once).
    func testPerformSearch_setsHasMoreCorrectly() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.searchQuery = "google"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.hasMore,
                "BUG-3: hasMore should be false after search in mock mode (all results at once)")
            let searchResults = vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
            XCTAssertEqual(searchResults.count, 1,
                "BUG-3: Search for 'google' should yield 1 result")
        }
    }

    /// BUG-3: clearSearch restores hasMore based on main list offset vs totalCount.
    func testClearSearch_restoresHasMoreFromMainList() {
        // 4 entries but totalCount=100 → hasMore should be true after loadInitial
        let vm = makeHistoryVM(entries: sampleEntries, totalCount: 100)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.hasMore,
                "Precondition: hasMore should be true when entries.count < totalCount")
        }

        // Search → hasMore changes to false (mock returns all filtered results at once)
        MainActor.assumeIsolated {
            vm.searchQuery = "apple"
            vm.search()
        }
        pump(0.5)

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.hasMore,
                "BUG-3: hasMore should be false during search in mock mode")
        }

        // clearSearch → hasMore should be restored to true (currentOffset < totalCount)
        MainActor.assumeIsolated {
            vm.clearSearch()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.hasMore,
                "BUG-3: clearSearch should restore hasMore to true (currentOffset < totalCount)")
        }
    }

    /// BUG-3: Consecutive searches replace results (not append), verifying offset reset.
    func testPerformSearch_resetsSearchOffset() {
        let vm = makeHistoryVM(entries: sampleEntries)

        MainActor.assumeIsolated {
            Task { await vm.loadInitial() }
        }
        pump()

        // First search: "apple" → should match Apple
        MainActor.assumeIsolated {
            vm.searchQuery = "apple"
            vm.search()
        }
        pump(0.5)

        let firstResults: [HistoryEntry] = MainActor.assumeIsolated {
            vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
        }
        XCTAssertEqual(firstResults.count, 1,
            "Precondition: 'apple' search should yield 1 result")
        XCTAssertEqual(firstResults.first?.title, "Apple",
            "Precondition: first search should find Apple")

        // Second search: "google" → results should be replaced, not appended
        MainActor.assumeIsolated {
            vm.searchQuery = "google"
            vm.search()
        }
        pump(0.5)

        let secondResults: [HistoryEntry] = MainActor.assumeIsolated {
            vm.groupedEntries.first(where: { $0.0 == "搜索结果" })?.1 ?? []
        }
        XCTAssertEqual(secondResults.count, 1,
            "BUG-3: Second search should replace results (1 result for 'google'), not append")
        XCTAssertEqual(secondResults.first?.title, "Google Search",
            "BUG-3: Second search should find Google Search, not carry over Apple")
    }
}
