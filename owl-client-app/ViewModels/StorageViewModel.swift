import Foundation

#if canImport(OWLBridge)
import OWLBridge
private let useMockMode = false
#else
private let useMockMode = true
#endif

/// ViewModel for the Settings > Storage panel.
/// Uses StorageService protocol so CLI router and UI share the same bridge code.
@MainActor
package class StorageViewModel: ObservableObject {

    // MARK: - Published State

    @Published package var domains: [CookieDomainInfo] = []
    @Published package var usageEntries: [StorageUsageInfo] = []
    @Published package var isLoading = false
    @Published package var showClearAllConfirm = false
    @Published package var errorMessage: String?

    // MARK: - Dependencies

    private let service: StorageService
    private var isMockMode: Bool { mockConfig != nil || useMockMode }

    // MARK: - MockConfig

    package struct MockConfig {
        package var domains: [CookieDomainInfo]
        package var usage: [StorageUsageInfo]
        package init(
            domains: [CookieDomainInfo] = [],
            usage: [StorageUsageInfo] = []
        ) {
            self.domains = domains
            self.usage = usage
        }
    }

    private var mockConfig: MockConfig?

    package init(service: StorageService = OWLStorageBridge()) {
        self.service = service
    }

    package convenience init(mockConfig: MockConfig) {
        self.init()
        self.mockConfig = mockConfig
    }

    // MARK: - Public API

    /// Load cookie domains from the Host process.
    package func loadDomains() async {
        if isMockMode {
            domains = mockConfig?.domains ?? []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            domains = try await service.getCookieDomains()
            errorMessage = nil
        } catch {
            NSLog("%@", "[OWL] StorageViewModel.loadDomains failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Load storage usage from the Host process.
    package func loadUsage() async {
        if isMockMode {
            usageEntries = mockConfig?.usage ?? []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            usageEntries = try await service.getStorageUsage()
            errorMessage = nil
        } catch {
            NSLog("%@", "[OWL] StorageViewModel.loadUsage failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Delete all cookies for a specific domain.
    package func deleteDomain(_ domain: String) async {
        if isMockMode {
            domains.removeAll { $0.domain == domain }
            return
        }
        do {
            let deleted = try await service.deleteCookies(domain: domain)
            NSLog("%@", "[OWL] Deleted \(deleted) cookies for \(domain)")
            // Refresh the list after deletion
            await loadDomains()
        } catch {
            NSLog("%@", "[OWL] StorageViewModel.deleteDomain failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Clear all browsing data after user confirms the alert.
    package func confirmClearAll() {
        Task { @MainActor in
            await clearAll()
        }
    }

    /// Clear all browsing data and refresh the panel state.
    package func clearAll() async {
        if isMockMode {
            domains = []
            usageEntries = []
            return
        }
        do {
            _ = try await service.clearData(
                types: .all,
                startTime: 0,
                endTime: Date().timeIntervalSince1970
            )
            // Refresh both lists
            await loadDomains()
            await loadUsage()
        } catch {
            NSLog("%@", "[OWL] StorageViewModel.confirmClearAll failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Formatting Helpers

    /// Format bytes into human-readable string.
    package static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}
