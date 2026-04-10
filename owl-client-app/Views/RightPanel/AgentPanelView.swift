import SwiftUI

struct AgentPanelView: View {
    var onClose: () -> Void
    @State private var newTaskText = ""

    // Phase 18 will connect to AgentViewModel
    @State private var mockTasks: [MockAgentTask] = [
        MockAgentTask(desc: "完成文本提取", status: .completed),
        MockAgentTask(desc: "分析页面内容", status: .running),
        MockAgentTask(desc: "需要确认：打开外部链接？", status: .needsConfirmation),
        MockAgentTask(desc: "搜索最新新闻", status: .pending),
        MockAgentTask(desc: "获取图片资源", status: .failed),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                title: "Agent Mode",
                statusDot: mockTasks.contains { $0.status == .running } ? OWL.accentSecondary : OWL.textTertiary
            )

            // Task list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(mockTasks) { task in
                        AgentTaskRow(task: task)
                    }
                }
                .padding(16)
            }

            PanelInputBar(
                text: $newTaskText,
                placeholder: "描述新任务...",
                icon: "play.fill",
                isEnabled: !newTaskText.isEmpty,
                action: { }
            )
        }
    }
}

// MARK: - Agent Task Row

enum AgentTaskStatus {
    case pending, running, completed, failed, needsConfirmation
}

struct MockAgentTask: Identifiable {
    let id = UUID()
    let desc: String
    var status: AgentTaskStatus
}

struct AgentTaskRow: View {
    let task: MockAgentTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.desc)
                    .font(OWL.buttonFont)
                    .foregroundColor(OWL.textPrimary)
                if task.status == .needsConfirmation {
                    HStack(spacing: 8) {
                        Button("确认") {}
                            .buttonStyle(.plain)
                            .font(OWL.captionFont)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(OWL.accentPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: OWL.radiusSmall))
                        Button("取消") {}
                            .buttonStyle(.plain)
                            .font(OWL.captionFont)
                            .foregroundColor(OWL.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(OWL.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: OWL.radiusSmall))
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(taskBackground)
        .clipShape(RoundedRectangle(cornerRadius: OWL.radiusLarge))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .pending:
            Image(systemName: "square").foregroundColor(OWL.textTertiary)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(OWL.accentPrimary)
                .rotationEffect(.degrees(360))
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(OWL.accentSecondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(OWL.error)
        case .needsConfirmation:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(OWL.warning)
        }
    }

    private var taskBackground: Color {
        switch task.status {
        case .pending: return OWL.surfaceSecondary
        case .running: return OWL.accentPrimary.opacity(0.08)
        case .completed: return OWL.accentSecondary.opacity(0.08)
        case .failed: return OWL.error.opacity(0.08)
        case .needsConfirmation: return OWL.warning.opacity(0.1)
        }
    }
}
