import SwiftUI

struct HistoryEmptyState: View {
    enum Variant {
        case noHistory
        case searchEmpty
    }

    var variant: Variant = .noHistory

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundColor(OWL.textTertiary)

            Text(titleText)
                .font(OWL.bodyFont)
                .foregroundColor(OWL.textPrimary)

            Text(subtitleText)
                .font(OWL.captionFont)
                .foregroundColor(OWL.textSecondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(variant == .noHistory ? "historyEmptyState" : "historySearchEmpty")
    }

    private var iconName: String {
        switch variant {
        case .noHistory: return "clock.badge.questionmark"
        case .searchEmpty: return "magnifyingglass"
        }
    }

    private var titleText: String {
        switch variant {
        case .noHistory: return "暂无浏览历史"
        case .searchEmpty: return "未找到匹配的历史记录"
        }
    }

    private var subtitleText: String {
        switch variant {
        case .noHistory: return "浏览的网页将自动记录在这里"
        case .searchEmpty: return "请尝试其他关键词"
        }
    }
}
