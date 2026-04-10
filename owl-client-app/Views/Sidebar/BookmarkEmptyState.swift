import SwiftUI

struct BookmarkEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "star")
                .font(.system(size: 32))
                .foregroundColor(OWL.textTertiary)
            Text("暂无书签")
                .font(OWL.bodyFont)
                .foregroundColor(OWL.textSecondary)
            Text("点击地址栏的 ☆\n即可收藏当前网页")
                .font(OWL.captionFont)
                .foregroundColor(OWL.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
