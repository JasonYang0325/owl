import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String  // "user" or "assistant"
    var content: String
    let timestamp = Date()

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class AIChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    @Published var pageContext: String?
    @Published var pageDomain: String?
    @Published var inputText: String = ""

    @Published private(set) var hasAPIKey: Bool = false

    init() {
        Task {
            hasAPIKey = await AIService.shared.hasAPIKey
        }
    }

    private var streamTask: Task<Void, Never>?

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        // Cancel any previous stream
        streamTask?.cancel()

        inputText = ""
        messages.append(ChatMessage(role: "user", content: text))
        isStreaming = true

        let aiMessage = ChatMessage(role: "assistant", content: "")
        messages.append(aiMessage)
        let aiMessageId = aiMessage.id  // Capture ID, not index

        let history = messages.dropLast(2).map { (role: $0.role, content: $0.content) }
        let capturedPageContext = pageContext

        streamTask = Task { [weak self] in
            let stream = await AIService.shared.sendMessage(
                text,
                history: Array(history),
                pageContext: capturedPageContext
            )

            var streamBuffer = ""
            for await event in stream {
                guard !Task.isCancelled else { break }
                switch event {
                case .token(let token):
                    streamBuffer += token
                    guard let self,
                          let idx = self.messages.firstIndex(where: { $0.id == aiMessageId })
                    else { continue }
                    self.messages[idx].content = streamBuffer
                case .error(let error):
                    guard let self,
                          let idx = self.messages.firstIndex(where: { $0.id == aiMessageId })
                    else { continue }
                    self.messages[idx].content = "错误: \(error.localizedDescription)"
                }
            }

            guard let self else { return }
            self.isStreaming = false
        }
    }

    func clearHistory() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        messages.removeAll()
    }

    func updatePageContext(domain: String?, content: String?) {
        pageDomain = domain
        pageContext = content
    }
}
