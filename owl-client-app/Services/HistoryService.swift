import Foundation
#if canImport(OWLBridge)
import OWLBridge
#endif

/// A single history entry returned from the Host process.
package struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    /// SQLite AUTOINCREMENT id from the visits table (unique per visit row).
    /// BH-025: Same URL visited at different times gets different visit_id values.
    /// Default 0 preserves backward compatibility with existing call sites that
    /// don't supply visit_id (e.g. mock/test code); in that case, falls back to url.
    package var visit_id: Int64 = 0
    package var id: String { visit_id != 0 ? String(visit_id) : url }
    package let url: String
    package let title: String
    package let visit_time: Double      // seconds since epoch
    package let last_visit_time: Double  // seconds since epoch
    package let visit_count: Int32

    /// Memberwise init (explicit because custom init(from:) suppresses the synthesized one).
    package init(
        url: String,
        title: String,
        visit_time: Double,
        last_visit_time: Double,
        visit_count: Int32,
        visit_id: Int64 = 0
    ) {
        self.url = url
        self.title = title
        self.visit_time = visit_time
        self.last_visit_time = last_visit_time
        self.visit_count = visit_count
        self.visit_id = visit_id
    }

    // Custom Decodable: visit_id is optional in JSON for backward compatibility.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // visit_id comes as String from C-ABI (base::NumberToString), Int64 from mock.
        if let intVal = try? container.decode(Int64.self, forKey: .visit_id) {
            visit_id = intVal
        } else if let strVal = try? container.decode(String.self, forKey: .visit_id),
                  let parsed = Int64(strVal) {
            visit_id = parsed
        } else {
            visit_id = 0
        }
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        visit_time = try container.decode(Double.self, forKey: .visit_time)
        last_visit_time = try container.decode(Double.self, forKey: .last_visit_time)
        visit_count = try container.decode(Int32.self, forKey: .visit_count)
    }

    /// Convenience: last_visit_time as Date.
    package var lastVisitDate: Date {
        Date(timeIntervalSince1970: last_visit_time)
    }

    /// Display URL: host or full URL if host unavailable.
    package var displayURL: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Swift async/await wrapper around OWLBridge history C-ABI functions.
/// Uses Box<CheckedContinuation> pattern for C callback bridging.
enum OWLHistoryBridge {

    // MARK: - Query by Time

    /// Query history by time (most recent first).
    /// Returns (entries, total) for pagination.
    static func queryByTime(query: String, maxResults: Int32, offset: Int32) async throws -> ([HistoryEntry], Int32) {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<([HistoryEntry], Int32), Error>) in
            final class Box {
                let value: CheckedContinuation<([HistoryEntry], Int32), Error>
                init(_ value: CheckedContinuation<([HistoryEntry], Int32), Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            query.withCString { queryPtr in
                OWLBridge_HistoryQueryByTime(queryPtr, maxResults, offset, { jsonArray, total, errorMsg, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    if let errorMsg {
                        box.value.resume(throwing: NSError(
                            domain: "OWLHistory", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                        return
                    }
                    guard let jsonArray,
                          let data = String(cString: jsonArray).data(using: .utf8),
                          let items = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
                        box.value.resume(throwing: NSError(
                            domain: "OWLHistory", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to decode history JSON"]))
                        return
                    }
                    box.value.resume(returning: (items, total))
                }, ctx)
            }
        }
        #else
        return ([], 0)
        #endif
    }

    // MARK: - Delete

    /// Delete a single URL from history.
    static func delete(url: String) async throws -> Bool {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            final class Box {
                let value: CheckedContinuation<Bool, Error>
                init(_ value: CheckedContinuation<Bool, Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            url.withCString { urlPtr in
                OWLBridge_HistoryDelete(urlPtr, { success, errorMsg, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    if let errorMsg {
                        box.value.resume(throwing: NSError(
                            domain: "OWLHistory", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                        return
                    }
                    box.value.resume(returning: success != 0)
                }, ctx)
            }
        }
        #else
        return false
        #endif
    }

    // MARK: - Delete Range

    /// Delete all visits in [startTime, endTime).
    static func deleteRange(startTime: Double, endTime: Double) async throws -> Int32 {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            final class Box {
                let value: CheckedContinuation<Int32, Error>
                init(_ value: CheckedContinuation<Int32, Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            OWLBridge_HistoryDeleteRange(startTime, endTime, { result, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLHistory", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                box.value.resume(returning: result)
            }, ctx)
        }
        #else
        return 0
        #endif
    }

    // MARK: - Clear All

    /// Delete all history.
    static func clear() async throws -> Bool {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            final class Box {
                let value: CheckedContinuation<Bool, Error>
                init(_ value: CheckedContinuation<Bool, Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            OWLBridge_HistoryClear({ success, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLHistory", code: -1,
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
}
