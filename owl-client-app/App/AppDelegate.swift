import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import OWLBrowserLib
#endif

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let browserViewModel = BrowserViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("%@", "[OWL] AppDelegate.applicationDidFinishLaunching")

        // SPM bare executable needs this to become a proper foreground app
        // that can receive keyboard focus and appear in Dock/Cmd+Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Configure window for material backgrounds
        if let window = NSApplication.shared.windows.first {
            window.isOpaque = false
            window.backgroundColor = .clear
        }

        // Mojo initialization is deferred to ContentView.task {} —
        // must happen AFTER SwiftUI creates the window to avoid
        // mojo::core::Init() blocking WindowGroup creation.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        browserViewModel.shutdown()
    }
}
