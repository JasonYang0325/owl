import Foundation

#if canImport(OWLBridge)
import OWLBridge
private let useMockMode = false
#else
private let useMockMode = true
#endif

@MainActor
package class BookmarkViewModel: ObservableObject {
    @Published package var bookmarks: [BookmarkItem] = []
    @Published package var isLoading = false

    // MARK: - MockConfig

    package struct MockConfig {
        package var bookmarks: [BookmarkItem]
        package init(bookmarks: [BookmarkItem] = []) {
            self.bookmarks = bookmarks
        }
    }

    private var mockConfig: MockConfig?
    private var isMockMode: Bool { mockConfig != nil || useMockMode }

    /// BH-022: Guard against duplicate addCurrentPage calls during async suspension.
    private var isAdding = false

    package init() {}

    package convenience init(mockConfig: MockConfig) {
        self.init()
        self.mockConfig = mockConfig
    }

    // MARK: - Public API

    package func loadAll() async {
        if isMockMode {
            bookmarks = mockConfig?.bookmarks ?? []
            return
        }
        #if canImport(OWLBridge)
        isLoading = true
        defer { isLoading = false }
        do {
            bookmarks = try await OWLBookmarkBridge.getAll()
        } catch {
            NSLog("%@", "[OWL] BookmarkViewModel.loadAll failed: \(error)")
        }
        #endif
    }

    @discardableResult
    package func addCurrentPage(title: String, url: String) async -> Bool {
        // BH-022: Prevent duplicate adds while an async operation is in-flight.
        guard !isAdding else { return false }
        isAdding = true
        defer { isAdding = false }

        let effectiveTitle = title.isEmpty ? url : title
        if isMockMode {
            let item = BookmarkItem(id: UUID().uuidString, title: effectiveTitle, url: url, parent_id: nil)
            bookmarks.insert(item, at: 0)
            return true
        }
        #if canImport(OWLBridge)
        do {
            let item = try await OWLBookmarkBridge.add(title: effectiveTitle, url: url, parentId: nil)
            bookmarks.insert(item, at: 0)
            return true
        } catch {
            NSLog("%@", "[OWL] BookmarkViewModel.addCurrentPage failed: \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    @discardableResult
    package func removeBookmark(id: String) async -> Bool {
        if isMockMode {
            let countBefore = bookmarks.count
            bookmarks.removeAll { $0.id == id }
            return bookmarks.count < countBefore
        }
        #if canImport(OWLBridge)
        do {
            let removed = try await OWLBookmarkBridge.remove(id: id)
            if removed {
                bookmarks.removeAll { $0.id == id }
            }
            return removed
        } catch {
            NSLog("%@", "[OWL] BookmarkViewModel.removeBookmark failed: \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    package func isBookmarked(url: String?) -> Bool {
        bookmarkId(for: url) != nil
    }

    package func bookmarkId(for url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        return bookmarks.first { $0.url == url }?.id
    }
}
