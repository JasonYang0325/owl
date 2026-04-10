import SwiftUI

struct HistoryRow: View {
    let entry: HistoryEntry
    let onNavigate: (String) -> Void
    let onDelete: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: { onNavigate(entry.url) }) {
            HStack(spacing: 8) {
                // Clock icon (28x28 to align with BookmarkRow favicon area)
                Image(systemName: "clock")
                    .font(.system(size: 14))
                    .foregroundColor(OWL.textTertiary)
                    .frame(width: 28, height: 28)

                // Title + URL
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? entry.displayURL : entry.title)
                        .font(OWL.tabFont)
                        .foregroundColor(OWL.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(entry.displayURL)
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                // Relative time
                Text(HistoryViewModel.relativeTime(from: entry.lastVisitDate))
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.textSecondary)
                    .fixedSize()
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 52)
            .background(isHovered ? OWL.surfaceSecondary.opacity(0.3) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(role: .destructive) {
                onDelete(entry.url)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("historyRow_\(entry.url)")
        .accessibilityLabel("\(entry.title.isEmpty ? entry.displayURL : entry.title), \(entry.displayURL), \(HistoryViewModel.relativeTime(from: entry.lastVisitDate))")
    }
}
