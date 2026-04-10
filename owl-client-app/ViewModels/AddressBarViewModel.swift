import Foundation
import SwiftUI

@MainActor
class AddressBarViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var isEditing: Bool = false

    weak var activeTab: TabViewModel?

    var displayText: String {
        if isEditing { return inputText }
        return activeTab?.displayDomain ?? ""
    }

    var placeholder: String {
        activeTab?.url == nil ? "询问 OWL 或输入 URL" : "搜索或输入 URL"
    }

    func startEditing() {
        inputText = activeTab?.url ?? ""
        isEditing = true
    }

    func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let looksLikeURL = text.contains(".") && !text.contains(" ")
        if looksLikeURL {
            activeTab?.navigate(to: text)
        } else {
            let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            activeTab?.navigate(to: "https://www.google.com/search?q=\(query)")
        }
        isEditing = false
    }

    func cancelEditing() {
        isEditing = false
        inputText = ""
    }
}
