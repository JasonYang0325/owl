import SwiftUI

/// A banner shown when page loading takes longer than 5 seconds.
struct SlowLoadingBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .font(.system(size: 12))
            Text("加载较慢...")
                .font(OWL.captionFont)
        }
        .foregroundColor(OWL.warning)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .background(OWL.warning.opacity(0.15))
        .accessibilityIdentifier("slowLoadingBanner")
    }
}
