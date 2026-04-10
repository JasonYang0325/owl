import SwiftUI

/// HTTP authentication dialog (Phase 3).
/// Displayed as `.sheet` on BrowserWindow when a 401/407 challenge arrives.
/// Design spec: docs/ui-design/navigation-events/design.md Section 3.4.
struct AuthAlertView: View {
    let challenge: AuthChallenge
    let onSubmit: (String, String) -> Void  // (username, password)
    let onCancel: () -> Void

    @State private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(spacing: 12) {
            // Lock icon
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(OWL.accentPrimary)
                .accessibilityHidden(true)

            // Title
            Text(challenge.isProxy ? "代理认证请求" : "认证请求")
                .font(OWL.titleFont)

            // Domain and realm
            VStack(spacing: 4) {
                Text("\(challenge.domain) 要求输入凭证")
                    .font(OWL.bodyFont)
                    .foregroundStyle(.secondary)
                if !challenge.realm.isEmpty {
                    Text("Realm: \"\(challenge.realm)\"")
                        .font(OWL.captionFont)
                        .foregroundStyle(.tertiary)
                }
            }

            // Error hint (shown on retry, failureCount > 0)
            if challenge.failureCount > 0 {
                Text("用户名或密码错误，请重试")
                    .font(OWL.captionFont)
                    .foregroundStyle(OWL.error)
                    .accessibilityLabel("错误：用户名或密码错误，请重试")
            }

            // Input fields
            VStack(spacing: 8) {
                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(height: 28)
                    .focused($focusedField, equals: .username)
                    .accessibilityIdentifier("authUsername")

                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(height: 28)
                    .focused($focusedField, equals: .password)
                    .accessibilityIdentifier("authPassword")
            }
            .padding(.vertical, 4)

            // Action buttons
            HStack(spacing: 12) {
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("authCancel")

                Button("登录") {
                    onSubmit(username, password)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(username.isEmpty)
                .accessibilityIdentifier("authSubmit")
            }

            // Proxy indicator (407 only)
            if challenge.isProxy {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                    Text("代理认证")
                        .font(OWL.captionFont)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            focusedField = .username
        }
        .accessibilityIdentifier("authAlertView")
    }
}
