import Foundation

#if canImport(OWLBridge)
import OWLBridge
#endif

// MARK: - HistoryBridge (C-ABI callback holder)

/// Global singleton that registers C-ABI history change callbacks and
/// forwards events to HistoryViewModel.
/// Follows the same pattern as SSLBridge / PermissionBridge.
@MainActor
final class HistoryBridge {
    static let shared = HistoryBridge()

    // Weak reference: HistoryViewModel is strongly held by BrowserViewModel.
    private weak var historyVM: HistoryViewModel?

    /// Call once from BrowserViewModel.registerAllCallbacks() after CreateWebView.
    /// Registers global history changed callback.
    func register(historyVM: HistoryViewModel) {
        self.historyVM = historyVM

        #if canImport(OWLBridge)
        OWLBridge_SetHistoryChangedCallback(historyChangedCallback, nil)
        #endif
    }

    /// Unregister callbacks (app shutdown).
    func unregister() {
        // Note: C-ABI function pointer is non-nullable, use a no-op stub to unregister.
        #if canImport(OWLBridge)
        let noopCtx: UnsafeMutableRawPointer? = nil
        OWLBridge_SetHistoryChangedCallback({ _, _ in }, noopCtx)
        #endif
        historyVM = nil
    }

    /// Internal: forward history change to HistoryViewModel.
    fileprivate func forward(url: String) {
        historyVM?.onHistoryChanged(url: url)
    }
}

// MARK: - C Callbacks (free functions, no closure capture)

#if canImport(OWLBridge)
private func historyChangedCallback(url: UnsafePointer<CChar>?,
                                     ctx: UnsafeMutableRawPointer?) {
    let urlStr = url.map { String(cString: $0) } ?? ""

    // C-ABI guarantees main thread, but Swift doesn't know — bridge via Task.
    Task { @MainActor in
        HistoryBridge.shared.forward(url: urlStr)
    }
}
#endif
