import SwiftUI

struct MemoryPanelView: View {
    var onClose: () -> Void
    @State private var searchText = ""

    // Phase 18 will connect to MemoryViewModel
    @State private var mockEntries: [MockMemoryEntry] = [
        MockMemoryEntry(title: "Google 搜索技巧", url: "google.com", summary: "搜索引擎的高级用法和技巧", time: "2小时前", tags: ["搜索", "工具"]),
        MockMemoryEntry(title: "SwiftUI 布局指南", url: "developer.apple.com", summary: "使用 VStack、HStack 和 ZStack 构建复杂布局", time: "昨天", tags: ["开发", "Swift"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(title: "浏览记忆", onClose: onClose)

            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(OWL.textTertiary)
                TextField("搜索记忆...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(OWL.captionFont)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(OWL.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: OWL.radiusMedium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if mockEntries.isEmpty {
                // Empty state
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 40))
                        .foregroundColor(OWL.textTertiary)
                    Text("浏览网页时，OWL 会自动记住重要内容")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textSecondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(mockEntries) { entry in
                            MemoryEntryRow(entry: entry)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct MockMemoryEntry: Identifiable {
    let id = UUID()
    let title: String
    let url: String
    let summary: String
    let time: String
    let tags: [String]
}

struct MemoryEntryRow: View {
    let entry: MockMemoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(OWL.buttonFont)
                .foregroundColor(OWL.textPrimary)
            Text(entry.url)
                .font(OWL.captionFont)
                .foregroundColor(OWL.accentPrimary)
            Text(entry.summary)
                .font(OWL.tabFont)
                .foregroundColor(OWL.textSecondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(entry.time)
                    .font(.system(size: 11))
                    .foregroundColor(OWL.textTertiary)
                ForEach(entry.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11))
                        .foregroundColor(OWL.accentPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OWL.accentPrimary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OWL.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: OWL.radiusLarge))
    }
}
