import SwiftUI

/// Security indicator icon for the address bar (Phase 4).
/// Displays an SF Symbol lock icon with color coding per security level.
/// Size: 20x20pt, positioned to the left of the address bar URL.
struct SecurityIndicator: View {
    let level: SecurityLevel

    private var symbolName: String {
        switch level {
        case .loading:   return "lock.open"
        case .secure:    return "lock.fill"
        case .info:      return "lock.open"
        case .warning:   return "exclamationmark.triangle.fill"
        case .dangerous: return "xmark.shield.fill"
        }
    }

    private var symbolColor: Color {
        switch level {
        case .loading:   return .secondary
        case .secure:    return .green
        case .info:      return .secondary
        case .warning:   return .yellow
        case .dangerous: return .red
        }
    }

    private var accessibilityLabel: String {
        switch level {
        case .loading:   return "Loading"
        case .secure:    return "Secure connection"
        case .info:      return "Not secure"
        case .warning:   return "Certificate warning (allowed)"
        case .dangerous: return "Certificate error"
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(symbolColor)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: level)
            .accessibilityLabel(accessibilityLabel)
            .help(accessibilityLabel)
    }
}
