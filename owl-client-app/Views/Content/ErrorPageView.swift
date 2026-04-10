import SwiftUI

struct ErrorPageView: View {
    var title: String = "无法连接到浏览器引擎"
    var message: String
    var onRetry: (() -> Void)? = nil
    // Phase 2 Navigation: extended parameters for navigation errors.
    var errorCode: Int? = nil
    var suggestion: String? = nil
    var onGoBack: (() -> Void)? = nil
    var showRetry: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(OWL.warning)

            Text(title)
                .font(OWL.titleFont)
                .foregroundColor(OWL.textPrimary)

            Text(message)
                .font(OWL.bodyFont)
                .foregroundColor(OWL.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if let suggestion {
                Text(suggestion)
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.textTertiary)
            }

            HStack(spacing: 12) {
                if let onGoBack {
                    Button(action: onGoBack) {
                        Text("返回")
                            .font(OWL.buttonFont)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(OWL.textSecondary)
                            .cornerRadius(OWL.radiusMedium)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("errorGoBackButton")
                }

                if showRetry, let onRetry {
                    Button(action: onRetry) {
                        Text("重试")
                            .font(OWL.buttonFont)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(OWL.accentPrimary)
                            .cornerRadius(OWL.radiusMedium)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("errorRetryButton")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OWL.surfaceSecondary)
        .accessibilityIdentifier("errorPageView")
    }
}
