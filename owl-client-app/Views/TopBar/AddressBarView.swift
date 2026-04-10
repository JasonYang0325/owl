import SwiftUI
import AppKit

// MARK: - NSTextField-backed address bar field
//
// Why NSViewRepresentable instead of SwiftUI TextField:
//
// XCUITest's typeText("url\n") synthesises a Return key event (keyCode 36)
// through the real macOS event system.  AppKit routes it via the responder
// chain and calls NSTextFieldDelegate.control(_:textView:doCommandBy:) with
// the selector `insertNewline:`.  SwiftUI's wrapped TextField does not surface
// that selector path reliably on macOS 14+ — onSubmit / onKeyPress(.return)
// may silently miss synthetic Return events, and onChange never sees "\n"
// because AppKit consumes the Return before writing it to the field's text
// storage.  Using NSTextField directly ensures every code path (real typing,
// typeText+\n, typeKey(.return)) hits the same delegate method.
//
// The onTapGesture that was previously on the outer HStack has been removed.
// It competed with XCUITest click() for first-responder promotion: the gesture
// recognizer called makeFirstResponder on the SwiftUI focus engine path, but
// the underlying NSTextField was sometimes not yet the actual key-window
// first responder when the subsequent typeKey("a", .command) arrived.
// Letting AppKit handle click-to-focus natively avoids this race.

private struct AddressTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isFocused: Bool
    var editingText: String?
    var onNavigate: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 14)
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        // Accessibility: XCUITest finds this by identifier "addressBar"
        field.setAccessibilityIdentifier("addressBar")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // CRITICAL: keep coordinator in sync with the latest parent struct so
        // that closures (onNavigate, onFocusChange) are never stale.
        context.coordinator.parent = self

        // Keep placeholder in sync with focus/URL state
        field.placeholderString = placeholder

        let isEditing = field.currentEditor() != nil
        // Keep the AppKit field in sync with programmatic state transitions.
        // In particular, when focus is gained we swap host display -> full URL.
        // Live typing still stays stable because controlTextDidChange keeps the
        // binding synchronized with the editor's current string.
        if field.stringValue != text && (!isEditing || isFocused) {
            field.stringValue = text
        }

        // Focus resignation is handled directly by the Coordinator's
        // fieldAction/doCommandBy (which call makeFirstResponder(nil) on
        // navigation). Do NOT remove focus here based on isFocused state —
        // there's a race: XCUITest click makes the field first responder,
        // but controlTextDidBeginEditing hasn't fired yet so isFocused is
        // still false, causing updateNSView to immediately steal focus back.
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressTextField

        init(_ parent: AddressTextField) {
            self.parent = parent
        }

        // Called by NSTextField when the user presses Return (action target).
        // Also called by typeText("url\n") and typeKey(.return) from XCUITest.
        @objc func fieldAction(_ sender: NSTextField) {
            let value = sender.stringValue
            parent.text = value
            parent.onNavigate?(value)
            parent.onFocusChange?(false)
            sender.window?.makeFirstResponder(nil)
        }

        // Also handles Return via the command-action path (covers all AppKit
        // routes: real key, CGEvent injection, and XCUITest synthetic events).
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let value = (control as? NSTextField)?.stringValue ?? textView.string
                parent.text = value
                parent.onNavigate?(value)
                parent.onFocusChange?(false)
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        // Sync live edits back to SwiftUI binding
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Notify focus gained
        func controlTextDidBeginEditing(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                let value = parent.editingText ?? field.stringValue
                if field.stringValue != value {
                    field.stringValue = value
                }
                parent.text = value
            }
            parent.onFocusChange?(true)
        }

        // Notify focus lost (Tab away, click elsewhere)
        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusChange?(false)
        }
    }
}

// MARK: - Zoom Indicator (Phase 34)

/// Inner view with @ObservedObject so SwiftUI re-renders on zoomLevel changes.
private struct ZoomIndicator: View {
    @ObservedObject var tab: TabViewModel

    var body: some View {
        if !tab.isDefaultZoom {
            Button("\(tab.zoomPercent)%") {
                tab.resetZoom()
            }
            .font(OWL.captionFont)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("zoomIndicator")
        }
    }
}

// MARK: - AddressBarView

struct AddressBarView: View {
    @State private var inputText = ""
    @State private var isFocused: Bool = false

    // Phase 13 接入: displayDomain, onSubmit
    var displayDomain: String? = nil
    var displayURL: String? = nil
    var onNavigate: ((String) -> Void)? = nil
    // Phase 34: Zoom indicator needs access to the active tab.
    var activeTab: TabViewModel? = nil
    // Bookmark star button support.
    var bookmarkVM: BookmarkViewModel? = nil
    // Phase 4: Security level for the lock icon.
    var securityLevel: SecurityLevel = .info

    private var placeholder: String {
        "搜索或输入 URL"
    }

    var body: some View {
        HStack(spacing: 6) {
            if !isFocused && displayDomain != nil {
                SecurityIndicator(level: securityLevel)
                    .font(.system(size: 12))
            }
            AddressTextField(
                text: $inputText,
                placeholder: placeholder,
                isFocused: isFocused,
                editingText: displayURL ?? displayDomain ?? "",
                onNavigate: { url in
                    onNavigate?(url)
                    inputText = ""
                    isFocused = false
                },
                onFocusChange: { focused in
                    isFocused = focused
                    if focused {
                        // Show full URL when focused for easy editing
                        inputText = displayURL ?? displayDomain ?? ""
                    } else if inputText.isEmpty {
                        // Restore domain display after losing focus
                        inputText = displayDomain ?? ""
                    }
                }
            )
            // Phase 34: Zoom percentage indicator (non-100% only).
            if let tab = activeTab {
                ZoomIndicator(tab: tab)
            }
            // Bookmark star button.
            if let bvm = bookmarkVM {
                let url = activeTab?.url
                StarButton(
                    isBookmarked: bvm.isBookmarked(url: url),
                    isEnabled: url != nil && !(url?.isEmpty ?? true),
                    onToggle: {
                        guard let tab = activeTab, let tabURL = tab.url, !tabURL.isEmpty else { return }
                        if let existingId = bvm.bookmarkId(for: tabURL) {
                            await bvm.removeBookmark(id: existingId)
                        } else {
                            await bvm.addCurrentPage(title: tab.title, url: tabURL)
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 32)
        .frame(maxWidth: 600)
        .background(OWL.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: OWL.radiusLarge))
        .overlay(alignment: .bottom) {
            if let tab = activeTab, tab.loadingProgress > 0 {
                ProgressBar(progress: tab.loadingProgress)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: OWL.radiusLarge)
                .stroke(isFocused ? OWL.accentPrimary : .clear, lineWidth: 2)
        )
        .onChange(of: displayDomain) { _, newDomain in
            if !isFocused {
                inputText = newDomain ?? ""
            }
        }
    }
}
