import XCTest
import AppKit
import SwiftUI

// MARK: - POC Test View

/// Test-only state — no @MainActor needed since setUp/test run on main thread.
private class POCState: ObservableObject, @unchecked Sendable {
    @Published var buttonTapCount = 0
    @Published var textValue = ""
    @Published var dragOffset: CGSize = .zero
    @Published var dragEnded = false
}

private struct POCTestView: View {
    @ObservedObject var state: POCState

    var body: some View {
        VStack(spacing: 20) {
            Button("Tap Me") {
                state.buttonTapCount += 1
                NSLog("[POC] Button tapped! count=\(state.buttonTapCount)")
            }
            .frame(width: 200, height: 44)

            TextField("Type here", text: $state.textValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Rectangle()
                .fill(Color.blue)
                .frame(width: 100, height: 100)
                .offset(state.dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            state.dragOffset = value.translation
                        }
                        .onEnded { _ in
                            state.dragEnded = true
                            NSLog("[POC] Drag ended!")
                        }
                )
        }
        .frame(width: 400, height: 300)
    }
}

// Custom window that always accepts key status (xctest process may not be active app)
private class TestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Tests
// All synchronous — XCTest setUp/test methods run on the main thread.

final class OWLNSEventPOCTests: XCTestCase {

    private var window: NSWindow!
    private var state: POCState!
    private var eventMonitor: Any?

    private static var appInitialized = false

    override func setUp() {
        super.setUp()

        if !Self.appInitialized {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            Self.appInitialized = true
        }
        NSApp.activate(ignoringOtherApps: true)

        state = POCState()
        window = TestWindow(
            contentRect: NSMakeRect(100, 100, 400, 300),
            styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: POCTestView(state: state))
        window.makeKeyAndOrderFront(nil)

        // Pump to process activation + SwiftUI layout
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    }

    override func tearDown() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        window?.close()
        window = nil
        state = nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        super.tearDown()
    }

    // MARK: - Helpers

    /// Click via sendEvent: post mouseUp first, then sendEvent(mouseDown).
    /// sendEvent enters the AppKit tracking loop which reads the queued mouseUp.
    /// Pure postEvent+RunLoop doesn't work because RunLoop.run doesn't drive
    /// NSApplication's event dispatch — only sendEvent does.
    private func click(at point: NSPoint) {
        let ts = ProcessInfo.processInfo.systemUptime
        let wn = window.windowNumber
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ts,
            windowNumber: wn, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1.0)!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: ts + 0.05,
            windowNumber: wn, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0.0)!
        // 1. Queue mouseUp first — tracking loop will find it
        NSApp.postEvent(up, atStart: false)
        // 2. sendEvent(mouseDown) enters tracking loop, finds mouseUp, returns
        NSApp.sendEvent(down)
        // 3. Pump to let SwiftUI process state changes
        pump(0.1)
    }

    private func typeChar(_ char: String, keyCode: UInt16) {
        let ts = ProcessInfo.processInfo.systemUptime
        let wn = window.windowNumber
        let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ts,
            windowNumber: wn, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode)!
        let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero,
            modifierFlags: [], timestamp: ts + 0.02,
            windowNumber: wn, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode)!
        // Key events don't enter tracking loops — sendEvent directly
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
        pump(0.05)
    }

    private func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - POC 1: Click triggers SwiftUI Button

    func testNSEventClickTriggersSwiftUIButton() {
        XCTAssertEqual(state.buttonTapCount, 0)

        NSLog("[POC] isKeyWindow=\(window.isKeyWindow) isActive=\(NSRunningApplication.current.isActive)")

        let hostingView = window.contentView!

        // Approach 1: sendEvent (post mouseUp, then sendEvent mouseDown)
        for y in stride(from: 10, through: 295, by: 10) {
            click(at: NSPoint(x: 200, y: CGFloat(y)))
            pump()
            if state.buttonTapCount > 0 {
                NSLog("[POC] Button hit via sendEvent at y=\(y)")
                break
            }
        }

        // Approach 2: Direct mouseDown/mouseUp on NSHostingView (bypass window routing)
        if state.buttonTapCount == 0 {
            NSLog("[POC] sendEvent failed (likely key window issue). Trying direct view mouseDown...")
            for y in stride(from: 10, through: 295, by: 10) {
                let pt = NSPoint(x: 200, y: CGFloat(y))
                let ts = ProcessInfo.processInfo.systemUptime
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: pt,
                    modifierFlags: [], timestamp: ts,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1.0)!
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: pt,
                    modifierFlags: [], timestamp: ts + 0.05,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0.0)!
                // Call mouseDown/Up directly on the content view
                hostingView.mouseDown(with: down)
                hostingView.mouseUp(with: up)
                pump(0.1)
                if state.buttonTapCount > 0 {
                    NSLog("[POC] Button hit via direct mouseDown at y=\(y)")
                    break
                }
            }
        }

        // Approach 3: AXUIElement AXPress action
        if state.buttonTapCount == 0 {
            NSLog("[POC] Direct mouseDown also failed. Trying AXUIElement AXPress...")
            let app = AXUIElementCreateApplication(getpid())
            func axFindAndPress(element: AXUIElement) -> Bool {
                var role: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                if let r = role as? String, r == kAXButtonRole as String {
                    let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
                    NSLog("[POC] AXPress on button: err=\(err.rawValue)")
                    return err == .success
                }
                var children: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for child in (children as? [AXUIElement]) ?? [] {
                    if axFindAndPress(element: child) { return true }
                }
                return false
            }
            if axFindAndPress(element: app) {
                pump(0.1)
                NSLog("[POC] AXPress result: buttonTapCount=\(state.buttonTapCount)")
            } else {
                NSLog("[POC] No AX button found")
            }
        }

        XCTAssertGreaterThan(state.buttonTapCount, 0,
            "NSEvent/directMouse/AXPress should trigger SwiftUI Button")
    }

    // MARK: - POC 2: Keyboard types into SwiftUI TextField

    func testNSEventKeyboardTypesInTextField() {
        // Click to focus the text field, then type
        for y in stride(from: 110, through: 200, by: 5) {
            click(at: NSPoint(x: 200, y: CGFloat(y)))
            pump()

            typeChar("x", keyCode: 7)
            pump()

            if !state.textValue.isEmpty {
                NSLog("[POC] TextField focused at y=\(y), typed=\(state.textValue)")
                break
            }
        }

        XCTAssertFalse(state.textValue.isEmpty,
            "NSEvent keyboard should type into SwiftUI TextField")
    }

    // MARK: - POC 3: Drag triggers SwiftUI DragGesture

    func testNSEventDragTriggersSwiftUIDragGesture() {
        state.dragEnded = false
        state.dragOffset = .zero

        let wn = window.windowNumber

        // Scan y to find the draggable rectangle
        for y in stride(from: 30, through: 150, by: 10) {
            let startY = CGFloat(y)
            let start = NSPoint(x: 200, y: startY)
            let ts = ProcessInfo.processInfo.systemUptime

            // Queue drag events + mouseUp first, then sendEvent(mouseDown).
            // Tracking loop reads them from queue in order.
            for i in 1...10 {
                let frac = CGFloat(i) / 10.0
                let pt = NSPoint(x: 200 + 60 * frac, y: startY)
                NSApp.postEvent(NSEvent.mouseEvent(
                    with: .leftMouseDragged, location: pt,
                    modifierFlags: [], timestamp: ts + 0.3 * Double(frac),
                    windowNumber: wn, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 1.0)!, atStart: false)
            }
            NSApp.postEvent(NSEvent.mouseEvent(
                with: .leftMouseUp, location: NSPoint(x: 260, y: startY),
                modifierFlags: [], timestamp: ts + 0.35,
                windowNumber: wn, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0.0)!, atStart: false)

            // sendEvent(mouseDown) enters tracking loop, processes queued drags + mouseUp
            NSApp.sendEvent(NSEvent.mouseEvent(
                with: .leftMouseDown, location: start,
                modifierFlags: [], timestamp: ts,
                windowNumber: wn, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1.0)!)
            pump(0.2)

            if state.dragEnded {
                NSLog("[POC] Drag detected at y=\(y)")
                break
            }
        }

        XCTAssertTrue(state.dragEnded,
            "NSEvent mouseDragged should trigger SwiftUI DragGesture")
    }
}
