import Foundation
import AVFoundation
import CoreLocation
import UserNotifications

#if canImport(OWLBridge)
import OWLBridge
private let useMockMode = false
#else
private let useMockMode = true
#endif

@MainActor
package class SettingsPermissionsViewModel: ObservableObject {

    // MARK: - Published State

    @Published package var siteGroups: [SettingsSiteGroup] = []
    @Published package var isLoading = false
    @Published package var showResetAllConfirm = false
    @Published package var systemDisabledTypes: Set<PermissionType> = []

    // MARK: - MockConfig

    package struct MockConfig {
        package var siteGroups: [SettingsSiteGroup]
        package var systemDisabledTypes: Set<PermissionType>
        package init(
            siteGroups: [SettingsSiteGroup] = [],
            systemDisabledTypes: Set<PermissionType> = []
        ) {
            self.siteGroups = siteGroups
            self.systemDisabledTypes = systemDisabledTypes
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

    /// Load all stored permissions from the Host process, grouped by origin.
    package func loadAll() async {
        if isMockMode {
            siteGroups = mockConfig?.siteGroups ?? []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try await OWLPermissionSettingsBridge.getAll()
            siteGroups = groupByOrigin(items)
        } catch {
            NSLog("%@", "[OWL] SettingsPermissionsViewModel.loadAll failed: \(error)")
        }
    }

    /// Check macOS system-level permission status for each type.
    package func checkSystemPermissions() async {
        if isMockMode {
            systemDisabledTypes = mockConfig?.systemDisabledTypes ?? []
            return
        }
        var disabled: Set<PermissionType> = []

        // Camera
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if camStatus == .denied || camStatus == .restricted {
            disabled.insert(.camera)
        }

        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            disabled.insert(.microphone)
        }

        // Geolocation
        let locManager = CLLocationManager()
        let locStatus = locManager.authorizationStatus
        if locStatus == .denied || locStatus == .restricted {
            disabled.insert(.geolocation)
        }

        // Notifications
        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        if notifSettings.authorizationStatus == .denied {
            disabled.insert(.notifications)
        }

        systemDisabledTypes = disabled
    }

    /// Set a single permission to a new status.
    package func setPermission(origin: String, type: PermissionType, status: PermissionStatus) async {
        if isMockMode {
            updateLocal(origin: origin, type: type, status: status)
            return
        }
        if status == .ask {
            OWLPermissionSettingsBridge.resetPermission(origin: origin, type: type)
        } else {
            OWLPermissionSettingsBridge.setPermission(origin: origin, type: type, status: status)
        }
        updateLocal(origin: origin, type: type, status: status)
    }

    /// Reset all permissions after user confirms the alert.
    package func confirmResetAll() {
        if isMockMode {
            siteGroups = []
            return
        }
        OWLPermissionSettingsBridge.resetAll()
        siteGroups = []  // Optimistic update
    }

    // MARK: - Private

    private func groupByOrigin(_ items: [SitePermission]) -> [SettingsSiteGroup] {
        var dict: [String: [SitePermission]] = [:]
        for item in items {
            dict[item.origin, default: []].append(item)
        }
        return dict.map { SettingsSiteGroup(origin: $0.key, permissions: $0.value) }
            .sorted { $0.origin < $1.origin }
    }

    private func updateLocal(origin: String, type: PermissionType, status: PermissionStatus) {
        guard let gi = siteGroups.firstIndex(where: { $0.origin == origin }),
              let pi = siteGroups[gi].permissions.firstIndex(where: { $0.permissionType == type })
        else { return }
        let p = siteGroups[gi].permissions[pi]
        siteGroups[gi].permissions[pi] = SitePermission(
            origin: p.origin, type: p.type, status: status.rawValue)
    }
}
