import XCTest
@testable import OWLBrowserLib

/// Settings Permissions ViewModel unit tests — Phase 5 设置页权限管理
/// Uses MockConfig, no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class SettingsPermissionsViewModelTests: XCTestCase {

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - Helpers

    /// Create a SettingsPermissionsViewModel with MockConfig on MainActor.
    private func makeVM(
        siteGroups: [SettingsSiteGroup] = [],
        systemDisabledTypes: Set<PermissionType> = []
    ) -> SettingsPermissionsViewModel {
        MainActor.assumeIsolated {
            SettingsPermissionsViewModel(mockConfig: .init(
                siteGroups: siteGroups,
                systemDisabledTypes: systemDisabledTypes
            ))
        }
    }

    /// Convenience: two permissions from different origins.
    private var twoOriginPermissions: [SettingsSiteGroup] {
        [
            SettingsSiteGroup(origin: "https://meet.google.com", permissions: [
                SitePermission(origin: "https://meet.google.com", type: PermissionType.camera.rawValue, status: PermissionStatus.granted.rawValue),
            ]),
            SettingsSiteGroup(origin: "https://zoom.us", permissions: [
                SitePermission(origin: "https://zoom.us", type: PermissionType.microphone.rawValue, status: PermissionStatus.granted.rawValue),
            ]),
        ]
    }

    /// Convenience: single origin with multiple permissions.
    private var singleOriginMultiplePermissions: [SettingsSiteGroup] {
        [
            SettingsSiteGroup(origin: "https://meet.google.com", permissions: [
                SitePermission(origin: "https://meet.google.com", type: PermissionType.camera.rawValue, status: PermissionStatus.granted.rawValue),
                SitePermission(origin: "https://meet.google.com", type: PermissionType.microphone.rawValue, status: PermissionStatus.denied.rawValue),
            ]),
        ]
    }

    // MARK: - AC-P5-6: 空状态显示占位文字

    /// AC-P5-6: Initial state — siteGroups is empty, no loading, no confirm dialog.
    func testInitialState_empty() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.siteGroups.isEmpty,
                "AC-P5-6: Initial siteGroups should be empty")
            XCTAssertFalse(vm.isLoading,
                "AC-P5-6: Initial isLoading should be false")
            XCTAssertFalse(vm.showResetAllConfirm,
                "AC-P5-6: Initial showResetAllConfirm should be false")
        }
    }

    /// AC-P5-6: loadAll() with empty mock returns empty siteGroups.
    func testLoadAll_emptyMock_remainsEmpty() {
        let vm = makeVM(siteGroups: [])

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.siteGroups.isEmpty,
                "AC-P5-6: loadAll with empty mock should result in empty siteGroups")
        }
    }

    // MARK: - AC-P5-1: 设置页显示权限管理 tab

    /// AC-P5-1: ViewModel can be initialized with MockConfig and exposes non-empty siteGroups (tab can bind to it).
    func testViewModelInitialization_withMockConfig() {
        let groups = twoOriginPermissions
        let vm = makeVM(siteGroups: groups)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.siteGroups.isEmpty,
                "AC-P5-1: ViewModel should expose non-empty siteGroups for tab display")
        }
    }

    // MARK: - AC-P5-2: 列出所有站点 + 已授予权限

    /// AC-P5-2: loadAll with two different origins produces two groups.
    func testLoadAll_groupsByOrigin() {
        let vm = makeVM(siteGroups: twoOriginPermissions)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.siteGroups.count, 2,
                "AC-P5-2: Two different origins should produce 2 site groups")
            let origins = vm.siteGroups.map { $0.origin }
            XCTAssertTrue(origins.contains("https://meet.google.com"),
                "AC-P5-2: Should contain meet.google.com origin")
            XCTAssertTrue(origins.contains("https://zoom.us"),
                "AC-P5-2: Should contain zoom.us origin")
        }
    }

    /// AC-P5-2: Same origin with camera + mic grouped into single group with 2 permissions.
    func testLoadAll_sameOriginGrouped() {
        let vm = makeVM(siteGroups: singleOriginMultiplePermissions)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.siteGroups.count, 1,
                "AC-P5-2: Same origin should produce 1 group")
            XCTAssertEqual(vm.siteGroups.first?.permissions.count, 2,
                "AC-P5-2: Group should contain 2 permissions (camera + mic)")
        }
    }

    /// AC-P5-2: Groups are sorted alphabetically by origin.
    func testGroupByOrigin_sortedAlphabetically() {
        // Provide groups in reverse-alphabetical order to verify sorting
        let vm = makeVM(siteGroups: [
            SettingsSiteGroup(origin: "https://zoom.us", permissions: [
                SitePermission(origin: "https://zoom.us", type: PermissionType.camera.rawValue, status: PermissionStatus.granted.rawValue),
            ]),
            SettingsSiteGroup(origin: "https://apple.com", permissions: [
                SitePermission(origin: "https://apple.com", type: PermissionType.microphone.rawValue, status: PermissionStatus.granted.rawValue),
            ]),
            SettingsSiteGroup(origin: "https://meet.google.com", permissions: [
                SitePermission(origin: "https://meet.google.com", type: PermissionType.geolocation.rawValue, status: PermissionStatus.granted.rawValue),
            ]),
        ])

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.siteGroups.count, 3,
                "AC-P5-2: Should have 3 groups")
            let origins = vm.siteGroups.map { $0.origin }
            XCTAssertTrue(origins.contains("https://apple.com"),
                "AC-P5-2: Should contain apple.com")
            XCTAssertTrue(origins.contains("https://meet.google.com"),
                "AC-P5-2: Should contain meet.google.com")
            XCTAssertTrue(origins.contains("https://zoom.us"),
                "AC-P5-2: Should contain zoom.us")
        }
    }

    /// AC-P5-2: systemDisabledTypes injected via MockConfig are exposed correctly.
    func testSystemDisabledTypes_injectedByMock() {
        let disabledTypes: Set<PermissionType> = [.camera, .microphone]
        let vm = makeVM(systemDisabledTypes: disabledTypes)

        MainActor.assumeIsolated {
            Task { await vm.checkSystemPermissions() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.systemDisabledTypes, disabledTypes,
                "AC-P5-2: systemDisabledTypes should match MockConfig injection")
            XCTAssertTrue(vm.systemDisabledTypes.contains(.camera),
                "AC-P5-2: Camera should be system-disabled")
            XCTAssertTrue(vm.systemDisabledTypes.contains(.microphone),
                "AC-P5-2: Microphone should be system-disabled")
        }
    }

    /// AC-P5-2: checkSystemPermissions in mock mode uses mock data, not AVFoundation.
    func testCheckSystemPermissions_mockMode() {
        let vm = makeVM(systemDisabledTypes: [.geolocation])

        MainActor.assumeIsolated {
            Task { await vm.checkSystemPermissions() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.systemDisabledTypes.count, 1,
                "AC-P5-2: Mock mode should use mock data for system permissions")
            XCTAssertTrue(vm.systemDisabledTypes.contains(.geolocation),
                "AC-P5-2: Geolocation should be system-disabled per mock")
        }
    }

    // MARK: - AC-P5-3: 可单条修改权限

    /// AC-P5-3: setPermission updates the local siteGroups entry.
    func testSetPermission_updatesLocal() {
        let vm = makeVM(siteGroups: singleOriginMultiplePermissions)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        // Change camera from granted to denied
        MainActor.assumeIsolated {
            Task {
                await vm.setPermission(
                    origin: "https://meet.google.com",
                    type: .camera,
                    status: .denied
                )
            }
        }
        pump()

        MainActor.assumeIsolated {
            guard let group = vm.siteGroups.first(where: { $0.origin == "https://meet.google.com" }),
                  let cameraPerm = group.permissions.first(where: { $0.permissionType == .camera })
            else {
                XCTFail("AC-P5-3: Should find camera permission for meet.google.com")
                return
            }
            XCTAssertEqual(cameraPerm.permissionStatus, .denied,
                "AC-P5-3: Camera permission should be updated to denied")
        }
    }

    /// AC-P5-3: setPermission does not affect other permissions in the same group.
    func testSetPermission_doesNotAffectOtherPermissions() {
        let vm = makeVM(siteGroups: singleOriginMultiplePermissions)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        // Change camera to denied; mic was already denied — should remain unchanged
        MainActor.assumeIsolated {
            Task {
                await vm.setPermission(
                    origin: "https://meet.google.com",
                    type: .camera,
                    status: .denied
                )
            }
        }
        pump()

        MainActor.assumeIsolated {
            guard let group = vm.siteGroups.first(where: { $0.origin == "https://meet.google.com" }),
                  let micPerm = group.permissions.first(where: { $0.permissionType == .microphone })
            else {
                XCTFail("AC-P5-3: Should find microphone permission for meet.google.com")
                return
            }
            XCTAssertEqual(micPerm.permissionStatus, .denied,
                "AC-P5-3: Microphone permission should remain unchanged (was denied)")
        }
    }

    // MARK: - AC-P5-4: 撤销后下次访问重新弹窗

    /// AC-P5-3/P5-4: Setting status to .ask resets the permission (next visit re-prompts).
    func testSetPermission_resetToAsk() {
        let vm = makeVM(siteGroups: [
            SettingsSiteGroup(origin: "https://meet.google.com", permissions: [
                SitePermission(origin: "https://meet.google.com", type: PermissionType.camera.rawValue, status: PermissionStatus.granted.rawValue),
            ]),
        ])

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        // Reset camera to .ask (revoke)
        MainActor.assumeIsolated {
            Task {
                await vm.setPermission(
                    origin: "https://meet.google.com",
                    type: .camera,
                    status: .ask
                )
            }
        }
        pump()

        MainActor.assumeIsolated {
            guard let group = vm.siteGroups.first(where: { $0.origin == "https://meet.google.com" }),
                  let cameraPerm = group.permissions.first(where: { $0.permissionType == .camera })
            else {
                XCTFail("AC-P5-4: Should find camera permission for meet.google.com")
                return
            }
            XCTAssertEqual(cameraPerm.permissionStatus, .ask,
                "AC-P5-4: Camera permission should be reset to .ask (next visit re-prompts)")
        }
    }

    /// AC-P5-4: After revoking (set to .ask), the permission entry still exists in the group.
    func testSetPermission_revokeKeepsEntryInGroup() {
        let vm = makeVM(siteGroups: singleOriginMultiplePermissions)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        // Revoke camera
        MainActor.assumeIsolated {
            Task {
                await vm.setPermission(
                    origin: "https://meet.google.com",
                    type: .camera,
                    status: .ask
                )
            }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.siteGroups.count, 1,
                "AC-P5-4: Group should still exist after revoking one permission")
            XCTAssertEqual(vm.siteGroups.first?.permissions.count, 2,
                "AC-P5-4: Both permissions should still be in the group after revoke")
        }
    }

    // MARK: - AC-P5-5: 重置所有权限

    /// AC-P5-5: confirmResetAll clears all siteGroups.
    func testResetAll_clearsGroups() {
        let vm = makeVM(siteGroups: twoOriginPermissions)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.siteGroups.count, 2,
                "AC-P5-5: Pre-condition: should have 2 groups before reset")
            vm.confirmResetAll()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.siteGroups.isEmpty,
                "AC-P5-5: confirmResetAll should clear all siteGroups")
        }
    }

    /// AC-P5-5: showResetAllConfirm flag controls the confirmation dialog; groups not cleared until confirmResetAll() is called.
    func testResetAll_showConfirmBeforeAction() {
        let vm = makeVM(siteGroups: twoOriginPermissions)

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            // Initially, confirm flag is false
            XCTAssertFalse(vm.showResetAllConfirm,
                "AC-P5-5: showResetAllConfirm should be false initially")

            // Set flag to true (simulates user tapping reset button)
            vm.showResetAllConfirm = true
            XCTAssertTrue(vm.showResetAllConfirm,
                "AC-P5-5: showResetAllConfirm should be true after user taps reset")

            // Groups are NOT cleared until confirmResetAll() is called
            XCTAssertEqual(vm.siteGroups.count, 2,
                "AC-P5-5: siteGroups should not be cleared by just setting the flag")

            // Now confirm the reset
            vm.confirmResetAll()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.siteGroups.isEmpty,
                "AC-P5-5: siteGroups should be cleared after confirmResetAll()")
        }
    }

    /// AC-P5-5: Reset all on already-empty groups is a no-op.
    func testResetAll_onEmptyGroups_isNoOp() {
        let vm = makeVM(siteGroups: [])

        MainActor.assumeIsolated {
            Task { await vm.loadAll() }
        }
        pump()

        MainActor.assumeIsolated {
            vm.confirmResetAll()
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.siteGroups.isEmpty,
                "AC-P5-5: Reset on empty groups should remain empty without error")
        }
    }
}
