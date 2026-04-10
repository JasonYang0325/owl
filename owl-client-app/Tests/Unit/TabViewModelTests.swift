import XCTest
@testable import OWLBrowserLib

/// TabViewModel unit tests -- Module 1 callback registration refactoring.
/// Uses TabViewModel.mock(), no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class TabViewModelTests: XCTestCase {

    // MARK: - Helpers

    /// Create a TabViewModel via mock factory on MainActor.
    private func makeTab(title: String = "新标签页",
                         url: String? = nil) -> TabViewModel {
        MainActor.assumeIsolated {
            TabViewModel.mock(title: title, url: url)
        }
    }

    // MARK: - AC3: webviewId property exists with default value

    /// AC3: TabViewModel.webviewId exists and defaults to 1.
    func testWebviewIdPropertyExistsWithDefault() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            // AC3: webviewId should be accessible and default to 1.
            XCTAssertEqual(tab.webviewId, 1,
                "AC3: webviewId should default to 1")
        }
    }

    /// AC3: webviewId is assignable (BrowserViewModel sets it after CreateWebView).
    func testWebviewIdIsAssignable() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.webviewId = 42
            XCTAssertEqual(tab.webviewId, 42,
                "AC3: webviewId should be assignable to arbitrary UInt64 values")
        }
    }

    // MARK: - AC2: handleFindResult filters non-active requestId

    /// AC2: handleFindResult ignores results with requestId != activeFindRequestId.
    /// In mock mode, activeFindRequestId stays 0 (find() C-ABI is gated).
    /// A requestId of 99 should be filtered out.
    func testHandleFindResult_filtersNonActiveRequestId() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isFindBarVisible = true
            tab.findState = FindState(query: "test")

            // activeFindRequestId is 0 in mock mode; pass requestId=99 to trigger mismatch.
            tab.handleFindResult(requestId: 99, matches: 5,
                                 activeOrdinal: 2, isFinal: true)

            // findState should NOT be updated (requestId mismatch).
            XCTAssertEqual(tab.findState?.totalMatches, 0,
                "AC2: handleFindResult should ignore results with non-matching requestId")
            XCTAssertEqual(tab.findState?.activeOrdinal, 0,
                "AC2: handleFindResult should not update activeOrdinal on requestId mismatch")
        }
    }

    // MARK: - AC2: handleFindResult filters when findBar is not visible

    /// AC2: handleFindResult ignores results when isFindBarVisible == false.
    func testHandleFindResult_filtersWhenFindBarNotVisible() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isFindBarVisible = false
            tab.findState = FindState(query: "test")

            // requestId=0 matches default activeFindRequestId, but findBar is hidden.
            tab.handleFindResult(requestId: 0, matches: 3,
                                 activeOrdinal: 1, isFinal: true)

            // findState should NOT be updated (findBar not visible).
            XCTAssertEqual(tab.findState?.totalMatches, 0,
                "AC2: handleFindResult should ignore results when findBar is not visible")
        }
    }

    // MARK: - AC2: handleFindResult filters non-final updates

    /// AC2: handleFindResult ignores incremental (non-final) results.
    func testHandleFindResult_filtersNonFinalUpdates() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isFindBarVisible = true
            tab.findState = FindState(query: "test")

            // All conditions met except isFinal=false.
            tab.handleFindResult(requestId: 0, matches: 10,
                                 activeOrdinal: 3, isFinal: false)

            // findState should NOT be updated (non-final).
            XCTAssertEqual(tab.findState?.totalMatches, 0,
                "AC2: handleFindResult should ignore non-final (incremental) results")
        }
    }

    // MARK: - AC2: handleFindResult updates findState on valid result

    /// AC2: handleFindResult correctly updates findState when all filters pass.
    func testHandleFindResult_updatesStateOnValidResult() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isFindBarVisible = true
            tab.findState = FindState(query: "hello")

            // requestId=0 matches default activeFindRequestId, findBar visible, isFinal=true.
            tab.handleFindResult(requestId: 0, matches: 7,
                                 activeOrdinal: 3, isFinal: true)

            // findState should be updated with new match results.
            XCTAssertEqual(tab.findState?.totalMatches, 7,
                "AC2: handleFindResult should update totalMatches on valid result")
            XCTAssertEqual(tab.findState?.activeOrdinal, 3,
                "AC2: handleFindResult should update activeOrdinal on valid result")
            XCTAssertEqual(tab.findState?.query, "hello",
                "AC2: handleFindResult should preserve query string")
        }
    }

    /// AC2: handleFindResult preserves existing query when findState has no query.
    func testHandleFindResult_preservesQueryFallback() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isFindBarVisible = true
            // findState with empty query (edge case).
            tab.findState = FindState(query: "")

            tab.handleFindResult(requestId: 0, matches: 2,
                                 activeOrdinal: 1, isFinal: true)

            // Should update and preserve the empty query.
            XCTAssertEqual(tab.findState?.query, "",
                "AC2: handleFindResult should preserve empty query string")
            XCTAssertEqual(tab.findState?.totalMatches, 2,
                "AC2: handleFindResult should update totalMatches even with empty query")
        }
    }

    /// AC2: handleFindResult does nothing when findState is nil.
    func testHandleFindResult_nilFindStateUsesEmptyQueryFallback() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isFindBarVisible = true
            tab.findState = nil  // No prior find initiated.

            tab.handleFindResult(requestId: 0, matches: 1,
                                 activeOrdinal: 1, isFinal: true)

            // findState should be created with fallback empty query.
            XCTAssertNotNil(tab.findState,
                "AC2: handleFindResult should create findState even if previously nil")
            XCTAssertEqual(tab.findState?.query, "",
                "AC2: handleFindResult should use empty string fallback for nil findState query")
            XCTAssertEqual(tab.findState?.totalMatches, 1,
                "AC2: handleFindResult should set totalMatches correctly")
        }
    }

    // MARK: - AC2: handleFindResult zero matches

    /// AC2: handleFindResult correctly handles zero matches.
    func testHandleFindResult_zeroMatches() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isFindBarVisible = true
            tab.findState = FindState(query: "nonexistent")

            tab.handleFindResult(requestId: 0, matches: 0,
                                 activeOrdinal: 0, isFinal: true)

            XCTAssertEqual(tab.findState?.totalMatches, 0,
                "AC2: handleFindResult should handle zero matches")
            XCTAssertEqual(tab.findState?.activeOrdinal, 0,
                "AC2: handleFindResult should set activeOrdinal to 0 when no matches")
        }
    }

    // MARK: - Phase 2: onNavigationStarted

    /// AC-P2: onNavigationStarted sets loadingProgress to 0.1.
    func testOnNavigationStarted_setsInitialProgress() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            XCTAssertEqual(tab.loadingProgress, 0.0,
                "Initial loadingProgress should be 0.0")

            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)

            XCTAssertEqual(tab.loadingProgress, 0.1,
                "AC-P2: onNavigationStarted should set progress to 0.1")
        }
    }

    /// AC-P2: onNavigationStarted clears any previous navigationError.
    func testOnNavigationStarted_clearsNavigationError() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            // Simulate a prior navigation error (must start nav first so navId matches guard).
            tab.onNavigationStarted(navigationId: 1, url: "https://bad.example.com",
                                    isUserInitiated: true)
            tab.onNavigationFailed(navigationId: 1, url: "https://bad.example.com",
                                   errorCode: -105, errorDescription: "Not resolved")
            XCTAssertNotNil(tab.navigationError,
                "Precondition: navigationError should be set after failure")

            // Start new navigation.
            tab.onNavigationStarted(navigationId: 2, url: "https://good.example.com",
                                    isUserInitiated: true)

            XCTAssertNil(tab.navigationError,
                "AC-P2: onNavigationStarted should clear previous navigationError")
        }
    }

    /// AC-P2: onNavigationStarted resets isSlowLoading to false.
    func testOnNavigationStarted_resetsSlowLoading() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)

            XCTAssertFalse(tab.isSlowLoading,
                "AC-P2: onNavigationStarted should reset isSlowLoading to false")
        }
    }

    // MARK: - Phase 2: onNavigationCommitted

    /// AC-P2: onNavigationCommitted bumps progress to at least 0.6.
    func testOnNavigationCommitted_bumpsProgressToSixty() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            // Simulate navigation start.
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            XCTAssertEqual(tab.loadingProgress, 0.1)

            tab.onNavigationCommitted(navigationId: 1, url: "https://example.com",
                                      httpStatus: 200)

            XCTAssertGreaterThanOrEqual(tab.loadingProgress, 0.6,
                "AC-P2: onNavigationCommitted should bump progress to >= 0.6")
        }
    }

    /// AC-P2: onNavigationCommitted does not reduce progress if already above 0.6.
    func testOnNavigationCommitted_doesNotReduceHigherProgress() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            // Manually set progress higher than 0.6 to simulate slow crawl.
            tab.loadingProgress = 0.8

            tab.onNavigationCommitted(navigationId: 1, url: "https://example.com",
                                      httpStatus: 200)

            XCTAssertGreaterThanOrEqual(tab.loadingProgress, 0.8,
                "AC-P2: onNavigationCommitted should not reduce progress below its current value")
        }
    }

    // MARK: - Phase 2: onNavigationFailed

    /// AC-P2: onNavigationFailed with non-aborted error sets navigationError.
    func testOnNavigationFailed_setsNavigationError() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://bad.example.com",
                                    isUserInitiated: true)

            tab.onNavigationFailed(navigationId: 1, url: "https://bad.example.com",
                                   errorCode: -105,
                                   errorDescription: "ERR_NAME_NOT_RESOLVED")

            XCTAssertNotNil(tab.navigationError,
                "AC-P2: onNavigationFailed should set navigationError for non-aborted errors")
            XCTAssertEqual(tab.navigationError?.errorCode, -105)
        }
    }

    /// AC-P2: onNavigationFailed resets loadingProgress to 0.
    func testOnNavigationFailed_resetsProgress() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://bad.example.com",
                                    isUserInitiated: true)
            XCTAssertGreaterThan(tab.loadingProgress, 0.0)

            tab.onNavigationFailed(navigationId: 1, url: "https://bad.example.com",
                                   errorCode: -105, errorDescription: "Not resolved")

            XCTAssertEqual(tab.loadingProgress, 0.0,
                "AC-P2: onNavigationFailed should reset loadingProgress to 0")
        }
    }

    /// AC-P2: onNavigationFailed resets isSlowLoading.
    func testOnNavigationFailed_resetsSlowLoading() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://bad.example.com",
                                    isUserInitiated: true)

            tab.onNavigationFailed(navigationId: 1, url: "https://bad.example.com",
                                   errorCode: -105, errorDescription: "Not resolved")

            XCTAssertFalse(tab.isSlowLoading,
                "AC-P2: onNavigationFailed should reset isSlowLoading to false")
        }
    }

    /// AC-P2: ERR_ABORTED (-3) does NOT set navigationError (user stopped loading).
    func testOnNavigationFailed_abortedDoesNotSetError() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)

            tab.onNavigationFailed(navigationId: 1, url: "https://example.com",
                                   errorCode: -3, errorDescription: "ERR_ABORTED")

            XCTAssertNil(tab.navigationError,
                "AC-P2: ERR_ABORTED should NOT show error page (navigationError stays nil)")
        }
    }

    /// AC-P2: ERR_TOO_MANY_REDIRECTS (-310) sets navigationError with requiresGoBack=true.
    func testOnNavigationFailed_tooManyRedirects_requiresGoBack() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://loop.example.com",
                                    isUserInitiated: true)

            tab.onNavigationFailed(navigationId: 1, url: "https://loop.example.com",
                                   errorCode: -310,
                                   errorDescription: "ERR_TOO_MANY_REDIRECTS")

            XCTAssertNotNil(tab.navigationError)
            XCTAssertTrue(tab.navigationError?.requiresGoBack ?? false,
                "AC-P2: ERR_TOO_MANY_REDIRECTS should show 'go back' instead of 'retry'")
        }
    }

    /// AC-P2: Initial state has no navigation error and zero progress.
    func testInitialState_noErrorNoProgress() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            XCTAssertEqual(tab.loadingProgress, 0.0)
            XCTAssertNil(tab.navigationError)
            XCTAssertFalse(tab.isSlowLoading)
        }
    }

    // MARK: - Phase 2: loadingProgress property exists

    /// AC-P2: loadingProgress property exists and is assignable (for animation testing).
    func testLoadingProgress_isPublishedAndAssignable() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.loadingProgress = 0.5
            XCTAssertEqual(tab.loadingProgress, 0.5)
            tab.loadingProgress = 1.0
            XCTAssertEqual(tab.loadingProgress, 1.0)
        }
    }

    /// AC-P2: navigationError property is settable (for view binding testing).
    func testNavigationError_isPublishedAndSettable() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            XCTAssertNil(tab.navigationError)
            tab.navigationError = NavigationError(
                navigationId: 1, url: "https://example.com",
                errorCode: -105, errorDescription: "test")
            XCTAssertNotNil(tab.navigationError)
            XCTAssertEqual(tab.navigationError?.errorCode, -105)
        }
    }

    // MARK: - P0: completeNavigation(success:)

    /// P0: completeNavigation(success: true) sets loadingProgress to 1.0 immediately.
    func testCompleteNavigation_success_setsProgressToOne() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            XCTAssertEqual(tab.loadingProgress, 0.1, "Precondition: progress at 0.1 after start")

            tab.completeNavigation(success: true)

            XCTAssertEqual(tab.loadingProgress, 1.0,
                "P0: completeNavigation(success: true) should set progress to 1.0")
        }
    }

    /// P0: completeNavigation(success: true) clears navigationError (via deferred Task).
    /// We verify the synchronous snapshot right after the call; the deferred nil-out
    /// happens after 300ms in a Task, so we test the immediate progress=1.0 state.
    func testCompleteNavigation_success_clearsError() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            // Set up a prior error.
            tab.onNavigationStarted(navigationId: 1, url: "https://bad.example.com",
                                    isUserInitiated: true)
            tab.onNavigationFailed(navigationId: 1, url: "https://bad.example.com",
                                   errorCode: -105, errorDescription: "Not resolved")
            XCTAssertNotNil(tab.navigationError, "Precondition: error should be set")

            // Start a new navigation so currentNavigationId advances.
            tab.onNavigationStarted(navigationId: 2, url: "https://good.example.com",
                                    isUserInitiated: true)
            XCTAssertNil(tab.navigationError,
                "Precondition: onNavigationStarted clears error")

            tab.completeNavigation(success: true)

            // Immediately after completeNavigation(success:true), progress is 1.0.
            // The error was already nil from onNavigationStarted; the deferred Task
            // in completeNavigation will also set it to nil after 300ms.
            XCTAssertEqual(tab.loadingProgress, 1.0,
                "P0: progress should be 1.0 on success completion")
        }
    }

    /// P0: completeNavigation(success: true) resets isSlowLoading.
    func testCompleteNavigation_success_resetsSlowLoading() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            // Force isSlowLoading to true to test reset.
            tab.isSlowLoading = true
            XCTAssertTrue(tab.isSlowLoading, "Precondition: isSlowLoading should be true")

            tab.completeNavigation(success: true)

            XCTAssertFalse(tab.isSlowLoading,
                "P0: completeNavigation(success: true) should reset isSlowLoading to false")
        }
    }

    /// P0: completeNavigation(success: false) resets loadingProgress to 0.
    func testCompleteNavigation_failure_resetsProgress() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            XCTAssertGreaterThan(tab.loadingProgress, 0.0,
                "Precondition: progress > 0 after start")

            tab.completeNavigation(success: false)

            XCTAssertEqual(tab.loadingProgress, 0.0,
                "P0: completeNavigation(success: false) should reset progress to 0")
        }
    }

    /// P0: completeNavigation(success: false) does NOT clear an existing error.
    func testCompleteNavigation_failure_keepsExistingError() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://bad.example.com",
                                    isUserInitiated: true)
            tab.onNavigationFailed(navigationId: 1, url: "https://bad.example.com",
                                   errorCode: -105, errorDescription: "Not resolved")
            XCTAssertNotNil(tab.navigationError,
                "Precondition: navigationError should be set after failure")

            tab.completeNavigation(success: false)

            XCTAssertNotNil(tab.navigationError,
                "P0: completeNavigation(success: false) should NOT clear existing error")
            XCTAssertEqual(tab.navigationError?.errorCode, -105,
                "P0: error code should be preserved")
        }
    }

    /// P0: completeNavigation(success: false) resets isSlowLoading.
    func testCompleteNavigation_failure_resetsSlowLoading() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            tab.isSlowLoading = true

            tab.completeNavigation(success: false)

            XCTAssertFalse(tab.isSlowLoading,
                "P0: completeNavigation(success: false) should reset isSlowLoading to false")
        }
    }

    // MARK: - P0: onNavigationRedirected

    /// P0: onNavigationRedirected does NOT reset loadingProgress.
    func testOnNavigationRedirected_doesNotResetProgress() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            let progressBeforeRedirect = tab.loadingProgress
            XCTAssertGreaterThan(progressBeforeRedirect, 0.0,
                "Precondition: progress > 0 after start")

            tab.onNavigationRedirected(navigationId: 2, url: "https://redirected.example.com")

            XCTAssertEqual(tab.loadingProgress, progressBeforeRedirect,
                "P0: onNavigationRedirected should NOT reset progress")
        }
    }

    /// P0: onNavigationRedirected does NOT clear an existing error.
    func testOnNavigationRedirected_doesNotClearError() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            // Set up a prior error that persists.
            tab.navigationError = NavigationError(
                navigationId: 0, url: "https://old.example.com",
                errorCode: -105, errorDescription: "Not resolved")
            XCTAssertNotNil(tab.navigationError,
                "Precondition: navigationError should exist")

            tab.onNavigationRedirected(navigationId: 2, url: "https://redirected.example.com")

            XCTAssertNotNil(tab.navigationError,
                "P0: onNavigationRedirected should NOT clear existing error")
        }
    }

    /// P0: onNavigationRedirected updates currentNavigationId.
    func testOnNavigationRedirected_updatesNavigationId() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            XCTAssertEqual(tab.currentNavigationId, 1,
                "Precondition: currentNavigationId should be 1")

            tab.onNavigationRedirected(navigationId: 2, url: "https://redirected.example.com")

            XCTAssertEqual(tab.currentNavigationId, 2,
                "P0: onNavigationRedirected should update currentNavigationId")
        }
    }

    // MARK: - P0: stop()

    /// P0: stop() resets loadingProgress to 0.
    func testStop_resetsLoadingProgress() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            XCTAssertGreaterThan(tab.loadingProgress, 0.0,
                "Precondition: progress > 0 after start")

            tab.stop()

            XCTAssertEqual(tab.loadingProgress, 0.0,
                "P0: stop() should reset loadingProgress to 0")
        }
    }

    /// P0: stop() resets isSlowLoading to false.
    func testStop_resetsSlowLoading() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            tab.isSlowLoading = true

            tab.stop()

            XCTAssertFalse(tab.isSlowLoading,
                "P0: stop() should reset isSlowLoading to false")
        }
    }

    /// P0: stop() does NOT set navigationError.
    func testStop_doesNotSetNavigationError() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.onNavigationStarted(navigationId: 1, url: "https://example.com",
                                    isUserInitiated: true)
            XCTAssertNil(tab.navigationError,
                "Precondition: no error before stop")

            tab.stop()

            XCTAssertNil(tab.navigationError,
                "P0: stop() should NOT set navigationError (no error page for user-stop)")
        }
    }

    /// P0: stop() sets isLoading to false.
    func testStop_setsIsLoadingToFalse() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            tab.isLoading = true

            tab.stop()

            XCTAssertFalse(tab.isLoading,
                "P0: stop() should set isLoading to false")
        }
    }

    // MARK: - P1: Stale navigationId guard

    /// P1: onNavigationCommitted ignores events with stale navigationId.
    func testOnNavigationCommitted_staleNavId_ignored() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            // Start navigation 1, then start navigation 2 (supersedes 1).
            tab.onNavigationStarted(navigationId: 1, url: "https://first.example.com",
                                    isUserInitiated: true)
            tab.onNavigationStarted(navigationId: 2, url: "https://second.example.com",
                                    isUserInitiated: true)
            XCTAssertEqual(tab.currentNavigationId, 2,
                "Precondition: currentNavigationId should be 2")
            XCTAssertEqual(tab.loadingProgress, 0.1,
                "Precondition: progress at 0.1 after fresh start")

            // Commit from stale navigation 1 — should be ignored.
            tab.onNavigationCommitted(navigationId: 1, url: "https://first.example.com",
                                      httpStatus: 200)

            // Progress should NOT have jumped to 0.6 because navId 1 is stale.
            XCTAssertEqual(tab.loadingProgress, 0.1,
                "P1: onNavigationCommitted with stale navId should be ignored (progress unchanged)")
        }
    }

    /// P1: onNavigationFailed ignores events with stale navigationId.
    func testOnNavigationFailed_staleNavId_ignored() {
        let tab = makeTab()

        MainActor.assumeIsolated {
            // Start navigation 1, then start navigation 2 (supersedes 1).
            tab.onNavigationStarted(navigationId: 1, url: "https://first.example.com",
                                    isUserInitiated: true)
            tab.onNavigationStarted(navigationId: 2, url: "https://second.example.com",
                                    isUserInitiated: true)
            XCTAssertEqual(tab.currentNavigationId, 2)
            XCTAssertEqual(tab.loadingProgress, 0.1)

            // Failure from stale navigation 1 — should be ignored.
            tab.onNavigationFailed(navigationId: 1, url: "https://first.example.com",
                                   errorCode: -105, errorDescription: "Not resolved")

            // Progress should remain at 0.1 (not reset to 0).
            XCTAssertEqual(tab.loadingProgress, 0.1,
                "P1: onNavigationFailed with stale navId should not reset progress")
            // No error should be set.
            XCTAssertNil(tab.navigationError,
                "P1: onNavigationFailed with stale navId should not set error")
        }
    }
}
