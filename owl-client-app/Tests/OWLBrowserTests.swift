/// OWL Browser E2E Tests — tests the full C-ABI → Mojo → Host → Renderer pipeline.
/// Requires: OWL_ENABLE_TEST_JS=1 env var (set by OWLTestBridge.setUp).
/// Run: swift test -F /path/to/out/owl-host
import XCTest
import OWLBridge

final class OWLBrowserTests: XCTestCase {

    static var webviewId: UInt64 = 0

    // Launch Host once for all tests.
    override class func setUp() {
        super.setUp()

        // Must initialize on main thread (CHECK(pthread_main_np()) in C-ABI).
        OWLTestBridge.initializeOnMainThread()

        let hostPath = ProcessInfo.processInfo.environment["OWL_HOST_PATH"]
            ?? "/Users/xiaoyang/Project/chromium/src/out/owl-host/OWL Host.app/Contents/MacOS/OWL Host"
        let userDataDir = NSTemporaryDirectory() + "owl-test-\(ProcessInfo.processInfo.processIdentifier)"

        let expectation = XCTestExpectation(description: "Host launch")
        Task {
            do {
                webviewId = try await OWLTestBridge.setUp(
                    hostPath: hostPath, userDataDir: userDataDir)
                expectation.fulfill()
            } catch {
                XCTFail("Failed to launch Host: \(error)")
                expectation.fulfill()
            }
        }
        _ = XCTWaiter.wait(for: [expectation], timeout: 30)
    }

    override class func tearDown() {
        // Kill Host child process so swift test can exit.
        OWLTestBridge.shutdown()
        super.tearDown()
    }

    private var wv: UInt64 { Self.webviewId }

    // MARK: - Helper

    /// Navigate and wait for load.
    private func navigateAndWait(_ url: String) async throws {
        try await OWLTestBridge.navigate(wv, url: url)
        if url.hasPrefix("data:") {
            await OWLTestBridge.quickWait()
        } else {
            try await Task.sleep(nanoseconds: 300_000_000)
            try await OWLTestBridge.waitForLoad(timeout: 15)
        }
    }

    // MARK: - Test: EvaluateJS basic

    func testEvalJSReturnsNumber() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "1 + 2")
        XCTAssertEqual(resultType, 0, "Should succeed")
        XCTAssertEqual(result, "3")
    }

    func testEvalJSReturnsString() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "'hello'")
        XCTAssertEqual(resultType, 0)
        XCTAssertEqual(result, "\"hello\"") // JSON-serialized string
    }

    func testEvalJSReturnsUndefined() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "undefined")
        XCTAssertEqual(resultType, 0)
        XCTAssertEqual(result, "") // undefined → empty string
    }

    func testEvalJSException() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "throw new Error('test')")
        XCTAssertEqual(resultType, 1, "Exception should return result_type=1")
        // Verify it's a real JS exception, not timeout/gate/host error
        XCTAssertNotEqual(result, "Timeout", "Should not be timeout")
        XCTAssertFalse(result.contains("requires"), "Should not be gate error: \(result)")
        XCTAssertFalse(result.contains("No WebContents"), "Should not be host error: \(result)")
    }

    func testEvalJSReturnsObject() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "({a: 1, b: 'hello'})")
        XCTAssertEqual(resultType, 0)
        XCTAssertTrue(result.contains("\"a\""), "Should contain key 'a': \(result)")
        XCTAssertTrue(result.contains("\"b\""), "Should contain key 'b': \(result)")
    }

    func testEvalJSReturnsNull() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        // JS null → base::Value NONE → empty string (same as undefined).
        // Chromium's ExecuteJavaScriptForTests maps null to NONE type.
        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "null")
        XCTAssertEqual(resultType, 0)
        XCTAssertEqual(result, "")
    }

    func testEvalJSPromise() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "Promise.resolve(42)")
        XCTAssertEqual(resultType, 0)
        XCTAssertEqual(result, "42") // resolve_promises=true
    }

    // MARK: - Test: Keyboard input through full pipeline

    func testKeyboardInput() async throws {
        try await navigateAndWait("data:text/html,<input id='kw' autofocus>")

        // Focus and clear search input via JS
        _ = await OWLTestBridge.evalJS(wv,
            "var e=document.querySelector('#kw');if(e){e.focus();e.value=''}")
        try await Task.sleep(nanoseconds: 200_000_000)

        // Type through C-ABI → Mojo → Host → ForwardKeyboardEvent → Renderer
        OWLTestBridge.typeText(wv, "owl")
        try await Task.sleep(nanoseconds: 500_000_000)

        // Verify DOM state via EvaluateJS
        let value = await OWLTestBridge.evalJS(wv,
            "document.querySelector('#kw')?.value")
        XCTAssertEqual(value, "\"owl\"")
    }

    // MARK: - Test: Mouse click navigation

    func testClickNavigates() async throws {
        // Use data: URL with a link — no external network dependency
        try await navigateAndWait("data:text/html,<a id='lnk' href='https://example.com' style='display:block;padding:20px'>Click</a>")

        // Get link coordinates — return object directly
        let coordsJSON = await OWLTestBridge.evalJS(wv, """
            (function() {
                var r = document.getElementById('lnk').getBoundingClientRect();
                return {x: r.x + r.width/2, y: r.y + r.height/2};
            })()
        """)

        // Parse coordinates from JSON. Values may be Int or Double.
        let (x, y): (Double, Double) = try {
            var json = coordsJSON
            // Unwrap if double-quoted JSON string
            if json.hasPrefix("\""), let d = json.data(using: .utf8),
               let s = try? JSONSerialization.jsonObject(with: d) as? String { json = s }
            guard let d = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let xv = obj["x"] as? NSNumber,
                  let yv = obj["y"] as? NSNumber else {
                throw NSError(domain: "OWLTest", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not parse coordinates: \(coordsJSON)"])
            }
            return (xv.doubleValue, yv.doubleValue)
        }()

        // Click through C-ABI → Mojo → Host → ForwardMouseEvent → Renderer
        OWLTestBridge.sendMouseEvent(wv, type: 0, button: 1, x: Float(x), y: Float(y)) // mouseDown
        OWLTestBridge.sendMouseEvent(wv, type: 1, button: 1, x: Float(x), y: Float(y)) // mouseUp
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3s for navigation

        // Verify URL changed
        let url = await OWLTestBridge.evalJS(wv, "window.location.href")
        XCTAssertTrue(url.contains("example.com"), "Should navigate to example.com, got: \(url)")
    }

    // MARK: - Test: Post-navigation interaction

    func testPostNavigationInteraction() async throws {
        // Navigate to first page
        try await navigateAndWait("data:text/html,<h1>test</h1>")

        // Navigate to second page (triggers RenderFrameHostChanged)
        try await navigateAndWait("data:text/html,<input id='kw' autofocus>")

        // Verify we can still interact after navigation
        _ = await OWLTestBridge.evalJS(wv,
            "var e=document.querySelector('#kw');if(e){e.focus();e.value=''}")
        try await Task.sleep(nanoseconds: 200_000_000)

        OWLTestBridge.typeText(wv, "nav")
        try await Task.sleep(nanoseconds: 500_000_000)

        let value = await OWLTestBridge.evalJS(wv,
            "document.querySelector('#kw')?.value")
        XCTAssertEqual(value, "\"nav\"")
    }

    // MARK: - Test: Cursor change on hover

    func testCursorChangeOnHover() async throws {
        // Use local page to avoid external network/layout nondeterminism.
        try await navigateAndWait(
            "data:text/html,<style>body{margin:0}#lnk{display:inline-block;margin:40px;padding:20px}</style><a id='lnk' href='https://example.com'>Hover me</a>"
        )
        OWLTestBridge.registerCursorCallback(wv)
        OWLTestBridge.lastCursorType = 0 // reset

        // Get link coordinates — return object directly.
        let coordsJSON = await OWLTestBridge.evalJS(wv, """
            (function() {
                var link = document.getElementById('lnk');
                if (!link) return null;
                var r = link.getBoundingClientRect();
                return {x: r.x + r.width / 2, y: r.y + r.height / 2};
            })()
        """)

        var json = coordsJSON
        if json.hasPrefix("\""), let d = json.data(using: .utf8),
           let s = try? JSONSerialization.jsonObject(with: d) as? String { json = s }
        guard json != "null",
              let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let xv = obj["x"] as? NSNumber,
              let yv = obj["y"] as? NSNumber else {
            return // No visible link — skip
        }
        let x = xv.doubleValue, y = yv.doubleValue

        // Move once outside link then over link; poll briefly for async callback.
        OWLTestBridge.sendMouseEvent(wv, type: 2, button: 0, x: 1, y: 1, clickCount: 0)
        for _ in 0..<10 {
            OWLTestBridge.sendMouseEvent(
                wv,
                type: 2,
                button: 0,
                x: Float(x),
                y: Float(y),
                clickCount: 0
            )
            if OWLTestBridge.lastCursorType == 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // kHand = 1 (from owl_input_types.mojom CursorType enum)
        XCTAssertEqual(OWLTestBridge.lastCursorType, 1,
                       "Cursor should be Hand(1) on link hover, got \(OWLTestBridge.lastCursorType)")
    }

    // MARK: - Test: Enter submits form

    func testEnterSubmitsSearch() async throws {
        try await navigateAndWait("data:text/html,<input id='kw' autofocus>")

        _ = await OWLTestBridge.evalJS(wv,
            "var e=document.querySelector('#kw');if(e){e.focus();e.value=''}")
        try await Task.sleep(nanoseconds: 200_000_000)

        OWLTestBridge.typeText(wv, "owltest")
        try await Task.sleep(nanoseconds: 300_000_000)

        // Install keydown hook after typing so only Enter path triggers it.
        _ = await OWLTestBridge.evalJS(wv, """
            (function() {
                var e = document.querySelector('#kw');
                if (!e) return;
                window.__enterTriggered = false;
                e.addEventListener('keydown', function() {
                    window.__enterTriggered = true;
                }, {once: true});
            })()
        """)

        // Send Enter key (keyCode 36 = kVK_Return on macOS)
        OWLTestBridge.sendKeyEvent(wv, type: 0, keyCode: 36, chars: "\r") // RawKeyDown
        OWLTestBridge.sendKeyEvent(wv, type: 1, keyCode: 36, chars: "\r") // KeyUp
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let triggered = await OWLTestBridge.evalJS(wv, "window.__enterTriggered === true")
        let value = await OWLTestBridge.evalJS(wv, "document.querySelector('#kw')?.value")
        XCTAssertEqual(triggered, "true")
        XCTAssertEqual(value, "\"owltest\"")
    }

    // MARK: - Test: IME composition + commit (Phase 31)

    func testImeSetCompositionThenCommit() async throws {
        try await navigateAndWait("data:text/html,<input id='inp' autofocus>")
        _ = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').focus(); document.getElementById('inp').value = ''")
        try await Task.sleep(nanoseconds: 300_000_000)

        // Simulate Chinese IME: type "ni" → composition → commit "你"
        OWLTestBridge.imeSetComposition(wv, text: "n")
        try await Task.sleep(nanoseconds: 200_000_000)
        OWLTestBridge.imeSetComposition(wv, text: "ni")
        try await Task.sleep(nanoseconds: 200_000_000)

        // Commit final text
        OWLTestBridge.imeCommitText(wv, text: "你")
        try await Task.sleep(nanoseconds: 500_000_000)

        let value = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').value")
        XCTAssertTrue(value.contains("你"), "Should contain committed Chinese char, got: \(value)")
    }

    func testImeCompositionCancel() async throws {
        try await navigateAndWait("data:text/html,<input id='inp' autofocus>")
        _ = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').focus(); document.getElementById('inp').value = ''")
        try await Task.sleep(nanoseconds: 300_000_000)

        // Start composition then cancel (empty setMarkedText or finishComposing)
        OWLTestBridge.imeSetComposition(wv, text: "he")
        try await Task.sleep(nanoseconds: 200_000_000)
        OWLTestBridge.imeFinishComposing(wv)
        try await Task.sleep(nanoseconds: 500_000_000)

        // After cancel, the composition text should have been committed as-is
        // (ImeFinishComposingText commits the current composition)
        let value = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').value")
        XCTAssertTrue(value.contains("he"), "FinishComposing should commit current text, got: \(value)")
    }

    func testImeCompositionThenClearCancel() async throws {
        try await navigateAndWait("data:text/html,<input id='inp' autofocus>")
        _ = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').focus(); document.getElementById('inp').value = ''")
        try await Task.sleep(nanoseconds: 300_000_000)

        // Start composition then cancel with empty text (ESC)
        OWLTestBridge.imeSetComposition(wv, text: "wo")
        try await Task.sleep(nanoseconds: 200_000_000)
        // Empty composition = cancel
        OWLTestBridge.imeSetComposition(wv, text: "")
        try await Task.sleep(nanoseconds: 500_000_000)

        let value = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').value")
        // Empty composition cancels — no text should remain
        XCTAssertEqual(value, "\"\"", "Cancelled composition should leave empty input, got: \(value)")
    }

    // MARK: - Test: Navigate twice (safe destruction)

    func testNavigateTwice() async throws {
        try await navigateAndWait("data:text/html,<h1>test</h1>")
        try await navigateAndWait("https://www.baidu.com")

        // Verify page is interactive after double navigation
        let (result, resultType) = await OWLTestBridge.evaluateJS(wv, "document.title")
        XCTAssertEqual(resultType, 0)
        XCTAssertFalse(result.isEmpty, "Title should not be empty after double navigation")
    }

    // MARK: - Phase C: Navigation stability

    /// Navigate twice to data URLs, verify JS works after each.
    func testDoubleDataURLNavigation() async throws {
        try await navigateAndWait("data:text/html,<div id='p1'>page1</div>")
        let v1 = await OWLTestBridge.evalJS(wv,
            "document.getElementById('p1')?.textContent")
        XCTAssertTrue(v1.contains("page1"), "First page content, got: \(v1)")

        try await navigateAndWait("data:text/html,<div id='p2'>page2</div>")
        let v2 = await OWLTestBridge.evalJS(wv,
            "document.getElementById('p2')?.textContent")
        XCTAssertTrue(v2.contains("page2"), "Second page content, got: \(v2)")

        // Old page element should not exist
        let old = await OWLTestBridge.evalJS(wv,
            "document.getElementById('p1')?.textContent ?? 'null'")
        XCTAssertTrue(old.contains("null"), "Old page element should not exist, got: \(old)")
    }

    /// Navigate to data URL, type, then navigate again — input state should reset.
    func testInputStateResetsAfterNavigation() async throws {
        try await navigateAndWait("data:text/html,<input id='inp' autofocus>")
        _ = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').focus()")
        try await Task.sleep(nanoseconds: 200_000_000)

        OWLTestBridge.typeText(wv, "abc")
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp').value")
        XCTAssertTrue(before.contains("abc"), "Should have typed text, got: \(before)")

        // Navigate to new page — old input state gone
        try await navigateAndWait("data:text/html,<input id='inp2'>")
        let after = await OWLTestBridge.evalJS(wv,
            "document.getElementById('inp2').value")
        XCTAssertTrue(after.contains("\"\"") || after.contains("''") || after == "\"\"",
            "New input should be empty, got: \(after)")
    }

    /// Rapid sequential navigations should not crash.
    func testRapidSequentialNavigations() async throws {
        // Fire 3 navigations in quick succession
        for i in 1...3 {
            try await OWLTestBridge.navigate(wv,
                url: "data:text/html,<p id='seq'>\(i)</p>")
        }
        // Wait for last one to load
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should be on the last page (or at least not crashed)
        let (result, resultType) = await OWLTestBridge.evaluateJS(wv,
            "document.getElementById('seq')?.textContent ?? 'none'")
        XCTAssertEqual(resultType, 0, "JS should execute without error")
        // The content should be "3" (last nav) or at least not crash
        XCTAssertFalse(result.contains("none"), "Should have loaded a page, got: \(result)")
    }

    // MARK: - Phase 32: Navigation E2E
    //
    // Note: GoBack/GoForward/Reload/Stop have no C-ABI functions in owl_bridge_api.h.
    // They exist only on OWLBridgeWebView (ObjC++ Mojo layer). E2E integration tests
    // use JS History API (history.back/forward, location.reload, window.stop) which
    // triggers the same NavigationController path the real app uses.

    /// [AC-001] [AC-002] Back/Forward navigation through history.
    /// Navigate A → B → verify canGoBack → back to A → verify canGoForward → forward to B.
    func testBackForwardNavigation() async throws {
        let urlA = "data:text/html,<h1 id='pg'>PageA</h1>"
        let urlB = "data:text/html,<h1 id='pg'>PageB</h1>"

        // Navigate to page A
        try await navigateAndWait(urlA)
        let contentA1 = await OWLTestBridge.evalJS(wv,
            "document.getElementById('pg').textContent")
        XCTAssertTrue(contentA1.contains("PageA"), "Should be on page A, got: \(contentA1)")

        // Navigate to page B
        try await navigateAndWait(urlB)
        let contentB1 = await OWLTestBridge.evalJS(wv,
            "document.getElementById('pg').textContent")
        XCTAssertTrue(contentB1.contains("PageB"), "Should be on page B, got: \(contentB1)")

        // AC-001: Verify canGoBack is true before going back
        XCTAssertTrue(OWLTestBridge.canGoBack,
            "canGoBack should be true before going back")

        // Go back to page A (signal-based wait)
        try await OWLTestBridge.goBackAndWait(wv)
        let contentA2 = await OWLTestBridge.evalJS(wv,
            "document.getElementById('pg').textContent")
        XCTAssertTrue(contentA2.contains("PageA"),
            "After back, should be on page A, got: \(contentA2)")

        // AC-002: Verify canGoForward is true before going forward
        XCTAssertTrue(OWLTestBridge.canGoForward,
            "canGoForward should be true before going forward")

        // Go forward to page B (signal-based wait)
        try await OWLTestBridge.goForwardAndWait(wv)
        let contentB2 = await OWLTestBridge.evalJS(wv,
            "document.getElementById('pg').textContent")
        XCTAssertTrue(contentB2.contains("PageB"),
            "After forward, should be on page B, got: \(contentB2)")
    }

    /// [AC-003] Reload resets JS state (proves page actually reloaded).
    /// Note: data: URL + location.reload() may not fully teardown the JS context in Chromium
    /// (soft reload optimization). We use re-navigation to the same URL as a reliable
    /// substitute that exercises the same NavigationController path.
    func testReloadResetsJSState() async throws {
        let reloadURL = "data:text/html,<h1>ReloadTest</h1>"
        try await navigateAndWait(reloadURL)

        // Set a JS variable that should be lost on reload
        _ = await OWLTestBridge.evalJS(wv, "window.__reloadTest = true")
        let before = await OWLTestBridge.evalJS(wv, "window.__reloadTest")
        XCTAssertTrue(before.contains("true"),
            "Variable should exist before reload, got: \(before)")

        // Record canGoBack before reload (should not change after reload)
        let canBackBefore = OWLTestBridge.canGoBack

        // Re-navigate to the same URL — forces full navigation pipeline,
        // creating a new JS context (equivalent to Reload for test purposes).
        try await navigateAndWait(reloadURL)

        // After reload, JS state should be reset — variable gone
        let after = await OWLTestBridge.evalJS(wv, "typeof window.__reloadTest")
        XCTAssertTrue(after.contains("undefined"),
            "After reload, __reloadTest should be undefined, got: \(after)")

        // Verify page is still functional (not blank/broken)
        let title = await OWLTestBridge.evalJS(wv, "document.querySelector('h1')?.textContent")
        XCTAssertTrue(title.contains("ReloadTest"),
            "Page content should survive reload, got: \(title)")

        // Verify reload doesn't affect navigation history (still has prior history)
        XCTAssertEqual(OWLTestBridge.canGoBack, canBackBefore,
            "canGoBack should not change after reload")
    }

    /// [AC-004] Stop loading — smoke test.
    /// Note: Testing "stop interrupts in-flight loading" is inherently racy in E2E.
    /// data: URLs load synchronously so we cannot catch mid-flight state.
    /// No C-ABI OWLBridge_Stop exists — window.stop() is the only E2E path.
    /// This test verifies: (1) stop() can be called without crash, (2) page remains
    /// functional after stop, (3) stop during a real URL load shows loadFinished flag.
    func testStopLoading() async throws {
        // Start from a known good page
        try await navigateAndWait("data:text/html,<h1>StopBase</h1>")

        // Call window.stop() — should not throw or crash
        let (_, resultType) = await OWLTestBridge.evaluateJS(wv, "window.stop()")
        XCTAssertEqual(resultType, 0, "window.stop() should execute without error")

        // Verify the page is still functional after stop
        let content = await OWLTestBridge.evalJS(wv,
            "document.querySelector('h1')?.textContent")
        XCTAssertTrue(content.contains("StopBase"),
            "Page should still be accessible after stop, got: \(content)")

        // Best-effort: start loading a real URL, immediately stop
        // This exercises the stop path during early navigation stages.
        try await OWLTestBridge.navigate(wv, url: "https://www.example.com")
        _ = await OWLTestBridge.evalJS(wv, "window.stop()")
        // We don't assert specific state here because the race between navigate
        // completing and stop executing is non-deterministic. The key assertion
        // is that neither navigate nor stop crashes the renderer.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let (_, rt2) = await OWLTestBridge.evaluateJS(wv, "document.readyState")
        XCTAssertEqual(rt2, 0, "JS should still be executable after stop during load")
    }

    /// [AC-005] canGoBack/canGoForward state reflects navigation history.
    /// Tests share a single webview — prior tests create history.
    /// We verify relative state TRANSITIONS (not absolute initial state).
    func testCanGoBackForwardState() async throws {
        // Navigate to page 1 — new navigation clears forward stack
        try await navigateAndWait("data:text/html,<h1>Nav1</h1>")

        XCTAssertFalse(OWLTestBridge.canGoForward,
            "canGoForward should be false on latest page")

        // Navigate to page 2 — canGoBack must be true, canGoForward still false
        try await navigateAndWait("data:text/html,<h1>Nav2</h1>")

        XCTAssertTrue(OWLTestBridge.canGoBack,
            "canGoBack should be true after navigating to second page")
        XCTAssertFalse(OWLTestBridge.canGoForward,
            "canGoForward should be false on latest page")

        // Go back — canGoForward should become true (signal-based wait)
        try await OWLTestBridge.goBackAndWait(wv)

        XCTAssertTrue(OWLTestBridge.canGoForward,
            "canGoForward should be true after going back")

        // Go forward — canGoForward should become false, canGoBack true (signal-based wait)
        try await OWLTestBridge.goForwardAndWait(wv)

        XCTAssertTrue(OWLTestBridge.canGoBack,
            "canGoBack should be true after going forward")
        XCTAssertFalse(OWLTestBridge.canGoForward,
            "canGoForward should be false on latest page after forward")
    }

    // MARK: - Phase 33: Find-in-Page E2E

    /// [AC-002, AC-003, AC-008] Find highlights all matches and returns correct count.
    /// Navigate to a data: URL containing repeated "hello" text, then call Find
    /// through C-ABI and verify that matches are found via the find result callback.
    func testFindMatchesExist() async throws {
        // Page with 3 occurrences of "hello"
        try await navigateAndWait(
            "data:text/html,<body><p>hello world</p><p>hello again</p><p>hello three</p></body>")

        // Register find result callback and reset state
        OWLTestBridge.registerFindResultCallback(wv)
        OWLTestBridge.resetFindState()

        // Trigger Find via C-ABI
        let requestId = await OWLTestBridge.find(wv, query: "hello")

        // request_id should be > 0 in real mode (live renderer allocates IDs)
        XCTAssertGreaterThan(requestId, 0,
            "Find should return a positive request_id, got: \(requestId)")

        // Wait for find result callback from the renderer
        await OWLTestBridge.waitForFindResult(timeout: 5)

        XCTAssertTrue(OWLTestBridge.findResultReceived,
            "Should have received a find result callback")
        XCTAssertEqual(OWLTestBridge.lastFindMatches, 3,
            "Should find 3 matches of 'hello', got: \(OWLTestBridge.lastFindMatches)")
        XCTAssertGreaterThan(OWLTestBridge.lastFindOrdinal, 0,
            "Active match ordinal should be > 0, got: \(OWLTestBridge.lastFindOrdinal)")

        // Cleanup
        OWLTestBridge.stopFinding(wv)
    }

    /// [AC-006, AC-008] Find with non-existent text returns 0 matches.
    func testFindNoMatches() async throws {
        try await navigateAndWait(
            "data:text/html,<body><p>The quick brown fox</p></body>")

        // Register find result callback and reset state
        OWLTestBridge.registerFindResultCallback(wv)
        OWLTestBridge.resetFindState()

        // Search for text that doesn't exist on the page
        let requestId = await OWLTestBridge.find(wv, query: "nonexistent_xyz_42")

        XCTAssertGreaterThan(requestId, 0,
            "Find should return a positive request_id even for no-match, got: \(requestId)")

        // Wait for find result callback
        await OWLTestBridge.waitForFindResult(timeout: 5)

        XCTAssertTrue(OWLTestBridge.findResultReceived,
            "Should have received a find result callback")
        XCTAssertEqual(OWLTestBridge.lastFindMatches, 0,
            "Should find 0 matches for nonexistent text, got: \(OWLTestBridge.lastFindMatches)")
        XCTAssertEqual(OWLTestBridge.lastFindOrdinal, 0,
            "Active ordinal should be 0 when no matches, got: \(OWLTestBridge.lastFindOrdinal)")

        // Cleanup
        OWLTestBridge.stopFinding(wv)
    }

    /// [AC-006] GetPageContent returns visible text content.
    func testGetPageContent() async throws {
        let expectedText = "Hello OWL Browser Phase32"
        try await navigateAndWait(
            "data:text/html,<body><p>\(expectedText)</p></body>")

        let content = await OWLTestBridge.getPageContent(wv)
        XCTAssertTrue(content.contains(expectedText),
            "Page content should contain '\(expectedText)', got: \(content)")
        // Verify non-empty (JSON-serialized empty string would be "\"\"", not empty)
        XCTAssertTrue(content.count > 2, "Page content should not be empty, got: \(content)")
    }

    // MARK: - Phase 34: Zoom Control E2E

    /// [P1-3] [AC-007] Set zoom level → OnZoomLevelChanged callback fires with correct value.
    func testZoomChangedCallbackFires() async throws {
        try await navigateAndWait("data:text/html,<h1>ZoomCallbackTest</h1>")

        OWLTestBridge.registerZoomChangedCallback(wv)
        OWLTestBridge.resetZoomChangedState()

        // Set zoom to 2.0 (≈144%)
        await OWLTestBridge.setZoomLevel(wv, level: 2.0)

        // Wait for OnZoomLevelChanged callback
        await OWLTestBridge.waitForZoomChanged(timeout: 5)

        XCTAssertTrue(OWLTestBridge.zoomChangedReceived,
            "Should have received OnZoomLevelChanged callback")
        XCTAssertEqual(OWLTestBridge.lastZoomChangedLevel, 2.0, accuracy: 0.01,
            "Callback should report level ≈2.0, got: \(OWLTestBridge.lastZoomChangedLevel)")

        // Reset zoom for subsequent tests
        OWLTestBridge.resetZoomChangedState()
        await OWLTestBridge.setZoomLevel(wv, level: 0.0)
        await OWLTestBridge.waitForZoomChanged(timeout: 5)
        // [R2-2] Must assert callback was actually received, not just that the
        // default-reset value happens to match 0.0.
        XCTAssertTrue(OWLTestBridge.zoomChangedReceived,
            "Should have received OnZoomLevelChanged callback after reset to 0.0")
        XCTAssertEqual(OWLTestBridge.lastZoomChangedLevel, 0.0, accuracy: 0.01,
            "Reset callback should report level ≈0.0")
    }

    /// [AC-005, AC-007] Set zoom level then get — verify value round-trips through
    /// C-ABI → Mojo → Host → HostZoomMap → Mojo → C-ABI.
    func testSetAndGetZoomLevel() async throws {
        try await navigateAndWait("data:text/html,<h1>ZoomTest</h1>")

        // Set zoom to 1.0 (≈120%)
        await OWLTestBridge.setZoomLevel(wv, level: 1.0)
        // Allow time for HostZoomMap to process and propagate
        try await Task.sleep(nanoseconds: 500_000_000)

        // Get zoom level and verify it matches what we set
        let level = await OWLTestBridge.getZoomLevel(wv)
        XCTAssertEqual(level, 1.0, accuracy: 0.01,
            "Zoom level should be approximately 1.0 (120%), got: \(level)")

        // Reset zoom to 0.0 (100%) for subsequent tests
        await OWLTestBridge.setZoomLevel(wv, level: 0.0)
        try await Task.sleep(nanoseconds: 500_000_000)

        let resetLevel = await OWLTestBridge.getZoomLevel(wv)
        XCTAssertEqual(resetLevel, 0.0, accuracy: 0.01,
            "Zoom level should be approximately 0.0 (100%) after reset, got: \(resetLevel)")
    }

    // MARK: - Phase 35: Bookmarks E2E

    /// Parse a bookmark JSON string into a dictionary. Returns nil on failure.
    private func parseBookmarkJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Parse a bookmark array JSON string into an array of dictionaries.
    private func parseBookmarkArrayJSON(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr
    }

    /// [AC-001, AC-002] Add a bookmark via C-ABI, then GetAll and verify it appears.
    func testBookmarkAddAndGetAll() async throws {
        // Add a bookmark
        let addResult = await OWLTestBridge.bookmarkAdd(
            title: "Example Site", url: "https://example.com")
        XCTAssertFalse(addResult.isEmpty,
            "bookmarkAdd should return non-empty JSON, got empty")

        let bookmark = parseBookmarkJSON(addResult)
        XCTAssertNotNil(bookmark, "Should parse as valid JSON: \(addResult)")
        XCTAssertEqual(bookmark?["title"] as? String, "Example Site")
        XCTAssertEqual(bookmark?["url"] as? String, "https://example.com")
        let bookmarkId = bookmark?["id"] as? String
        XCTAssertNotNil(bookmarkId, "Bookmark should have an id")
        XCTAssertFalse(bookmarkId?.isEmpty ?? true, "Bookmark id should not be empty")

        // GetAll and verify
        let allJSON = await OWLTestBridge.bookmarkGetAll()
        XCTAssertFalse(allJSON.isEmpty,
            "bookmarkGetAll should return non-empty JSON")
        let allBookmarks = parseBookmarkArrayJSON(allJSON)
        XCTAssertNotNil(allBookmarks, "Should parse as valid JSON array: \(allJSON)")

        let found = allBookmarks?.contains { ($0["id"] as? String) == bookmarkId }
        XCTAssertTrue(found ?? false,
            "GetAll should contain the added bookmark with id \(bookmarkId ?? "nil")")

        // Cleanup: remove the bookmark we added
        if let id = bookmarkId {
            _ = await OWLTestBridge.bookmarkRemove(id: id)
        }
    }

    /// [AC-003] Add a bookmark, remove it, verify it no longer appears in GetAll.
    func testBookmarkRemove() async throws {
        // Add
        let addResult = await OWLTestBridge.bookmarkAdd(
            title: "ToRemove", url: "https://remove.example.com")
        let bookmark = parseBookmarkJSON(addResult)
        let bookmarkId = bookmark?["id"] as? String
        XCTAssertNotNil(bookmarkId, "Should have bookmark id to remove")

        // Remove
        let removeSuccess = await OWLTestBridge.bookmarkRemove(id: bookmarkId!)
        XCTAssertTrue(removeSuccess,
            "bookmarkRemove should succeed for existing bookmark")

        // GetAll — removed bookmark should not appear
        let allJSON = await OWLTestBridge.bookmarkGetAll()
        XCTAssertFalse(allJSON.isEmpty,
            "bookmarkGetAll should return non-empty response")
        let allBookmarks = parseBookmarkArrayJSON(allJSON) ?? []
        let found = allBookmarks.contains { ($0["id"] as? String) == bookmarkId }
        XCTAssertFalse(found,
            "Removed bookmark should not appear in GetAll, but found id \(bookmarkId!)")
    }

    /// [AC-004] Add a bookmark, update its title, verify via GetAll.
    func testBookmarkUpdate() async throws {
        // Add
        let addResult = await OWLTestBridge.bookmarkAdd(
            title: "OldTitle", url: "https://update.example.com")
        let bookmark = parseBookmarkJSON(addResult)
        let bookmarkId = bookmark?["id"] as? String
        XCTAssertNotNil(bookmarkId, "Should have bookmark id to update")

        // Update title
        let updateSuccess = await OWLTestBridge.bookmarkUpdate(
            id: bookmarkId!, title: "NewTitle")
        XCTAssertTrue(updateSuccess,
            "bookmarkUpdate should succeed")

        // GetAll — verify updated title
        let allJSON = await OWLTestBridge.bookmarkGetAll()
        let allBookmarks = parseBookmarkArrayJSON(allJSON) ?? []
        let updated = allBookmarks.first { ($0["id"] as? String) == bookmarkId }
        XCTAssertNotNil(updated, "Updated bookmark should still exist")
        XCTAssertEqual(updated?["title"] as? String, "NewTitle",
            "Title should be updated to 'NewTitle', got: \(updated?["title"] ?? "nil")")
        XCTAssertEqual(updated?["url"] as? String, "https://update.example.com",
            "URL should remain unchanged")

        // Cleanup
        _ = await OWLTestBridge.bookmarkRemove(id: bookmarkId!)
    }

    /// [AC-004] Add a bookmark, update only its URL, verify title unchanged via GetAll.
    func testBookmarkUpdateUrl() async throws {
        // Add
        let addResult = await OWLTestBridge.bookmarkAdd(
            title: "KeepTitle", url: "https://old-url.example.com")
        let bookmark = parseBookmarkJSON(addResult)
        let bookmarkId = bookmark?["id"] as? String
        XCTAssertNotNil(bookmarkId, "Should have bookmark id to update")

        // Update URL only (title = nil)
        let updateSuccess = await OWLTestBridge.bookmarkUpdate(
            id: bookmarkId!, url: "https://new.com")
        XCTAssertTrue(updateSuccess,
            "bookmarkUpdate with URL-only should succeed")

        // GetAll — verify URL updated, title unchanged
        let allJSON = await OWLTestBridge.bookmarkGetAll()
        XCTAssertFalse(allJSON.isEmpty,
            "bookmarkGetAll should return non-empty response")
        let allBookmarks = parseBookmarkArrayJSON(allJSON) ?? []
        let updated = allBookmarks.first { ($0["id"] as? String) == bookmarkId }
        XCTAssertNotNil(updated, "Updated bookmark should still exist")
        XCTAssertEqual(updated?["url"] as? String, "https://new.com",
            "URL should be updated to 'https://new.com', got: \(updated?["url"] ?? "nil")")
        XCTAssertEqual(updated?["title"] as? String, "KeepTitle",
            "Title should remain unchanged as 'KeepTitle', got: \(updated?["title"] ?? "nil")")

        // Cleanup
        _ = await OWLTestBridge.bookmarkRemove(id: bookmarkId!)
    }

    /// [AC-001] Add with empty title should fail (return empty/error).
    func testBookmarkAddEmptyTitleFails() async throws {
        let addResult = await OWLTestBridge.bookmarkAdd(
            title: "", url: "https://example.com")
        // Empty title → should return empty string (error) or null bookmark.
        // The C-ABI callback should have error_msg set or bookmark_json = NULL.
        XCTAssertTrue(addResult.isEmpty,
            "bookmarkAdd with empty title should fail, got: \(addResult)")
    }
}
