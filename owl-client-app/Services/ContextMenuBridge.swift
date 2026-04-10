import Foundation

#if canImport(OWLBridge)
import OWLBridge
#endif

// MARK: - ContextMenuBridge (C-ABI callback registration)

/// Registers C-ABI context menu callback for a webview and forwards events
/// to ContextMenuHandler. Follows the same pattern as SSLBridge / DownloadBridge.
enum ContextMenuBridge {

    /// Register context menu callback for the given webview.
    /// The handler is passed as unretained context — caller must ensure it outlives the callback.
    static func register(webviewId: UInt64, handler: ContextMenuHandler) {
        #if canImport(OWLBridge)
        let ctx = Unmanaged.passUnretained(handler).toOpaque()
        OWLBridge_SetContextMenuCallback(webviewId, onContextMenu, ctx)
        #endif
    }

    /// Unregister context menu callback (set to NULL).
    static func unregister(webviewId: UInt64) {
        #if canImport(OWLBridge)
        OWLBridge_SetContextMenuCallback(webviewId, nil, nil)
        #endif
    }
}

// MARK: - C Callback (free function, no closure capture)

#if canImport(OWLBridge)
/// C-ABI callback matching OWLBridge_ContextMenuCallback signature.
/// Note: `is_editable` and `has_image_contents` are C `int`, which maps to `Int32` in Swift.
private func onContextMenu(
    webviewId: UInt64,
    type: Int32,
    isEditable: Int32,
    linkUrl: UnsafePointer<CChar>?,
    srcUrl: UnsafePointer<CChar>?,
    hasImageContents: Int32,
    selectionText: UnsafePointer<CChar>?,
    pageUrl: UnsafePointer<CChar>?,
    x: Int32,
    y: Int32,
    menuId: UInt32,
    ctx: UnsafeMutableRawPointer?
) {
    guard let ctx = ctx else { return }

    // Copy all C strings before escaping — pointers may be invalidated after return.
    let linkUrlStr = linkUrl.map { String(cString: $0) }.nilIfEmpty
    let srcUrlStr = srcUrl.map { String(cString: $0) }.nilIfEmpty
    let selectionTextStr = selectionText.map { String(cString: $0) }.nilIfEmpty
    let pageUrlStr: String
    if let p = pageUrl {
        pageUrlStr = String(cString: p)
    } else {
        pageUrlStr = ""
    }

    let handler = Unmanaged<ContextMenuHandler>.fromOpaque(ctx).takeUnretainedValue()
    let params = ContextMenuParams(
        type: ContextMenuType(rawValue: type) ?? .page,
        isEditable: isEditable,
        linkUrl: linkUrlStr,
        srcUrl: srcUrlStr,
        hasImageContents: hasImageContents,
        selectionText: selectionTextStr,
        pageUrl: pageUrlStr,
        x: Int(x), y: Int(y),
        menuId: menuId
    )

    // C-ABI guarantees main thread, but Swift doesn't know — bridge via Task.
    Task { @MainActor in
        handler.showContextMenu(params)
    }
}
#endif
