import Foundation
import SwiftUI
import Combine

#if canImport(OWLBridge)
import OWLBridge
private let useMockMode = false
#else
private let useMockMode = true
#endif

/// Date group key for history entries.
package enum HistoryDateGroup: String, CaseIterable {
    case today = "今天"
    case yesterday = "昨天"
    case thisWeek = "本周"
    case earlier = "更早"
}

@MainActor
package class HistoryViewModel: ObservableObject {
    @Published package var entries: [HistoryEntry] = []
    @Published package var groupedEntries: [(String, [HistoryEntry])] = []
    @Published package var searchQuery: String = ""
    @Published package var isLoading: Bool = false
    @Published package var isSearching: Bool = false
    @Published package var hasMore: Bool = true

    // Undo support
    @Published package var undoEntry: HistoryEntry? = nil
    @Published package var showUndoToast: Bool = false

    private let pageSize: Int32 = 50
    private var currentOffset: Int32 = 0
    private var totalCount: Int32 = 0
    private var searchDebounceTask: Task<Void, Never>?
    private var undoDismissTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var searchOffset: Int32 = 0

    /// Whether the history sidebar is currently visible.
    /// Push-based refresh only triggers when visible (avoid background work).
    package var isVisible: Bool = false

    // Navigate callback (set by parent)
    package var onNavigate: ((String) -> Void)?

    // MARK: - MockConfig

    package struct MockConfig {
        package var entries: [HistoryEntry]
        package var totalCount: Int32
        package init(entries: [HistoryEntry] = [], totalCount: Int32 = 0) {
            self.entries = entries
            self.totalCount = totalCount
        }
    }

    private var mockConfig: MockConfig?
    private var isMockMode: Bool { mockConfig != nil || useMockMode }

    package init() {}

    package convenience init(mockConfig: MockConfig) {
        self.init()
        self.mockConfig = mockConfig
    }

    // MARK: - Public API

    /// Load initial history (first page).
    package func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        entries = []
        currentOffset = 0
        hasMore = true

        if isMockMode {
            let mockEntries = mockConfig?.entries ?? []
            entries = mockEntries
            // Filter out entry pending deletion (undo window still active)
            if let pendingUrl = undoEntry?.url {
                entries.removeAll { $0.url == pendingUrl }
            }
            totalCount = mockConfig?.totalCount ?? Int32(mockEntries.count)
            hasMore = entries.count < Int(totalCount)
            groupedEntries = groupByDate(entries)
            isLoading = false
            return
        }

        do {
            let (items, total) = try await OWLHistoryBridge.queryByTime(
                query: "", maxResults: pageSize, offset: 0)
            entries = items
            // Filter out entry pending deletion (undo window still active)
            if let pendingUrl = undoEntry?.url {
                entries.removeAll { $0.url == pendingUrl }
            }
            totalCount = total
            currentOffset = Int32(items.count)
            hasMore = currentOffset < total
            groupedEntries = groupByDate(entries)
        } catch {
            NSLog("%@", "[OWL] HistoryViewModel.loadInitial failed: \(error)")
        }
        isLoading = false
    }

    /// Load more entries (pagination).
    package func loadMore() async {
        guard !isLoading, hasMore else { return }
        if !searchQuery.isEmpty {
            await searchMore()
            return
        }
        isLoading = true

        if isMockMode {
            isLoading = false
            hasMore = false
            return
        }

        do {
            let (items, total) = try await OWLHistoryBridge.queryByTime(
                query: "", maxResults: pageSize, offset: currentOffset)
            entries.append(contentsOf: items)
            totalCount = total
            currentOffset += Int32(items.count)
            hasMore = currentOffset < total
            groupedEntries = groupByDate(entries)
        } catch {
            NSLog("%@", "[OWL] HistoryViewModel.loadMore failed: \(error)")
        }
        isLoading = false
    }

    /// Search with 300ms debounce.
    package func search() {
        searchDebounceTask?.cancel()

        if searchQuery.isEmpty {
            clearSearch()
            return
        }

        isSearching = true
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    /// Clear search and restore date-grouped view.
    package func clearSearch() {
        searchDebounceTask?.cancel()
        searchQuery = ""
        isSearching = false
        searchOffset = 0
        hasMore = currentOffset < totalCount
        groupedEntries = groupByDate(entries)
    }

    /// Called by HistoryBridge when C-ABI pushes a history change notification.
    /// Debounces 100ms to coalesce rapid-fire events, then reloads if visible.
    func onHistoryChanged(url: String) {
        guard isVisible else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await loadInitial()
        }
    }

    /// Navigate to a URL.
    package func navigate(url: String) {
        onNavigate?(url)
    }

    /// Delete a single entry (with undo support).
    package func deleteEntry(_ entry: HistoryEntry) async {
        // Dismiss any existing undo toast
        commitPendingUndo()

        // Optimistic removal
        let removedEntry = entry
        withAnimation(.easeInOut(duration: 0.25)) {
            entries.removeAll { $0.url == entry.url }
            groupedEntries = groupByDate(entries)
        }

        // Show undo toast
        undoEntry = removedEntry
        showUndoToast = true
        scheduleUndoDismiss()

        // Perform actual deletion (non-blocking, will commit when toast expires)
    }

    /// Undo the last delete.
    package func undoDelete() {
        guard let entry = undoEntry else { return }
        undoDismissTask?.cancel()

        // Re-insert entry at correct position (sorted by last_visit_time DESC)
        let insertIndex = entries.firstIndex { $0.last_visit_time < entry.last_visit_time } ?? entries.endIndex
        withAnimation(.easeInOut(duration: 0.25)) {
            entries.insert(entry, at: insertIndex)
            groupedEntries = groupByDate(entries)
        }

        undoEntry = nil
        showUndoToast = false
    }

    /// Clear history for a time range.
    package func clearRange(_ range: ClearRange) async {
        if isMockMode {
            entries = []
            groupedEntries = []
            return
        }

        let now = Date()
        let calendar = Calendar.current

        switch range {
        case .today:
            let startOfDay = calendar.startOfDay(for: now)
            _ = try? await OWLHistoryBridge.deleteRange(
                startTime: startOfDay.timeIntervalSince1970,
                endTime: now.timeIntervalSince1970 + 1)
        case .lastSevenDays:
            let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
            _ = try? await OWLHistoryBridge.deleteRange(
                startTime: sevenDaysAgo.timeIntervalSince1970,
                endTime: now.timeIntervalSince1970 + 1)
        case .all:
            _ = try? await OWLHistoryBridge.clear()
        }

        await loadInitial()
    }

    package enum ClearRange {
        case today
        case lastSevenDays
        case all
    }

    // MARK: - Private

    private func performSearch() async {
        guard !searchQuery.isEmpty else { return }

        if isMockMode {
            let query = searchQuery.lowercased()
            let filtered = (mockConfig?.entries ?? []).filter {
                $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query)
            }
            groupedEntries = filtered.isEmpty ? [] : [("搜索结果", filtered)]
            searchOffset = Int32(filtered.count)
            hasMore = false  // Mock mode: no pagination
            isSearching = false
            return
        }

        do {
            let (items, total) = try await OWLHistoryBridge.queryByTime(
                query: searchQuery, maxResults: pageSize, offset: 0)
            groupedEntries = items.isEmpty ? [] : [("搜索结果", items)]
            searchOffset = Int32(items.count)
            hasMore = searchOffset < total
        } catch {
            NSLog("%@", "[OWL] HistoryViewModel.search failed: \(error)")
        }
        isSearching = false
    }

    /// Load more search results (pagination during search).
    private func searchMore() async {
        guard !searchQuery.isEmpty, !isLoading, hasMore else { return }
        isLoading = true

        if isMockMode {
            isLoading = false
            hasMore = false
            return
        }

        do {
            let (items, total) = try await OWLHistoryBridge.queryByTime(
                query: searchQuery, maxResults: pageSize, offset: searchOffset)
            // Append to existing search results
            if var existing = groupedEntries.first(where: { $0.0 == "搜索结果" }) {
                existing.1.append(contentsOf: items)
                groupedEntries = [existing]
            } else {
                groupedEntries = items.isEmpty ? [] : [("搜索结果", items)]
            }
            searchOffset += Int32(items.count)
            hasMore = searchOffset < total
        } catch {
            NSLog("%@", "[OWL] HistoryViewModel.searchMore failed: \(error)")
        }
        isLoading = false
    }

    private func scheduleUndoDismiss() {
        undoDismissTask?.cancel()
        undoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.commitPendingUndo()
        }
    }

    private func commitPendingUndo() {
        undoDismissTask?.cancel()
        guard let entry = undoEntry else { return }
        undoEntry = nil
        withAnimation(.easeOut(duration: 0.2)) {
            showUndoToast = false
        }
        // Ensure entry is removed from UI (may have been re-fetched by loadInitial)
        if entries.contains(where: { $0.url == entry.url }) {
            entries.removeAll { $0.url == entry.url }
            groupedEntries = groupByDate(entries)
        }
        // Always delete from backend — user explicitly requested this deletion
        Task {
            if !isMockMode {
                _ = try? await OWLHistoryBridge.delete(url: entry.url)
            }
        }
    }

    /// Group entries by date (today / yesterday / this week / earlier).
    package func groupByDate(_ items: [HistoryEntry]) -> [(String, [HistoryEntry])] {
        guard !items.isEmpty else { return [] }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

        var groups: [HistoryDateGroup: [HistoryEntry]] = [:]

        for entry in items {
            let date = entry.lastVisitDate
            let group: HistoryDateGroup
            if date >= startOfToday {
                group = .today
            } else if date >= startOfYesterday {
                group = .yesterday
            } else if date >= startOfWeek {
                group = .thisWeek
            } else {
                group = .earlier
            }
            groups[group, default: []].append(entry)
        }

        // Maintain order: today, yesterday, thisWeek, earlier
        var result: [(String, [HistoryEntry])] = []
        for dateGroup in HistoryDateGroup.allCases {
            if let entries = groups[dateGroup], !entries.isEmpty {
                result.append((dateGroup.rawValue, entries))
            }
        }
        return result
    }

    /// Relative time string for display.
    package static func relativeTime(from date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "刚刚"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)分钟前"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)小时前"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)天前"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日"
            return formatter.string(from: date)
        }
    }
}
