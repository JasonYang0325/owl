import XCTest
@testable import OWLBrowserLib

/// SecurityViewModel unit tests -- Phase 4 SSL 安全状态 + 错误页
/// Uses direct construction, no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class SecurityViewModelTests: XCTestCase {

    // MARK: - Helpers

    /// Create a SecurityViewModel on MainActor.
    private func makeVM() -> SecurityViewModel {
        MainActor.assumeIsolated {
            SecurityViewModel()
        }
    }

    // MARK: - AC-P4-1: HTTPS page shows secure level

    /// AC-P4-1: updateFromPageInfo with HTTPS URL sets level to .secure.
    func testSecurityLevelHTTPS() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Start from loading state (as real navigation would).
            vm.onNavigationStarted()
            XCTAssertEqual(vm.level, .loading,
                "Precondition: level should be .loading after navigation start")

            // Simulate page info callback with HTTPS URL and loading complete.
            vm.updateFromPageInfo(url: "https://example.com/page", isLoading: false)

            // AC-P4-1: HTTPS page -> .secure level.
            XCTAssertEqual(vm.level, .secure,
                "AC-P4-1: HTTPS page should set level to .secure")
        }
    }

    // MARK: - AC-P4-2: HTTP page shows info level

    /// AC-P4-2: updateFromPageInfo with HTTP URL sets level to .info.
    func testSecurityLevelHTTP() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onNavigationStarted()

            // Simulate page info callback with HTTP URL and loading complete.
            vm.updateFromPageInfo(url: "http://example.com/page", isLoading: false)

            // AC-P4-2: HTTP page -> .info level.
            XCTAssertEqual(vm.level, .info,
                "AC-P4-2: HTTP page should set level to .info")
        }
    }

    // MARK: - AC-P4-3: SSL error sets level to dangerous + pendingSSLError

    /// AC-P4-3: onSSLError sets level to .dangerous and populates pendingSSLError.
    func testSSLErrorSetsLevelDangerous() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            XCTAssertNil(vm.pendingSSLError,
                "Precondition: pendingSSLError should be nil initially")

            // Simulate SSL error callback from Host.
            vm.onSSLError(
                url: "https://expired.badssl.com",
                certSubject: "*.badssl.com",
                errorDesc: "net::ERR_CERT_DATE_INVALID",
                errorId: 42
            )

            // AC-P4-3: level becomes .dangerous.
            XCTAssertEqual(vm.level, .dangerous,
                "AC-P4-3: SSL error should set level to .dangerous")

            // AC-P4-3: pendingSSLError is populated with error details.
            XCTAssertNotNil(vm.pendingSSLError,
                "AC-P4-3: pendingSSLError should be non-nil after onSSLError")
            XCTAssertEqual(vm.pendingSSLError?.url, "https://expired.badssl.com",
                "AC-P4-3: pendingSSLError.url should match")
            XCTAssertEqual(vm.pendingSSLError?.certSubject, "*.badssl.com",
                "AC-P4-3: pendingSSLError.certSubject should match")
            XCTAssertEqual(vm.pendingSSLError?.errorDescription,
                "net::ERR_CERT_DATE_INVALID",
                "AC-P4-3: pendingSSLError.errorDescription should match")
            XCTAssertEqual(vm.pendingSSLError?.errorId, 42,
                "AC-P4-3: pendingSSLError.errorId should match")
        }
    }

    // MARK: - AC-P4-4: goBackToSafety clears pending and responds false

    /// AC-P4-4: goBackToSafety() clears pendingSSLError and calls
    /// onRespondToSSLError with (errorId, false).
    func testGoBackToClearsPending() {
        let vm = makeVM()

        // Track callback invocation.
        var capturedErrorId: UInt64?
        var capturedProceed: Bool?

        MainActor.assumeIsolated {
            vm.onRespondToSSLError = { errorId, proceed in
                capturedErrorId = errorId
                capturedProceed = proceed
            }

            // Set up SSL error state.
            vm.onSSLError(
                url: "https://self-signed.badssl.com",
                certSubject: "self-signed.badssl.com",
                errorDesc: "net::ERR_CERT_AUTHORITY_INVALID",
                errorId: 99
            )
            XCTAssertNotNil(vm.pendingSSLError,
                "Precondition: pendingSSLError should exist")

            // AC-P4-4: User taps "go back to safety".
            vm.goBackToSafety()

            // AC-P4-4: pendingSSLError is cleared.
            XCTAssertNil(vm.pendingSSLError,
                "AC-P4-4: pendingSSLError should be nil after goBackToSafety")

            // AC-P4-4: onRespondToSSLError called with proceed=false.
            XCTAssertEqual(capturedErrorId, 99,
                "AC-P4-4: onRespondToSSLError should receive the correct errorId")
            XCTAssertEqual(capturedProceed, false,
                "AC-P4-4: onRespondToSSLError should receive proceed=false")
        }
    }

    // MARK: - AC-P4-5: proceedAnyway sets warning level and responds true

    /// AC-P4-5: proceedAnyway() sets level to .warning, clears pendingSSLError,
    /// and calls onRespondToSSLError with (errorId, true).
    func testProceedAnywaySetWarning() {
        let vm = makeVM()

        var capturedErrorId: UInt64?
        var capturedProceed: Bool?

        MainActor.assumeIsolated {
            vm.onRespondToSSLError = { errorId, proceed in
                capturedErrorId = errorId
                capturedProceed = proceed
            }

            // Set up SSL error state.
            vm.onSSLError(
                url: "https://expired.badssl.com",
                certSubject: "*.badssl.com",
                errorDesc: "net::ERR_CERT_DATE_INVALID",
                errorId: 77
            )
            XCTAssertEqual(vm.level, .dangerous,
                "Precondition: level should be .dangerous")

            // AC-P4-5: User confirms "proceed anyway" (after secondary confirmation).
            vm.proceedAnyway()

            // AC-P4-5: level transitions to .warning (cert error but user allowed).
            XCTAssertEqual(vm.level, .warning,
                "AC-P4-5: level should be .warning after proceedAnyway")

            // AC-P4-5: pendingSSLError is cleared.
            XCTAssertNil(vm.pendingSSLError,
                "AC-P4-5: pendingSSLError should be nil after proceedAnyway")

            // AC-P4-5: onRespondToSSLError called with proceed=true.
            XCTAssertEqual(capturedErrorId, 77,
                "AC-P4-5: onRespondToSSLError should receive the correct errorId")
            XCTAssertEqual(capturedProceed, true,
                "AC-P4-5: onRespondToSSLError should receive proceed=true")
        }
    }

    // MARK: - AC-P4-1/AC-P4-2: Loading state transition

    /// AC-P4-1, AC-P4-2: onNavigationStarted() resets level to .loading
    /// and clears any pending SSL error.
    func testLoadingStateTransition() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Start with a completed secure page.
            vm.updateFromPageInfo(url: "https://example.com", isLoading: false)
            // Set up an SSL error to verify it gets cleared.
            vm.onSSLError(
                url: "https://bad.example.com",
                certSubject: "bad.example.com",
                errorDesc: "net::ERR_CERT_DATE_INVALID",
                errorId: 1
            )
            XCTAssertNotNil(vm.pendingSSLError,
                "Precondition: pendingSSLError should exist")

            // AC-P4-1, AC-P4-2: New navigation starts.
            vm.onNavigationStarted()

            // Level resets to .loading.
            XCTAssertEqual(vm.level, .loading,
                "AC-P4-1: onNavigationStarted should set level to .loading")

            // Pending SSL error is cleared (new navigation = fresh state).
            XCTAssertNil(vm.pendingSSLError,
                "AC-P4-1: onNavigationStarted should clear pendingSSLError")
        }
    }

    // MARK: - Module 1 AC: updateSecurityState rawLevel mapping

    /// Module 1: updateSecurityState(rawLevel: 0) -> .secure
    func testUpdateSecurityState_rawLevel0_secure() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.updateSecurityState(rawLevel: 0, certSubject: "example.com",
                                   errorDesc: "")

            XCTAssertEqual(vm.level, .secure,
                "AC: rawLevel 0 should map to .secure")
            XCTAssertEqual(vm.certSubject, "example.com",
                "AC: certSubject should be stored")
            XCTAssertEqual(vm.errorDescription, "",
                "AC: errorDescription should be stored")
        }
    }

    /// Module 1: updateSecurityState(rawLevel: 1) -> .info
    func testUpdateSecurityState_rawLevel1_info() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.updateSecurityState(rawLevel: 1, certSubject: "",
                                   errorDesc: "")

            XCTAssertEqual(vm.level, .info,
                "AC: rawLevel 1 should map to .info")
        }
    }

    /// Module 1: updateSecurityState(rawLevel: 2) -> .warning
    func testUpdateSecurityState_rawLevel2_warning() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.updateSecurityState(rawLevel: 2, certSubject: "self-signed.test",
                                   errorDesc: "net::ERR_CERT_AUTHORITY_INVALID")

            XCTAssertEqual(vm.level, .warning,
                "AC: rawLevel 2 should map to .warning")
            XCTAssertEqual(vm.certSubject, "self-signed.test",
                "AC: certSubject should reflect the certificate subject")
            XCTAssertEqual(vm.errorDescription, "net::ERR_CERT_AUTHORITY_INVALID",
                "AC: errorDescription should reflect the error string")
        }
    }

    /// Module 1: updateSecurityState(rawLevel: 3) -> .dangerous
    func testUpdateSecurityState_rawLevel3_dangerous() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.updateSecurityState(rawLevel: 3, certSubject: "expired.badssl.com",
                                   errorDesc: "net::ERR_CERT_DATE_INVALID")

            XCTAssertEqual(vm.level, .dangerous,
                "AC: rawLevel 3 should map to .dangerous")
        }
    }

    /// Module 1: updateSecurityState with unknown rawLevel defaults to .info
    func testUpdateSecurityState_unknownRawLevel_defaultsToInfo() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Start with a known state to verify it changes.
            vm.updateSecurityState(rawLevel: 0, certSubject: "", errorDesc: "")
            XCTAssertEqual(vm.level, .secure,
                "Precondition: level should be .secure")

            // Unknown rawLevel (e.g., 99) should default to .info.
            vm.updateSecurityState(rawLevel: 99, certSubject: "", errorDesc: "")

            XCTAssertEqual(vm.level, .info,
                "AC: unknown rawLevel should default to .info")
        }
    }

    /// Module 1: updateSecurityState with negative rawLevel defaults to .info
    func testUpdateSecurityState_negativeRawLevel_defaultsToInfo() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.updateSecurityState(rawLevel: -1, certSubject: "", errorDesc: "")

            XCTAssertEqual(vm.level, .info,
                "AC: negative rawLevel should default to .info")
        }
    }
}

// MARK: - AC5: SSLBridge split verification

/// Compile-time verification that SSLBridge exposes registerGlobal and
/// registerSecurityState as separate methods (AC5).
/// These tests run in mock mode. SSLBridge now avoids calling C-ABI registration
/// functions unless OWLBridge has been initialized in-process.
final class SSLBridgeSplitTests: XCTestCase {

    // MARK: - AC5: registerGlobal exists and accepts SecurityViewModel

    /// AC5: SSLBridge.shared.registerGlobal(securityVM:) compiles and runs.
    /// This is primarily a compile-time verification that the old single
    /// `register(securityVM:)` has been split into registerGlobal.
    func testRegisterGlobalExists() {
        MainActor.assumeIsolated {
            let securityVM = SecurityViewModel()
            // If this compiles, AC5 registerGlobal interface exists.
            SSLBridge.shared.registerGlobal(securityVM: securityVM)

            // Verify the respond callback was wired.
            XCTAssertNotNil(securityVM.onRespondToSSLError,
                "AC5: registerGlobal should wire onRespondToSSLError callback")

            // Clean up.
            SSLBridge.shared.unregister()
        }
    }

    // MARK: - AC5: registerSecurityState exists and accepts webviewId

    /// AC5: SSLBridge.shared.registerSecurityState(webviewId:) compiles and runs.
    /// This verifies the per-webview registration is a separate step from
    /// the global registration (AC5 split).
    func testRegisterSecurityStateExists() {
        MainActor.assumeIsolated {
            let securityVM = SecurityViewModel()
            // Must call registerGlobal first (assertion guard inside).
            SSLBridge.shared.registerGlobal(securityVM: securityVM)

            // If this compiles, AC5 registerSecurityState interface exists.
            // The webviewId parameter confirms it's per-webview.
            SSLBridge.shared.registerSecurityState(webviewId: 1)

            // Clean up.
            SSLBridge.shared.unregister()
        }
    }
}
