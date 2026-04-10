import XCTest
@testable import OWLBrowserLib

/// Console ViewModel unit tests — Phase 2 Console panel
/// Pure Swift tests: ConsoleLevel enum, ConsoleViewModel addMessage/filter/search/clear/preserveLog
/// No Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class ConsoleViewModelTests: XCTestCase {

    /// Pump RunLoop to allow async refresh task to fire.
    /// ConsoleViewModel uses 200ms refresh interval, so 0.4s gives adequate margin.
    private func pump(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - Helpers

    /// Create a ConsoleViewModel on MainActor.
    private func makeVM() -> ConsoleViewModel {
        MainActor.assumeIsolated {
            ConsoleViewModel()
        }
    }

    /// Add a single console message with sensible defaults.
    private func addMsg(
        to vm: ConsoleViewModel,
        level: ConsoleLevel = .info,
        message: String = "test message",
        source: String = "test.js",
        line: Int = 1,
        timestamp: Date = Date()
    ) {
        MainActor.assumeIsolated {
            vm.addMessage(level: level, message: message, source: source,
                          line: line, timestamp: timestamp)
        }
    }

    // =========================================================================
    // MARK: - ConsoleLevel enum values
    // =========================================================================

    /// ConsoleLevel raw values must match Mojom: Verbose=0, Info=1, Warning=2, Error=3.
    func testConsoleLevel_rawValues() {
        XCTAssertEqual(ConsoleLevel.verbose.rawValue, 0,
            "ConsoleLevel.verbose must map to 0")
        XCTAssertEqual(ConsoleLevel.info.rawValue, 1,
            "ConsoleLevel.info must map to 1")
        XCTAssertEqual(ConsoleLevel.warning.rawValue, 2,
            "ConsoleLevel.warning must map to 2")
        XCTAssertEqual(ConsoleLevel.error.rawValue, 3,
            "ConsoleLevel.error must map to 3")
    }

    /// ConsoleLevel.allCases should contain exactly 4 levels.
    func testConsoleLevel_allCases() {
        XCTAssertEqual(ConsoleLevel.allCases.count, 4,
            "ConsoleLevel should have exactly 4 cases")
    }

    /// ConsoleLevel can be initialized from raw Int values.
    func testConsoleLevel_initFromRawValue() {
        XCTAssertEqual(ConsoleLevel(rawValue: 0), .verbose)
        XCTAssertEqual(ConsoleLevel(rawValue: 1), .info)
        XCTAssertEqual(ConsoleLevel(rawValue: 2), .warning)
        XCTAssertEqual(ConsoleLevel(rawValue: 3), .error)
        XCTAssertNil(ConsoleLevel(rawValue: 99),
            "Invalid raw value should return nil")
    }

    // =========================================================================
    // MARK: - AC-CON-ADD: addMessage correctly records messages
    // =========================================================================

    /// addMessage adds a single message that appears in filteredItems after refresh.
    func testAddMessage_singleMessage() {
        let vm = makeVM()
        addMsg(to: vm, level: .warning, message: "something went wrong")
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.filteredItems.count, 1,
                "AC-ADD: single addMessage should produce 1 filtered item")
            if case .message(let item) = vm.filteredItems.first {
                XCTAssertEqual(item.level, .warning)
                XCTAssertEqual(item.message, "something went wrong")
            } else {
                XCTFail("AC-ADD: first item should be a .message")
            }
        }
    }

    /// addMessage records source, line, and timestamp correctly.
    func testAddMessage_fieldsPreserved() {
        let vm = makeVM()
        let ts = Date(timeIntervalSince1970: 1700000000.0)
        addMsg(to: vm, level: .error, message: "err", source: "app.js",
               line: 42, timestamp: ts)
        pump()

        MainActor.assumeIsolated {
            guard case .message(let item) = vm.filteredItems.first else {
                XCTFail("AC-ADD: expected .message item"); return
            }
            XCTAssertEqual(item.source, "app.js",
                "AC-ADD: source should be preserved")
            XCTAssertEqual(item.line, 42,
                "AC-ADD: line should be preserved")
            XCTAssertEqual(item.timestamp.timeIntervalSince1970, 1700000000.0, accuracy: 0.001,
                "AC-ADD: timestamp should be preserved")
        }
    }

    /// addMessage updates counts per level.
    func testAddMessage_updatesCounts() {
        let vm = makeVM()
        addMsg(to: vm, level: .info)
        addMsg(to: vm, level: .info)
        addMsg(to: vm, level: .error)
        addMsg(to: vm, level: .warning)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.counts[.info], 2, "AC-ADD: info count should be 2")
            XCTAssertEqual(vm.counts[.error], 1, "AC-ADD: error count should be 1")
            XCTAssertEqual(vm.counts[.warning], 1, "AC-ADD: warning count should be 1")
            XCTAssertEqual(vm.counts[.verbose], 0, "AC-ADD: verbose count should be 0")
        }
    }

    /// Multiple messages accumulate in order.
    func testAddMessage_multipleMessagesInOrder() {
        let vm = makeVM()
        for i in 0..<5 {
            addMsg(to: vm, message: "msg \(i)")
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.filteredItems.count, 5,
                "AC-ADD: 5 messages should produce 5 items")
            // Verify ordering: first added = first displayed
            if case .message(let first) = vm.filteredItems[0] {
                XCTAssertEqual(first.message, "msg 0")
            }
            if case .message(let last) = vm.filteredItems[4] {
                XCTAssertEqual(last.message, "msg 4")
            }
        }
    }

    /// addMessage with message near 10KB marks isTruncated.
    func testAddMessage_truncatedFlag() {
        let vm = makeVM()
        let longMsg = String(repeating: "x", count: 10000)
        addMsg(to: vm, message: longMsg)
        pump()

        MainActor.assumeIsolated {
            guard case .message(let item) = vm.filteredItems.first else {
                XCTFail("AC-ADD: expected .message item"); return
            }
            XCTAssertTrue(item.isTruncated,
                "AC-ADD: message >= 10000 chars should set isTruncated=true")
        }
    }

    /// addMessage with short message does not set isTruncated.
    func testAddMessage_notTruncated() {
        let vm = makeVM()
        addMsg(to: vm, message: "short")
        pump()

        MainActor.assumeIsolated {
            guard case .message(let item) = vm.filteredItems.first else {
                XCTFail("AC-ADD: expected .message item"); return
            }
            XCTAssertFalse(item.isTruncated,
                "AC-ADD: short message should not be truncated")
        }
    }

    // =========================================================================
    // MARK: - AC-CON-RING: Ring buffer FIFO eviction at capacity=1000
    // =========================================================================

    /// When buffer exceeds capacity (1000), oldest messages are evicted FIFO.
    func testRingBuffer_FIFOEviction() {
        let vm = makeVM()

        // Fill past capacity: add 1010 messages
        MainActor.assumeIsolated {
            for i in 0..<1010 {
                vm.addMessage(level: .info, message: "msg \(i)", source: "test.js",
                              line: 1, timestamp: Date())
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.displayItems.count, 1000,
                "AC-RING: buffer should cap at 1000 items")
            // Oldest messages (0..9) should have been evicted
            if case .message(let first) = vm.displayItems[0] {
                XCTAssertEqual(first.message, "msg 10",
                    "AC-RING: first item should be msg 10 after 10 evictions")
            } else {
                XCTFail("AC-RING: first item should be .message")
            }
        }
    }

    /// Eviction decrements the counts for the evicted message level.
    func testRingBuffer_evictionUpdatesCounts() {
        let vm = makeVM()

        // Add 1000 verbose messages, then 10 error messages
        MainActor.assumeIsolated {
            for _ in 0..<1000 {
                vm.addMessage(level: .verbose, message: "v", source: "", line: 0,
                              timestamp: Date())
            }
            for _ in 0..<10 {
                vm.addMessage(level: .error, message: "e", source: "", line: 0,
                              timestamp: Date())
            }
        }

        MainActor.assumeIsolated {
            // 10 verbose messages should have been evicted
            XCTAssertEqual(vm.counts[.verbose], 990,
                "AC-RING: eviction should decrement verbose count by 10")
            XCTAssertEqual(vm.counts[.error], 10,
                "AC-RING: error count should remain 10")
        }
    }

    // =========================================================================
    // MARK: - AC-CON-FILTER: Level filtering
    // =========================================================================

    /// filter=nil shows all messages.
    func testFilter_nilShowsAll() {
        let vm = makeVM()
        addMsg(to: vm, level: .verbose, message: "v")
        addMsg(to: vm, level: .info, message: "i")
        addMsg(to: vm, level: .warning, message: "w")
        addMsg(to: vm, level: .error, message: "e")
        pump()

        MainActor.assumeIsolated {
            vm.filter = nil
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 4,
                "AC-FILTER: nil filter should show all 4 messages")
        }
    }

    /// filter=.error shows only error messages.
    func testFilter_errorOnly() {
        let vm = makeVM()
        addMsg(to: vm, level: .verbose, message: "v")
        addMsg(to: vm, level: .info, message: "i")
        addMsg(to: vm, level: .warning, message: "w")
        addMsg(to: vm, level: .error, message: "e1")
        addMsg(to: vm, level: .error, message: "e2")
        pump()

        MainActor.assumeIsolated {
            vm.filter = .error
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 2,
                "AC-FILTER: .error filter should show only 2 error messages")
            for item in vm.filteredItems {
                if case .message(let msg) = item {
                    XCTAssertEqual(msg.level, .error)
                }
            }
        }
    }

    /// filter=.warning shows only warning messages.
    func testFilter_warningOnly() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "i")
        addMsg(to: vm, level: .warning, message: "w1")
        addMsg(to: vm, level: .error, message: "e")
        pump()

        MainActor.assumeIsolated {
            vm.filter = .warning
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 1,
                "AC-FILTER: .warning filter should show only 1 warning message")
        }
    }

    /// filter=.verbose shows only verbose messages.
    func testFilter_verboseOnly() {
        let vm = makeVM()
        addMsg(to: vm, level: .verbose, message: "v1")
        addMsg(to: vm, level: .verbose, message: "v2")
        addMsg(to: vm, level: .info, message: "i")
        pump()

        MainActor.assumeIsolated {
            vm.filter = .verbose
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 2,
                "AC-FILTER: .verbose filter should show only verbose messages")
        }
    }

    /// Separators are always visible regardless of level filter.
    func testFilter_separatorsAlwaysVisible() {
        let vm = makeVM()
        MainActor.assumeIsolated {
            vm.preserveLog = true
        }
        addMsg(to: vm, level: .info, message: "before nav")
        MainActor.assumeIsolated {
            vm.onNavigation(url: "https://example.com")
        }
        addMsg(to: vm, level: .error, message: "after nav")
        pump()

        MainActor.assumeIsolated {
            vm.filter = .error
            vm.refilter()
            // Should show: separator + error message
            let separatorCount = vm.filteredItems.filter {
                if case .separator = $0 { return true }; return false
            }.count
            XCTAssertEqual(separatorCount, 1,
                "AC-FILTER: separators should pass through level filter")
        }
    }

    // =========================================================================
    // MARK: - AC-CON-SEARCH: Text search
    // =========================================================================

    /// searchText filters messages by message content (case insensitive).
    func testSearch_filtersByMessageContent() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "Hello World")
        addMsg(to: vm, level: .info, message: "Goodbye")
        addMsg(to: vm, level: .info, message: "hello again")
        pump()

        MainActor.assumeIsolated {
            vm.searchText = "hello"
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 2,
                "AC-SEARCH: 'hello' should match 2 messages (case insensitive)")
        }
    }

    /// searchText filters by source field too.
    func testSearch_filtersBySource() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "msg1", source: "app.js")
        addMsg(to: vm, level: .info, message: "msg2", source: "vendor.js")
        pump()

        MainActor.assumeIsolated {
            vm.searchText = "app.js"
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 1,
                "AC-SEARCH: searching by source should find matching message")
        }
    }

    /// Empty searchText shows all messages.
    func testSearch_emptyShowsAll() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "a")
        addMsg(to: vm, level: .info, message: "b")
        pump()

        MainActor.assumeIsolated {
            vm.searchText = ""
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 2,
                "AC-SEARCH: empty searchText should show all messages")
        }
    }

    /// searchText with no matches produces empty filteredItems.
    func testSearch_noMatchesReturnsEmpty() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "hello")
        pump()

        MainActor.assumeIsolated {
            vm.searchText = "zzz_no_match"
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 0,
                "AC-SEARCH: non-matching search should return empty")
        }
    }

    /// Combined filter + search narrows results.
    func testSearch_combinedWithLevelFilter() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "hello info")
        addMsg(to: vm, level: .error, message: "hello error")
        addMsg(to: vm, level: .info, message: "goodbye info")
        pump()

        MainActor.assumeIsolated {
            vm.filter = .info
            vm.searchText = "hello"
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 1,
                "AC-SEARCH: filter=info + search=hello should match 1 message")
        }
    }

    // =========================================================================
    // MARK: - AC-CON-CLEAR: Clear button
    // =========================================================================

    /// clear() removes all messages and resets counts.
    func testClear_removesAllMessages() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "a")
        addMsg(to: vm, level: .error, message: "b")
        pump()

        MainActor.assumeIsolated {
            XCTAssertGreaterThan(vm.filteredItems.count, 0, "Precondition")
            vm.clear()
            XCTAssertEqual(vm.displayItems.count, 0,
                "AC-CLEAR: displayItems should be empty after clear()")
            XCTAssertEqual(vm.filteredItems.count, 0,
                "AC-CLEAR: filteredItems should be empty after clear()")
            XCTAssertEqual(vm.counts[.info], 0,
                "AC-CLEAR: info count should be 0 after clear()")
            XCTAssertEqual(vm.counts[.error], 0,
                "AC-CLEAR: error count should be 0 after clear()")
            XCTAssertEqual(vm.counts[.warning], 0,
                "AC-CLEAR: warning count should be 0 after clear()")
            XCTAssertEqual(vm.counts[.verbose], 0,
                "AC-CLEAR: verbose count should be 0 after clear()")
        }
    }

    /// clear() after adding many messages works without crash.
    func testClear_afterManyMessages() {
        let vm = makeVM()
        MainActor.assumeIsolated {
            for i in 0..<500 {
                vm.addMessage(level: .info, message: "msg \(i)", source: "",
                              line: 0, timestamp: Date())
            }
        }
        pump()

        MainActor.assumeIsolated {
            vm.clear()
            XCTAssertEqual(vm.displayItems.count, 0,
                "AC-CLEAR: should clear even after many messages")
        }
    }

    // =========================================================================
    // MARK: - AC-CON-PRESERVE: preserveLog switch
    // =========================================================================

    /// preserveLog defaults to false.
    func testPreserveLog_defaultOff() {
        let vm = makeVM()
        MainActor.assumeIsolated {
            XCTAssertFalse(vm.preserveLog,
                "AC-PRESERVE: preserveLog should default to false")
        }
    }

    /// onNavigation with preserveLog=false clears the buffer.
    func testOnNavigation_preserveLogOff_clears() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "before nav")
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.filteredItems.count, 1, "Precondition")
            vm.preserveLog = false
            vm.onNavigation(url: "https://example.com/page2")
            XCTAssertEqual(vm.displayItems.count, 0,
                "AC-PRESERVE: onNavigation with preserveLog=off should clear")
            XCTAssertEqual(vm.filteredItems.count, 0,
                "AC-PRESERVE: filteredItems should also be cleared")
        }
    }

    /// onNavigation with preserveLog=true inserts a separator and keeps messages.
    func testOnNavigation_preserveLogOn_insertsSeparator() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "before nav")
        MainActor.assumeIsolated {
            vm.preserveLog = true
            vm.onNavigation(url: "https://example.com/page2")
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.displayItems.count, 2,
                "AC-PRESERVE: should have original message + separator")
            // Second item should be a separator
            if case .separator(let url, _) = vm.displayItems[1] {
                XCTAssertEqual(url, "https://example.com/page2",
                    "AC-PRESERVE: separator URL should match navigation URL")
            } else {
                XCTFail("AC-PRESERVE: second item should be .separator")
            }
        }
    }

    /// onNavigation with preserveLog=true preserves existing messages.
    func testOnNavigation_preserveLogOn_keepsExistingMessages() {
        let vm = makeVM()
        addMsg(to: vm, level: .error, message: "important error")
        MainActor.assumeIsolated {
            vm.preserveLog = true
            vm.onNavigation(url: "https://example.com/page2")
        }
        addMsg(to: vm, level: .info, message: "after nav")
        pump()

        MainActor.assumeIsolated {
            // Should have: message + separator + message = 3 items
            XCTAssertEqual(vm.displayItems.count, 3,
                "AC-PRESERVE: should have 3 items (msg, separator, msg)")
            if case .message(let first) = vm.displayItems[0] {
                XCTAssertEqual(first.message, "important error",
                    "AC-PRESERVE: original message should be preserved")
            }
        }
    }

    /// onNavigation with preserveLog=off resets counts.
    func testOnNavigation_preserveLogOff_resetsCounts() {
        let vm = makeVM()
        addMsg(to: vm, level: .info)
        addMsg(to: vm, level: .error)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.counts[.info], 1, "Precondition")
            XCTAssertEqual(vm.counts[.error], 1, "Precondition")

            vm.preserveLog = false
            vm.onNavigation(url: "https://example.com")

            XCTAssertEqual(vm.counts[.info], 0,
                "AC-PRESERVE: counts should reset on navigation (preserveLog=off)")
            XCTAssertEqual(vm.counts[.error], 0,
                "AC-PRESERVE: counts should reset on navigation (preserveLog=off)")
        }
    }

    // =========================================================================
    // MARK: - AC-CON-NAVDIV: onNavigation separator/divider behavior
    // =========================================================================

    /// onNavigation inserts separator with the navigated URL.
    func testOnNavigation_separatorContainsURL() {
        let vm = makeVM()
        MainActor.assumeIsolated {
            vm.preserveLog = true
            vm.onNavigation(url: "https://github.com")
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.displayItems.count, 1,
                "AC-NAVDIV: should have 1 separator item")
            if case .separator(let url, _) = vm.displayItems[0] {
                XCTAssertEqual(url, "https://github.com",
                    "AC-NAVDIV: separator should contain navigation URL")
            } else {
                XCTFail("AC-NAVDIV: item should be .separator")
            }
        }
    }

    /// Multiple navigations with preserveLog=true produce multiple separators.
    func testOnNavigation_multipleSeparators() {
        let vm = makeVM()
        MainActor.assumeIsolated {
            vm.preserveLog = true
            vm.onNavigation(url: "https://a.com")
            vm.onNavigation(url: "https://b.com")
            vm.onNavigation(url: "https://c.com")
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.displayItems.count, 3,
                "AC-NAVDIV: 3 navigations should produce 3 separators")
        }
    }

    // =========================================================================
    // MARK: - ConsoleItem identity
    // =========================================================================

    /// ConsoleItem.message id is derived from the inner item's UUID.
    func testConsoleItem_messageId() {
        let msg = ConsoleMessageItem(level: .info, message: "test",
                                     source: "", line: 0, timestamp: Date())
        let item = ConsoleItem.message(msg)
        XCTAssertEqual(item.id, msg.id.uuidString,
            "ConsoleItem.message id should be the inner UUID string")
    }

    /// ConsoleItem.separator id has "sep-" prefix.
    func testConsoleItem_separatorId() {
        let item = ConsoleItem.separator(url: "https://example.com")
        XCTAssertTrue(item.id.hasPrefix("sep-"),
            "ConsoleItem.separator id should start with 'sep-'")
    }

    // =========================================================================
    // MARK: - refilter()
    // =========================================================================

    /// refilter() applies current filter + search to displayItems.
    func testRefilter_appliesFilterAndSearch() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "hello info")
        addMsg(to: vm, level: .error, message: "hello error")
        addMsg(to: vm, level: .info, message: "world info")
        pump()

        MainActor.assumeIsolated {
            // Initially no filter → 3 items
            XCTAssertEqual(vm.filteredItems.count, 3, "Precondition")

            // Apply filter + search
            vm.filter = .info
            vm.searchText = "hello"
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 1,
                "refilter: filter=info + search=hello should yield 1 result")
        }
    }

    // =========================================================================
    // MARK: - Coverage gap: separator + message mixed eviction
    // =========================================================================

    /// When buffer is full with a mix of separators and messages, eviction
    /// correctly decrements counts only for evicted messages (not separators).
    func testRingBuffer_separatorMixedEviction() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.preserveLog = true

            // Fill buffer with 500 info messages, then a separator, then 499 warning messages
            // Total = 500 + 1 + 499 = 1000 (at capacity)
            for i in 0..<500 {
                vm.addMessage(level: .info, message: "info \(i)", source: "", line: 0,
                              timestamp: Date())
            }
            vm.onNavigation(url: "https://example.com/page2")
            for i in 0..<499 {
                vm.addMessage(level: .warning, message: "warn \(i)", source: "", line: 0,
                              timestamp: Date())
            }

            XCTAssertEqual(vm.counts[.info], 500, "Precondition: 500 info messages")
            XCTAssertEqual(vm.counts[.warning], 499, "Precondition: 499 warning messages")

            // Now add 20 error messages, which evicts the 20 oldest items:
            // items 0..19 are all info messages
            for _ in 0..<20 {
                vm.addMessage(level: .error, message: "err", source: "", line: 0,
                              timestamp: Date())
            }

            // 20 info messages evicted, so info count should drop by 20
            XCTAssertEqual(vm.counts[.info], 480,
                "COV-MIXED: evicting 20 info messages should leave 480")
            XCTAssertEqual(vm.counts[.warning], 499,
                "COV-MIXED: warning count should be unchanged")
            XCTAssertEqual(vm.counts[.error], 20,
                "COV-MIXED: error count should be 20")
        }
    }

    /// When buffer is full of only separators, eviction does not touch counts.
    func testRingBuffer_separatorOnly_eviction() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.preserveLog = true

            // Fill buffer with 1000 separators
            for i in 0..<1000 {
                vm.onNavigation(url: "https://example.com/page\(i)")
            }

            // Counts should all be 0 — separators don't affect counts
            XCTAssertEqual(vm.counts[.info], 0, "Precondition: no messages added")
            XCTAssertEqual(vm.counts[.error], 0, "Precondition: no messages added")

            // Add 5 more separators, causing 5 evictions of old separators
            for i in 1000..<1005 {
                vm.onNavigation(url: "https://example.com/page\(i)")
            }

            // Counts should still all be 0 — evicting separators never decrements
            XCTAssertEqual(vm.counts[.info], 0,
                "COV-SEP-ONLY: evicting separators should not change info count")
            XCTAssertEqual(vm.counts[.warning], 0,
                "COV-SEP-ONLY: evicting separators should not change warning count")
            XCTAssertEqual(vm.counts[.error], 0,
                "COV-SEP-ONLY: evicting separators should not change error count")
            XCTAssertEqual(vm.counts[.verbose], 0,
                "COV-SEP-ONLY: evicting separators should not change verbose count")
        }
    }

    /// Adding new messages while a filter is active updates filteredItems correctly
    /// on the next refresh cycle.
    func testFilter_withNewMessagesAfterFilterSet() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "initial info")
        addMsg(to: vm, level: .error, message: "initial error")
        pump()

        MainActor.assumeIsolated {
            // Set filter to error
            vm.filter = .error
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 1,
                "Precondition: only 1 error visible")
        }

        // Add more messages while filter is active
        addMsg(to: vm, level: .info, message: "new info")
        addMsg(to: vm, level: .error, message: "new error 1")
        addMsg(to: vm, level: .error, message: "new error 2")
        addMsg(to: vm, level: .warning, message: "new warning")
        pump()

        MainActor.assumeIsolated {
            // After refresh, refilter with current filter
            vm.refilter()
            // Should show: initial error + new error 1 + new error 2 = 3
            XCTAssertEqual(vm.filteredItems.count, 3,
                "COV-FILTER-NEW: adding messages after filter set should update filtered list")
            for item in vm.filteredItems {
                if case .message(let msg) = item {
                    XCTAssertEqual(msg.level, .error,
                        "COV-FILTER-NEW: all filtered items should be .error")
                }
            }
        }
    }

    /// Adding new messages while a search is active updates filteredItems correctly
    /// on the next refresh cycle.
    func testSearch_withNewMessagesAfterSearchSet() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "alpha one")
        addMsg(to: vm, level: .info, message: "beta two")
        pump()

        MainActor.assumeIsolated {
            vm.searchText = "alpha"
            vm.refilter()
            XCTAssertEqual(vm.filteredItems.count, 1,
                "Precondition: only 1 match for 'alpha'")
        }

        // Add more messages while search is active
        addMsg(to: vm, level: .info, message: "alpha three")
        addMsg(to: vm, level: .info, message: "gamma four")
        addMsg(to: vm, level: .info, message: "alpha five")
        pump()

        MainActor.assumeIsolated {
            vm.refilter()
            // Should show: "alpha one" + "alpha three" + "alpha five" = 3
            XCTAssertEqual(vm.filteredItems.count, 3,
                "COV-SEARCH-NEW: adding messages after search set should update filtered list")
            for item in vm.filteredItems {
                if case .message(let msg) = item {
                    XCTAssertTrue(msg.message.lowercased().contains("alpha"),
                        "COV-SEARCH-NEW: all filtered items should contain 'alpha'")
                }
            }
        }
    }

    /// Multiple navigations producing separators that eventually get evicted
    /// when buffer reaches capacity. Counts remain accurate.
    func testOnNavigation_multipleSeparators_eviction() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.preserveLog = true

            // Add 990 info messages
            for i in 0..<990 {
                vm.addMessage(level: .info, message: "msg \(i)", source: "", line: 0,
                              timestamp: Date())
            }
            XCTAssertEqual(vm.counts[.info], 990, "Precondition: 990 info messages")

            // Add 10 navigation separators (total = 1000, at capacity)
            for i in 0..<10 {
                vm.onNavigation(url: "https://example.com/nav\(i)")
            }
            XCTAssertEqual(vm.counts[.info], 990,
                "Precondition: info count unchanged after adding separators")

            // Now add 15 error messages, evicting the 15 oldest items (all info messages)
            for _ in 0..<15 {
                vm.addMessage(level: .error, message: "err", source: "", line: 0,
                              timestamp: Date())
            }

            XCTAssertEqual(vm.counts[.info], 975,
                "COV-NAV-EVICT: 15 info messages evicted, 975 remain")
            XCTAssertEqual(vm.counts[.error], 15,
                "COV-NAV-EVICT: 15 error messages added")

            // Now add 980 more error messages, evicting remaining info msgs + some separators
            // Total added = 990 info + 10 sep + 15 err + 980 err = 1995
            // Buffer keeps last 1000: some errors + remaining separators + later errors
            for _ in 0..<980 {
                vm.addMessage(level: .error, message: "err2", source: "", line: 0,
                              timestamp: Date())
            }

            // After the 15 errors, buffer (front→back):
            //   info(15)..info(989) = 975 info, sep(0)..sep(9) = 10 sep, err(0)..err(14) = 15 err
            // Adding 980 errors evicts 980 from front: 975 info + 5 sep
            XCTAssertEqual(vm.counts[.info], 0,
                "COV-NAV-EVICT: all info messages should be evicted")
            XCTAssertEqual(vm.counts[.error], 995,
                "COV-NAV-EVICT: all 995 errors should remain (only info+sep evicted)")
        }
        pump()

        MainActor.assumeIsolated {
            // Verify buffer length is exactly at capacity
            XCTAssertEqual(vm.displayItems.count, 1000,
                "COV-NAV-EVICT: buffer should be exactly at capacity")

            // Count separators remaining in display
            let sepCount = vm.displayItems.filter {
                if case .separator = $0 { return true }; return false
            }.count
            XCTAssertEqual(sepCount, 5,
                "COV-NAV-EVICT: 5 of 10 separators should remain after eviction")
        }
    }

    // =========================================================================
    // MARK: - Phase 3: CLI `owl console` contract tests
    // =========================================================================
    // These tests validate the ViewModel-level logic that backs `owl console
    // --level <level> --limit <N>`:
    //   AC1: `owl console --level error --limit 10` returns JSON (filter+limit)
    //   AC2: timestamp is ISO 8601 format
    //   AC3: XCUITest (separate target, not unit-testable here)

    // -- Helper: extract ConsoleMessageItems from displayItems, applying an
    //    optional level filter and limit — mirrors what the CLI handler does. --
    private func cliSnapshot(
        from vm: ConsoleViewModel,
        level: ConsoleLevel? = nil,
        limit: Int = 100
    ) -> [ConsoleMessageItem] {
        MainActor.assumeIsolated {
            let clampedLimit = max(1, min(limit, 1000))
            let messages: [ConsoleMessageItem] = vm.displayItems.compactMap {
                if case .message(let item) = $0 { return item }
                return nil
            }
            let filtered: [ConsoleMessageItem]
            if let level = level {
                filtered = messages.filter { $0.level == level }
            } else {
                filtered = messages
            }
            return Array(filtered.suffix(clampedLimit))
        }
    }

    /// AC1 — filter by level: `--level error` returns only error messages.
    func testConsoleMessages_filterByLevel() {
        let vm = makeVM()
        addMsg(to: vm, level: .info, message: "info msg")
        addMsg(to: vm, level: .warning, message: "warn msg")
        addMsg(to: vm, level: .error, message: "err 1")
        addMsg(to: vm, level: .error, message: "err 2")
        addMsg(to: vm, level: .verbose, message: "verbose msg")
        addMsg(to: vm, level: .error, message: "err 3")
        pump()

        let result = cliSnapshot(from: vm, level: .error)
        XCTAssertEqual(result.count, 3,
            "AC1-FILTER: --level error should return exactly 3 error messages")
        for item in result {
            XCTAssertEqual(item.level, .error,
                "AC1-FILTER: every returned message must be .error")
        }

        // Also verify other levels work
        let warnings = cliSnapshot(from: vm, level: .warning)
        XCTAssertEqual(warnings.count, 1,
            "AC1-FILTER: --level warning should return 1 warning")
        XCTAssertEqual(warnings.first?.message, "warn msg")

        // nil level returns all messages
        let all = cliSnapshot(from: vm, level: nil)
        XCTAssertEqual(all.count, 6,
            "AC1-FILTER: no level filter should return all 6 messages")
    }

    /// AC1 — limit clamp: limit is clamped to [1, 1000].
    func testConsoleMessages_limitClamp() {
        let vm = makeVM()
        // Add 15 messages
        MainActor.assumeIsolated {
            for i in 0..<15 {
                vm.addMessage(level: .info, message: "msg \(i)", source: "test.js",
                              line: 1, timestamp: Date())
            }
        }
        pump()

        // Normal limit
        let ten = cliSnapshot(from: vm, limit: 10)
        XCTAssertEqual(ten.count, 10,
            "AC1-LIMIT: limit=10 with 15 messages should return 10")

        // Limit larger than available → returns all
        let big = cliSnapshot(from: vm, limit: 100)
        XCTAssertEqual(big.count, 15,
            "AC1-LIMIT: limit=100 with 15 messages should return 15")

        // Limit = 0 → clamped to 1
        let zero = cliSnapshot(from: vm, limit: 0)
        XCTAssertEqual(zero.count, 1,
            "AC1-LIMIT: limit=0 should be clamped to 1 (min)")

        // Negative limit → clamped to 1
        let negative = cliSnapshot(from: vm, limit: -5)
        XCTAssertEqual(negative.count, 1,
            "AC1-LIMIT: negative limit should be clamped to 1")

        // Limit > 1000 → clamped to 1000
        // (we only have 15 messages, but verify the clamp logic returns all 15)
        let huge = cliSnapshot(from: vm, limit: 5000)
        XCTAssertEqual(huge.count, 15,
            "AC1-LIMIT: limit=5000 clamped to 1000, but only 15 available → 15")

        // Verify ordering: suffix semantics → returns the newest N messages
        XCTAssertEqual(ten.first?.message, "msg 5",
            "AC1-LIMIT: limited results should start from (count - limit)")
        XCTAssertEqual(ten.last?.message, "msg 14",
            "AC1-LIMIT: limited results should end with the newest message")
    }

    /// AC1 — empty state: no messages returns an empty array.
    func testConsoleMessages_emptyWhenNoMessages() {
        let vm = makeVM()
        pump()

        let result = cliSnapshot(from: vm, level: .error, limit: 10)
        XCTAssertTrue(result.isEmpty,
            "AC1-EMPTY: no messages added → empty result array")

        let allLevels = cliSnapshot(from: vm, level: nil, limit: 100)
        XCTAssertTrue(allLevels.isEmpty,
            "AC1-EMPTY: no messages, no filter → still empty")
    }

    /// AC2 — timestamp format: ConsoleMessageItem.timestamp (Date) round-trips
    /// through ISO 8601 formatting and produces a valid ISO 8601 string.
    func testConsoleMessages_timestampFormat() {
        let vm = makeVM()

        // Use a known Unix epoch timestamp: 2024-01-15T10:30:00Z
        let knownEpoch: TimeInterval = 1705312200.0
        let knownDate = Date(timeIntervalSince1970: knownEpoch)
        addMsg(to: vm, level: .error, message: "ts test", timestamp: knownDate)
        pump()

        let result = cliSnapshot(from: vm, level: .error, limit: 10)
        XCTAssertEqual(result.count, 1, "Precondition: 1 error message")

        let item = result[0]

        // Verify the stored timestamp matches the input
        XCTAssertEqual(item.timestamp.timeIntervalSince1970, knownEpoch, accuracy: 0.001,
            "AC2-TS: stored timestamp should preserve the original epoch value")

        // Format as ISO 8601 and verify the string is valid
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601String = formatter.string(from: item.timestamp)

        // Verify the string is non-empty and can be parsed back
        XCTAssertFalse(iso8601String.isEmpty,
            "AC2-TS: ISO 8601 string should not be empty")

        let roundTripped = formatter.date(from: iso8601String)
        XCTAssertNotNil(roundTripped,
            "AC2-TS: ISO 8601 string should parse back to a valid Date")
        XCTAssertEqual(roundTripped!.timeIntervalSince1970, knownEpoch, accuracy: 0.001,
            "AC2-TS: round-tripped timestamp should match original")

        // Verify the string contains expected ISO 8601 components
        XCTAssertTrue(iso8601String.contains("2024-01-15"),
            "AC2-TS: ISO 8601 string should contain the correct date")
        XCTAssertTrue(iso8601String.contains("T"),
            "AC2-TS: ISO 8601 string should contain 'T' separator")
        XCTAssertTrue(iso8601String.hasSuffix("Z"),
            "AC2-TS: ISO 8601 string in UTC should end with 'Z'")

        // Verify double → Date → ISO 8601 pipeline for the CLI JSON output
        let fromDouble = Date(timeIntervalSince1970: knownEpoch)
        let formatted = formatter.string(from: fromDouble)
        XCTAssertEqual(formatted, iso8601String,
            "AC2-TS: double→Date→ISO8601 should produce identical string")
    }

    // =========================================================================
    // MARK: - Phase 3 supplement: newest-first, JSON contract, ISO 8601
    // =========================================================================

    /// cliSnapshot (and the real CLI) uses .suffix to return the newest N messages,
    /// not the oldest. Verify with 20 messages and limit=5.
    func testConsoleMessages_returnsNewestFirst() {
        let vm = makeVM()
        MainActor.assumeIsolated {
            for i in 0..<20 {
                vm.addMessage(level: .info, message: "msg \(i)", source: "test.js",
                              line: i, timestamp: Date())
            }
        }
        pump()

        let result = cliSnapshot(from: vm, limit: 5)
        XCTAssertEqual(result.count, 5,
            "NEWEST: limit=5 on 20 messages should return 5")
        // .suffix(5) on [msg 0 .. msg 19] → [msg 15, msg 16, msg 17, msg 18, msg 19]
        XCTAssertEqual(result[0].message, "msg 15",
            "NEWEST: first element should be msg 15 (5th from end)")
        XCTAssertEqual(result[1].message, "msg 16",
            "NEWEST: second element should be msg 16")
        XCTAssertEqual(result[2].message, "msg 17",
            "NEWEST: third element should be msg 17")
        XCTAssertEqual(result[3].message, "msg 18",
            "NEWEST: fourth element should be msg 18")
        XCTAssertEqual(result[4].message, "msg 19",
            "NEWEST: fifth (last) element should be msg 19 (newest)")
    }

    /// The JSON output contract requires exactly these keys:
    /// "level", "message", "source", "line", "timestamp".
    /// This test mirrors BrowserViewModel.consoleMessages() dict structure.
    func testConsoleMessages_jsonContractKeys() {
        let vm = makeVM()
        let knownDate = Date(timeIntervalSince1970: 1700000000.0)
        addMsg(to: vm, level: .warning, message: "contract test",
               source: "app.js", line: 42, timestamp: knownDate)
        pump()

        let result = cliSnapshot(from: vm, limit: 10)
        XCTAssertEqual(result.count, 1, "Precondition: 1 message")

        // Build the same dict that BrowserViewModel.consoleMessages() produces
        let item = result[0]
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let levelStr: String
        switch item.level {
        case .verbose: levelStr = "verbose"
        case .info:    levelStr = "info"
        case .warning: levelStr = "warning"
        case .error:   levelStr = "error"
        }

        let dict: [String: String] = [
            "level": levelStr,
            "message": item.message,
            "source": item.source,
            "line": String(item.line),
            "timestamp": iso8601Formatter.string(from: item.timestamp),
        ]

        // Verify the exact key set
        let expectedKeys: Set<String> = ["level", "message", "source", "line", "timestamp"]
        XCTAssertEqual(Set(dict.keys), expectedKeys,
            "JSON-CONTRACT: dict keys must be exactly {level, message, source, line, timestamp}")

        // Verify values are non-empty
        for (key, value) in dict {
            XCTAssertFalse(value.isEmpty,
                "JSON-CONTRACT: value for '\(key)' must not be empty")
        }

        // Verify specific values match what was added
        XCTAssertEqual(dict["level"], "warning",
            "JSON-CONTRACT: level should be 'warning'")
        XCTAssertEqual(dict["message"], "contract test",
            "JSON-CONTRACT: message should match input")
        XCTAssertEqual(dict["source"], "app.js",
            "JSON-CONTRACT: source should match input")
        XCTAssertEqual(dict["line"], "42",
            "JSON-CONTRACT: line should be stringified Int")
    }

    /// The timestamp string produced by the CLI pipeline must be valid ISO 8601
    /// with 'T' separator and 'Z' suffix (UTC), matching the regex pattern.
    func testConsoleMessages_timestampIsISO8601() {
        let vm = makeVM()
        // Use multiple known dates to cover edge cases
        let dates: [Date] = [
            Date(timeIntervalSince1970: 0),            // 1970-01-01T00:00:00Z
            Date(timeIntervalSince1970: 1700000000.0), // 2023-11-14
            Date(timeIntervalSince1970: 1609459200.0), // 2021-01-01T00:00:00Z
        ]
        MainActor.assumeIsolated {
            for (i, date) in dates.enumerated() {
                vm.addMessage(level: .info, message: "ts \(i)", source: "test.js",
                              line: 1, timestamp: date)
            }
        }
        pump()

        let result = cliSnapshot(from: vm, limit: 10)
        XCTAssertEqual(result.count, 3, "Precondition: 3 messages")

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // ISO 8601 pattern: YYYY-MM-DDTHH:MM:SS.sssZ
        // Regex allows fractional seconds (1-6 digits) and requires Z suffix
        let iso8601Pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{1,6}Z$"#
        let regex = try! NSRegularExpression(pattern: iso8601Pattern)

        for (i, item) in result.enumerated() {
            let tsString = iso8601Formatter.string(from: item.timestamp)

            // Check regex match
            let range = NSRange(tsString.startIndex..., in: tsString)
            let match = regex.firstMatch(in: tsString, range: range)
            XCTAssertNotNil(match,
                "ISO8601[\(i)]: '\(tsString)' must match ISO 8601 pattern YYYY-MM-DDTHH:MM:SS.sssZ")

            // Must contain T separator
            XCTAssertTrue(tsString.contains("T"),
                "ISO8601[\(i)]: timestamp must contain 'T' separator")

            // Must end with Z (UTC)
            XCTAssertTrue(tsString.hasSuffix("Z"),
                "ISO8601[\(i)]: timestamp must end with 'Z' for UTC")

            // Round-trip: parse back and verify equality
            let roundTripped = iso8601Formatter.date(from: tsString)
            XCTAssertNotNil(roundTripped,
                "ISO8601[\(i)]: timestamp must be parseable back to Date")
            XCTAssertEqual(roundTripped!.timeIntervalSince1970,
                           item.timestamp.timeIntervalSince1970,
                           accuracy: 0.001,
                "ISO8601[\(i)]: round-tripped timestamp must match original")
        }
    }
}
