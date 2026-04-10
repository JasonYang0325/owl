import Foundation

#if canImport(OWLBridge)
import OWLBridge
#endif

// MARK: - DownloadBridge (C-ABI callback holder)

/// Global singleton that registers C-ABI download event callbacks and
/// forwards events to DownloadViewModel.
/// Follows the same pattern as HistoryBridge / SSLBridge / PermissionBridge.
@MainActor
final class DownloadBridge {
    static let shared = DownloadBridge()

    // Weak reference: DownloadViewModel is strongly held by BrowserViewModel.
    private weak var downloadVM: DownloadViewModel?

    /// Call once from BrowserViewModel.registerAllCallbacks() after CreateWebView.
    /// Registers global download event callback.
    func register(downloadVM: DownloadViewModel) {
        self.downloadVM = downloadVM

        #if canImport(OWLBridge)
        OWLBridge_SetDownloadCallback(downloadEventCallback, nil)
        #endif
    }

    /// Unregister callbacks (app shutdown).
    func unregister() {
        #if canImport(OWLBridge)
        OWLBridge_SetDownloadCallback(nil, nil)
        #endif
        downloadVM = nil
    }

    /// Internal: forward created/updated download event to DownloadViewModel.
    fileprivate func forward(item: DownloadItem, eventType: Int32) {
        switch eventType {
        case 0: downloadVM?.onDownloadCreated(item)
        case 1: downloadVM?.onDownloadUpdated(item)
        default: break
        }
    }

    /// Internal: forward removed download event to DownloadViewModel.
    fileprivate func forwardRemoved(id: UInt32) {
        downloadVM?.onDownloadRemoved(id: id)
    }
}

// MARK: - C Callbacks (free functions, no closure capture)

/// Minimal struct for decoding removed events (only contains id).
private struct RemovedEvent: Decodable {
    let id: UInt32
}

#if canImport(OWLBridge)
private func downloadEventCallback(jsonItem: UnsafePointer<CChar>?,
                                    eventType: Int32,
                                    ctx: UnsafeMutableRawPointer?) {
    guard let jsonItem else { return }
    let jsonStr = String(cString: jsonItem)
    guard let data = jsonStr.data(using: .utf8) else { return }

    if eventType == 2 {
        // removed event: JSON only contains {"id": N}, do not decode full DownloadItem
        guard let event = try? JSONDecoder().decode(RemovedEvent.self, from: data) else {
            NSLog("%@", "[OWL] DownloadBridge: failed to decode removed event JSON: \(jsonStr.prefix(200))")
            return
        }
        Task { @MainActor in
            DownloadBridge.shared.forwardRemoved(id: event.id)
        }
    } else {
        // created/updated events: full DownloadItem JSON
        guard let item = try? JSONDecoder().decode(DownloadItem.self, from: data) else {
            NSLog("%@", "[OWL] DownloadBridge: failed to decode event JSON: \(jsonStr.prefix(200))")
            return
        }
        Task { @MainActor in
            DownloadBridge.shared.forward(item: item, eventType: eventType)
        }
    }
}
#endif
