import SwiftUI

struct AIChatView: View {
    @StateObject private var chatVM = AIChatViewModel()
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(title: "Claude 3.5 Sonnet", onClose: onClose)

            // Page context tag
            if let domain = chatVM.pageDomain {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                    Text("已读取: \(domain)")
                        .font(OWL.captionFont)
                }
                .foregroundColor(OWL.accentPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OWL.accentPrimary.opacity(0.1))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Messages or empty state
            ScrollViewReader { proxy in
                ScrollView {
                    if chatVM.messages.isEmpty {
                        // Prompt starters
                        VStack(spacing: 8) {
                            Spacer().frame(height: 60)
                            PromptStarterButton(icon: "bubble.left", text: "帮我总结这个页面") {
                                chatVM.inputText = "帮我总结这个页面的主要内容"
                                chatVM.sendMessage()
                            }
                            PromptStarterButton(icon: "lightbulb", text: "解释这段代码") {
                                chatVM.inputText = "解释这段代码的作用"
                                chatVM.sendMessage()
                            }
                            PromptStarterButton(icon: "globe", text: "翻译成中文") {
                                chatVM.inputText = "将这个页面翻译成中文"
                                chatVM.sendMessage()
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(chatVM.messages) { msg in
                                ChatBubbleView(message: msg)
                                    .id(msg.id)
                            }
                            if chatVM.isStreaming {
                                TypingIndicator()
                                    .id("typing")
                            }
                        }
                        .padding(16)
                    }
                }
                .onChange(of: chatVM.messages.count) { _, _ in
                    withAnimation(.none) {
                        if let lastId = chatVM.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            PanelInputBar(
                text: $chatVM.inputText,
                placeholder: "输入消息...",
                icon: "arrow.up",
                isEnabled: !chatVM.inputText.isEmpty,
                action: { chatVM.sendMessage() }
            )
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer() }
            Text(message.content)
                .font(OWL.bodyFont)
                .foregroundColor(message.role == "user" ? .white : OWL.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: OWL.radiusBubble)
                        .fill(message.role == "user" ? OWL.accentPrimary : OWL.surfaceSecondary)
                )
            if message.role == "assistant" { Spacer() }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(OWL.textSecondary)
                        .frame(width: 6, height: 6)
                        .opacity(animating ? 1.0 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(i) * 0.2),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OWL.radiusBubble)
                    .fill(OWL.surfaceSecondary)
            )
            Spacer()
        }
        .onAppear { animating = true }
    }
}

// MARK: - Prompt Starter

struct PromptStarterButton: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(OWL.accentPrimary)
                Text(text)
                    .font(OWL.bodyFont)
                    .foregroundColor(OWL.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(isHovered ? OWL.surfaceSecondary.opacity(0.8) : OWL.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: OWL.radiusLarge))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
