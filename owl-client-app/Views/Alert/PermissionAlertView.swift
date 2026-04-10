import SwiftUI

/// Permission alert overlay — slides in from below the address bar.
/// Mounted as `.overlay(alignment: .top)` on BrowserWindow.
struct PermissionAlertView: View {
    @ObservedObject var permissionVM: PermissionViewModel

    var body: some View {
        if let request = permissionVM.pendingAlert {
            alertCard(for: request)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func alertCard(for request: PermissionRequest) -> some View {
        VStack(spacing: 16) {
            // Icon (48pt)
            Image(systemName: request.type.sfSymbol)
                .font(.system(size: 48))
                .foregroundColor(request.type.iconColor)

            // Copy
            VStack(spacing: 4) {
                Text("\u{300C}\(request.displayOrigin)\u{300D}想要使用")
                    .font(.headline)
                Text("你的\(request.type.displayName)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("拒绝") {
                    withAnimation { permissionVM.respond(status: .denied) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("允许") {
                    withAnimation { permissionVM.respond(status: .granted) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // Countdown hint
            Text("\(permissionVM.countdown) 秒后自动拒绝")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(24)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: OWL.radiusCard))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("权限请求：\(request.displayOrigin) 请求使用 \(request.type.displayName)")
    }
}
