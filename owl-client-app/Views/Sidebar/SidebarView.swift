import SwiftUI

struct SidebarView: View {
    let isCompact: Bool
    let width: CGFloat
    var onTogglePanel: ((RightPanel) -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    @EnvironmentObject var viewModel: BrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            // === Top fixed area (shared across all modes) ===
            if !isCompact {
                NewTabButton { viewModel.createTab() }
                    .padding(.horizontal, 10)
                BookmarkButton(
                    isActive: viewModel.sidebarMode == .bookmarks,
                    action: { viewModel.toggleSidebarMode(.bookmarks) }
                )
                .padding(.horizontal, 10)
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            // === Content area (sidebarMode branching) ===
            if viewModel.sidebarMode == .history && !isCompact {
                HistorySidebarView(
                    historyVM: viewModel.historyVM,
                    onNavigate: { url in
                        if let tab = viewModel.activeTab {
                            tab.navigate(to: url)
                        }
                    }
                )
            } else if viewModel.sidebarMode == .bookmarks && !isCompact {
                BookmarkSidebarView(
                    bookmarkVM: viewModel.bookmarkVM,
                    onNavigate: { url in
                        if let tab = viewModel.activeTab {
                            tab.navigate(to: url)
                        }
                    }
                )
            } else if viewModel.sidebarMode == .downloads && !isCompact {
                DownloadSidebarView(
                    downloadVM: viewModel.downloadVM
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Pinned tabs section
                        let pinnedTabs = viewModel.tabs.filter { $0.isPinned }
                        let unpinnedTabs = viewModel.tabs.filter { !$0.isPinned }

                        if !pinnedTabs.isEmpty {
                            ForEach(pinnedTabs) { tabVM in
                                ObservedPinnedTabRow(
                                    tab: tabVM,
                                    isActive: tabVM.id == viewModel.activeTab?.id,
                                    isCompact: isCompact,
                                    onSelect: { viewModel.activateTab(tabVM) }
                                )
                                .tabContextMenu(tab: tabVM)
                            }

                            if !unpinnedTabs.isEmpty {
                                Divider()
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                            }
                        }

                        // Unpinned tabs section
                        ForEach(unpinnedTabs) { tabVM in
                            ObservedTabRow(
                                tab: tabVM,
                                isActive: tabVM.id == viewModel.activeTab?.id,
                                isCompact: isCompact,
                                onClose: { viewModel.closeTab(tabVM) },
                                onSelect: { viewModel.activateTab(tabVM) }
                            )
                            .tabContextMenu(tab: tabVM)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }

            // === Bottom toolbar ===
            Divider()
            SidebarToolbar(
                isCompact: isCompact,
                onOpenSettings: { onOpenSettings?() }
            )
        }
        .frame(width: width)
        .background(OWL.surfacePrimary)
    }
}

/// Wrapper that observes TabViewModel so title changes trigger re-render.
private struct ObservedTabRow: View {
    @ObservedObject var tab: TabViewModel
    let isActive: Bool
    let isCompact: Bool
    var onClose: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil

    var body: some View {
        TabRowView(
            title: tab.displayTitle,
            isActive: isActive,
            isCompact: isCompact,
            onClose: onClose,
            onSelect: onSelect
        )
    }
}

/// Wrapper for pinned tab rows — uses PinnedTabRow (no close button).
private struct ObservedPinnedTabRow: View {
    @ObservedObject var tab: TabViewModel
    let isActive: Bool
    let isCompact: Bool
    var onSelect: (() -> Void)? = nil

    var body: some View {
        PinnedTabRow(
            title: tab.displayTitle,
            isActive: isActive,
            isCompact: isCompact,
            onSelect: onSelect
        )
    }
}

// MARK: - New Tab Button

struct NewTabButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14))
                Text("添加标签页")
                    .font(OWL.tabFont)
                Spacer()
            }
            .foregroundColor(isHovered ? OWL.textPrimary : OWL.textSecondary)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("newTabButton")
    }
}

// MARK: - Bookmark Button

struct BookmarkButton: View {
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 14))
                Text("书签")
                    .font(OWL.tabFont)
                Spacer()
            }
            .foregroundColor(isActive ? OWL.accentPrimary :
                           (isHovered ? OWL.textPrimary : OWL.textSecondary))
            .fontWeight(isActive ? .medium : .regular)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("sidebarTopBookmarkButton")
    }
}
