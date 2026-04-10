import Foundation

/// Console message severity level (maps from Mojom ConsoleLevel).
package enum ConsoleLevel: Int, CaseIterable, Sendable {
    case verbose = 0
    case info = 1
    case warning = 2
    case error = 3
}

/// A single console message captured from the renderer.
package struct ConsoleMessageItem: Identifiable, Sendable {
    package let id = UUID()
    package let level: ConsoleLevel
    package let message: String
    package let source: String
    package let line: Int
    package let timestamp: Date
    package let isTruncated: Bool

    package init(level: ConsoleLevel, message: String, source: String,
                 line: Int, timestamp: Date, isTruncated: Bool = false) {
        self.level = level
        self.message = message
        self.source = source
        self.line = line
        self.timestamp = timestamp
        self.isTruncated = isTruncated
    }
}

/// Union type for console list items: either a message or a navigation separator.
package enum ConsoleItem: Identifiable {
    case message(ConsoleMessageItem)
    case separator(url: String, id: UUID = UUID())

    package var id: String {
        switch self {
        case .message(let item): return item.id.uuidString
        case .separator(_, let id): return "sep-\(id.uuidString)"
        }
    }
}
