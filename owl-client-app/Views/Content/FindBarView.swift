import SwiftUI

struct FindBarView: View {
    @ObservedObject var tab: TabViewModel
    @FocusState private var isQueryFocused: Bool
    @State private var query: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("查找...", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isQueryFocused)
                .frame(width: 200)
                .onSubmit { tab.findNext() }
                .onChange(of: query) { _, newValue in
                    tab.find(query: newValue)
                }
                .accessibilityIdentifier("findTextField")

            // Match count
            if let state = tab.findState {
                if state.totalMatches > 0 {
                    Text("\(state.activeOrdinal)/\(state.totalMatches)")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textSecondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("findMatchCount")
                } else if !state.query.isEmpty {
                    Text("无匹配")
                        .font(OWL.captionFont)
                        .foregroundColor(OWL.textTertiary)
                        .accessibilityIdentifier("findNoMatch")
                }
            }

            Button(action: { tab.findPrevious() }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(tab.findState?.totalMatches == 0)
            .accessibilityIdentifier("findPrevious")

            Button(action: { tab.findNext() }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(tab.findState?.totalMatches == 0)
            .accessibilityIdentifier("findNext")

            Button(action: { tab.hideFindBar() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("findClose")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OWL.surfaceSecondary)
        .cornerRadius(8)
        .shadow(radius: 2)
        .onAppear {
            isQueryFocused = true
            // Restore previous search query if any
            query = tab.findState?.query ?? ""
        }
        .onDisappear {
            query = ""  // Reset on close
        }
    }
}
