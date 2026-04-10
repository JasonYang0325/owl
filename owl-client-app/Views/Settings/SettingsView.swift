import SwiftUI

struct SettingsView: View {
    @State private var selectedTab = "ai"
    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var validationResult: String?
    @StateObject private var permissionsVM = SettingsPermissionsViewModel()
    @StateObject private var storageVM = StorageViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            // AI Settings
            Form {
                Section("Claude API Key") {
                    SecureField("sk-ant-api03-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("验证连接") {
                            validateKey()
                        }
                        .disabled(apiKey.isEmpty || isValidating)

                        if isValidating {
                            ProgressView()
                                .scaleEffect(0.7)
                        }

                        if let result = validationResult {
                            Text(result)
                                .font(OWL.captionFont)
                                .foregroundColor(result.contains("成功") ? OWL.accentSecondary : OWL.error)
                        }
                    }
                }
            }
            .accessibilityIdentifier("settingsAITab")
            .tabItem { Label("AI", systemImage: "brain") }
            .tag("ai")

            // General Settings
            Form {
                Section("搜索引擎") {
                    Picker("默认搜索引擎", selection: .constant("google")) {
                        Text("Google").tag("google")
                        Text("Bing").tag("bing")
                        Text("DuckDuckGo").tag("duckduckgo")
                    }
                }
                Section("外观") {
                    Picker("主题", selection: .constant("auto")) {
                        Text("跟随系统").tag("auto")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }
            }
            .accessibilityIdentifier("settingsGeneralTab")
            .tabItem { Label("通用", systemImage: "gear") }
            .tag("general")

            // Permissions Settings
            PermissionsPanel(vm: permissionsVM)
                .tabItem { Label("权限", systemImage: "hand.raised.fill") }
                .tag("permissions")

            // Storage Settings
            StoragePanel(vm: storageVM)
                .tabItem { Label("存储", systemImage: "externaldrive") }
                .tag("storage")
        }
        .accessibilityIdentifier("settingsView")
        .frame(width: 520, height: 460)
        .onAppear { loadKey() }
    }

    private func loadKey() {
        Task {
            let key = await AIService.shared.loadAPIKey()
            if let key { apiKey = key }
        }
    }

    private func validateKey() {
        guard !apiKey.isEmpty else { return }
        isValidating = true
        validationResult = nil
        Task {
            do {
                try await AIService.shared.saveAPIKey(apiKey)
                validationResult = "✓ 已保存"
            } catch {
                validationResult = "✗ \(error.localizedDescription)"
            }
            isValidating = false
        }
    }
}
