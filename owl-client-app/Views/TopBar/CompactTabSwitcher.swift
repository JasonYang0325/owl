import SwiftUI

struct CompactTabSwitcher: View {
    // Phase 13 接入: tabCount, activeIndex, onSwitch
    var tabCount: Int = 1
    var activeIndex: Int = 1

    @State private var showDropdown = false

    var body: some View {
        HStack(spacing: 8) {
            // Toolbar icons (moved from sidebar in minimal mode)
            HStack(spacing: 4) {
                CompactToolIcon(icon: "bookmark")
                CompactToolIcon(icon: "bubble.left.and.bubble.right")
                CompactToolIcon(icon: "cpu")
                CompactToolIcon(icon: "gearshape")
            }

            // Tab counter
            Button(action: { showDropdown.toggle() }) {
                Text("\(activeIndex)/\(tabCount)")
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(OWL.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: OWL.radiusSmall))
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 12)
    }
}

struct CompactToolIcon: View {
    let icon: String
    @State private var isHovered = false

    var body: some View {
        Button(action: { }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isHovered ? OWL.textPrimary : OWL.textSecondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
