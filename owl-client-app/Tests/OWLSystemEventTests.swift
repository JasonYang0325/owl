/// OWL Browser System Event Tests — uses CGEvent to inject real OS-level events.
/// Unlike XCUITest, this doesn't require a separate Runner process.
/// Events go through: macOS Event System → NSApp → NSWindow → OWLRemoteLayerView
///
/// Run: OWL_ENABLE_TEST_JS=1 swift test --filter SystemEvent
import XCTest
import OWLBridge
import CoreGraphics

final class OWLSystemEventTests: XCTestCase {

    static var webviewId: UInt64 = 0

    override class func setUp() {
        super.setUp()
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
        OWLTestBridge.shutdown()
        super.tearDown()
    }

    private var wv: UInt64 { Self.webviewId }

    private func navigateAndWait(_ url: String) async throws {
        try await OWLTestBridge.navigate(wv, url: url)
        if url.hasPrefix("data:") {
            await OWLTestBridge.quickWait()
        } else {
            try await Task.sleep(nanoseconds: 300_000_000)
            try await OWLTestBridge.waitForLoad(timeout: 15)
        }
    }

    /// Get the OWL Browser window position and size.
    private func getWindowFrame() -> CGRect? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return nil
        }
        // Convert from AppKit coordinates (bottom-left) to screen coordinates (top-left)
        let frame = window.frame
        guard let screen = window.screen else { return nil }
        let screenH = screen.frame.height
        return CGRect(x: frame.origin.x, y: screenH - frame.origin.y - frame.height,
                      width: frame.width, height: frame.height)
    }

    /// Post a real CGEvent keyboard event to the system.
    private func postKeyEvent(keyCode: CGKeyCode, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between events
    }

    /// Post a real CGEvent mouse click to screen coordinates.
    private func postMouseClick(screenX: CGFloat, screenY: CGFloat) {
        let point = CGPoint(x: screenX, y: screenY)
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        usleep(100_000)
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
        usleep(100_000)
    }

    /// Type a string using CGEvent keyboard events.
    /// These go through: macOS → NSApp → NSWindow → OWLRemoteLayerView.keyDown:
    private func typeString(_ text: String) {
        for char in text {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            let utf16 = Array(String(char).utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)
            usleep(30_000)

            guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            upEvent.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    // MARK: - Tests

    /// Test: Type into web page using REAL system keyboard events.
    /// User will see: app window gets focus, keystrokes appear in search box.
    func testSystemKeyboardInput() async throws {
        try await navigateAndWait("https://www.baidu.com")
        sleep(2)

        // Focus the search input via JS
        _ = await OWLTestBridge.evalJS(wv,
            "var e=document.querySelector('#kw');if(e){e.focus();e.value=''}")
        try await Task.sleep(nanoseconds: 500_000_000)

        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Type using REAL CGEvent keyboard events
        // Goes through: macOS → NSApp → OWLRemoteLayerView.keyDown: → C-ABI → Mojo → Host → Renderer
        typeString("owl")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Verify DOM state
        let value = await OWLTestBridge.evalJS(wv, "document.querySelector('#kw')?.value")
        XCTAssertTrue(value.contains("owl"), "Search box should contain 'owl', got: \(value)")
    }

    /// Test: Click in web content using REAL system mouse events.
    func testSystemMouseClick() async throws {
        try await navigateAndWait("data:text/html,<a id='lnk' href='https://example.com' style='display:block;padding:40px;font-size:24px'>Click Me</a>")

        // Get link position relative to page
        let coordsJSON = await OWLTestBridge.evalJS(wv, """
            (function() {
                var r = document.getElementById('lnk').getBoundingClientRect();
                return {x: r.x + r.width/2, y: r.y + r.height/2};
            })()
        """)

        // Parse coords
        guard let data = coordsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageX = (obj["x"] as? NSNumber)?.doubleValue,
              let pageY = (obj["y"] as? NSNumber)?.doubleValue else {
            XCTFail("Could not parse coords: \(coordsJSON)")
            return
        }

        // Convert page coords to screen coords
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 500_000_000)

        guard let windowFrame = getWindowFrame() else {
            XCTFail("Could not get window frame")
            return
        }

        // Account for title bar (~52px) and top bar (~40px)
        let screenX = windowFrame.origin.x + CGFloat(pageX)
        let screenY = windowFrame.origin.y + 92 + CGFloat(pageY) // title bar + top bar offset

        // Click using REAL CGEvent mouse events
        postMouseClick(screenX: screenX, screenY: screenY)
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let url = await OWLTestBridge.evalJS(wv, "window.location.href")
        XCTAssertTrue(url.contains("example.com"), "Should navigate, got: \(url)")
    }
}
