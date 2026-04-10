import Foundation

/// Context menu type aligned with C-ABI OWLBridgeContextMenuType.
enum ContextMenuType: Int32 {
    case page = 0
    case link = 1
    case image = 2
    case selection = 3
    case editable = 4
}

/// Context menu action aligned with C-ABI OWLBridgeContextMenuAction.
enum ContextMenuAction: Int32 {
    case copyLink = 0
    case copyImage = 1
    case saveImage = 2
    case copy = 3
    case cut = 4
    case paste = 5
    case selectAll = 6
    case openLinkInNewTab = 7
    case search = 8
    case copyImageUrl = 9
    case viewSource = 10
}

/// Parsed context menu parameters from C-ABI callback.
struct ContextMenuParams {
    let type: ContextMenuType
    let isEditable: Bool
    let linkUrl: String?
    let srcUrl: String?
    let hasImageContents: Bool
    let selectionText: String?
    let pageUrl: String
    let x: Int
    let y: Int
    let menuId: UInt32

    /// Init from C-ABI raw values (int for booleans).
    init(type: ContextMenuType,
         isEditable: Int32,
         linkUrl: String?,
         srcUrl: String?,
         hasImageContents: Int32,
         selectionText: String?,
         pageUrl: String,
         x: Int, y: Int,
         menuId: UInt32) {
        self.type = type
        self.isEditable = isEditable != 0
        self.linkUrl = linkUrl
        self.srcUrl = srcUrl
        self.hasImageContents = hasImageContents != 0
        self.selectionText = selectionText
        self.pageUrl = pageUrl
        self.x = x
        self.y = y
        self.menuId = menuId
    }
}

/// Host-side action descriptor attached to NSMenuItem.representedObject.
final class HostAction: NSObject {
    let action: ContextMenuAction
    let menuId: UInt32
    let payload: String?

    init(action: ContextMenuAction, menuId: UInt32, payload: String? = nil) {
        self.action = action
        self.menuId = menuId
        self.payload = payload
    }
}

// MARK: - String Helpers

extension Optional where Wrapped == String {
    /// Returns nil for empty strings; useful for C-ABI nullable string conversion.
    var nilIfEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
