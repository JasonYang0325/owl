import SwiftUI

// MARK: - DownloadRow

struct DownloadRow: View {
    @ObservedObject var item: DownloadItemVM
    @ObservedObject var downloadVM: DownloadViewModel
    @Environment(\.downloadPanelWidth) var panelWidth
    @State private var isHovered = false

    private var isCompact: Bool { panelWidth < 200 }

    var body: some View {
        HStack(spacing: 8) {
            // File icon
            FileIconView(filename: item.filename, state: item.state)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                // Row 1: filename + action buttons
                HStack {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(
                            item.state == .cancelled || item.state == .interrupted
                                ? OWL.textSecondary : OWL.textPrimary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("downloadFilename_\(item.id)")
                    Spacer()
                    actionButtons
                }

                // Progress bar (in-progress / paused)
                if item.state == .inProgress || item.state == .paused {
                    DownloadProgressBar(
                        progress: item.progress,
                        isIndeterminate: item.totalBytes <= 0,
                        isPaused: item.state == .paused
                    )
                    .frame(height: 4)
                }

                // Status text
                statusText
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(isHovered ? OWL.surfaceSecondary.opacity(0.3) : .clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier("downloadRow_\(item.id)")
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if item.state == .complete {
                downloadVM.openFile(id: item.id)
            }
        }
        .contextMenu { contextMenuItems }
    }

    // MARK: - Action Buttons (state-driven)

    @ViewBuilder var actionButtons: some View {
        switch item.state {
        case .inProgress:
            HStack(spacing: 4) {
                DownloadIconButton(icon: "pause.fill") {
                    downloadVM.pause(id: item.id)
                }
                .accessibilityIdentifier("downloadPause_\(item.id)")
                DownloadIconButton(icon: "xmark") {
                    downloadVM.cancel(id: item.id)
                }
                .accessibilityIdentifier("downloadCancel_\(item.id)")
            }
        case .paused:
            HStack(spacing: 4) {
                DownloadIconButton(icon: "play.fill", accent: true) {
                    downloadVM.resume(id: item.id)
                }
                .accessibilityIdentifier("downloadResume_\(item.id)")
                DownloadIconButton(icon: "xmark") {
                    downloadVM.cancel(id: item.id)
                }
                .accessibilityIdentifier("downloadCancel_\(item.id)")
            }
        case .complete:
            HStack(spacing: 4) {
                DownloadTextButton("打开") {
                    downloadVM.openFile(id: item.id)
                }
                .accessibilityIdentifier("downloadOpen_\(item.id)")
                DownloadIconButton(icon: "folder") {
                    downloadVM.showInFolder(id: item.id)
                }
                .accessibilityIdentifier("downloadFinder_\(item.id)")
            }
        case .interrupted:
            if item.canResume {
                DownloadTextButton("恢复") {
                    downloadVM.resume(id: item.id)
                }
                .accessibilityIdentifier("downloadResume_\(item.id)")
            }
            // When !canResume, don't show redownload (not implemented); just show error text
        case .cancelled:
            EmptyView()
        }
    }

    // MARK: - Status Text

    @ViewBuilder var statusText: some View {
        switch item.state {
        case .inProgress:
            if isCompact {
                Text(formatBytes(item.receivedBytes) + " / " + formatBytes(item.totalBytes))
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.textSecondary)
                    .accessibilityIdentifier("downloadStatus_\(item.id)")
            } else {
                Text(formatBytes(item.receivedBytes) + " / " + formatBytes(item.totalBytes)
                     + " \u{00B7} " + item.speed)
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.textSecondary)
                    .accessibilityIdentifier("downloadStatus_\(item.id)")
            }
        case .paused:
            if isCompact {
                Text("已暂停")
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.warning)
                    .accessibilityIdentifier("downloadStatus_\(item.id)")
            } else {
                Text("已暂停 \u{00B7} " + formatBytes(item.receivedBytes) + " / "
                     + formatBytes(item.totalBytes))
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.warning)
                    .accessibilityIdentifier("downloadStatus_\(item.id)")
            }
        case .complete:
            Text(formatBytes(item.totalBytes))
                .font(OWL.captionFont)
                .foregroundColor(OWL.textSecondary)
                .accessibilityIdentifier("downloadStatus_\(item.id)")
        case .cancelled:
            Text("已取消")
                .font(OWL.captionFont)
                .foregroundColor(OWL.textTertiary)
                .accessibilityIdentifier("downloadStatus_\(item.id)")
        case .interrupted:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(item.errorDescription ?? "下载失败")
            }
            .font(OWL.captionFont)
            .foregroundColor(OWL.error)
            .accessibilityIdentifier("downloadStatus_\(item.id)")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder var contextMenuItems: some View {
        switch item.state {
        case .inProgress:
            Button("暂停下载") { downloadVM.pause(id: item.id) }
            Button("取消下载") { downloadVM.cancel(id: item.id) }
        case .paused:
            Button("恢复下载") { downloadVM.resume(id: item.id) }
            Button("取消下载") { downloadVM.cancel(id: item.id) }
        case .complete:
            Button("打开") { downloadVM.openFile(id: item.id) }
            Button("在 Finder 中显示") { downloadVM.showInFolder(id: item.id) }
            Divider()
            Button("从列表中移除") { downloadVM.removeEntry(id: item.id) }
        case .cancelled:
            Button("从列表中移除") { downloadVM.removeEntry(id: item.id) }
        case .interrupted:
            if item.canResume {
                Button("恢复下载") { downloadVM.resume(id: item.id) }
            }
            Button("从列表中移除") { downloadVM.removeEntry(id: item.id) }
        }
    }
}

// MARK: - DownloadProgressBar

struct DownloadProgressBar: View {
    let progress: Double
    let isIndeterminate: Bool
    let isPaused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(OWL.surfaceSecondary)
                if isIndeterminate {
                    IndeterminateBar()
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isPaused ? OWL.warning : OWL.accentPrimary)
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                }
            }
        }
    }
}

// MARK: - IndeterminateBar

struct IndeterminateBar: View {
    @State private var offset: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(OWL.accentPrimary)
                .frame(width: geo.size.width * 0.3)
                .offset(x: geo.size.width * offset)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true)
                    ) {
                        offset = 1.0
                    }
                }
        }
    }
}

// MARK: - DownloadIconButton

struct DownloadIconButton: View {
    let icon: String
    var accent: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(
                    accent ? OWL.accentPrimary
                        : (isHovered ? OWL.textPrimary : OWL.textSecondary)
                )
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - DownloadTextButton

struct DownloadTextButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OWL.captionFont)
                .foregroundColor(OWL.accentPrimary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FileIconView

struct FileIconView: View {
    let filename: String
    let state: DownloadState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "doc.fill")
                .font(.system(size: 14))
                .foregroundColor(OWL.textSecondary)
                .frame(width: 28, height: 28)
                .background(OWL.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: OWL.radiusSmall))
                .opacity(state == .cancelled ? 0.5 : 1.0)

            if state == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0x34C759))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

// MARK: - formatBytes

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 0 { return "未知" }
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }
    if bytes < 1024 * 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
    return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
}

// MARK: - Download Panel Width Environment Key

private struct DownloadPanelWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 280
}

extension EnvironmentValues {
    var downloadPanelWidth: CGFloat {
        get { self[DownloadPanelWidthKey.self] }
        set { self[DownloadPanelWidthKey.self] = newValue }
    }
}
