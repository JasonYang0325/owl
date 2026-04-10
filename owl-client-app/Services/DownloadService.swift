import Foundation
#if canImport(OWLBridge)
import OWLBridge
#endif

/// Swift async/await wrapper around OWLBridge download C-ABI functions.
/// Uses Box<CheckedContinuation> pattern for C callback bridging.
enum OWLDownloadBridge {

    // MARK: - Query All Downloads

    /// Query all downloads. Returns decoded array of DownloadItem.
    /// Throws on C-ABI error or JSON decode failure (never silently returns empty).
    static func getAll() async throws -> [DownloadItem] {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { cont in
            final class Box {
                let value: CheckedContinuation<[DownloadItem], Error>
                init(_ v: CheckedContinuation<[DownloadItem], Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_DownloadGetAll({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(domain: "OWLDownload",
                        code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                guard let jsonArray else {
                    box.value.resume(returning: [])
                    return
                }
                let jsonStr = String(cString: jsonArray)
                guard let data = jsonStr.data(using: .utf8) else {
                    box.value.resume(throwing: NSError(domain: "OWLDownload",
                        code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 in JSON"]))
                    return
                }
                do {
                    let items = try JSONDecoder().decode([DownloadItem].self, from: data)
                    box.value.resume(returning: items)
                } catch {
                    box.value.resume(throwing: error)  // Throw decode error, never silently return empty
                }
            }, ctx)
        }
        #else
        return []
        #endif
    }

    // MARK: - Control Operations (fire-and-forget, no callback)

    static func pause(id: UInt32) {
        #if canImport(OWLBridge)
        OWLBridge_DownloadPause(id)
        #endif
    }

    static func resume(id: UInt32) {
        #if canImport(OWLBridge)
        OWLBridge_DownloadResume(id)
        #endif
    }

    static func cancel(id: UInt32) {
        #if canImport(OWLBridge)
        OWLBridge_DownloadCancel(id)
        #endif
    }

    static func removeEntry(id: UInt32) {
        #if canImport(OWLBridge)
        OWLBridge_DownloadRemoveEntry(id)
        #endif
    }

    static func openFile(id: UInt32) {
        #if canImport(OWLBridge)
        OWLBridge_DownloadOpenFile(id)
        #endif
    }

    static func showInFolder(id: UInt32) {
        #if canImport(OWLBridge)
        OWLBridge_DownloadShowInFolder(id)
        #endif
    }
}
