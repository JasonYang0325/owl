import SwiftUI
#if SWIFT_PACKAGE
import OWLBrowserLib
#endif

@main
struct OWLBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(appDelegate.browserViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
    }
}
