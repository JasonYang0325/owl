import Foundation

// MARK: - Session Data Models

/// Persisted representation of a single tab.
package struct SessionTab: Codable, Equatable {
    package let url: String
    package let title: String
    package let isPinned: Bool
    package let isActive: Bool

    package init(url: String, title: String, isPinned: Bool, isActive: Bool) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.isActive = isActive
    }
}

/// Top-level session data written to session.json.
package struct SessionData: Codable, Equatable {
    package let version: Int
    package let tabs: [SessionTab]
    package let savedAt: Date

    package init(version: Int = 1, tabs: [SessionTab], savedAt: Date = Date()) {
        self.version = version
        self.tabs = tabs
        self.savedAt = savedAt
    }
}

// MARK: - SessionRestoreService

/// Handles saving and restoring browser session state to/from disk.
///
/// Pure data service: `save()` writes `SessionData` to `session.json`,
/// `load()` reads it back. `BrowserViewModel` is responsible for creating
/// `TabViewModel` instances from the returned `[SessionTab]`.
///
/// Auto-save is debounced: `scheduleSave()` coalesces rapid changes into
/// a single write after a short delay.
@MainActor
package final class SessionRestoreService {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var autoSaveTask: Task<Void, Never>?
    private let autoSaveDelay: TimeInterval

    /// Callback to capture current tab state from BrowserViewModel.
    /// Set by BrowserViewModel during initialization.
    package var tabStateProvider: (() -> [SessionTab])?

    package init(directory: URL? = nil, autoSaveDelay: TimeInterval = 2.0) {
        let dir = directory ?? Self.defaultDirectory()
        // Ensure directory exists with 0700 permissions.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        self.fileURL = dir.appendingPathComponent("session.json")
        self.autoSaveDelay = autoSaveDelay

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Save

    /// Synchronously saves the given session data to disk.
    /// Uses Foundation's `.atomic` option (temp file + rename) for crash safety.
    package func save(_ data: SessionData) {
        do {
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: fileURL, options: .atomic)
            // Ensure owner-only permissions after atomic write (temp+rename inherits umask).
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            NSLog("%@", "[OWL] Session saved: \(data.tabs.count) tabs")
        } catch {
            NSLog("%@", "[OWL] Session save failed: \(error.localizedDescription)")
        }
    }

    /// Convenience: saves current state from the tabStateProvider callback.
    package func saveCurrentState() {
        guard let provider = tabStateProvider else { return }
        let tabs = provider()
        guard !tabs.isEmpty else { return }
        let sessionData = SessionData(tabs: tabs)
        save(sessionData)
    }

    // MARK: - Load

    /// Loads session data from disk. Returns nil if file doesn't exist or is corrupt.
    /// Corrupt files are logged and removed to prevent repeated failures.
    package func load() -> SessionData? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSLog("%@", "[OWL] No session file found")
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let session = try decoder.decode(SessionData.self, from: data)
            // Validate version.
            guard session.version == 1 else {
                NSLog("%@", "[OWL] Session file has unsupported version \(session.version), ignoring")
                return nil
            }
            NSLog("%@", "[OWL] Session loaded: \(session.tabs.count) tabs")
            return session
        } catch {
            NSLog("%@", "[OWL] Session file corrupt, removing: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    /// Returns true if a session file exists on disk.
    package func hasSession() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Auto-Save (Debounced)

    /// Schedule a debounced save. Multiple calls within `autoSaveDelay` are coalesced.
    package func scheduleSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(Int(self.autoSaveDelay * 1000)))
            guard !Task.isCancelled else { return }
            self.saveCurrentState()
        }
    }

    /// Cancel any pending auto-save.
    package func cancelPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    // MARK: - Delete

    /// Remove the session file (e.g., on explicit "clear session" or for testing).
    package func deleteSession() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Default Directory

    private static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("OWLBrowser")
    }
}
