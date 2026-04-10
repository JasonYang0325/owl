import XCTest
@testable import OWLBrowserLib

@MainActor
final class StorageViewModelTests: XCTestCase {
    private actor FakeStorageService: StorageService {
        var cookieDomainsResult: [CookieDomainInfo] = []
        var cookieDomainsError: Error?
        var deleteCookiesResult: Int32 = 0
        var deleteCookiesError: Error?
        var clearDataResult = false
        var clearDataError: Error?
        var storageUsageResult: [StorageUsageInfo] = []
        var storageUsageError: Error?

        private(set) var deletedDomains: [String] = []
        private(set) var clearDataCalls: [(types: StorageDataType, start: Double, end: Double)] = []

        func configureCookieDomains(_ value: [CookieDomainInfo]) {
            cookieDomainsResult = value
            cookieDomainsError = nil
        }

        func configureCookieDomainsError(_ value: Error) {
            cookieDomainsError = value
        }

        func configureDeleteCookiesResult(_ value: Int32) {
            deleteCookiesResult = value
            deleteCookiesError = nil
        }

        func configureDeleteCookiesError(_ value: Error) {
            deleteCookiesError = value
        }

        func configureStorageUsage(_ value: [StorageUsageInfo]) {
            storageUsageResult = value
            storageUsageError = nil
        }

        func configureStorageUsageError(_ value: Error) {
            storageUsageError = value
        }

        func configureClearDataResult(_ value: Bool) {
            clearDataResult = value
            clearDataError = nil
        }

        func configureClearDataError(_ value: Error) {
            clearDataError = value
        }

        func getCookieDomains() async throws -> [CookieDomainInfo] {
            if let cookieDomainsError { throw cookieDomainsError }
            return cookieDomainsResult
        }

        func deleteCookies(domain: String) async throws -> Int32 {
            deletedDomains.append(domain)
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

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    @discardableResult
    private func pumpUntil(
        timeout: TimeInterval,
        step: TimeInterval = 0.02,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate() { return true }
            pump(step)
        }
        return predicate()
    }

    func testInitialState_isEmptyAndIdle() {
        let vm = StorageViewModel(mockConfig: .init())

        XCTAssertTrue(vm.domains.isEmpty)
        XCTAssertTrue(vm.usageEntries.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.showClearAllConfirm)
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadDomains_mockMode_populatesDomains() async {
        let vm = StorageViewModel(mockConfig: .init(domains: [
            CookieDomainInfo(domain: "example.com", count: 2),
            CookieDomainInfo(domain: "test.dev", count: 5),
        ]))

        await vm.loadDomains()

        XCTAssertEqual(vm.domains.map(\.domain), ["example.com", "test.dev"])
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadUsage_mockMode_populatesUsageEntries() async {
        let vm = StorageViewModel(mockConfig: .init(usage: [
            StorageUsageInfo(origin: "https://example.com", usage_bytes: 1024),
            StorageUsageInfo(origin: "https://a.test", usage_bytes: 2048),
        ]))

        await vm.loadUsage()

        XCTAssertEqual(vm.usageEntries.map(\.origin), ["https://example.com", "https://a.test"])
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadDomains_success_setsDomainsAndClearsError() async {
        let service = FakeStorageService()
        await service.configureCookieDomains([
            CookieDomainInfo(domain: "example.com", count: 3),
        ])
        let vm = StorageViewModel(service: service)
        vm.errorMessage = "old error"

        await vm.loadDomains()

        XCTAssertEqual(vm.domains.count, 1)
        XCTAssertEqual(vm.domains.first?.domain, "example.com")
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadDomains_failure_setsErrorMessage() async {
        let service = FakeStorageService()
        await service.configureCookieDomainsError(DummyError(message: "cookie bridge failed"))
        let vm = StorageViewModel(service: service)

        await vm.loadDomains()

        XCTAssertEqual(vm.errorMessage, "cookie bridge failed")
        XCTAssertTrue(vm.domains.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadUsage_success_setsUsageAndClearsError() async {
        let service = FakeStorageService()
        await service.configureStorageUsage([
            StorageUsageInfo(origin: "https://example.com", usage_bytes: 4096),
        ])
        let vm = StorageViewModel(service: service)
        vm.errorMessage = "old error"

        await vm.loadUsage()

        XCTAssertEqual(vm.usageEntries.count, 1)
        XCTAssertEqual(vm.usageEntries.first?.usage_bytes, 4096)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadUsage_failure_setsErrorMessage() async {
        let service = FakeStorageService()
        await service.configureStorageUsageError(DummyError(message: "usage bridge failed"))
        let vm = StorageViewModel(service: service)

        await vm.loadUsage()

        XCTAssertEqual(vm.errorMessage, "usage bridge failed")
        XCTAssertTrue(vm.usageEntries.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    func testDeleteDomain_mockMode_removesMatchingDomainOnly() async {
        let vm = StorageViewModel(mockConfig: .init(domains: [
            CookieDomainInfo(domain: "example.com", count: 1),
            CookieDomainInfo(domain: "keep.test", count: 2),
        ]))
        await vm.loadDomains()

        await vm.deleteDomain("example.com")

        XCTAssertEqual(vm.domains.map(\.domain), ["keep.test"])
    }

    func testDeleteDomain_serviceMode_callsDeleteAndReloadsDomains() async {
        let service = FakeStorageService()
        await service.configureDeleteCookiesResult(2)
        await service.configureCookieDomains([
            CookieDomainInfo(domain: "keep.test", count: 4),
        ])
        let vm = StorageViewModel(service: service)
        vm.domains = [
            CookieDomainInfo(domain: "delete.me", count: 2),
            CookieDomainInfo(domain: "keep.test", count: 4),
        ]

        await vm.deleteDomain("delete.me")

        let deletedDomains = await service.deletedDomains
        XCTAssertEqual(deletedDomains, ["delete.me"])
        XCTAssertEqual(vm.domains.map(\.domain), ["keep.test"])
        XCTAssertNil(vm.errorMessage)
    }

    func testDeleteDomain_failure_setsErrorAndKeepsCurrentDomains() async {
        let service = FakeStorageService()
        await service.configureDeleteCookiesError(DummyError(message: "delete failed"))
        let vm = StorageViewModel(service: service)
        vm.domains = [CookieDomainInfo(domain: "keep.test", count: 4)]

        await vm.deleteDomain("keep.test")

        XCTAssertEqual(vm.errorMessage, "delete failed")
        XCTAssertEqual(vm.domains.map(\.domain), ["keep.test"])
    }

    func testConfirmClearAll_mockMode_clearsDomainsAndUsage() async {
        let vm = StorageViewModel(mockConfig: .init(
            domains: [CookieDomainInfo(domain: "example.com", count: 2)],
            usage: [StorageUsageInfo(origin: "https://example.com", usage_bytes: 1024)]
        ))
        vm.domains = [CookieDomainInfo(domain: "example.com", count: 2)]
        vm.usageEntries = [StorageUsageInfo(origin: "https://example.com", usage_bytes: 1024)]

        await vm.clearAll()

        XCTAssertTrue(vm.domains.isEmpty)
        XCTAssertTrue(vm.usageEntries.isEmpty)
    }

    func testConfirmClearAll_serviceMode_clearsAndReloadsLists() async {
        let service = FakeStorageService()
        await service.configureClearDataResult(true)
        await service.configureCookieDomains([])
        await service.configureStorageUsage([])
        let vm = StorageViewModel(service: service)
        vm.domains = [CookieDomainInfo(domain: "example.com", count: 1)]
        vm.usageEntries = [StorageUsageInfo(origin: "https://example.com", usage_bytes: 2048)]

        await vm.clearAll()

        let calls = await service.clearDataCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].types, .all)
        XCTAssertEqual(calls[0].start, 0)
        XCTAssertGreaterThan(calls[0].end, 0)
        XCTAssertTrue(vm.domains.isEmpty)
        XCTAssertTrue(vm.usageEntries.isEmpty)
    }

    func testConfirmClearAll_serviceFailure_setsError() async {
        let service = FakeStorageService()
        await service.configureClearDataError(DummyError(message: "clear failed"))
        let vm = StorageViewModel(service: service)

        await vm.clearAll()

        XCTAssertEqual(vm.errorMessage, "clear failed")
    }

    func testFormatBytes_formatsBoundaryValues() {
        XCTAssertEqual(StorageViewModel.formatBytes(512), "512 B")
        XCTAssertEqual(StorageViewModel.formatBytes(1024), "1.0 KB")
        XCTAssertEqual(StorageViewModel.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(StorageViewModel.formatBytes(1024 * 1024), "1.0 MB")
        XCTAssertEqual(StorageViewModel.formatBytes(1024 * 1024 * 1024), "1.00 GB")
    }
}
