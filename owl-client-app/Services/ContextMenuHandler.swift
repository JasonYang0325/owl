import AppKit
import Foundation

#if canImport(OWLBridge)
import OWLBridge
#endif

/// NSMenuItem subclass that holds a closure for local (non-IPC) actions.
final class CallbackMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, keyEquivalent: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(invokeCallback(_:)), keyEquivalent: keyEquivalent)
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("Not supported") }

    @objc private func invokeCallback(_ sender: Any?) {
        callback()
    }
}

/// Builds and displays NSMenu for context menu events from the Chromium Host.
/// Independent from TabViewModel — receives the view reference and webviewId
/// to execute actions.
@MainActor
package final class ContextMenuHandler: NSObject {
    /// The NSView on which to display the popup menu (RemoteLayerView).
    weak var view: NSView?

    /// The webview ID for C-ABI calls (set once on creation).
    let webviewId: UInt64

    /// Navigation state needed for page-type context menu.
    weak var tabViewModel: TabViewModel?

    init(webviewId: UInt64) {
        self.webviewId = webviewId
        super.init()
    }

    deinit {
        ContextMenuBridge.unregister(webviewId: webviewId)
    }

    // MARK: - Show Context Menu

    func showContextMenu(_ params: ContextMenuParams) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch params.type {
        case .editable:
            buildEditableMenu(menu, params: params)
        case .link:
            buildLinkMenu(menu, params: params)
        case .image:
            buildImageMenu(menu, params: params)
        case .selection:
            buildSelectionMenu(menu, params: params)
        case .page:
            buildPageMenu(menu, params: params)
        }

        guard menu.items.count > 0 else { return }

        // WebContents 坐标系: 原点左上角，Y 轴向下 (DIP)
        // NSView 坐标系: 原点左下角，Y 轴向上 (points，与 DIP 等价)
        // 假设: RemoteLayerView frame 与 WebContents 视口对齐，无偏移
        guard let view = self.view else { return }
        let flippedY = view.bounds.height - CGFloat(params.y)
        let pt = NSPoint(x: CGFloat(params.x), y: flippedY)
        menu.popUp(positioning: nil, at: pt, in: view)
    }

    // MARK: - Menu Builders (by type)

    private func buildEditableMenu(_ menu: NSMenu, params: ContextMenuParams) {
        menu.addItem(makeHostItem("剪切", action: .cut, key: "x", menuId: params.menuId))
        menu.addItem(makeHostItem("复制", action: .copy, key: "c", menuId: params.menuId))
        menu.addItem(makeHostItem("粘贴", action: .paste, key: "v", menuId: params.menuId))
        menu.addItem(.separator())
        menu.addItem(makeHostItem("全选", action: .selectAll, key: "a", menuId: params.menuId))
    }

    private func buildLinkMenu(_ menu: NSMenu, params: ContextMenuParams) {
        guard let url = params.linkUrl, !url.isEmpty else { return }
        menu.addItem(makeHostItem("在新标签页中打开", action: .openLinkInNewTab,
                                   menuId: params.menuId, payload: url))
        menu.addItem(makeLocalItem("复制链接地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        })
    }

    private func buildImageMenu(_ menu: NSMenu, params: ContextMenuParams) {
        guard let url = params.srcUrl, !url.isEmpty else { return }
        menu.addItem(makeHostItem("将图片存储到「下载」", action: .saveImage,
                                   menuId: params.menuId, payload: url))
        menu.addItem(.separator())
        menu.addItem(makeHostItem("复制图片", action: .copyImage,
                                   menuId: params.menuId, payload: url))
        menu.addItem(makeLocalItem("复制图片地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        })
    }

    private func buildSelectionMenu(_ menu: NSMenu, params: ContextMenuParams) {
        guard let text = params.selectionText, !text.isEmpty else { return }
        menu.addItem(makeLocalItem("复制", key: "c") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        let display = text.count <= 20 ? text : String(text.prefix(17)) + "..."
        menu.addItem(makeHostItem("搜索\"\(display)\"", action: .search,
                                   menuId: params.menuId, payload: text))
    }

    private func buildPageMenu(_ menu: NSMenu, params: ContextMenuParams) {
        let tab = tabViewModel

        let backItem = makeLocalItem("后退", key: "[") { [weak tab] in
            tab?.goBack()
        }
        backItem.isEnabled = tab?.canGoBack ?? false
        menu.addItem(backItem)

        let fwdItem = makeLocalItem("前进", key: "]") { [weak tab] in
            tab?.goForward()
        }
        fwdItem.isEnabled = tab?.canGoForward ?? false
        menu.addItem(fwdItem)

        menu.addItem(makeLocalItem("重新加载", key: "r") { [weak tab] in
            tab?.reload()
        })
    }

    // MARK: - Item Factories

    /// Host action item — executes via C-ABI IPC.
    private func makeHostItem(_ title: String, action: ContextMenuAction,
                               key: String = "", menuId: UInt32,
                               payload: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(executeHostAction(_:)),
                              keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        item.target = self
        item.representedObject = HostAction(action: action, menuId: menuId, payload: payload)
        return item
    }

    /// Local action item — executes closure directly (no IPC).
    private func makeLocalItem(_ title: String, key: String = "",
                                handler: @escaping () -> Void) -> NSMenuItem {
        let item = CallbackMenuItem(title: title, keyEquivalent: key, callback: handler)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        return item
    }

    // MARK: - Host Action Execution

    @objc private func executeHostAction(_ sender: NSMenuItem) {
        guard let hostAction = sender.representedObject as? HostAction else { return }
        #if canImport(OWLBridge)
        // Parameter order: (webview_id, action, menu_id, payload) — matches C header
        let payloadStr = hostAction.payload ?? ""
        payloadStr.withCString { payloadCStr in
            OWLBridge_ExecuteContextMenuAction(
                webviewId,
                hostAction.action.rawValue,
                hostAction.menuId,
                payloadCStr)
        }
        #endif
    }
}
