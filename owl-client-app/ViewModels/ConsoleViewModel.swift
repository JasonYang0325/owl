import Foundation
import SwiftUI

/// ViewModel for the Console panel. Manages a ring buffer of console messages
/// with level filtering, text search, and throttled UI refresh.
@MainActor
package class ConsoleViewModel: ObservableObject {
    // MARK: - Published State

    @Published package var displayItems: [ConsoleItem] = []
    @Published package var filteredItems: [ConsoleItem] = []
    @Published package var filter: ConsoleLevel? = nil
    @Published package var searchText: String = ""
    @Published package var preserveLog: Bool = false
    @Published package var counts: [ConsoleLevel: Int] = [
        .verbose: 0, .info: 0, .warning: 0, .error: 0
    ]
    @Published package var isAtBottom: Bool = true

    // MARK: - Ring Buffer

    private var buffer: [ConsoleItem] = []
    private let capacity = 1000
    private var needsRefresh = false
    private var refreshTask: Task<Void, Never>?

    // MARK: - Timestamp Formatter

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt
    }()

    package static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    // MARK: - Lifecycle

    package init() {
        startRefreshLoop()
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public API

    /// Add a console message from the bridge callback.
    package func addMessage(level: ConsoleLevel, message: String, source: String,
                            line: Int, timestamp: Date) {
        let isTruncated = message.count >= 10000
        let item = ConsoleMessageItem(
            level: level, message: message, source: source,
            line: line, timestamp: timestamp, isTruncated: isTruncated
        )
        appendToBuffer(.message(item))
        counts[level, default: 0] += 1
        needsRefresh = true
    }

    /// Called on navigation events.
    /// If preserveLog is off, clears the buffer.
    /// If on, inserts a navigation separator.
    package func onNavigation(url: String) {
        if preserveLog {
            appendToBuffer(.separator(url: url))
            needsRefresh = true
        } else {
            clear()
        }
    }

    /// Clear all messages and counts.
    package func clear() {
        buffer.removeAll()
        counts = [.verbose: 0, .info: 0, .warning: 0, .error: 0]
        displayItems = []
        filteredItems = []
        needsRefresh = false
    }

    /// Copy a single message to pasteboard in a readable format.
    package func copyMessage(_ item: ConsoleMessageItem) {
        let levelStr: String
        switch item.level {
        case .verbose: levelStr = "[verbose]"
        case .info: levelStr = "[info]"
        case .warning: levelStr = "[warning]"
        case .error: levelStr = "[error]"
        }
        let ts = Self.formatTimestamp(item.timestamp)
        var text = "\(levelStr) \(ts) \(item.message)"
        if !item.source.isEmpty {
            text += "\n\(item.source):\(item.line)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy all visible (filtered) messages to pasteboard.
    package func copyAll() {
        let text = filteredItems.compactMap { item -> String? in
            switch item {
            case .message(let msg):
                let levelStr: String
                switch msg.level {
                case .verbose: levelStr = "[verbose]"
                case .info: levelStr = "[info]"
                case .warning: levelStr = "[warning]"
                case .error: levelStr = "[error]"
                }
                let ts = Self.formatTimestamp(msg.timestamp)
                var line = "\(levelStr) \(ts) \(msg.message)"
                if !msg.source.isEmpty {
                    line += "  \(msg.source):\(msg.line)"
                }
                return line
            case .separator(let url, _):
                return "--- Navigated to \(url) ---"
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Number of new messages since user scrolled away from bottom.
    package var newMessageCount: Int {
        guard !isAtBottom else { return 0 }
        // Approximate: count messages added since last refresh that user hasn't seen
        return max(0, filteredItems.count - displayItems.count)
    }

    // MARK: - Private

    private func appendToBuffer(_ item: ConsoleItem) {
        buffer.append(item)
        if buffer.count > capacity {
            // Remove oldest, adjusting counts if it was a message
            let removed = buffer.removeFirst()
            if case .message(let msg) = removed {
                counts[msg.level, default: 0] = max(0, counts[msg.level, default: 0] - 1)
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.needsRefresh {
                    self.displayItems = self.buffer
                    self.filteredItems = self.displayItems.filter { item in
                        self.matchesFilter(item) && self.matchesSearch(item)
                    }
                    self.needsRefresh = false
                }
            }
        }
    }

    private func matchesFilter(_ item: ConsoleItem) -> Bool {
        guard let filter else { return true }
        switch item {
        case .message(let msg):
            return msg.level == filter
        case .separator:
            return true  // separators always visible
        }
    }

    private func matchesSearch(_ item: ConsoleItem) -> Bool {
        guard !searchText.isEmpty else { return true }
        switch item {
        case .message(let msg):
            return msg.message.localizedCaseInsensitiveContains(searchText)
                || msg.source.localizedCaseInsensitiveContains(searchText)
        case .separator(let url, _):
            return url.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Re-filter when filter or searchText changes (called from view onChange).
    package func refilter() {
        filteredItems = displayItems.filter { item in
            matchesFilter(item) && matchesSearch(item)
        }
    }
}
