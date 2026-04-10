import SwiftUI
import AppKit

#if canImport(OWLBridge)
import OWLBridge
#endif

/// SwiftUI wrapper for OWLRemoteLayerView (ObjC).
/// Embeds Chromium's compositor output via CALayerHost.
struct RemoteLayerView: NSViewRepresentable {
    let webviewId: UInt64
    let contextId: UInt32
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let scaleFactor: Float
    // Phase 35: Cross-screen DPI change callback.
    var onScaleChange: ((CGFloat, CGSize) -> Void)?
    /// Callback to expose the underlying NSView for context menu positioning.
    var onViewCreated: ((NSView) -> Void)?

    func makeNSView(context: Context) -> NSView {
        #if canImport(OWLBridge)
        let view = OWLRemoteLayerView(frame: .zero)
        view.webviewId = webviewId
        view.setAccessibilityIdentifier("webContentView")
        onViewCreated?(view)
        return view
        #else
        let view = NSView()
        view.setAccessibilityIdentifier("webContentView")
        onViewCreated?(view)
        return view
        #endif
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        #if canImport(OWLBridge)
        if let view = nsView as? OWLRemoteLayerView {
            view.webviewId = webviewId
            view.update(withContextId: contextId,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight,
                        scaleFactor: scaleFactor)
            // Phase 35: Bind scale change handler on every update.
            view.scaleChangeHandler = onScaleChange
        }
        #endif
        // Ensure context menu handler always has the current view reference.
        onViewCreated?(nsView)
    }
}
