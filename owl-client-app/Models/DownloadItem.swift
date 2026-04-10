import Foundation

/// Download state matching the C++ DownloadItem::State enum in host.
package enum DownloadState: Int, Codable {
    case inProgress = 0
    case paused = 1
    case complete = 2
    case cancelled = 3
    case interrupted = 4
}

/// A single download entry deserialized from the Host process JSON.
package struct DownloadItem: Codable, Identifiable {
    package var id: UInt32
    package let url: String
    package let filename: String
    package let mimeType: String
    package var totalBytes: Int64
    package var receivedBytes: Int64
    package var speedBytesPerSec: Int64
    package var state: DownloadState
    package var errorDescription: String?
    package var canResume: Bool
    package let targetPath: String

    // JSON key mapping (C-ABI uses snake_case)
    enum CodingKeys: String, CodingKey {
        case id, url, filename
        case mimeType = "mime_type"
        case totalBytes = "total_bytes"
        case receivedBytes = "received_bytes"
        case speedBytesPerSec = "speed_bytes_per_sec"
        case state
        case errorDescription = "error_description"
        case canResume = "can_resume"
        case targetPath = "target_path"
    }
}
