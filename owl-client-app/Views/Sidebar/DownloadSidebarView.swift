import SwiftUI

struct DownloadSidebarView: View {
    @ObservedObject var downloadVM: DownloadViewModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("下载")
                        .font(OWL.buttonFont)
                        .foregroundColor(OWL.textPrimary)
                    Spacer()
                    if downloadVM.items.contains(where: {
                        $0.state != .inProgress && $0.state != .paused
                    }) {
                        Button(action: { downloadVM.clearCompleted() }) {
                            Image(systemName: "trash.circle")
                                .font(.system(size: 13))
                                .foregroundColor(OWL.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除已完成的下载")
                        .accessibilityIdentifier("downloadClearButton")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(height: 36)

                Divider()

                // Content
                if downloadVM.items.isEmpty {
                    // Empty state
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 40))
                            .foregroundColor(OWL.textTertiary)
                        Text("暂无下载记录")
                            .font(OWL.captionFont)
                            .foregroundColor(OWL.textTertiary)
                            .accessibilityIdentifier("downloadEmptyState")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(downloadVM.items) { item in
                                DownloadRow(item: item, downloadVM: downloadVM)
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
            .environment(\.downloadPanelWidth, geo.size.width)
        }
        .accessibilityIdentifier("downloadSidebarPanel")
        .task {
            await downloadVM.loadAll()
        }
    }
}
