import Foundation
import SwiftUI

// MARK: - DownloadItemVM

/// Per-row ObservableObject for individual download item.
/// Separate from DownloadItem (model) to enable per-row SwiftUI updates.
package class DownloadItemVM: ObservableObject, Identifiable {
    package let id: UInt32
    @Published package var filename: String
    @Published package var state: DownloadState
    @Published package var progress: Double  // 0.0-1.0
    @Published package var receivedBytes: Int64
    @Published package var totalBytes: Int64
    @Published package var speed: String
    @Published package var errorDescription: String?
    @Published package var canResume: Bool
    package let url: String
    package let targetPath: String

    // Speed calculation: 3-second ring buffer of (timestamp, receivedBytes)
    private var speedSamples: [(time: CFAbsoluteTime, bytes: Int64)] = []

    init(from item: DownloadItem) {
        id = item.id
        filename = item.filename
        state = item.state
        receivedBytes = item.receivedBytes
        totalBytes = item.totalBytes
        progress = item.totalBytes > 0
            ? Double(item.receivedBytes) / Double(item.totalBytes) : 0
        speed = Self.formatSpeed(item.speedBytesPerSec)
        errorDescription = item.errorDescription
        canResume = item.canResume
        url = item.url
        targetPath = item.targetPath
    }

    func update(from item: DownloadItem) {
        state = item.state
        receivedBytes = item.receivedBytes
        totalBytes = item.totalBytes
        progress = item.totalBytes > 0
            ? Double(item.receivedBytes) / Double(item.totalBytes) : 0
        errorDescription = item.errorDescription
        canResume = item.canResume

        // Speed calculation using 3-second ring buffer
        let now = CFAbsoluteTimeGetCurrent()
        speedSamples.append((now, item.receivedBytes))
        speedSamples.removeAll { now - $0.time > 3.0 }

        if let first = speedSamples.first, now - first.time > 0.1 {
            let avgSpeed = Double(item.receivedBytes - first.bytes) / (now - first.time)
            speed = Self.formatSpeed(Int64(max(0, avgSpeed)))
        } else {
            speed = Self.formatSpeed(item.speedBytesPerSec)
        }
    }

    static func formatSpeed(_ bytesPerSec: Int64) -> String {
        if bytesPerSec < 1024 { return "\(bytesPerSec) B/s" }
        if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", Double(bytesPerSec) / 1024)
        }
        return String(format: "%.1f MB/s", Double(bytesPerSec) / (1024 * 1024))
    }

    /// Format byte count for display (e.g. "5.2 MB", "1.3 GB").
    /// Used by download panel to show received/total sizes.
    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 0 { return "0 B" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

// MARK: - DownloadViewModel

@MainActor
package class DownloadViewModel: ObservableObject {
    @Published package var items: [DownloadItemVM] = []
    @Published package var activeCount: Int = 0
    @Published package var isLoading: Bool = false

    // Throttle: per-item level to avoid multi-download concurrent updates cancelling each other
    private var pendingUpdates: [UInt32: Task<Void, Never>] = [:]
    private var lastUpdateTimes: [UInt32: CFAbsoluteTime] = [:]

    // MARK: - Load All

    /// Fetch all downloads from host. Uses upsert merge (not overwrite).
    package func loadAll() async {
        guard !isLoading else { return }
        isLoading = true

        #if canImport(OWLBridge)
        do {
            let downloads = try await OWLDownloadBridge.getAll()
            let fetchedIds = Set(downloads.map { $0.id })

            // Upsert: update existing items, add new ones
            for dl in downloads {
                if let idx = items.firstIndex(where: { $0.id == dl.id }) {
                    items[idx].update(from: dl)
                } else {
                    items.append(DownloadItemVM(from: dl))
                }
            }

            // Remove items no longer present on host side
            items.removeAll { !fetchedIds.contains($0.id) }
            updateActiveCount()
        } catch {
            NSLog("%@", "[OWL] DownloadViewModel.loadAll failed: \(error)")
            // Don't clear items — preserve existing data to avoid flicker
        }
        #endif

        isLoading = false
    }

    // MARK: - Push Callback Handlers

    /// Handle download created event. Dedup: if already exists, update instead of insert.
    func onDownloadCreated(_ item: DownloadItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].update(from: item)
        } else {
            let vm = DownloadItemVM(from: item)
            items.insert(vm, at: 0)  // Newest at top
        }
        updateActiveCount()
    }

    /// Handle download updated event. Upsert: if not found, insert (covers race with loadAll).
    func onDownloadUpdated(_ item: DownloadItem) {
        throttlePerItem(id: item.id) {
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx].update(from: item)
            } else {
                self.items.insert(DownloadItemVM(from: item), at: 0)
            }
            self.updateActiveCount()
        }
    }

    /// Handle download removed event. Cancels any pending throttled update for same id.
    func onDownloadRemoved(id: UInt32) {
        pendingUpdates[id]?.cancel()
        pendingUpdates.removeValue(forKey: id)
        lastUpdateTimes.removeValue(forKey: id)
        items.removeAll { $0.id == id }
        updateActiveCount()
    }

    // MARK: - Actions

    package func pause(id: UInt32) {
        OWLDownloadBridge.pause(id: id)
    }

    package func resume(id: UInt32) {
        OWLDownloadBridge.resume(id: id)
    }

    package func cancel(id: UInt32) {
        OWLDownloadBridge.cancel(id: id)
    }

    package func removeEntry(id: UInt32) {
        // Optimistic removal from UI
        pendingUpdates[id]?.cancel()
        pendingUpdates.removeValue(forKey: id)
        lastUpdateTimes.removeValue(forKey: id)
        items.removeAll { $0.id == id }
        updateActiveCount()
        OWLDownloadBridge.removeEntry(id: id)
    }

    package func openFile(id: UInt32) {
        OWLDownloadBridge.openFile(id: id)
    }

    package func showInFolder(id: UInt32) {
        OWLDownloadBridge.showInFolder(id: id)
    }

    package func clearCompleted() {
        let toRemove = items.filter { $0.state != .inProgress && $0.state != .paused }
        for item in toRemove {
            pendingUpdates[item.id]?.cancel()
            pendingUpdates.removeValue(forKey: item.id)
            lastUpdateTimes.removeValue(forKey: item.id)
            OWLDownloadBridge.removeEntry(id: item.id)
        }
        items.removeAll { $0.state != .inProgress && $0.state != .paused }
        updateActiveCount()
    }

    // MARK: - Private

    private func updateActiveCount() {
        activeCount = items.filter { $0.state == .inProgress }.count
    }

    /// Per-item throttle: 100ms minimum interval between updates for each download id.
    /// Ensures the last update is never lost (pending Task fires after delay).
    private func throttlePerItem(id: UInt32, _ action: @escaping () -> Void) {
        let now = CFAbsoluteTimeGetCurrent()
        let lastTime = lastUpdateTimes[id] ?? 0

        if now - lastTime >= 0.1 {
            // Enough time has passed — execute immediately
            lastUpdateTimes[id] = now
            pendingUpdates[id]?.cancel()
            pendingUpdates.removeValue(forKey: id)
            action()
        } else {
            // Too soon — schedule a deferred update
            pendingUpdates[id]?.cancel()
            pendingUpdates[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                self?.lastUpdateTimes[id] = CFAbsoluteTimeGetCurrent()
                action()
            }
        }
    }
}
