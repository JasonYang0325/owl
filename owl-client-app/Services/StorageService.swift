import Foundation
#if canImport(OWLBridge)
import OWLBridge
#endif

// MARK: - Domain Models

/// A cookie domain with its cookie count, returned from the Host process.
package struct CookieDomainInfo: Codable, Identifiable, Equatable, Sendable {
    package var id: String { domain }
    package let domain: String
    package let count: Int32
}

/// Storage usage per origin, returned from the Host process.
package struct StorageUsageInfo: Codable, Identifiable, Equatable, Sendable {
    package var id: String { origin }
    package let origin: String
    package let usage_bytes: Int64
}

/// Bitmask for browsing data types (matches C-ABI).
package struct StorageDataType: OptionSet, Sendable {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }

    package static let cookies        = StorageDataType(rawValue: 0x01)
    package static let cache          = StorageDataType(rawValue: 0x02)
    package static let localStorage   = StorageDataType(rawValue: 0x04)
    package static let sessionStorage = StorageDataType(rawValue: 0x08)
    package static let indexedDB      = StorageDataType(rawValue: 0x10)
    package static let all: StorageDataType = [.cookies, .cache, .localStorage, .sessionStorage, .indexedDB]
}

// MARK: - StorageService Protocol

/// Shared protocol used by both CLI Router and StorageViewModel.
/// Abstracts OWLBridge C-ABI calls so both layers use the same implementation.
package protocol StorageService: Sendable {
    func getCookieDomains() async throws -> [CookieDomainInfo]
    func deleteCookies(domain: String) async throws -> Int32
    func clearData(types: StorageDataType, startTime: Double, endTime: Double) async throws -> Bool
    func getStorageUsage() async throws -> [StorageUsageInfo]
}

// MARK: - Bridge Implementation

/// Production implementation backed by OWLBridge C-ABI functions.
/// Uses Box<CheckedContinuation> pattern consistent with HistoryService/BookmarkService.
/// Struct (not enum) so it can conform to StorageService protocol with instance methods.
package struct OWLStorageBridge: StorageService {

    package init() {}

    package func getCookieDomains() async throws -> [CookieDomainInfo] {
        try await Self.getCookieDomainsStatic()
    }
    package func deleteCookies(domain: String) async throws -> Int32 {
        try await Self.deleteCookiesStatic(domain: domain)
    }
    package func clearData(types: StorageDataType, startTime: Double, endTime: Double) async throws -> Bool {
        try await Self.clearDataStatic(types: types, startTime: startTime, endTime: endTime)
    }
    package func getStorageUsage() async throws -> [StorageUsageInfo] {
        try await Self.getStorageUsageStatic()
    }

    // MARK: - Get Cookie Domains

    /// Returns all cookie domains with counts.
    static func getCookieDomainsStatic() async throws -> [CookieDomainInfo] {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CookieDomainInfo], Error>) in
            final class Box {
                let value: CheckedContinuation<[CookieDomainInfo], Error>
                init(_ v: CheckedContinuation<[CookieDomainInfo], Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            OWLBridge_StorageGetCookieDomains({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLStorage", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                guard let jsonArray,
                      let data = String(cString: jsonArray).data(using: .utf8),
                      let items = try? JSONDecoder().decode([CookieDomainInfo].self, from: data) else {
                    box.value.resume(throwing: NSError(
                        domain: "OWLStorage", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode cookie domains JSON"]))
                    return
                }
                box.value.resume(returning: items)
            }, ctx)
        }
        #else
        return []
        #endif
    }

    // MARK: - Delete Cookies for Domain

    /// Delete all cookies for a specific domain. Returns deleted count.
    static func deleteCookiesStatic(domain: String) async throws -> Int32 {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            final class Box {
                let value: CheckedContinuation<Int32, Error>
                init(_ v: CheckedContinuation<Int32, Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            domain.withCString { domainPtr in
                OWLBridge_StorageDeleteDomain(domainPtr, { value, errorMsg, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    if let errorMsg {
                        box.value.resume(throwing: NSError(
                            domain: "OWLStorage", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                        return
                    }
                    box.value.resume(returning: value)
                }, ctx)
            }
        }
        #else
        return 0
        #endif
    }

    // MARK: - Clear Browsing Data

    /// Clear browsing data by type mask within a time range.
    static func clearDataStatic(types: StorageDataType, startTime: Double, endTime: Double) async throws -> Bool {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            final class Box {
                let value: CheckedContinuation<Bool, Error>
                init(_ v: CheckedContinuation<Bool, Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            OWLBridge_StorageClearData(types.rawValue, startTime, endTime, { success, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLStorage", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                box.value.resume(returning: success != 0)
            }, ctx)
        }
        #else
        return false
        #endif
    }

    // MARK: - Get Storage Usage

    /// Returns storage usage per origin.
    static func getStorageUsageStatic() async throws -> [StorageUsageInfo] {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[StorageUsageInfo], Error>) in
            final class Box {
                let value: CheckedContinuation<[StorageUsageInfo], Error>
                init(_ v: CheckedContinuation<[StorageUsageInfo], Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            OWLBridge_StorageGetUsage({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLStorage", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                guard let jsonArray,
                      let data = String(cString: jsonArray).data(using: .utf8),
                      let items = try? JSONDecoder().decode([StorageUsageInfo].self, from: data) else {
                    box.value.resume(throwing: NSError(
                        domain: "OWLStorage", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode storage usage JSON"]))
                    return
                }
                box.value.resume(returning: items)
            }, ctx)
        }
        #else
        return []
        #endif
    }
}
