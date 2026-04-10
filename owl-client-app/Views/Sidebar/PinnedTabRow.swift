import SwiftUI

/// A compact tab row for pinned tabs — no close button, favicon-only in compact mode.
struct PinnedTabRow: View {
    let title: String
    let isActive: Bool
    let isCompact: Bool
    var onSelect: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Pin icon instead of favicon placeholder
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundColor(isActive ? OWL.textPrimary : OWL.textTertiary)
                .frame(width: 16, height: 16)

            if !isCompact {
                Text(title)
                    .font(OWL.tabFont)
                    .lineLimit(1)
                    .foregroundColor(OWL.textPrimary)

                Spacer()
                // No close button for pinned tabs
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: OWL.tabItemHeight)
        .background(
            RoundedRectangle(cornerRadius: OWL.radiusMedium)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pinnedTabRow")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "selected" : "")
    }

    private var backgroundColor: Color {
        if isActive { return Color(light: Color(hex: 0xF5F5F5), dark: Color(hex: 0x333333)) }
        if isHovered { return OWL.surfaceSecondary.opacity(0.3) }
        return .clear
    }
}
