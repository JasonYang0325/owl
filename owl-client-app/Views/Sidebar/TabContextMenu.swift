import SwiftUI

/// Phase 4: Context menu for tab rows (pinned and unpinned).
struct TabContextMenu: ViewModifier {
    @ObservedObject var tab: TabViewModel
    @EnvironmentObject var viewModel: BrowserViewModel

    func body(content: Content) -> some View {
        content.contextMenu {
            // Pin / Unpin
            if tab.isPinned {
                Button {
                    viewModel.unpinTab(tab)
                } label: {
                    Label("取消固定标签页", systemImage: "pin.slash")
                }
            } else {
                Button {
                    viewModel.pinTab(tab)
                } label: {
                    Label("固定标签页", systemImage: "pin")
                }
            }

            Divider()

            // Reload
            Button {
                tab.reload()
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
            }

            // Copy Link
            Button {
                viewModel.copyTabLink(tab)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }
            .disabled(tab.url == nil)

            Divider()

            // Close
            Button {
                viewModel.closeTab(tab)
            } label: {
                Label("关闭标签页", systemImage: "xmark")
            }

            // Close Others (available for both pinned and unpinned)
            Button {
                viewModel.closeOtherTabs(tab)
            } label: {
                Label("关闭其他标签页", systemImage: "xmark.square")
            }
            .disabled(viewModel.tabs.count <= 1)

            // Close Below (only for unpinned tabs that have tabs below)
            if !tab.isPinned {
                let tabIndex = viewModel.tabs.firstIndex(where: { $0.id == tab.id })
                let hasTabsBelow = tabIndex.map { idx in
                    viewModel.tabs[(idx + 1)...].contains(where: { !$0.isPinned })
                } ?? false

                Button {
                    viewModel.closeTabsBelow(tab)
                } label: {
                    Label("关闭下方标签页", systemImage: "xmark.square.fill")
                }
                .disabled(!hasTabsBelow)
            }
        }
    }
}

extension View {
    func tabContextMenu(tab: TabViewModel) -> some View {
        modifier(TabContextMenu(tab: tab))
    }
}
