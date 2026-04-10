import Foundation

#if canImport(OWLBridge)
import OWLBridge
#endif

// MARK: - SSLBridge (C-ABI callback holder)

/// Global singleton that registers C-ABI SSL callbacks and
/// forwards events to SecurityViewModel.
/// Follows the same pattern as PermissionBridge.
@MainActor
final class SSLBridge {
    static let shared = SSLBridge()

    // Weak reference: SecurityViewModel is strongly held by BrowserViewModel.
    private weak var securityVM: SecurityViewModel?
    private var registeredSecurityStateWebViewIDs = Set<UInt64>()

    /// Call once from BrowserViewModel.initializeAndLaunch() after OWLBridge_Initialize().
    /// Registers global SSL error callback only. Per-webview security state callback
    /// is registered separately via registerSecurityState(webviewId:) after CreateWebView.
    func registerGlobal(securityVM: SecurityViewModel) {
        self.securityVM = securityVM

        // Wire the respond callback so SecurityViewModel can send responses.
        securityVM.onRespondToSSLError = { errorId, proceed in
            #if canImport(OWLBridge)
            OWLBridge_RespondToSSLError(errorId, proceed ? 1 : 0)
            #endif
        }

        guard OWLBridgeSwift.isInitializedInProcess() else { return }
        #if canImport(OWLBridge)
        // Register global SSL error callback.
        OWLBridge_SetSSLErrorCallback(sslErrorCallback, nil)
        #endif
    }

    /// Register per-webview security state callback.
    /// Called from BrowserViewModel.registerAllCallbacks after CreateWebView succeeds.
    func registerSecurityState(webviewId: UInt64) {
        assert(securityVM != nil, "registerGlobal must be called first")
        registeredSecurityStateWebViewIDs.insert(webviewId)

        guard OWLBridgeSwift.isInitializedInProcess() else { return }

        #if canImport(OWLBridge)
        OWLBridge_SetSecurityStateCallback(webviewId, securityStateCallback, nil)
        #endif
    }

    /// Unregister callbacks (app shutdown).
    func unregister() {
        guard OWLBridgeSwift.isInitializedInProcess() else {
            securityVM?.onRespondToSSLError = nil
            securityVM = nil
            registeredSecurityStateWebViewIDs.removeAll()
            return
        }

        #if canImport(OWLBridge)
        OWLBridge_SetSSLErrorCallback(nil, nil)
        for webviewId in registeredSecurityStateWebViewIDs {
            OWLBridge_SetSecurityStateCallback(webviewId, nil, nil)
        }
        #endif
        securityVM?.onRespondToSSLError = nil
        securityVM = nil
        registeredSecurityStateWebViewIDs.removeAll()
    }

    /// Internal: forward SSL error to SecurityViewModel.
    fileprivate func forwardSSLError(url: String, certSubject: String,
                                     errorDesc: String, errorId: UInt64) {
        securityVM?.onSSLError(url: url, certSubject: certSubject,
                               errorDesc: errorDesc, errorId: errorId)
    }

    /// Internal: forward security state change to SecurityViewModel.
    fileprivate func forwardSecurityState(level: Int32, certSubject: String,
                                          errorDesc: String) {
        securityVM?.updateSecurityState(rawLevel: level, certSubject: certSubject,
                                         errorDesc: errorDesc)
    }
}

// MARK: - C Callbacks (free functions, no closure capture)

#if canImport(OWLBridge)
private func sslErrorCallback(
    webviewId: UInt64,
    url: UnsafePointer<CChar>?,
    certSubject: UnsafePointer<CChar>?,
    errorDesc: UnsafePointer<CChar>?,
    errorId: UInt64,
    context: UnsafeMutableRawPointer?
) {
    let urlStr = url.map { String(cString: $0) } ?? ""
    let subject = certSubject.map { String(cString: $0) } ?? ""
    let desc = errorDesc.map { String(cString: $0) } ?? ""

    // C-ABI guarantees main thread, but Swift doesn't know — bridge via Task.
    Task { @MainActor in
        SSLBridge.shared.forwardSSLError(url: urlStr, certSubject: subject,
                                         errorDesc: desc, errorId: errorId)
    }
}

private func securityStateCallback(
    webviewId: UInt64,
    level: Int32,
    certSubject: UnsafePointer<CChar>?,
    errorDesc: UnsafePointer<CChar>?,
    context: UnsafeMutableRawPointer?
) {
    let subject = certSubject.map { String(cString: $0) } ?? ""
    let desc = errorDesc.map { String(cString: $0) } ?? ""

    Task { @MainActor in
        SSLBridge.shared.forwardSecurityState(level: level, certSubject: subject,
                                               errorDesc: desc)
    }
}
#endif
