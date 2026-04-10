import SwiftUI

struct NavigationButtons: View {
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isLoading: Bool = false
    var onGoBack: (() -> Void)? = nil
    var onGoForward: (() -> Void)? = nil
    var onReloadOrStop: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            NavButton(icon: "chevron.left", enabled: canGoBack) {
                onGoBack?()
            }
            NavButton(icon: "chevron.right", enabled: canGoForward) {
                onGoForward?()
            }
            NavButton(
                icon: isLoading ? "xmark" : "arrow.clockwise",
                enabled: true
            ) {
                onReloadOrStop?()
            }
        }
        .padding(.horizontal, 8)
    }
}

struct NavButton: View {
    let icon: String
    let enabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(enabled ? OWL.textSecondary : OWL.textTertiary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: OWL.radiusSmall)
                        .fill(isHovered && enabled ? OWL.surfaceSecondary : .clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
    }
}
