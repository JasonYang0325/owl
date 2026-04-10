import SwiftUI

/// Shared header bar for right-panel views (AI Chat, Agent, Memory).
struct PanelHeaderView: View {
    let title: String
    var statusDot: Color? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack {
            if let dot = statusDot {
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            Text(title)
                .font(OWL.buttonFont)
                .foregroundColor(OWL.textPrimary)
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(OWL.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }
}
