import SwiftUI

/// Shared input bar for right-panel views (AI Chat, Agent).
struct PanelInputBar: View {
    @Binding var text: String
    let placeholder: String
    let icon: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(OWL.bodyFont)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(OWL.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: OWL.radiusLarge))
                .onSubmit(action)

            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(isEnabled ? OWL.accentPrimary : OWL.surfaceSecondary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }
}
