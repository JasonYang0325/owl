import SwiftUI

struct WelcomeView: View {
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    var onNavigate: ((String) -> Void)?

    var body: some View {
        ZStack {
            OWL.surfaceSecondary.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // OWL Logo
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: [OWL.accentPrimary, Color(hex: 0x5AC8FA)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Text("O")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    )

                // Search bar
                HStack(spacing: 10) {
                    Text("+")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(OWL.accentPrimary)

                    TextField("询问 OWL 或输入 URL", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isSearchFocused)
                        .onSubmit {
                            let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            onNavigate?(text)
                        }

                    Image(systemName: "mic")
                        .font(.system(size: 16))
                        .foregroundColor(OWL.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(width: 560, height: 48)
                .background(OWL.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: OWL.radiusPill))
                .overlay(
                    RoundedRectangle(cornerRadius: OWL.radiusPill)
                        .stroke(isSearchFocused ? OWL.accentPrimary : OWL.border, lineWidth: isSearchFocused ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)

                // Suggestion cards
                LazyVGrid(columns: [
                    GridItem(.fixed(220)),
                    GridItem(.fixed(220))
                ], spacing: 12) {
                    SuggestionCardView(icon: "magnifyingglass", title: "帮我总结这篇文章", subtitle: "AI 阅读当前页面并生成摘要")
                    SuggestionCardView(icon: "globe", title: "翻译这个页面", subtitle: "将页面内容翻译成指定语言")
                    SuggestionCardView(icon: "iphone", title: "对比手机套餐", subtitle: "搜索并比较各运营商套餐")
                    SuggestionCardView(icon: "film", title: "找回近期观影记录", subtitle: "从浏览记忆中提取影视内容")
                }

                Spacer()

                // Default browser button
                Button(action: { }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(OWL.accentPrimary)
                            .frame(width: 8, height: 8)
                        Text("设为默认浏览器")
                            .font(OWL.buttonFont)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(OWL.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: OWL.radiusMedium))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 32)
            }
        }
        .onAppear { isSearchFocused = true }
    }
}

struct SuggestionCardView: View {
    let icon: String
    let title: String
    let subtitle: String
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(OWL.accentPrimary)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OWL.buttonFont)
                    .foregroundColor(OWL.textPrimary)
                Text(subtitle)
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 220, height: 72)
        .background(OWL.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: OWL.radiusCard))
        .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 6 : 2, y: isHovered ? 4 : 1)
        .offset(y: isHovered ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
