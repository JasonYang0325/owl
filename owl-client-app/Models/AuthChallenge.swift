import Foundation

/// Model representing an HTTP authentication challenge (401/407).
/// Used as `.sheet(item:)` binding on BrowserWindow.
package struct AuthChallenge: Identifiable {
    package let id = UUID()
    package let authId: UInt64
    package let url: String
    package let realm: String
    package let scheme: String
    package let isProxy: Bool
    package let failureCount: Int  // 0=first attempt, 1=second, 2=third

    /// Domain extracted from url for display.
    package var domain: String {
        URL(string: url)?.host ?? url
    }
}
