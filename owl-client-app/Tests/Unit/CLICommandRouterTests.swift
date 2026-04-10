import XCTest
@testable import OWLBrowserLib

@MainActor
final class CLICommandRouterTests: XCTestCase {
    private final class FakeBrowser: BrowserControl {
        var activeWebviewId: UInt64 = 99
        var pageInfoResult: [String: String] = [:]
        var navStatusResult: [String: String] = [:]
        var navEventsResult: [NavigationEventRecord] = []
        var consoleMessagesResult: [[String: String]] = []

        var lastPageInfoTab: Int?
        var navigatedURL: String?
        var goBackCalls = 0
        var goForwardCalls = 0
        var reloadCalls = 0
        var lastNavEventsLimit: Int?
        var lastConsoleLevel: String?
        var lastConsoleLimit: Int?

        func pageInfo(tab: Int?) -> [String: String] {
            lastPageInfoTab = tab
            return pageInfoResult
        }

        func cliNavigate(url: String) {
            navigatedURL = url
        }

        func cliGoBack() {
            goBackCalls += 1
        }

        func cliGoForward() {
            goForwardCalls += 1
        }

        func cliReload() {
            reloadCalls += 1
        }

        func navStatus() -> [String: String] {
            navStatusResult
        }

        func navEvents(limit: Int) -> [NavigationEventRecord] {
            lastNavEventsLimit = limit
            return navEventsResult
        }

        func consoleMessages(level: String?, limit: Int) -> [[String: String]] {
            lastConsoleLevel = level
            lastConsoleLimit = limit
            return consoleMessagesResult
        }
    }

    private actor FakeStorageService: StorageService {
        var cookieDomainsResult: [CookieDomainInfo] = []
        var cookieDomainsError: Error?
        var deleteCookiesResult: Int32 = 0
        var deleteCookiesError: Error?
        var clearDataResult = false
        var clearDataError: Error?
        var storageUsageResult: [StorageUsageInfo] = []
        var storageUsageError: Error?

        private(set) var deletedDomain: String?
        private(set) var clearDataCalls: [(types: StorageDataType, start: Double, end: Double)] = []

        func setCookieDomainsResult(_ value: [CookieDomainInfo]) {
            cookieDomainsResult = value
        }

        func setCookieDomainsError(_ value: Error?) {
            cookieDomainsError = value
        }

        func setDeleteCookiesResult(_ value: Int32) {
            deleteCookiesResult = value
        }

        func setClearDataResult(_ value: Bool) {
            clearDataResult = value
        }

        func setStorageUsageResult(_ value: [StorageUsageInfo]) {
            storageUsageResult = value
        }

        func getCookieDomains() async throws -> [CookieDomainInfo] {
            if let cookieDomainsError { throw cookieDomainsError }
            return cookieDomainsResult
        }

        func deleteCookies(domain: String) async throws -> Int32 {
            deletedDomain = domain
            if let deleteCookiesError { throw deleteCookiesError }
            return deleteCookiesResult
        }

        func clearData(types: StorageDataType, startTime: Double, endTime: Double) async throws -> Bool {
            clearDataCalls.append((types, startTime, endTime))
            if let clearDataError { throw clearDataError }
            return clearDataResult
        }

        func getStorageUsage() async throws -> [StorageUsageInfo] {
            if let storageUsageError { throw storageUsageError }
            return storageUsageResult
        }
    }

    private struct DummyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func makeRouter() -> (CLICommandRouter, FakeBrowser, FakeStorageService) {
        let browser = FakeBrowser()
        let storage = FakeStorageService()
        return (CLICommandRouter(browser: browser, storageService: storage), browser, storage)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from response: CLIResponse) throws -> T {
        let json = try XCTUnwrap(response.data?["result"])
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }

    func testPageInfo_forwardsTabArgument() async throws {
        let (router, browser, _) = makeRouter()
        browser.pageInfoResult = ["title": "Example", "url": "https://example.com"]

        let response = await router.handle(CLIRequest(cmd: "page.info", args: ["tab": "2"]))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(browser.lastPageInfoTab, 2)
        XCTAssertEqual(response.data?["title"], "Example")
        XCTAssertEqual(response.data?["url"], "https://example.com")
    }

    func testNavigate_requiresURL() async {
        let (router, browser, _) = makeRouter()

        let response = await router.handle(CLIRequest(cmd: "navigate"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "Missing 'url' argument")
        XCTAssertNil(browser.navigatedURL)
    }

    func testNavigate_callsBrowser() async {
        let (router, browser, _) = makeRouter()

        let response = await router.handle(CLIRequest(cmd: "navigate", args: ["url": "https://example.com"]))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(browser.navigatedURL, "https://example.com")
    }

    func testBackForwardReload_callBrowserActions() async {
        let (router, browser, _) = makeRouter()

        _ = await router.handle(CLIRequest(cmd: "back"))
        _ = await router.handle(CLIRequest(cmd: "forward"))
        _ = await router.handle(CLIRequest(cmd: "reload"))

        XCTAssertEqual(browser.goBackCalls, 1)
        XCTAssertEqual(browser.goForwardCalls, 1)
        XCTAssertEqual(browser.reloadCalls, 1)
    }

    func testCookieList_filtersDomainsCaseInsensitively() async throws {
        let (router, _, storage) = makeRouter()
        await storage.setCookieDomainsResult([
            CookieDomainInfo(domain: "example.com", count: 2),
            CookieDomainInfo(domain: "another.test", count: 5),
            CookieDomainInfo(domain: "EXAMPLE.org", count: 1),
        ])

        let response = await router.handle(CLIRequest(cmd: "cookie.list", args: ["domain": "example"]))
        let items = try decodeJSON([CookieDomainInfo].self, from: response)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(items.map(\.domain), ["example.com", "EXAMPLE.org"])
    }

    func testCookieList_bubblesStorageErrors() async {
        let (router, _, storage) = makeRouter()
        await storage.setCookieDomainsError(DummyError(message: "bridge down"))

        let response = await router.handle(CLIRequest(cmd: "cookie.list"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "cookie.list failed: bridge down")
    }

    func testCookieDelete_requiresDomain() async {
        let (router, _, _) = makeRouter()

        let response = await router.handle(CLIRequest(cmd: "cookie.delete"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "Missing 'domain' argument")
    }

    func testCookieDelete_returnsDeletedCountAndPassesDomain() async {
        let (router, _, storage) = makeRouter()
        await storage.setDeleteCookiesResult(7)

        let response = await router.handle(CLIRequest(cmd: "cookie.delete", args: ["domain": "example.com"]))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.data?["deleted"], "7")
        let deletedDomain = await storage.deletedDomain
        XCTAssertEqual(deletedDomain, "example.com")
    }

    func testClearData_rejectsInvalidMask() async {
        let (router, _, _) = makeRouter()

        let response = await router.handle(CLIRequest(cmd: "clear-data", args: ["types": "0"]))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "Invalid data types mask")
    }

    func testClearData_passesExplicitRangeAndTypes() async {
        let (router, _, storage) = makeRouter()
        await storage.setClearDataResult(true)

        let response = await router.handle(CLIRequest(
            cmd: "clear-data",
            args: ["types": "5", "start_time": "123", "end_time": "456"]
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.data?["cleared"], "true")
        let calls = await storage.clearDataCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].types.rawValue, 5)
        XCTAssertEqual(calls[0].start, 123)
        XCTAssertEqual(calls[0].end, 456)
    }

    func testStorageUsage_returnsEncodedJSON() async throws {
        let (router, _, storage) = makeRouter()
        await storage.setStorageUsageResult([
            StorageUsageInfo(origin: "https://example.com", usage_bytes: 1024),
            StorageUsageInfo(origin: "https://another.test", usage_bytes: 2048),
        ])

        let response = await router.handle(CLIRequest(cmd: "storage.usage"))
        let items = try decodeJSON([StorageUsageInfo].self, from: response)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].origin, "https://example.com")
        XCTAssertEqual(items[0].usage_bytes, 1024)
    }

    func testNavStatus_returnsJSONResult() async throws {
        let (router, browser, _) = makeRouter()
        browser.navStatusResult = ["loading": "true", "url": "https://example.com"]

        let response = await router.handle(CLIRequest(cmd: "nav.status"))
        let result = try decodeJSON([String: String].self, from: response)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(result["loading"], "true")
        XCTAssertEqual(result["url"], "https://example.com")
    }

    func testNavEvents_honorsLimitAndEncodesRecords() async throws {
        let (router, browser, _) = makeRouter()
        browser.navEventsResult = [
            NavigationEventRecord(navigationId: 1, eventType: "started", url: "https://a.com"),
            NavigationEventRecord(navigationId: 1, eventType: "committed", url: "https://a.com", httpStatus: 200),
        ]

        let response = await router.handle(CLIRequest(cmd: "nav.events", args: ["limit": "5"]))
        let items = try decodeJSON([NavigationEventRecord].self, from: response)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(browser.lastNavEventsLimit, 5)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1].eventType, "committed")
    }

    func testConsoleList_clampsLimitAndForwardsLevel() async throws {
        let (router, browser, _) = makeRouter()
        browser.consoleMessagesResult = [
            ["level": "error", "message": "boom"],
        ]

        let response = await router.handle(CLIRequest(
            cmd: "console.list",
            args: ["limit": "5000", "level": "error"]
        ))
        let data = try XCTUnwrap(response.data?["result"].flatMap { $0.data(using: .utf8) })
        let result = try JSONSerialization.jsonObject(with: data) as? [[String: String]]

        XCTAssertTrue(response.ok)
        XCTAssertEqual(browser.lastConsoleLevel, "error")
        XCTAssertEqual(browser.lastConsoleLimit, 1000)
        XCTAssertEqual(result?.first?["message"], "boom")
    }

    func testUnknownCommand_returnsFailure() async {
        let (router, _, _) = makeRouter()

        let response = await router.handle(CLIRequest(cmd: "not-a-real-command"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "Unknown command: not-a-real-command")
    }
}
