import Foundation

// Phase 4: Security level enum (wire values match C++ SecurityLevel / Mojom).
package enum SecurityLevel: Equatable {
    case loading     // Navigation in progress, icon greyed out
    case secure      // Valid HTTPS
    case info        // HTTP / localhost
    case warning     // Cert error but user chose to proceed (allowed)
    case dangerous   // Cert error not yet handled (SSLErrorPage visible)
}

@MainActor
package class SecurityViewModel: ObservableObject {
    @Published package var level: SecurityLevel = .info
    @Published package var certSubject: String = ""
    @Published package var errorDescription: String = ""

    // SSL error state: non-nil means SSLErrorPage should be displayed.
    @Published package var pendingSSLError: SSLErrorInfo? = nil

    package struct SSLErrorInfo: Equatable {
        package let url: String
        package let certSubject: String
        package let errorDescription: String
        package let errorId: UInt64
    }

    // Injected callback for responding to SSL errors via C-ABI.
    package var onRespondToSSLError: ((UInt64, Bool) -> Void)?

    // MARK: - State Transitions

    /// Called when a new navigation starts.
    package func onNavigationStarted() {
        level = .loading
        pendingSSLError = nil
    }

    /// Coarse-grained update from PageInfo (URL scheme heuristic).
    /// The precise level is overridden by OnSecurityStateChanged.
    package func updateFromPageInfo(url: String, isLoading: Bool) {
        if isLoading {
            level = .loading
            return
        }
        guard !url.isEmpty else { return }
        if url.hasPrefix("https://") || url.hasPrefix("wss://") {
            if level == .loading { level = .secure }
        } else {
            if level == .loading { level = .info }
        }
    }

    /// Precise security state from OnSecurityStateChanged C-ABI callback.
    /// rawLevel: 0=Secure, 1=Info, 2=Warning, 3=Dangerous
    package func updateSecurityState(rawLevel: Int32, certSubject: String,
                                     errorDesc: String) {
        self.certSubject = certSubject
        self.errorDescription = errorDesc
        switch rawLevel {
        case 0: level = .secure
        case 1: level = .info
        case 2: level = .warning
        case 3: level = .dangerous
        default: level = .info
        }
    }

    /// SSL error arrived from OnSSLError C-ABI callback.
    package func onSSLError(url: String, certSubject: String,
                            errorDesc: String, errorId: UInt64) {
        level = .dangerous
        pendingSSLError = SSLErrorInfo(
            url: url, certSubject: certSubject,
            errorDescription: errorDesc, errorId: errorId)
    }

    /// User chose "Go back to safety".
    package func goBackToSafety() {
        guard let err = pendingSSLError else { return }
        onRespondToSSLError?(err.errorId, false)
        pendingSSLError = nil
    }

    /// User chose "Proceed anyway" (after second confirmation in SSLErrorPage).
    package func proceedAnyway() {
        guard let err = pendingSSLError else { return }
        onRespondToSSLError?(err.errorId, true)
        pendingSSLError = nil
        level = .warning  // Optimistic: will be refined by OnSecurityStateChanged after reload.
    }
}
