import SwiftUI
import AppKit

// MARK: - AX label backed by NSTextField (AXStaticText role)
//
// SwiftUI Text() with frame(1,1)+clipped() does not reliably post
// NSAccessibilityLayoutChangedNotification, so XCUITest sees stale
// snapshots even after @Published properties change.  NSTextField
// posts NSAccessibilityValueChangedNotification synchronously whenever
// stringValue is set, guaranteeing XCUITest reads the fresh value.
//
// The NSTextField subclass overrides accessibilityRole to return
// .staticText so that XCUITest's app.staticTexts["identifier"] query
// finds the element (default NSTextField in a SwiftUI context reports
// AXUnknown which staticTexts queries ignore).
private struct AccessibleLabel: NSViewRepresentable {
    var value: String
    var identifier: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.focusRingType = .none
        field.alphaValue = 0.005  // nearly invisible; alphaValue=0 disables AX
        field.setAccessibilityIdentifier(identifier)
        // Force AXStaticText role so XCUITest's app.staticTexts[] finds it
        field.setAccessibilityRole(.staticText)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        guard field.stringValue != value else { return }
        field.stringValue = value
        // Keep AX role and value in sync after each update
        field.setAccessibilityRole(.staticText)
        field.setAccessibilityValue(value)
        field.setAccessibilityLabel(value)
        NSAccessibility.post(element: field, notification: .valueChanged)
    }
}

struct TopBarView: View {
    @EnvironmentObject var viewModel: BrowserViewModel
    let layoutMode: LayoutMode
    var onTogglePanel: ((RightPanel) -> Void)? = nil
    var onToggleSidebar: (() -> Void)? = nil
    var isSidebarVisible: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            // Window controls space (red/yellow/green are system-managed)
            Spacer()
                .frame(width: 72)

            // Sidebar toggle — inline, hidden in minimal mode
            if layoutMode != .minimal {
                Button(action: { onToggleSidebar?() }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14))
                        .foregroundColor(OWL.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: OWL.radiusSmall)
                                .fill(Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebarToggleButton")
                .accessibilityValue(isSidebarVisible ? "expanded" : "collapsed")
                .padding(.trailing, 4)
            }

            if let tab = viewModel.activeTab {
                ActiveTabTopBar(tab: tab, bookmarkVM: viewModel.bookmarkVM,
                                securityVM: viewModel.securityVM)
            } else {
                NavigationButtons()
                Spacer()
                AddressBarView()
                Spacer()
            }

            if layoutMode == .minimal {
                CompactTabSwitcher()
            }
        }
        .frame(height: OWL.topBarHeight)
        .background(OWL.surfacePrimary)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Inner view that observes the active TabViewModel directly,
/// so SwiftUI re-renders when tab properties (URL, loading, etc.) change.
private struct ActiveTabTopBar: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject var bookmarkVM: BookmarkViewModel
    @ObservedObject var securityVM: SecurityViewModel

    var body: some View {
        NavigationButtons(
            canGoBack: tab.canGoBack,
            canGoForward: tab.canGoForward,
            isLoading: tab.isLoading,
            onGoBack: { tab.goBack() },
            onGoForward: { tab.goForward() },
            onReloadOrStop: { tab.isLoading ? tab.stop() : tab.reload() }
        )

        Spacer()

        AddressBarView(
            displayDomain: tab.displayDomain,
            displayURL: tab.url,
            onNavigate: { text in
                tab.navigate(to: text)
            },
            activeTab: tab,
            bookmarkVM: bookmarkVM,
            securityLevel: securityVM.level
        )

        // Hidden labels for XCUITest to read page state.
        // Use NSTextField-backed AccessibleLabel: NSTextField posts
        // NSAccessibilityValueChangedNotification synchronously, so
        // XCUITest sees changes immediately instead of using stale snapshots.
        AccessibleLabel(value: tab.title, identifier: "pageTitle")
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        AccessibleLabel(value: tab.pendingURL ?? tab.url ?? "", identifier: "pageURL")
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        AccessibleLabel(value: tab.isLoading ? "true" : "false", identifier: "pageLoading")
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)

        Spacer()
    }
}
