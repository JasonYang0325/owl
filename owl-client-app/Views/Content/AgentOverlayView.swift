import SwiftUI

/// Blue breathing border overlay shown when Agent is operating on this tab.
struct AgentOverlayView: View {
    @State private var opacity: Double = 0.3

    var body: some View {
        ZStack {
            // Blue breathing border
            RoundedRectangle(cornerRadius: 0)
                .stroke(OWL.accentPrimary.opacity(opacity), lineWidth: 2)
                .ignoresSafeArea()

            // Top banner
            VStack {
                HStack {
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                    Text("Agent 正在操作... 按 ESC 中止")
                        .font(OWL.captionFont)
                }
                .foregroundColor(OWL.accentPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(OWL.accentPrimary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: OWL.radiusSmall))

                Spacer()
            }
            .padding(.top, 4)
        }
        // Note: allowsHitTesting only affects SwiftUI views.
        // NSView-based WebContentView needs separate event interception.
        .allowsHitTesting(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                opacity = 1.0
            }
        }
    }
}
