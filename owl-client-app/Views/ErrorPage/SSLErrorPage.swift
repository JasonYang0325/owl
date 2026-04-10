import SwiftUI

/// Full-screen SSL certificate error warning page (Phase 4).
/// Displayed as a ZStack overlay on top of the WebView when a cert error occurs.
/// "Proceed anyway" requires a second confirmation alert (AC-P4-5).
struct SSLErrorPage: View {
    let errorInfo: SecurityViewModel.SSLErrorInfo
    let canGoBack: Bool
    let onGoBack: () -> Void
    let onProceed: () -> Void  // Called after the user confirms in the alert.

    @State private var showConfirmAlert = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                // Title
                Text("Your connection is not private")
                    .font(.title)
                    .bold()

                // Description
                VStack(spacing: 8) {
                    Text("Attackers might be trying to steal your information from \(host(from: errorInfo.url)) (for example, passwords, messages, or credit cards).")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)

                    // Error code
                    Text(errorInfo.errorDescription)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }

                // Go back to safety (primary button)
                Button(action: onGoBack) {
                    Text(canGoBack ? "Back to safety" : "Open blank page")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("sslGoBack")

                // Proceed anyway (secondary text button, triggers confirmation)
                Button("Proceed anyway (unsafe)") {
                    showConfirmAlert = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .accessibilityIdentifier("sslProceed")

                Spacer()
            }
            .padding(40)
        }
        .alert("Are you sure you want to proceed?", isPresented: $showConfirmAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Proceed", role: .destructive) {
                onProceed()
            }
        } message: {
            Text("This site's certificate is invalid. Proceeding may put your information at risk.")
        }
        .accessibilityIdentifier("sslErrorPage")
    }

    private func host(from url: String) -> String {
        URL(string: url)?.host ?? url
    }
}
