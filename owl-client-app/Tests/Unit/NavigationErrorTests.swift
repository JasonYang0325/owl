import XCTest
@testable import OWLBrowserLib

/// NavigationError model unit tests — Phase 2.
/// Validates computed properties: localizedTitle, localizedMessage, suggestion,
/// requiresGoBack, isAborted for all known Chromium net error codes.
final class NavigationErrorTests: XCTestCase {

    // MARK: - Helpers

    /// Create a NavigationError with the given error code.
    private func makeError(
        code: Int32,
        description: String = "",
        navigationId: Int64 = 1,
        url: String = "https://example.com"
    ) -> NavigationError {
        NavigationError(
            navigationId: navigationId,
            url: url,
            errorCode: code,
            errorDescription: description
        )
    }

    // MARK: - localizedTitle

    /// AC: ERR_NAME_NOT_RESOLVED (-105) shows "找不到该网站".
    func testLocalizedTitle_NameNotResolved() {
        let error = makeError(code: -105)
        XCTAssertEqual(error.localizedTitle, "找不到该网站")
    }

    /// AC: ERR_INTERNET_DISCONNECTED (-106) shows "无法连接到互联网".
    func testLocalizedTitle_InternetDisconnected() {
        let error = makeError(code: -106)
        XCTAssertEqual(error.localizedTitle, "无法连接到互联网")
    }

    /// AC: ERR_CONNECTION_TIMED_OUT (-118) shows "连接超时".
    func testLocalizedTitle_ConnectionTimedOut() {
        let error = makeError(code: -118)
        XCTAssertEqual(error.localizedTitle, "连接超时")
    }

    /// AC: ERR_CERT_DATE_INVALID (-200) shows "证书错误".
    func testLocalizedTitle_CertError() {
        let error = makeError(code: -200)
        XCTAssertEqual(error.localizedTitle, "证书错误")
    }

    /// AC: ERR_TOO_MANY_REDIRECTS (-310) shows "重定向次数过多".
    func testLocalizedTitle_TooManyRedirects() {
        let error = makeError(code: -310)
        XCTAssertEqual(error.localizedTitle, "重定向次数过多")
    }

    /// AC: ERR_NAME_RESOLUTION_FAILED (-137) shows "域名解析失败".
    func testLocalizedTitle_NameResolutionFailed() {
        let error = makeError(code: -137)
        XCTAssertEqual(error.localizedTitle, "域名解析失败")
    }

    /// AC: ERR_ABORTED (-2) shows "请求被取消".
    func testLocalizedTitle_Aborted() {
        let error = makeError(code: -2)
        XCTAssertEqual(error.localizedTitle, "请求被取消")
    }

    /// AC: Unknown error code shows generic "无法访问此页面".
    func testLocalizedTitle_UnknownError() {
        let error = makeError(code: -999)
        XCTAssertEqual(error.localizedTitle, "无法访问此页面")
    }

    /// AC: Positive error code falls through to default.
    func testLocalizedTitle_PositiveCodeUsesDefault() {
        let error = makeError(code: 42)
        XCTAssertEqual(error.localizedTitle, "无法访问此页面")
    }

    /// AC: Zero error code falls through to default.
    func testLocalizedTitle_ZeroCodeUsesDefault() {
        let error = makeError(code: 0)
        XCTAssertEqual(error.localizedTitle, "无法访问此页面")
    }

    // MARK: - localizedMessage

    /// AC: ERR_NAME_NOT_RESOLVED (-105) message.
    func testLocalizedMessage_NameNotResolved() {
        let error = makeError(code: -105)
        XCTAssertEqual(error.localizedMessage, "请检查网址是否正确，或稍后重试。")
    }

    /// AC: ERR_INTERNET_DISCONNECTED (-106) message.
    func testLocalizedMessage_InternetDisconnected() {
        let error = makeError(code: -106)
        XCTAssertEqual(error.localizedMessage, "请检查网络连接是否正常。")
    }

    /// AC: ERR_CONNECTION_TIMED_OUT (-118) message.
    func testLocalizedMessage_ConnectionTimedOut() {
        let error = makeError(code: -118)
        XCTAssertEqual(error.localizedMessage, "服务器响应时间过长，请稍后重试。")
    }

    /// AC: ERR_CERT_DATE_INVALID (-200) message.
    func testLocalizedMessage_CertError() {
        let error = makeError(code: -200)
        XCTAssertEqual(error.localizedMessage, "该网站的安全证书存在问题。")
    }

    /// AC: ERR_TOO_MANY_REDIRECTS (-310) message.
    func testLocalizedMessage_TooManyRedirects() {
        let error = makeError(code: -310)
        XCTAssertEqual(error.localizedMessage, "该页面重定向次数过多，无法继续加载。")
    }

    /// AC: ERR_NAME_RESOLUTION_FAILED (-137) message.
    func testLocalizedMessage_NameResolutionFailed() {
        let error = makeError(code: -137)
        XCTAssertEqual(error.localizedMessage, "无法解析域名，请检查网址。")
    }

    /// AC: Unknown error code with non-empty description uses that description.
    func testLocalizedMessage_UnknownWithDescription() {
        let error = makeError(code: -999, description: "Custom error text")
        XCTAssertEqual(error.localizedMessage, "Custom error text")
    }

    /// AC: Unknown error code with empty description falls back to generic.
    func testLocalizedMessage_UnknownWithEmptyDescription() {
        let error = makeError(code: -999, description: "")
        XCTAssertEqual(error.localizedMessage, "发生了未知错误。")
    }

    // MARK: - suggestion

    /// AC: ERR_NAME_NOT_RESOLVED (-105) has suggestion about checking URL spelling.
    func testSuggestion_NameNotResolved() {
        let error = makeError(code: -105)
        XCTAssertEqual(error.suggestion, "检查网址拼写是否正确")
    }

    /// AC: ERR_NAME_RESOLUTION_FAILED (-137) shares same suggestion as -105.
    func testSuggestion_NameResolutionFailed() {
        let error = makeError(code: -137)
        XCTAssertEqual(error.suggestion, "检查网址拼写是否正确")
    }

    /// AC: ERR_INTERNET_DISCONNECTED (-106) suggests checking WiFi.
    func testSuggestion_InternetDisconnected() {
        let error = makeError(code: -106)
        XCTAssertEqual(error.suggestion, "检查 Wi-Fi 或网线连接")
    }

    /// AC: ERR_CONNECTION_TIMED_OUT (-118) mentions server unavailability.
    func testSuggestion_ConnectionTimedOut() {
        let error = makeError(code: -118)
        XCTAssertEqual(error.suggestion, "服务器可能暂时不可用")
    }

    /// AC: ERR_TOO_MANY_REDIRECTS (-310) suggests going back.
    func testSuggestion_TooManyRedirects() {
        let error = makeError(code: -310)
        XCTAssertEqual(error.suggestion, "尝试返回上一页")
    }

    /// AC: ERR_CERT_DATE_INVALID (-200) has no suggestion.
    func testSuggestion_CertErrorIsNil() {
        let error = makeError(code: -200)
        XCTAssertNil(error.suggestion)
    }

    /// AC: Unknown error code has no suggestion.
    func testSuggestion_UnknownErrorIsNil() {
        let error = makeError(code: -999)
        XCTAssertNil(error.suggestion)
    }

    // MARK: - requiresGoBack

    /// AC: ERR_TOO_MANY_REDIRECTS (-310) shows "返回" instead of "重试".
    func testRequiresGoBack_TooManyRedirects() {
        let error = makeError(code: -310)
        XCTAssertTrue(error.requiresGoBack,
            "ERR_TOO_MANY_REDIRECTS should require go-back instead of retry")
    }

    /// AC: ERR_NAME_NOT_RESOLVED (-105) does NOT require go-back.
    func testRequiresGoBack_NameNotResolved_IsFalse() {
        let error = makeError(code: -105)
        XCTAssertFalse(error.requiresGoBack)
    }

    /// AC: ERR_ABORTED (-3) does NOT require go-back.
    func testRequiresGoBack_Aborted_IsFalse() {
        let error = makeError(code: -3)
        XCTAssertFalse(error.requiresGoBack)
    }

    /// AC: Unknown error does NOT require go-back.
    func testRequiresGoBack_UnknownError_IsFalse() {
        let error = makeError(code: -999)
        XCTAssertFalse(error.requiresGoBack)
    }

    // MARK: - isAborted

    /// AC: ERR_ABORTED (-3) is treated as user-stop, no error page shown.
    func testIsAborted_ErrAborted() {
        let error = makeError(code: -3)
        XCTAssertTrue(error.isAborted,
            "ERR_ABORTED (-3) should suppress error page display")
    }

    /// AC: ERR_NAME_NOT_RESOLVED (-105) is NOT aborted.
    func testIsAborted_NameNotResolved_IsFalse() {
        let error = makeError(code: -105)
        XCTAssertFalse(error.isAborted)
    }

    /// AC: ERR_TOO_MANY_REDIRECTS (-310) is NOT aborted.
    func testIsAborted_TooManyRedirects_IsFalse() {
        let error = makeError(code: -310)
        XCTAssertFalse(error.isAborted)
    }

    /// AC: ERR_ABORTED uses code -3, NOT -2 (which is ERR_FAILED).
    func testIsAborted_ErrFailedIsNotAborted() {
        let error = makeError(code: -2)
        XCTAssertFalse(error.isAborted,
            "ERR_FAILED (-2) should NOT be treated as aborted")
    }

    // MARK: - Identity

    /// Each NavigationError instance gets a unique UUID.
    func testIdentity_UniqueIds() {
        let e1 = makeError(code: -105)
        let e2 = makeError(code: -105)
        XCTAssertNotEqual(e1.id, e2.id,
            "Two NavigationError instances should have distinct UUIDs")
    }

    /// URL and navigationId are preserved.
    func testIdentity_PropertiesPreserved() {
        let error = makeError(code: -105, navigationId: 42,
                              url: "https://test.example.com/path")
        XCTAssertEqual(error.navigationId, 42)
        XCTAssertEqual(error.url, "https://test.example.com/path")
        XCTAssertEqual(error.errorCode, -105)
    }
}
