import Foundation
import SwiftUI
#if canImport(OWLBridge)
import OWLBridge
#endif

// MARK: - Shared Types

/// Permission type enum aligned with C-ABI values
/// (0=Camera, 1=Mic, 2=Geo, 3=Notifications).
package enum PermissionType: Int32, CaseIterable, Sendable {
    case camera        = 0
    case microphone    = 1
    case geolocation   = 2
    case notifications = 3

    package var displayName: String {
        switch self {
        case .camera:        return "摄像头"
        case .microphone:    return "麦克风"
        case .geolocation:   return "位置"
        case .notifications: return "通知"
        }
    }

    package var sfSymbol: String {
        switch self {
        case .camera:        return "camera.fill"
        case .microphone:    return "mic.fill"
        case .geolocation:   return "location.fill"
        case .notifications: return "bell.fill"
        }
    }

    package var iconColor: Color {
        switch self {
        case .camera:        return .blue
        case .microphone:    return .red
        case .geolocation:   return .green
        case .notifications: return .orange
        }
    }
}

/// Permission status enum aligned with C-ABI values
/// (0=Granted, 1=Denied, 2=Ask).
package enum PermissionStatus: Int32, Sendable {
    case granted = 0
    case denied  = 1
    case ask     = 2
}

/// A single permission request from the renderer.
package struct PermissionRequest: Identifiable, Equatable, Sendable {
    package let id: UInt64          // request_id from C-ABI
    package let origin: String      // e.g. "https://meet.google.com"
    package let type: PermissionType

    /// Display-friendly origin (host only, no scheme).
    package var displayOrigin: String {
        URL(string: origin)?.host ?? origin
    }
}

// MARK: - PermissionBridge (C-ABI callback holder)

/// Global singleton that registers C-ABI permission callbacks and
/// forwards requests to PermissionViewModel.
/// Must survive as long as the app runs (C callbacks can fire at any time).
@MainActor
final class PermissionBridge {
    static let shared = PermissionBridge()

    // Weak reference: PermissionViewModel is strongly held by BrowserViewModel.
    private weak var permissionVM: PermissionViewModel?

    /// Call once from BrowserViewModel.initializeAndLaunch() after OWLBridge_Initialize().
    func register(permissionVM: PermissionViewModel) {
        self.permissionVM = permissionVM

        #if canImport(OWLBridge)
        OWLBridge_SetPermissionRequestCallback(
            permissionRequestCallback,
            nil  // context not needed — access via PermissionBridge.shared
        )
        #endif
    }

    /// Unregister callback (app shutdown).
    func unregister() {
        #if canImport(OWLBridge)
        let nullCallback: OWLBridge_PermissionRequestCallback? = nil
        OWLBridge_SetPermissionRequestCallback(nullCallback, nil)
        #endif
        permissionVM = nil
    }

    /// Internal access for the C callback to forward requests.
    fileprivate func forward(_ request: PermissionRequest) {
        permissionVM?.enqueue(request)
    }
}

// MARK: - C Callback (free function, no closure capture)

#if canImport(OWLBridge)
private func permissionRequestCallback(
    webviewId: UInt64,
    origin: UnsafePointer<CChar>?,
    permissionType: Int32,
    requestId: UInt64,
    context: UnsafeMutableRawPointer?
) {
    let originStr = origin.map { String(cString: $0) } ?? ""
    let type = PermissionType(rawValue: permissionType) ?? .camera
    let request = PermissionRequest(id: requestId, origin: originStr, type: type)

    // C-ABI guarantees main thread, but Swift doesn't know — bridge via Task.
    Task { @MainActor in
        PermissionBridge.shared.forward(request)
    }
}
#endif

// MARK: - SitePermission (data transfer object for Settings)

/// A single stored site permission returned from the Host process.
package struct SitePermission: Codable, Identifiable, Equatable, Sendable {
    package let origin: String
    package let type: Int32      // PermissionType.rawValue
    package let status: Int32    // PermissionStatus.rawValue

    package var id: String { "\(origin):\(type)" }
    package var permissionType: PermissionType { PermissionType(rawValue: type) ?? .camera }
    package var permissionStatus: PermissionStatus { PermissionStatus(rawValue: status) ?? .ask }
}

/// Aggregated site group for the permissions settings panel.
package struct SettingsSiteGroup: Identifiable {
    package let origin: String
    package var permissions: [SitePermission]
    package var id: String { origin }
}

// MARK: - OWLPermissionBridge (fire-and-forget response)

/// Namespace for sending permission responses back to Host via C-ABI.
enum OWLPermissionBridge {
    static func respond(requestId: UInt64, status: PermissionStatus) {
        #if canImport(OWLBridge)
        OWLBridge_RespondToPermission(requestId, status.rawValue)
        #endif
    }
}

// MARK: - OWLPermissionSettingsBridge (async wrappers for Settings)

/// Async wrappers for permission management C-ABI functions.
/// Uses Box/CheckedContinuation pattern consistent with OWLBookmarkBridge.
enum OWLPermissionSettingsBridge {

    /// Fetch all stored permissions from the Host process.
    static func getAll() async throws -> [SitePermission] {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[SitePermission], Error>) in
            final class Box {
                let value: CheckedContinuation<[SitePermission], Error>
                init(_ value: CheckedContinuation<[SitePermission], Error>) { self.value = value }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()

            OWLBridge_PermissionGetAll({ jsonArray, errorMsg, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                if let errorMsg {
                    box.value.resume(throwing: NSError(
                        domain: "OWLPermission", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                    return
                }
                guard let jsonArray,
                      let data = String(cString: jsonArray).data(using: .utf8),
                      let items = try? JSONDecoder().decode([SitePermission].self, from: data) else {
                    box.value.resume(throwing: NSError(
                        domain: "OWLPermission", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode permission list JSON"]))
                    return
                }
                box.value.resume(returning: items)
            }, ctx)
        }
        #else
        return []
        #endif
    }

    /// Set a permission status. Fire-and-forget (wrapped as sync call in async context).
    static func setPermission(origin: String, type: PermissionType, status: PermissionStatus) {
        #if canImport(OWLBridge)
        origin.withCString { o in
            OWLBridge_PermissionSet(o, type.rawValue, status.rawValue)
        }
        #endif
    }

    /// Reset a single permission back to Ask. Fire-and-forget.
    static func resetPermission(origin: String, type: PermissionType) {
        #if canImport(OWLBridge)
        origin.withCString { o in
            OWLBridge_PermissionReset(o, type.rawValue)
        }
        #endif
    }

    /// Reset all permissions. Fire-and-forget.
    static func resetAll() {
        #if canImport(OWLBridge)
        OWLBridge_PermissionResetAll()
        #endif
    }
}
