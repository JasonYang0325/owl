import SwiftUI

/// OWL Browser design tokens — colors from Asset Catalog, fonts and spacing as constants.
enum OWL {
    // MARK: - Colors (Asset Catalog with Light/Dark variants)

    /// For projects without Asset Catalog, we define colors inline.
    /// In production, these should come from Assets.xcassets Color Sets.
    static let surfacePrimary = Color(light: .white, dark: Color(hex: 0x1A1A1A))
    static let surfaceSecondary = Color(light: Color(hex: 0xF5F5F5), dark: Color(hex: 0x2A2A2A))
    static let accentPrimary = Color(hex: 0x0A84FF)
    static let accentSecondary = Color(light: Color(hex: 0x34C759), dark: Color(hex: 0x30D158))
    static let textPrimary = Color(light: .black, dark: .white)
    static let textSecondary = Color(hex: 0x8E8E93)
    static let textTertiary = Color(light: Color(hex: 0xC7C7CC), dark: Color(hex: 0x636366))
    static let border = Color(light: Color(hex: 0xE5E5EA), dark: Color(hex: 0x38383A))
    static let error = Color(light: Color(hex: 0xFF3B30), dark: Color(hex: 0xFF453A))
    static let warning = Color(light: Color(hex: 0xFF9500), dark: Color(hex: 0xFF9F0A))

    // MARK: - Typography

    static let titleFont = Font.system(size: 20, weight: .semibold)
    static let bodyFont = Font.system(size: 14)
    static let captionFont = Font.system(size: 12)
    static let tabFont = Font.system(size: 13)
    static let buttonFont = Font.system(size: 13, weight: .medium)
    static let codeFont = Font.system(size: 13, design: .monospaced)

    // MARK: - Spacing & Radii

    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8
    static let radiusLarge: CGFloat = 10
    static let radiusCard: CGFloat = 12
    static let radiusBubble: CGFloat = 16
    static let radiusPill: CGFloat = 24

    static let sidebarWidth: CGFloat = 200
    static let topBarHeight: CGFloat = 48
    static let tabItemHeight: CGFloat = 36
    static let toolbarHeight: CGFloat = 40
    static let rightPanelWidth: CGFloat = 360
}

// MARK: - Color Helpers

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }

    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
