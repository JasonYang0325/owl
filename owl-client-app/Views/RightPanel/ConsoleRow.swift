import SwiftUI

/// A single console message row with level icon, timestamp, message, and source.
struct ConsoleRow: View {
    let item: ConsoleMessageItem
    let isSelected: Bool
    var onCopy: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                // Level icon
                Image(systemName: levelIcon)
                    .font(.system(size: 12))
                    .foregroundColor(levelColor)
                    .frame(width: 14)

                // Timestamp
                Text(ConsoleViewModel.formatTimestamp(item.timestamp))
                    .font(OWL.codeFont)
                    .foregroundColor(OWL.textTertiary)

                // Message
                Text(item.message)
                    .font(OWL.codeFont)
                    .foregroundColor(messageColor)
                    .lineLimit(nil)
                    .textSelection(.enabled)
            }

            // Source:line (right-aligned on second line)
            if !item.source.isEmpty {
                HStack {
                    Spacer()
                    Text(sourceLabel)
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textTertiary)
                }
            }

            // Truncation indicator
            if item.isTruncated {
                Text("... (truncated to 10KB)")
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.error)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OWL.border)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("consoleRow_\(levelLabel)")
        .accessibilityLabel("\(levelLabel) \(ConsoleViewModel.formatTimestamp(item.timestamp)) \(item.message)")
    }

    // MARK: - Computed

    private var levelIcon: String {
        switch item.level {
        case .verbose: return "text.alignleft"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var levelColor: Color {
        switch item.level {
        case .verbose: return OWL.textTertiary
        case .info: return OWL.textSecondary
        case .warning: return OWL.warning
        case .error: return OWL.error
        }
    }

    private var messageColor: Color {
        switch item.level {
        case .verbose: return OWL.textTertiary
        case .info: return OWL.textPrimary
        case .warning: return OWL.warning
        case .error: return OWL.error
        }
    }

    private var levelLabel: String {
        switch item.level {
        case .verbose: return "verbose"
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    private var sourceLabel: String {
        let filename = URL(string: item.source)?.lastPathComponent ?? item.source
        return "\(filename):\(item.line)"
    }

    private var rowBackground: Color {
        if isSelected {
            return OWL.accentPrimary.opacity(0.1)
        } else if isHovered {
            return OWL.surfaceSecondary.opacity(0.5)
        }
        return .clear
    }
}

/// Navigation separator line shown when "Preserve Log" is enabled.
struct NavigationSeparator: View {
    let url: String

    var body: some View {
        HStack(spacing: 8) {
            line
            Text("Navigated to \(displayHost)")
                .font(OWL.captionFont)
                .foregroundColor(OWL.textTertiary)
                .lineLimit(1)
            line
        }
        .frame(height: 20)
        .padding(.horizontal, 10)
    }

    private var line: some View {
        Rectangle()
            .fill(OWL.border)
            .frame(height: 0.5)
    }

    private var displayHost: String {
        URL(string: url)?.host ?? url
    }
}
