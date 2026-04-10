import SwiftUI

struct SidebarToolbar: View {
    let isCompact: Bool
    let onOpenSettings: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                    if !isCompact {
                        Text("设置")
                            .font(OWL.tabFont)
                    }
                }
                .foregroundColor(isHovered ? OWL.textPrimary : OWL.textSecondary)
            }
            .accessibilityIdentifier("sidebarSettingsButton")
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: OWL.toolbarHeight)
    }
}
