import Foundation

/// Parse a time string into a Unix timestamp (seconds since epoch).
/// Supports:
///   - Relative: "30m" (minutes), "1h" (hours), "7d" (days)
///   - ISO 8601: "2024-01-15T10:30:00Z"
///   - Unix timestamp: "1705312200" or "1705312200.5" (0 = epoch is valid)
/// Returns nil if the input cannot be parsed.
package func parseTime(_ input: String) -> Double? {
    // Relative time: "30m", "1h", "7d"
    if let last = input.last, "mhd".contains(last),
       let value = Double(input.dropLast()), value >= 0 {
        let multiplier: Double
        switch last {
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default: return nil
        }
        return Date().timeIntervalSince1970 - value * multiplier
    }

    // ISO 8601
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: input) {
        return date.timeIntervalSince1970
    }

    // Also try ISO 8601 with fractional seconds
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: input) {
        return date.timeIntervalSince1970
    }

    // Unix timestamp (integer or floating point, 0 = epoch is valid)
    if let ts = Double(input), ts >= 0 {
        return ts
    }

    return nil
}
