import SwiftUI

struct BookmarkRow: View {
    let bookmark: BookmarkItem
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    private var domain: String? {
        guard let host = URL(string: bookmark.url)?.host else { return nil }
        let cleaned = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return cleaned
    }

    private var faviconLetter: String {
        guard let domain else { return "?" }
        return String(domain.prefix(1)).uppercased()
    }

    private var titleEqualsURL: Bool {
        bookmark.title == bookmark.url
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Favicon placeholder
                Text(faviconLetter)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(OWL.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(OWL.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: OWL.radiusSmall))

                // Title + domain
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.title)
                        .font(OWL.tabFont)
                        .foregroundColor(OWL.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !titleEqualsURL, let domain {
                        Text(domain)
                            .font(.system(size: 10))
                            .foregroundColor(OWL.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)

                // Hover delete button
                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(OWL.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("删除书签")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 44)
            .background(isHovered ? OWL.surfaceSecondary.opacity(0.3) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("删除书签", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(bookmark.title), \(domain ?? bookmark.url)")
    }
}
