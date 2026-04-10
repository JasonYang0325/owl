import SwiftUI

struct HistorySidebarView: View {
    @ObservedObject var historyVM: HistoryViewModel
    var onNavigate: ((String) -> Void)?

    @State private var showClearConfirmation = false
    @State private var pendingClearRange: HistoryViewModel.ClearRange?

    var body: some View {
        VStack(spacing: 0) {
            // Search bar + Clear button
            HStack(spacing: 6) {
                HistorySearchField(
                    text: $historyVM.searchQuery,
                    onSearch: { historyVM.search() },
                    onClear: { historyVM.clearSearch() }
                )

                Menu {
                    Button("今天") {
                        pendingClearRange = .today
                        showClearConfirmation = true
                    }
                    Button("最近 7 天") {
                        pendingClearRange = .lastSevenDays
                        showClearConfirmation = true
                    }
                    Divider()
                    Button("全部", role: .destructive) {
                        pendingClearRange = .all
                        showClearConfirmation = true
                    }
                } label: {
                    Text("清除")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("清除浏览历史")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 10)

            // Content
            if historyVM.isLoading && historyVM.entries.isEmpty {
                HistorySkeletonView()
            } else if historyVM.groupedEntries.isEmpty && !historyVM.searchQuery.isEmpty {
                HistoryEmptyState(variant: .searchEmpty)
            } else if historyVM.groupedEntries.isEmpty {
                HistoryEmptyState(variant: .noHistory)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if historyVM.searchQuery.isEmpty {
                            // Date-grouped display
                            ForEach(historyVM.groupedEntries, id: \.0) { group in
                                HistoryGroupHeader(title: group.0)
                                ForEach(group.1, id: \.url) { entry in
                                    HistoryRow(
                                        entry: entry,
                                        onNavigate: { url in onNavigate?(url) },
                                        onDelete: { url in
                                            Task { await historyVM.deleteEntry(entry) }
                                        }
                                    )
                                }
                            }
                        } else {
                            // Search results: flat list
                            ForEach(historyVM.groupedEntries, id: \.0) { group in
                                ForEach(group.1, id: \.url) { entry in
                                    HistoryRow(
                                        entry: entry,
                                        onNavigate: { url in onNavigate?(url) },
                                        onDelete: { url in
                                            Task { await historyVM.deleteEntry(entry) }
                                        }
                                    )
                                }
                            }
                        }

                        // Pagination / end state
                        if historyVM.hasMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .foregroundColor(OWL.textTertiary)
                                .onAppear {
                                    Task { await historyVM.loadMore() }
                                }
                        } else if !historyVM.hasMore && !historyVM.groupedEntries.isEmpty {
                            Text("已显示全部")
                                .font(OWL.captionFont)
                                .foregroundColor(OWL.textTertiary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                    }
                }
            }

            // Undo toast
            if historyVM.showUndoToast, let entry = historyVM.undoEntry {
                HistoryUndoToast(
                    title: entry.title.isEmpty ? entry.displayURL : entry.title,
                    onUndo: { historyVM.undoDelete() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .animation(.spring(response: 0.35), value: historyVM.showUndoToast)
        .confirmationDialog(
            clearConfirmationTitle,
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                if let range = pendingClearRange {
                    Task { await historyVM.clearRange(range) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(clearConfirmationMessage)
        }
        .onAppear {
            historyVM.isVisible = true
            Task { await historyVM.loadInitial() }
        }
        .onDisappear {
            historyVM.isVisible = false
        }
    }

    private var clearConfirmationTitle: String {
        switch pendingClearRange {
        case .today: return "清除今天的浏览历史"
        case .lastSevenDays: return "清除最近 7 天的浏览历史"
        case .all: return "清除所有浏览历史"
        case nil: return ""
        }
    }

    private var clearConfirmationMessage: String {
        switch pendingClearRange {
        case .today: return "确定要清除今天的浏览历史吗？此操作不可撤销。"
        case .lastSevenDays: return "确定要清除最近 7 天的浏览历史吗？此操作不可撤销。"
        case .all: return "确定要清除所有浏览历史吗？此操作不可撤销。"
        case nil: return ""
        }
    }
}

// MARK: - Search Field

private struct HistorySearchField: View {
    @Binding var text: String
    var onSearch: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(OWL.textTertiary)

            TextField("搜索历史记录", text: $text)
                .textFieldStyle(.plain)
                .font(OWL.captionFont)
                .onChange(of: text) { _, _ in
                    onSearch()
                }
                .accessibilityIdentifier("historySearchField")

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(OWL.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(OWL.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: OWL.radiusMedium))
    }
}

// MARK: - Group Header

private struct HistoryGroupHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(OWL.captionFont)
                .foregroundColor(OWL.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Skeleton Loading

private struct HistorySkeletonView: View {
    @State private var shimmerOffset: CGFloat = -1.0

    // Pre-computed widths to avoid SwiftUI re-randomizing on every redraw (BH-026).
    private static let titleWidths: [CGFloat] = [120, 95, 145, 110]
    private static let subtitleWidths: [CGFloat] = [80, 105, 70, 90]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: OWL.radiusSmall)
                        .fill(OWL.surfaceSecondary)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(OWL.surfaceSecondary)
                            .frame(width: Self.titleWidths[index], height: 12)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(OWL.surfaceSecondary)
                            .frame(width: Self.subtitleWidths[index], height: 10)
                    }

                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 52)
            }
            Spacer()
        }
        .mask(
            LinearGradient(
                gradient: Gradient(colors: [.clear, .white, .clear]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .scaleEffect(x: 3.0)
            .offset(x: shimmerOffset * 300)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.0
            }
        }
    }
}

// MARK: - Undo Toast

struct HistoryUndoToast: View {
    let title: String
    let onUndo: () -> Void

    @State private var progress: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(OWL.textSecondary)

                Text("已删除 \"\(title)\"")
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button(action: onUndo) {
                    Text("撤销")
                        .font(OWL.buttonFont)
                        .foregroundColor(OWL.accentPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("historyUndoButton")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            // Countdown progress bar
            GeometryReader { geo in
                OWL.accentPrimary
                    .frame(width: geo.size.width * progress, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2)
        }
        .background(OWL.warning.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: OWL.radiusMedium))
        .accessibilityLabel("已删除 \(title)，双击撤销")
        .onAppear {
            progress = 1.0
            withAnimation(.linear(duration: 5.0)) {
                progress = 0.0
            }
        }
    }
}
