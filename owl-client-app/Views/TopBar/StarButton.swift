import SwiftUI

/// Star/bookmark toggle button for the address bar.
/// Props-driven: parent passes bookmark state; internal @State manages loading.
struct StarButton: View {
    var isBookmarked: Bool
    var isEnabled: Bool
    var onToggle: () async -> Void

    @State private var isLoading = false
    @State private var isHovered = false

    private var foregroundColor: Color {
        if !isEnabled { return OWL.textTertiary }
        if isBookmarked { return OWL.accentPrimary }
        return isHovered ? OWL.textPrimary : OWL.textSecondary
    }

    var body: some View {
        Button {
            guard !isLoading else { return }
            isLoading = true
            Task {
                await onToggle()
                isLoading = false
            }
        } label: {
            Image(systemName: isBookmarked ? "star.fill" : "star")
                .font(.system(size: 15))
                .foregroundColor(foregroundColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .opacity(isLoading ? 0.5 : 1.0)
        .onHover { isHovered = $0 }
        .help(isBookmarked ? "从书签移除" : "添加到书签")
        .accessibilityIdentifier("starButton")
    }
}
