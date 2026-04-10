import SwiftUI

/// A thin horizontal progress bar used in the address bar during navigation.
/// Fills from left to right, then fades out when progress reaches 1.0.
struct ProgressBar: View {
    let progress: Double
    @State private var fadeOpacity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(OWL.accentPrimary)
                .frame(width: geo.size.width * min(max(progress, 0), 1), height: 2)
                .opacity(fadeOpacity)
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(height: 2)
        .onChange(of: progress) { _, newValue in
            if newValue >= 1.0 {
                withAnimation(.easeOut(duration: 0.3)) { fadeOpacity = 0 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { fadeOpacity = 1.0 }
                }
            } else if newValue > 0 {
                fadeOpacity = 1.0
            }
        }
        .accessibilityLabel("页面加载进度")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}
