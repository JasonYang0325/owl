import SwiftUI

/// Main console panel displayed in the right panel.
struct ConsolePanelView: View {
    @ObservedObject var viewModel: ConsoleViewModel
    var onClose: () -> Void

    @State private var selectedItemId: String? = nil
    @State private var newMessagesVisible = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            consoleHeader

            // Toolbar (filters + search + preserve log)
            ConsoleToolbar(viewModel: viewModel)

            // Message list
            ZStack(alignment: .bottom) {
                messageList

                // New messages banner
                if !viewModel.isAtBottom && !viewModel.filteredItems.isEmpty {
                    newMessagesBanner
                }
            }
        }
        .accessibilityIdentifier("consolePanelView")
    }

    // MARK: - Header

    private var consoleHeader: some View {
        HStack {
            Text("Console")
                .font(OWL.buttonFont)
                .foregroundColor(OWL.textPrimary)
            Spacer()

            // Copy All button
            Button(action: { viewModel.copyAll() }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundColor(OWL.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy All")

            // Clear button
            Button(action: { viewModel.clear() }) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(OWL.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Clear Console")

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundColor(OWL.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredItems) { item in
                        switch item {
                        case .message(let msg):
                            ConsoleRow(
                                item: msg,
                                isSelected: selectedItemId == item.id,
                                onCopy: { viewModel.copyMessage(msg) }
                            )
                            .id(item.id)
                            .onTapGesture {
                                selectedItemId = item.id
                            }
                        case .separator(let url, _):
                            NavigationSeparator(url: url)
                                .id(item.id)
                        }
                    }
                    // Anchor for auto-scroll
                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .onChange(of: viewModel.filteredItems.count) { _, _ in
                if viewModel.isAtBottom {
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo("bottom") }
                    }
                }
            }
            .onCopyCommand {
                // Cmd+C copies selected message
                if let selectedId = selectedItemId,
                   let item = viewModel.filteredItems.first(where: { $0.id == selectedId }),
                   case .message(let msg) = item {
                    viewModel.copyMessage(msg)
                }
                return []
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("consoleScroll")).maxY)
            }
        )
        .coordinateSpace(name: "consoleScroll")
        .onPreferenceChange(ScrollOffsetKey.self) { maxY in
            // Rough heuristic: if the bottom of content is near viewport bottom, we're at bottom
            viewModel.isAtBottom = maxY < 50
        }
    }

    // MARK: - New Messages Banner

    private var newMessagesBanner: some View {
        Button {
            viewModel.isAtBottom = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11))
                Text("New Messages")
                    .font(OWL.captionFont)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(OWL.accentPrimary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

// MARK: - Console Toolbar

struct ConsoleToolbar: View {
    @ObservedObject var viewModel: ConsoleViewModel

    var body: some View {
        VStack(spacing: 6) {
            // Row 1: Level filter pills
            HStack(spacing: 4) {
                filterPill(label: "All", level: nil, count: nil)
                filterPill(label: "E", level: .error, count: viewModel.counts[.error] ?? 0,
                          color: OWL.error, icon: "xmark.circle.fill")
                filterPill(label: "W", level: .warning, count: viewModel.counts[.warning] ?? 0,
                          color: OWL.warning, icon: "exclamationmark.triangle.fill")
                filterPill(label: "I", level: .info, count: viewModel.counts[.info] ?? 0,
                          color: OWL.accentPrimary, icon: "info.circle")
                filterPill(label: "V", level: .verbose, count: viewModel.counts[.verbose] ?? 0,
                          color: OWL.textTertiary, icon: "text.alignleft")
                Spacer()
            }

            // Row 2: Search + Preserve Log
            HStack(spacing: 8) {
                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(OWL.textTertiary)
                    TextField("Search...", text: $viewModel.searchText)
                        .font(OWL.captionFont)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(OWL.surfaceSecondary)
                .cornerRadius(OWL.radiusSmall)

                // Preserve log toggle
                Toggle(isOn: $viewModel.preserveLog) {
                    Text("Preserve")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textSecondary)
                }
                .toggleStyle(.checkbox)
                .help("Preserve log across navigations")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: viewModel.filter) { _, _ in viewModel.refilter() }
        .onChange(of: viewModel.searchText) { _, _ in viewModel.refilter() }
    }

    @ViewBuilder
    private func filterPill(label: String, level: ConsoleLevel?, count: Int?,
                           color: Color = OWL.textPrimary, icon: String? = nil) -> some View {
        let isActive = viewModel.filter == level

        Button {
            viewModel.filter = viewModel.filter == level ? nil : level
        } label: {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundColor(isActive ? color : OWL.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isActive ? color.opacity(0.15) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("consoleFilter_\(label)")
    }
}

// MARK: - Preference Key for Scroll Detection

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
