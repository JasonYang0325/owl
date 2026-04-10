import SwiftUI

struct TabRowView: View {
    let title: String
    let isActive: Bool
    let isCompact: Bool
    var onClose: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Favicon placeholder
            RoundedRectangle(cornerRadius: 4)
                .fill(OWL.textTertiary)
                .frame(width: 16, height: 16)

            if !isCompact {
                Text(title)
                    .font(OWL.tabFont)
                    .lineLimit(1)
                    .foregroundColor(OWL.textPrimary)

                Spacer()

                if isHovered {
                    Button(action: { onClose?() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(OWL.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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
        .accessibilityIdentifier("tabRow")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "selected" : "")
    }

    private var backgroundColor: Color {
        if isActive { return Color(light: Color(hex: 0xF5F5F5), dark: Color(hex: 0x333333)) }
        if isHovered { return OWL.surfaceSecondary.opacity(0.3) }
        return .clear
    }
}
