import SwiftUI

package enum RightPanel: Equatable {
    case none
    case aiChat
    case agent
    case memory
    case console
}

struct RightPanelContainer: View {
    @Binding var activePanel: RightPanel
    var consoleVM: ConsoleViewModel? = nil

    var body: some View {
        if activePanel != .none {
            VStack(spacing: 0) {
                switch activePanel {
                case .aiChat:
                    AIChatView(onClose: { activePanel = .none })
                case .agent:
                    AgentPanelView(onClose: { activePanel = .none })
                case .memory:
                    MemoryPanelView(onClose: { activePanel = .none })
                case .console:
                    if let consoleVM {
                        ConsolePanelView(viewModel: consoleVM, onClose: { activePanel = .none })
                    }
                case .none:
                    EmptyView()
                }
            }
            .frame(width: OWL.rightPanelWidth)
            .background(OWL.surfacePrimary)
            .transition(.move(edge: .trailing))
        }
    }
}
