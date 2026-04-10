import Foundation

/// A single navigation event record stored in the ring buffer.
package struct NavigationEventRecord: Codable {
    package let navigationId: Int64
    package let eventType: String  // "started", "committed", "failed", "redirected"
    package let url: String
    package let timestamp: String  // ISO 8601
    package let httpStatus: Int32?
    package let errorCode: Int32?

    package init(
        navigationId: Int64,
        eventType: String,
        url: String,
        timestamp: Date = Date(),
        httpStatus: Int32? = nil,
        errorCode: Int32? = nil
    ) {
        self.navigationId = navigationId
        self.eventType = eventType
        self.url = url
        self.timestamp = Self.formatter.string(from: timestamp)
        self.httpStatus = httpStatus
        self.errorCode = errorCode
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private enum CodingKeys: String, CodingKey {
        case navigationId = "navigation_id"
        case eventType = "event_type"
        case url
        case timestamp
        case httpStatus = "http_status"
        case errorCode = "error_code"
    }
}

/// Fixed-capacity FIFO ring buffer for navigation events.
/// Capacity: 100. When full, oldest events are overwritten.
/// All access must be on @MainActor.
@MainActor
package final class NavigationEventRing {
    package static let capacity = 100

    private var buffer: [NavigationEventRecord?]
    private var head: Int = 0   // next write position
    private var count: Int = 0

    package init() {
        self.buffer = Array(repeating: nil, count: Self.capacity)
    }

    /// Append an event. If buffer is full, overwrites the oldest entry.
    package func append(_ event: NavigationEventRecord) {
        buffer[head] = event
        head = (head + 1) % Self.capacity
        if count < Self.capacity {
            count += 1
        }
    }

    /// Return the most recent `limit` events, ordered oldest-first.
    /// `limit` is clamped to [1, 100].
    package func recent(limit: Int) -> [NavigationEventRecord] {
        let clamped = min(max(limit, 1), Self.capacity)
        let n = min(clamped, count)
        guard n > 0 else { return [] }

        var result: [NavigationEventRecord] = []
        result.reserveCapacity(n)
        // Start from (head - n) mod capacity → oldest of the requested slice.
        let start = (head - n + Self.capacity) % Self.capacity
        for i in 0..<n {
            let idx = (start + i) % Self.capacity
            if let event = buffer[idx] {
                result.append(event)
            }
        }
        return result
    }

    /// Total number of events currently stored (max 100).
    package var storedCount: Int { count }
}
