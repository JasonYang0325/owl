import SwiftUI
import AppKit

#if canImport(OWLBridge)
import OWLBridge

/// Embeds OWLWebContentView (NSView) into SwiftUI.
/// The NSView instance is owned by TabViewModel, not by SwiftUI lifecycle.
struct WebContentRepresentable: NSViewRepresentable {
    let webContentView: OWLWebContentView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.addSubview(webContentView)
        webContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webContentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webContentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webContentView.topAnchor.constraint(equalTo: container.topAnchor),
            webContentView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
