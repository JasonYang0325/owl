import Foundation
#if canImport(OWLBridge)
import OWLBridge
#endif

/// A single bookmark item returned from the Host process.
package struct BookmarkItem: Codable, Identifiable, Equatable, Sendable {
    package let id: String
    package var title: String
    package var url: String
    package var parent_id: String?
}

/// Swift async/await wrapper around OWLBridge bookmark C-ABI functions.
/// Uses Box<CheckedContinuation> pattern for C callback bridging.
enum OWLBookmarkBridge {

    // MARK: - Add

    /// Add a bookmark. Returns the created BookmarkItem on success.
    static func add(title: String, url: String, parentId: String? = nil) async throws -> BookmarkItem {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BookmarkItem, Error>) in
            final class Box {
                let value: CheckedContinuation<BookmarkItem, Error>
                init(_ value: CheckedContinuation<BookmarkItem, Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            let callback: OWLBridge_BookmarkAddCallback = { json, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLBookmark", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                guard let json,
                      let data = String(cString: json).data(using: .utf8),
                      let item = try? JSONDecoder().decode(BookmarkItem.self, from: data) else {
                    box.value.resume(throwing: NSError(
                        domain: "OWLBookmark", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode bookmark JSON"]))
                    return
                }
                box.value.resume(returning: item)
            }

            title.withCString { titlePtr in
                url.withCString { urlPtr in
                    if let parentId {
                        parentId.withCString { parentPtr in
                            OWLBridge_BookmarkAdd(titlePtr, urlPtr, parentPtr, callback, ctx)
                        }
                    } else {
                        OWLBridge_BookmarkAdd(titlePtr, urlPtr, nil, callback, ctx)
                    }
                }
            }
        }
    }

    // MARK: - Get All

    /// Get all bookmarks as an array.
    static func getAll() async throws -> [BookmarkItem] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[BookmarkItem], Error>) in
            final class Box {
                let value: CheckedContinuation<[BookmarkItem], Error>
                init(_ value: CheckedContinuation<[BookmarkItem], Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            OWLBridge_BookmarkGetAll({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLBookmark", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                guard let jsonArray,
                      let data = String(cString: jsonArray).data(using: .utf8),
                      let items = try? JSONDecoder().decode([BookmarkItem].self, from: data) else {
                    box.value.resume(throwing: NSError(
                        domain: "OWLBookmark", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode bookmark list JSON"]))
                    return
                }
                box.value.resume(returning: items)
            }, ctx)
        }
    }

    // MARK: - Remove

    /// Remove a bookmark by ID. Returns true if removed.
    static func remove(id: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            final class Box {
                let value: CheckedContinuation<Bool, Error>
                init(_ value: CheckedContinuation<Bool, Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            id.withCString { idPtr in
                OWLBridge_BookmarkRemove(idPtr, { success, errorMsg, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    if let errorMsg {
                        box.value.resume(throwing: NSError(
                            domain: "OWLBookmark", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                        return
                    }
                    box.value.resume(returning: success != 0)
                }, ctx)
            }
        }
    }

    // MARK: - Update

    /// Update a bookmark's title and/or URL. Pass nil for fields to keep unchanged.
    /// Returns true if the bookmark was found and updated.
    static func update(id: String, title: String? = nil, url: String? = nil) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            final class Box {
                let value: CheckedContinuation<Bool, Error>
                init(_ value: CheckedContinuation<Bool, Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            let callBridge = { (idPtr: UnsafePointer<CChar>,
                                titlePtr: UnsafePointer<CChar>?,
                                urlPtr: UnsafePointer<CChar>?) in
                OWLBridge_BookmarkUpdate(idPtr, titlePtr, urlPtr, { success, errorMsg, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    if let errorMsg {
                        box.value.resume(throwing: NSError(
                            domain: "OWLBookmark", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                        return
                    }
                    box.value.resume(returning: success != 0)
                }, ctx)
            }

            // Use withCString for non-nil values, nil otherwise.
            id.withCString { idPtr in
                if let title, let url {
                    title.withCString { tPtr in
                        url.withCString { uPtr in
                            callBridge(idPtr, tPtr, uPtr)
                        }
                    }
                } else if let title {
                    title.withCString { tPtr in
                        callBridge(idPtr, tPtr, nil)
                    }
                } else if let url {
                    url.withCString { uPtr in
                        callBridge(idPtr, nil, uPtr)
                    }
                } else {
                    callBridge(idPtr, nil, nil)
                }
            }
        }
    }
}
