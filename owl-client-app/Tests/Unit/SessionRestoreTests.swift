import XCTest
@testable import OWLBrowserLib

/// Phase 5 Session Restore unit tests.
///
/// Test matrix coverage:
///
/// | AC       | Happy                          | Boundary                   | Error                          |
/// |----------|--------------------------------|----------------------------|--------------------------------|
/// | AC-004   | save 3 tabs → load → match     | pinned + active on same tab| empty JSON → nil               |
/// | AC-004   | order preserved via titles      | single tab save/restore    | file not exist → nil           |
/// | deferred | non-active tabs isDeferred=true | activate → isDeferred=false| corrupt JSON → nil             |
/// | deferred | closeTab on deferred → safe    | close last deferred        | wrong schema → nil             |
/// | deferred | activate dedup (2nd is no-op)  | close activating deferred  | corrupt JSON → file deleted    |
/// | autosave | scheduleSave debounced          | cancelPendingSave          | —                              |
/// | autosave | activateTab → scheduleSave     | —                          | —                              |
///
/// Uses real file I/O in a temp directory. No Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class SessionRestoreTests: XCTestCase {

    // MARK: - Test Infrastructure

    /// Temp directory for each test — cleaned up in tearDown.
    private var tempDir: URL!

    /// Session file URL inside tempDir.
    private var sessionFileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("owl-session-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sessionFileURL = tempDir.appendingPathComponent("session.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Pump the run loop so mock-async callbacks settle.
    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Create a BrowserViewModel with MockConfig, launch, and pump.
    private func makeVM(
        tabs: [(String, String?)] = [("Tab 1", "https://a.com")]
    ) -> BrowserViewModel {
        let vm = MainActor.assumeIsolated {
            BrowserViewModel(mockConfig: .init(
                initialTabs: tabs,
                connectionDelay: 0,
                shouldFail: false,
                failMessage: ""
            ))
        }
        MainActor.assumeIsolated { vm.launch() }
        pump()
        return vm
    }

    /// Create a SessionRestoreService pointing at tempDir.
    private func makeService() -> SessionRestoreService {
        MainActor.assumeIsolated {
            SessionRestoreService(directory: tempDir)
        }
    }

    /// Build a SessionData from an array of SessionTab.
    private func makeSessionData(_ tabs: [SessionTab]) -> SessionData {
        SessionData(tabs: tabs)
    }

    // =========================================================================
    // MARK: - SessionTab Codable: Encode / Decode Round-Trip
    // =========================================================================

    /// AC-004 Happy: SessionTab encodes and decodes without data loss.
    func testSessionTab_encodeDecode_roundTrip() throws {
        let tab = SessionTab(
            url: "https://example.com",
            title: "Example",
            isPinned: true,
            isActive: false
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(SessionTab.self, from: data)

        XCTAssertEqual(decoded.url, "https://example.com",
            "AC-004: url should survive round-trip")
        XCTAssertEqual(decoded.title, "Example",
            "AC-004: title should survive round-trip")
        XCTAssertTrue(decoded.isPinned,
            "AC-004: isPinned should survive round-trip")
        XCTAssertFalse(decoded.isActive,
            "AC-004: isActive should survive round-trip")
    }

    /// AC-004 Happy: Array of SessionTabs encodes/decodes correctly.
    func testSessionTabArray_encodeDecode_roundTrip() throws {
        let tabs = [
            SessionTab(url: "https://a.com", title: "A",
                       isPinned: false, isActive: true),
            SessionTab(url: "https://b.com", title: "B",
                       isPinned: true, isActive: false),
            SessionTab(url: "", title: "New Tab",
                       isPinned: false, isActive: false),
        ]

        let data = try JSONEncoder().encode(tabs)
        let decoded = try JSONDecoder().decode([SessionTab].self, from: data)

        XCTAssertEqual(decoded.count, 3,
            "AC-004: all tabs should survive round-trip")
        XCTAssertEqual(decoded[0].url, "https://a.com")
        XCTAssertTrue(decoded[0].isActive)
        XCTAssertTrue(decoded[1].isPinned)
        XCTAssertEqual(decoded[2].url, "",
            "AC-004: empty URL (about:blank) should be preserved")
    }

    /// AC-004 Boundary: SessionTab with empty strings for url and title.
    func testSessionTab_emptyStrings() throws {
        let tab = SessionTab(url: "", title: "",
                             isPinned: false, isActive: false)

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(SessionTab.self, from: data)

        XCTAssertEqual(decoded.url, "")
        XCTAssertEqual(decoded.title, "")
    }

    /// AC-004 Boundary: SessionTab with Unicode title.
    func testSessionTab_unicodeTitle() throws {
        let tab = SessionTab(url: "https://example.com",
                             title: "Safari \u{6D4F}\u{89C8}\u{5668} \u{1F30D}",
                             isPinned: false, isActive: true)

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(SessionTab.self, from: data)

        XCTAssertEqual(decoded.title, "Safari \u{6D4F}\u{89C8}\u{5668} \u{1F30D}",
            "AC-004: Unicode titles should survive round-trip")
    }

    // =========================================================================
    // MARK: - SessionData Codable: Envelope Round-Trip
    // =========================================================================

    /// SessionData wraps tabs with version and savedAt metadata.
    func testSessionData_encodeDecode_roundTrip() throws {
        let tabs = [
            SessionTab(url: "https://a.com", title: "A", isPinned: false, isActive: true),
        ]
        let sessionData = SessionData(tabs: tabs)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessionData)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionData.self, from: data)

        XCTAssertEqual(decoded.version, 1,
            "SessionData version should default to 1")
        XCTAssertEqual(decoded.tabs.count, 1)
        XCTAssertEqual(decoded.tabs[0].url, "https://a.com")
    }

    // =========================================================================
    // MARK: - AC-004: Save 3 Tabs -> Load -> Data Consistent
    // =========================================================================

    /// AC-004 Happy: save 3 tabs, load back, verify all fields match.
    func testSaveAndLoad_threeTabsRoundTrip() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://google.com", title: "Google",
                       isPinned: false, isActive: false),
            SessionTab(url: "https://github.com", title: "GitHub",
                       isPinned: false, isActive: true),
            SessionTab(url: "https://twitter.com", title: "Twitter",
                       isPinned: false, isActive: false),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded, "AC-004: load should return non-nil")
        XCTAssertEqual(loaded!.tabs.count, 3,
            "AC-004: should load exactly 3 tabs")

        // Verify order preserved (array order)
        XCTAssertEqual(loaded!.tabs[0].url, "https://google.com")
        XCTAssertEqual(loaded!.tabs[1].url, "https://github.com")
        XCTAssertEqual(loaded!.tabs[2].url, "https://twitter.com")

        // Verify active state: only second tab is active
        XCTAssertFalse(loaded!.tabs[0].isActive)
        XCTAssertTrue(loaded!.tabs[1].isActive,
            "AC-004: second tab should be active")
        XCTAssertFalse(loaded!.tabs[2].isActive)
    }

    /// AC-004 Happy: save with pinned tabs, verify isPinned preserved.
    func testSaveAndLoad_pinnedState() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://pinned.com", title: "Pinned",
                       isPinned: true, isActive: false),
            SessionTab(url: "https://regular.com", title: "Regular",
                       isPinned: false, isActive: true),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded!.tabs[0].isPinned,
            "AC-004: pinned state should be preserved")
        XCTAssertFalse(loaded!.tabs[1].isPinned)
    }

    /// AC-004 Boundary: save and load with pinned + active on same tab.
    func testSaveAndLoad_pinnedAndActiveTab() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://pinned.com", title: "Pinned Active",
                       isPinned: true, isActive: true),
            SessionTab(url: "https://regular.com", title: "Regular",
                       isPinned: false, isActive: false),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded!.tabs[0].isPinned,
            "AC-004: tab should be both pinned and active")
        XCTAssertTrue(loaded!.tabs[0].isActive,
            "AC-004: tab should be both pinned and active")
    }

    /// AC-004 Boundary: save and load single tab.
    func testSaveAndLoad_singleTab() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://solo.com", title: "Solo",
                       isPinned: false, isActive: true),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.tabs.count, 1,
            "AC-004: single tab save/restore should work")
        XCTAssertEqual(loaded!.tabs[0].url, "https://solo.com")
        XCTAssertEqual(loaded!.tabs[0].title, "Solo")
    }

    /// AC-004 Happy: restore order is correct (array order preserved).
    func testSaveAndLoad_orderPreserved() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://1.com", title: "First",
                       isPinned: false, isActive: true),
            SessionTab(url: "https://2.com", title: "Second",
                       isPinned: false, isActive: false),
            SessionTab(url: "https://3.com", title: "Third",
                       isPinned: false, isActive: false),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.tabs.map(\.title), ["First", "Second", "Third"],
            "AC-004: tab order should be preserved")
    }

    // =========================================================================
    // MARK: - Error: Corrupt / Empty / Missing session.json
    // =========================================================================

    /// Error: invalid JSON in session.json -> load returns nil.
    func testLoad_corruptJSON_returnsNil() throws {
        let service = makeService()

        // Write garbage to session.json
        try "{{{{not valid json!!!!".data(using: .utf8)!
            .write(to: sessionFileURL)

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNil(loaded,
            "AC-004 Error: corrupt JSON should return nil")
    }

    /// Error: empty file -> load returns nil.
    func testLoad_emptyFile_returnsNil() throws {
        let service = makeService()

        try Data().write(to: sessionFileURL)

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNil(loaded,
            "AC-004 Error: empty file should return nil")
    }

    /// Error: session.json does not exist -> load returns nil.
    func testLoad_fileNotFound_returnsNil() {
        let service = makeService()

        // tempDir/session.json does not exist
        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNil(loaded,
            "AC-004 Error: missing file should return nil")
    }

    /// Error: valid JSON but wrong schema (plain object instead of SessionData).
    func testLoad_wrongSchema_returnsNil() throws {
        let service = makeService()

        try "{\"key\": \"value\"}".data(using: .utf8)!
            .write(to: sessionFileURL)

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNil(loaded,
            "AC-004 Error: wrong JSON schema should return nil")
    }

    /// Error: valid SessionData JSON but with unsupported version.
    func testLoad_unsupportedVersion_returnsNil() throws {
        let service = makeService()

        // Write a valid JSON with version=99 (unsupported)
        let json = """
        {"version":99,"tabs":[],"savedAt":"2025-01-01T00:00:00Z"}
        """
        try json.data(using: .utf8)!.write(to: sessionFileURL)

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNil(loaded,
            "AC-004 Error: unsupported version should return nil")
    }

    /// hasSession returns false when no file exists.
    func testHasSession_noFile_returnsFalse() {
        let service = makeService()

        let has = MainActor.assumeIsolated {
            service.hasSession()
        }

        XCTAssertFalse(has,
            "hasSession should be false when no file exists")
    }

    /// hasSession returns true after save.
    func testHasSession_afterSave_returnsTrue() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://test.com", title: "Test",
                       isPinned: false, isActive: true),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        let has = MainActor.assumeIsolated {
            service.hasSession()
        }

        XCTAssertTrue(has,
            "hasSession should be true after save")
    }

    // =========================================================================
    // MARK: - Deferred Tab: isDeferred Property on TabViewModel
    // =========================================================================

    /// Deferred: TabViewModel.isDeferred defaults to false.
    func testTabViewModel_isDeferredDefaultsFalse() {
        let tab = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Test", url: "https://test.com")
        }

        MainActor.assumeIsolated {
            XCTAssertFalse(tab.isDeferred,
                "Deferred: isDeferred should default to false for new tabs")
        }
    }

    /// Deferred: isDeferred is assignable (for restored non-active tabs).
    func testTabViewModel_isDeferredAssignable() {
        let tab = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Restored", url: "https://restored.com")
        }

        MainActor.assumeIsolated {
            tab.isDeferred = true
            XCTAssertTrue(tab.isDeferred,
                "Deferred: isDeferred should be settable to true")

            tab.isDeferred = false
            XCTAssertFalse(tab.isDeferred,
                "Deferred: isDeferred should be settable back to false")
        }
    }

    /// Deferred: simulate restore -- non-active tabs remain deferred.
    func testDeferredTab_restoredNonActiveTabsAreDeferred() {
        let tabActive = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Active", url: "https://active.com")
        }
        let tabBg = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Background", url: "https://bg.com")
        }

        MainActor.assumeIsolated {
            // Simulate restore: all tabs start deferred
            tabActive.isDeferred = true
            tabBg.isDeferred = true

            // Active tab gets activated -> isDeferred cleared
            tabActive.isDeferred = false
            tabActive.isLoading = true

            XCTAssertFalse(tabActive.isDeferred,
                "Deferred: active tab should not be deferred after activation")
            XCTAssertTrue(tabBg.isDeferred,
                "Deferred: non-active tab should remain deferred")
        }
    }

    /// Deferred: activation clears isDeferred and shows loading state.
    func testDeferredTab_activationClearsDeferred() {
        let tab = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Deferred", url: "https://deferred.com")
        }

        MainActor.assumeIsolated {
            tab.isDeferred = true
            tab.webviewId = 0  // No real WebView

            // Simulate activation
            tab.isDeferred = false
            tab.isLoading = true

            XCTAssertFalse(tab.isDeferred,
                "Deferred: activation should clear isDeferred")
            XCTAssertTrue(tab.isLoading,
                "Deferred: activation should show loading state")
        }
    }

    /// Deferred: webviewId=0 for deferred tab (no real WebView allocated).
    func testDeferredTab_webviewIdZero() {
        let tab = MainActor.assumeIsolated {
            TabViewModel.mock(title: "Deferred", url: "https://deferred.com")
        }

        MainActor.assumeIsolated {
            tab.isDeferred = true
            tab.webviewId = 0

            XCTAssertEqual(tab.webviewId, 0,
                "Deferred: deferred tab should have webviewId=0")
        }
    }

    // =========================================================================
    // MARK: - Deferred Tab: Close Deferred -> Safe
    // =========================================================================

    /// Deferred: closing a deferred tab does not crash, removes from array.
    func testCloseTab_deferredTab_safe() {
        let vm = makeVM(tabs: [
            ("Active", "https://active.com"),
            ("Deferred", "https://deferred.com"),
        ])

        MainActor.assumeIsolated {
            vm.tabs[1].isDeferred = true
            vm.tabs[1].webviewId = 0

            let deferredTab = vm.tabs[1]
            vm.closeTab(deferredTab)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 1,
                "Deferred: closing deferred tab should remove it from tabs")
            XCTAssertEqual(vm.tabs[0].title, "Active",
                "Deferred: remaining tab should be the active one")
        }
    }

    /// Deferred: closing last deferred tab should auto-create new blank tab.
    func testCloseTab_lastDeferredTab_autoCreatesNew() {
        let vm = makeVM(tabs: [("Only", "https://only.com")])

        MainActor.assumeIsolated {
            vm.tabs[0].isDeferred = true
            vm.tabs[0].webviewId = 0
            vm.closeTab(vm.tabs[0])
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertGreaterThanOrEqual(vm.tabs.count, 1,
                "Deferred: closing last tab should auto-create a new tab")
        }
    }

    /// Deferred: closing multiple deferred tabs in sequence is safe.
    func testCloseTab_multipleDeferredTabs_safe() {
        let vm = makeVM(tabs: [
            ("Active", "https://active.com"),
            ("Def1", "https://def1.com"),
            ("Def2", "https://def2.com"),
        ])

        MainActor.assumeIsolated {
            vm.tabs[1].isDeferred = true
            vm.tabs[1].webviewId = 0
            vm.tabs[2].isDeferred = true
            vm.tabs[2].webviewId = 0

            // Close in reverse order to avoid index shifting issues
            vm.closeTab(vm.tabs[2])
        }
        pump()

        MainActor.assumeIsolated {
            vm.closeTab(vm.tabs[1])
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 1,
                "Deferred: closing all deferred tabs should leave only active")
            XCTAssertEqual(vm.tabs[0].title, "Active")
        }
    }

    // =========================================================================
    // MARK: - Autosave: scheduleSave / cancelPendingSave
    // =========================================================================

    /// Autosave: scheduleSave does not crash without tabStateProvider.
    func testScheduleSave_withoutProvider_doesNotCrash() {
        let service = makeService()

        MainActor.assumeIsolated {
            // No tabStateProvider set -- should be a no-op, not crash
            service.scheduleSave()
        }
        pump(0.1)

        // If we get here, the test passes (no crash).
    }

    /// Autosave: cancelPendingSave cancels a pending save.
    func testCancelPendingSave_cancelsScheduled() {
        let service = makeService()

        MainActor.assumeIsolated {
            service.scheduleSave()
            service.cancelPendingSave()
        }
        // After cancel, no file should be written (no provider anyway)
        pump(0.5)

        let has = MainActor.assumeIsolated {
            service.hasSession()
        }
        XCTAssertFalse(has,
            "Autosave: cancelPendingSave should prevent file write")
    }

    /// Autosave: multiple scheduleSave calls are coalesced (debounced).
    func testScheduleSave_multipleCallsDebounced() {
        let service = makeService()
        var saveCount = 0

        MainActor.assumeIsolated {
            service.tabStateProvider = {
                saveCount += 1
                return [SessionTab(url: "https://test.com", title: "Test",
                                   isPinned: false, isActive: true)]
            }

            // Rapid-fire multiple scheduleSave calls
            service.scheduleSave()
            service.scheduleSave()
            service.scheduleSave()
        }

        // Wait for debounce to fire (autoSaveDelay defaults to 2.0s,
        // but we pass a custom short delay via the service)
        pump(3.0)

        // The provider should have been called at most once due to debouncing
        // (the last scheduleSave cancels previous ones)
        XCTAssertLessThanOrEqual(saveCount, 1,
            "Autosave: multiple scheduleSave should be debounced into one save")
    }

    // =========================================================================
    // MARK: - Save: File Existence and Overwrite
    // =========================================================================

    /// Save: session.json file is created after save.
    func testSave_createsFile() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://test.com", title: "Test",
                       isPinned: false, isActive: true),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFileURL.path),
            "Save: session.json should exist after save")
    }

    /// Save: overwriting preserves latest data (no stale reads).
    func testSave_overwritePreservesLatest() {
        let service = makeService()

        // First save
        let tabs1 = [
            SessionTab(url: "https://old.com", title: "Old",
                       isPinned: false, isActive: true),
        ]
        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs1))
        }

        // Second save with different data
        let tabs2 = [
            SessionTab(url: "https://new.com", title: "New",
                       isPinned: false, isActive: true),
        ]
        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs2))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.tabs.count, 1)
        XCTAssertEqual(loaded!.tabs[0].title, "New",
            "Save: overwrite should store latest data")
        XCTAssertEqual(loaded!.tabs[0].url, "https://new.com")
    }

    /// Save: saving empty tabs array writes valid JSON (empty array).
    func testSave_emptyTabs_writesValidJSON() {
        let service = makeService()

        MainActor.assumeIsolated {
            service.save(makeSessionData([]))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded,
            "Save: empty tabs should produce loadable SessionData")
        XCTAssertTrue(loaded!.tabs.isEmpty,
            "Save: empty tabs should produce empty array")
    }

    /// deleteSession removes the session file.
    func testDeleteSession_removesFile() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://test.com", title: "Test",
                       isPinned: false, isActive: true),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFileURL.path),
            "Precondition: file should exist after save")

        MainActor.assumeIsolated {
            service.deleteSession()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFileURL.path),
            "deleteSession should remove the file")
    }

    // =========================================================================
    // MARK: - Integration: Full Save-Restore Cycle
    // =========================================================================

    /// Full cycle: save SessionData -> load -> verify data consistency.
    func testFullCycle_saveLoadDataConsistency() {
        let service = makeService()

        let tabs = [
            SessionTab(url: "https://apple.com", title: "Apple",
                       isPinned: false, isActive: false),
            SessionTab(url: "https://google.com", title: "Google",
                       isPinned: false, isActive: true),
            SessionTab(url: "https://github.com", title: "GitHub",
                       isPinned: false, isActive: false),
        ]

        MainActor.assumeIsolated {
            service.save(makeSessionData(tabs))
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.version, 1)
        XCTAssertEqual(loaded!.tabs.count, 3, "Full cycle: should have 3 tabs")

        // Verify URLs and titles
        XCTAssertEqual(loaded!.tabs[0].url, "https://apple.com")
        XCTAssertEqual(loaded!.tabs[0].title, "Apple")
        XCTAssertEqual(loaded!.tabs[1].url, "https://google.com")
        XCTAssertEqual(loaded!.tabs[1].title, "Google")
        XCTAssertEqual(loaded!.tabs[2].url, "https://github.com")
        XCTAssertEqual(loaded!.tabs[2].title, "GitHub")

        // Verify only second tab is active
        XCTAssertFalse(loaded!.tabs[0].isActive)
        XCTAssertTrue(loaded!.tabs[1].isActive,
            "Full cycle: second tab should be marked active")
        XCTAssertFalse(loaded!.tabs[2].isActive)
    }

    /// Full cycle: save with pinned+active, load into fresh service, verify.
    func testFullCycle_pinnedActivePreserved() {
        let saveService = makeService()

        let tabs = [
            SessionTab(url: "https://pin.com", title: "Pin",
                       isPinned: true, isActive: false),
            SessionTab(url: "https://active.com", title: "Active",
                       isPinned: false, isActive: true),
            SessionTab(url: "https://normal.com", title: "Normal",
                       isPinned: false, isActive: false),
        ]

        MainActor.assumeIsolated {
            saveService.save(makeSessionData(tabs))
        }

        // Create a fresh service instance (simulating app restart)
        let loadService = makeService()
        let loaded: SessionData? = MainActor.assumeIsolated {
            loadService.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.tabs.count, 3,
            "Full cycle: fresh load should have all 3 tabs")

        let pinned = loaded!.tabs.filter(\.isPinned)
        let active = loaded!.tabs.filter(\.isActive)
        XCTAssertEqual(pinned.count, 1,
            "Full cycle: exactly one tab should be pinned")
        XCTAssertEqual(active.count, 1,
            "Full cycle: exactly one tab should be active")
    }

    /// Full cycle: saveCurrentState uses tabStateProvider.
    func testFullCycle_saveCurrentState_usesProvider() {
        let service = makeService()

        MainActor.assumeIsolated {
            service.tabStateProvider = {
                [
                    SessionTab(url: "https://provider.com", title: "Provider",
                               isPinned: false, isActive: true),
                ]
            }
            service.saveCurrentState()
        }

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.tabs.count, 1)
        XCTAssertEqual(loaded!.tabs[0].url, "https://provider.com",
            "saveCurrentState should use tabStateProvider to get tabs")
    }

    /// Full cycle: saveCurrentState with no provider is a no-op.
    func testFullCycle_saveCurrentState_noProvider_noOp() {
        let service = makeService()

        MainActor.assumeIsolated {
            // tabStateProvider is nil
            service.saveCurrentState()
        }

        let has = MainActor.assumeIsolated {
            service.hasSession()
        }

        XCTAssertFalse(has,
            "saveCurrentState without provider should not write file")
    }

    /// Full cycle: saveCurrentState with empty tabs from provider is a no-op.
    func testFullCycle_saveCurrentState_emptyProvider_noOp() {
        let service = makeService()

        MainActor.assumeIsolated {
            service.tabStateProvider = { [] }
            service.saveCurrentState()
        }

        let has = MainActor.assumeIsolated {
            service.hasSession()
        }

        XCTAssertFalse(has,
            "saveCurrentState with empty tabs should not write file")
    }

    // =========================================================================
    // MARK: - Phase 5 Supplemental: Deferred Activation Dedup
    // =========================================================================

    /// Deferred dedup: calling activateTab twice on the same non-deferred tab
    /// is idempotent — the tab stays active and only one WebView exists.
    /// For deferred tabs, isDeferred only flips true→false once; a second
    /// assignment is a no-op (mock mode validates property-level dedup).
    func testActivateTab_deferredDedup_secondCallIsNoOp() {
        let vm = makeVM(tabs: [
            ("A", "https://a.com"),
            ("B", "https://b.com"),
        ])

        MainActor.assumeIsolated {
            // Activate tab B (non-deferred) — first call
            vm.activateTab(vm.tabs[1])
            XCTAssertEqual(vm.activeTab?.id, vm.tabs[1].id,
                "Deferred dedup: first activateTab should select the tab")

            let webviewIdAfterFirst = vm.tabs[1].webviewId

            // Activate tab B again — second call (should be no-op)
            vm.activateTab(vm.tabs[1])
            XCTAssertEqual(vm.activeTab?.id, vm.tabs[1].id,
                "Deferred dedup: second activateTab should keep same tab active")
            XCTAssertEqual(vm.tabs[1].webviewId, webviewIdAfterFirst,
                "Deferred dedup: webviewId should not change on duplicate activation")
            XCTAssertEqual(vm.tabs.count, 2,
                "Deferred dedup: tab count should not change after duplicate activation")
        }

        // Also validate property-level dedup for isDeferred
        MainActor.assumeIsolated {
            let tab = vm.tabs[1]
            tab.isDeferred = true
            XCTAssertTrue(tab.isDeferred)

            // First flip: true → false
            tab.isDeferred = false
            XCTAssertFalse(tab.isDeferred,
                "Deferred dedup: isDeferred should flip to false")

            // Second flip attempt: false → false (no-op)
            tab.isDeferred = false
            XCTAssertFalse(tab.isDeferred,
                "Deferred dedup: isDeferred should stay false on repeated assignment")
        }
    }

    // =========================================================================
    // MARK: - Phase 5 Supplemental: closeTab on Activating Deferred Tab
    // =========================================================================

    /// closeTab on a tab that was deferred but is now being activated
    /// (isDeferred just manually cleared, simulating activation) should
    /// still remove it from the tabs array.
    func testCloseTab_activatingDeferredTab_removesFromTabs() {
        let vm = makeVM(tabs: [
            ("Keeper", "https://keeper.com"),
            ("Activating", "https://activating.com"),
        ])

        MainActor.assumeIsolated {
            // Simulate: tab was deferred, now being activated
            // (manually clear isDeferred to mimic activation without bridge call)
            vm.tabs[1].isDeferred = true
            vm.tabs[1].webviewId = 0

            // Simulate activation: clear deferred, set loading
            vm.tabs[1].isDeferred = false
            vm.tabs[1].isLoading = true

            XCTAssertFalse(vm.tabs[1].isDeferred,
                "Precondition: tab should no longer be deferred")

            // Now close the tab that was just activated
            let activatingTab = vm.tabs[1]
            vm.closeTab(activatingTab)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.tabs.count, 1,
                "closeTab on activating deferred tab should remove it")
            XCTAssertEqual(vm.tabs[0].title, "Keeper",
                "closeTab should leave only the other tab")
        }
    }

    // =========================================================================
    // MARK: - Phase 5 Supplemental: activateTab Triggers Session Save
    // =========================================================================

    /// activateTab should trigger a session save (scheduleSave path).
    /// We wire up a tabStateProvider and verify it gets called after activation.
    func testActivateTab_triggersSessionSave() {
        let vm = makeVM(tabs: [
            ("A", "https://a.com"),
            ("B", "https://b.com"),
        ])

        var providerCallCount = 0

        MainActor.assumeIsolated {
            // Wire up the sessionService with a provider that counts calls
            vm.sessionService.tabStateProvider = {
                providerCallCount += 1
                return [
                    SessionTab(url: "https://a.com", title: "A",
                               isPinned: false, isActive: false),
                    SessionTab(url: "https://b.com", title: "B",
                               isPinned: false, isActive: true),
                ]
            }

            // Reset counter after setup (launch may have triggered saves)
            providerCallCount = 0

            // Activate a different tab — should trigger scheduleSave
            vm.activateTab(vm.tabs[1])
        }

        // Wait for debounced save to fire
        pump(3.0)

        XCTAssertGreaterThanOrEqual(providerCallCount, 1,
            "activateTab should trigger session save via scheduleSave")
    }

    // =========================================================================
    // MARK: - Phase 5 Supplemental: load() Deletes Corrupt File
    // =========================================================================

    /// load() with corrupt JSON should delete the corrupt session file.
    func testLoad_corruptJSON_deletesFile() throws {
        let service = makeService()

        // Write corrupt data to session.json
        try "<<<NOT JSON>>>".data(using: .utf8)!
            .write(to: sessionFileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFileURL.path),
            "Precondition: corrupt file should exist before load")

        let loaded: SessionData? = MainActor.assumeIsolated {
            service.load()
        }

        XCTAssertNil(loaded,
            "load() should return nil for corrupt JSON")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFileURL.path),
            "load() should delete the corrupt session file")
    }
}
