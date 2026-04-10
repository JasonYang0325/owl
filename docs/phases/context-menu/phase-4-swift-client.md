# Phase 4: Swift ContextMenuHandler 客户端

## 目标

实现 Swift 侧的 NSMenu 构建与显示，连接已完成的 C-ABI 管线。完成后用户可在页面上右键看到菜单并执行操作。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 新增 | `owl-client-app/Services/ContextMenuBridge.swift` | C-ABI 回调注册 |
| 新增 | `owl-client-app/Services/ContextMenuHandler.swift` | NSMenu 构建 + 显示（持有 view 引用） |
| 新增 | `owl-client-app/Models/ContextMenuParams.swift` | 类型定义 |
| 修改 | `owl-client-app/Views/Content/RemoteLayerView.swift` 或 `OWLRemoteLayerView.mm` | 创建 ContextMenuHandler 实例 |
| 修改 | `owl-client-app/Services/OWLBridgeSwift.swift` | registerAllCallbacks 中注册 context menu |

## 依赖

- Phase 1-3 Host+Bridge 已完成（C-ABI 接口就绪）
- 现有 OWLBridgeSwift.registerAllCallbacks 模式

## 技术方案

### 1. 架构

```
OWLBridge_ContextMenuCallback (C-ABI, main thread)
  → ContextMenuBridge.handleContextMenu() (free function)
  → Task { @MainActor in tabViewModel.showContextMenu(...) }
  → TabViewModel 构建 NSMenu
  → NSMenu.popUp(positioning:at:in:) on RemoteLayerView
  → 用户选择菜单项
  → 本地操作: NSPasteboard.general.setString()
  → Host 操作: OWLBridge_ExecuteContextMenuAction()
```

### 2. ContextMenuBridge.swift

```swift
import Foundation

enum ContextMenuBridge {
    static func register(webviewId: UInt64, handler: TabViewModel) {
        let ctx = Unmanaged.passUnretained(handler).toOpaque()
        OWLBridge_SetContextMenuCallback(webviewId, onContextMenu, ctx)
    }

    static func unregister(webviewId: UInt64) {
        OWLBridge_SetContextMenuCallback(webviewId, nil, nil)
    }
}

// C-ABI 回调: int(非 Bool) 匹配 C 头文件签名
private func onContextMenu(
    type: Int32, isEditable: Int32,
    linkUrl: UnsafePointer<CChar>?, srcUrl: UnsafePointer<CChar>?,
    hasImageContents: Int32, selectionText: UnsafePointer<CChar>?,
    pageUrl: UnsafePointer<CChar>?,
    x: Int32, y: Int32, menuId: UInt32, ctx: UnsafeMutableRawPointer?
) {
    guard let ctx = ctx else { return }
    // 注意: 回调已在 main thread (C-ABI 约定)，但仍用 Task 确保 @MainActor 隔离
    let handler = Unmanaged<ContextMenuHandler>.fromOpaque(ctx).takeUnretainedValue()
    let params = ContextMenuParams(
        type: ContextMenuType(rawValue: type) ?? .page,
        isEditable: isEditable,
        linkUrl: linkUrl.flatMap { String(cString: $0) }.nilIfEmpty,
        srcUrl: srcUrl.flatMap { String(cString: $0) }.nilIfEmpty,
        hasImageContents: hasImageContents,
        selectionText: selectionText.flatMap { String(cString: $0) }.nilIfEmpty,
        pageUrl: String(cString: pageUrl ?? ""),
        x: Int(x), y: Int(y), menuId: menuId
    )
    Task { @MainActor in vm.showContextMenu(params) }
}
```

### 3. ContextMenuParams 模型

```swift
enum ContextMenuType: Int32 {
    case page = 0, link = 1, image = 2, selection = 3, editable = 4
}

struct ContextMenuParams {
    let type: ContextMenuType
    let isEditable: Bool
    let linkUrl: String?
    let srcUrl: String?
    let hasImageContents: Bool
    let selectionText: String?
    let pageUrl: String
    let x: Int, y: Int
    let menuId: UInt32
}
```

### 4. TabViewModel.showContextMenu

```swift
@MainActor
func showContextMenu(_ params: ContextMenuParams) {
    let menu = NSMenu()
    menu.autoenablesItems = false

    switch params.type {
    case .editable:
        menu.addItem(makeHostItem("剪切", action: .cut, key: "x", menuId: params.menuId))
        menu.addItem(makeHostItem("复制", action: .copy, key: "c", menuId: params.menuId))
        menu.addItem(makeHostItem("粘贴", action: .paste, key: "v", menuId: params.menuId))
        menu.addItem(.separator())
        menu.addItem(makeHostItem("全选", action: .selectAll, key: "a", menuId: params.menuId))

    case .link:
        guard let url = params.linkUrl, !url.isEmpty else { return }
        menu.addItem(makeHostItem("在新标签页中打开", action: .openLinkInNewTab,
                                   menuId: params.menuId, payload: url))
        menu.addItem(makeLocalItem("复制链接地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        })

    case .image:
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

    case .selection:
        guard let text = params.selectionText, !text.isEmpty else { return }
        menu.addItem(makeLocalItem("复制", key: "c") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        let display = text.count <= 20 ? text : String(text.prefix(17)) + "..."
        menu.addItem(makeHostItem("搜索\"\(display)\"", action: .search,
                                   menuId: params.menuId, payload: text))

    case .page:
        let backItem = makeLocalItem("后退", key: "[") { [weak self] in
            self?.goBack()
        }
        backItem.isEnabled = canGoBack
        menu.addItem(backItem)

        let fwdItem = makeLocalItem("前进", key: "]") { [weak self] in
            self?.goForward()
        }
        fwdItem.isEnabled = canGoForward
        menu.addItem(fwdItem)

        menu.addItem(makeLocalItem("重新加载", key: "r") { [weak self] in
            self?.reload()
        })
    }

    // 坐标: params.x/y 是 WebContents view-local DIP 坐标
    // NSMenu.popUp(at:in:) 需要 view 本地坐标（不是 window 坐标！）
    // WebContents Y 轴向下，NSView Y 轴向上 → 需要 flip
    guard let view = contextMenuView else { return }
    let flippedY = view.bounds.height - CGFloat(params.y)
    let pt = NSPoint(x: CGFloat(params.x), y: flippedY)
    menu.popUp(positioning: nil, at: pt, in: view)
}
```

### 5. Helper 方法

```swift
// Host 操作（走 IPC）
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

// 本地操作（不走 IPC）
private func makeLocalItem(_ title: String, key: String = "",
                            handler: @escaping () -> Void) -> NSMenuItem {
    let item = CallbackMenuItem(title: title, keyEquivalent: key, callback: handler)
    item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
    return item
}

@objc private func executeHostAction(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? HostAction else { return }
    // 参数顺序: (webview_id, action, menu_id, payload) — 匹配 C 头文件
    OWLBridge_ExecuteContextMenuAction(
        webviewId, action.action.rawValue, action.menuId,
        action.payload ?? "")
}
```

### 6. 文件变更清单

| 文件 | 操作 | 变更 |
|------|------|------|
| `owl-client-app/Services/ContextMenuBridge.swift` | 新增 | 回调注册 + 事件转发 |
| `owl-client-app/Models/ContextMenuParams.swift` | 新增 | 类型定义 |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | +showContextMenu, +helper 方法 |
| `owl-client-app/Services/OWLBridgeSwift.swift` | 修改 | registerAllCallbacks 中调用 ContextMenuBridge.register |
| `owl-client-app/Views/Content/RemoteLayerView.swift` | 修改 | 暴露 view 引用给 TabViewModel |

### 7. 测试策略

- Swift 单元测试: ContextMenuParams 构造、搜索文本截断、类型枚举映射
- 手动验证: 启动 OWL → 右键各元素 → 菜单弹出 + 操作执行
- XCUITest: Phase 5 单独实现

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 测试通过
