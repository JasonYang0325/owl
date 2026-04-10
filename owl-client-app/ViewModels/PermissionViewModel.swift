import Foundation
import SwiftUI
import UserNotifications

#if canImport(OWLBridge)
import OWLBridge
private let useMockMode = false
#else
private let useMockMode = true
#endif

@MainActor
package class PermissionViewModel: ObservableObject {

    // MARK: - Published State

    /// Current alert request. Non-nil means PermissionAlertView should show.
    @Published package var pendingAlert: PermissionRequest? = nil

    /// Countdown seconds (meaningful only when pendingAlert != nil).
    @Published package var countdown: Int = 30

    /// Toast message (timeout / notifications system denied).
    @Published package var toastMessage: String? = nil
    @Published package var showToast: Bool = false

    // MARK: - MockConfig (unit test support)

    package struct MockConfig {
        package var simulatedRequests: [PermissionRequest]
        /// Simulate macOS system notification authorization denied.
        package var simulateSystemNotificationsDenied: Bool
        package var countdownStart: Int
        package var countdownTickSeconds: TimeInterval
        package var toastDismissSeconds: TimeInterval
        package init(simulatedRequests: [PermissionRequest] = [],
                     simulateSystemNotificationsDenied: Bool = false,
                     countdownStart: Int = 30,
                     countdownTickSeconds: TimeInterval = 1.0,
                     toastDismissSeconds: TimeInterval = 3.0) {
            self.simulatedRequests = simulatedRequests
            self.simulateSystemNotificationsDenied = simulateSystemNotificationsDenied
            self.countdownStart = countdownStart
            self.countdownTickSeconds = countdownTickSeconds
            self.toastDismissSeconds = toastDismissSeconds
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

    /// External entry point (PermissionBridge calls this): enqueue a permission request.
    package func enqueue(_ request: PermissionRequest) {
        if request.type == .notifications {
            if isMockMode {
                // Mock: check simulateSystemNotificationsDenied
                if mockConfig?.simulateSystemNotificationsDenied == true {
                    showToastMessage("请在系统设置中允许 OWL Browser 发送通知")
                    return  // Don't enqueue — simulate system denied
                }
                // Mock + system not denied → normal enqueue
                queue.append(request)
                if pendingAlert == nil { processQueue() }
            } else {
                // Real mode: async check UNUserNotificationCenter
                Task { @MainActor [weak self] in
                    await self?.handleNotificationsEnqueue(request)
                }
            }
        } else {
            queue.append(request)
            if pendingAlert == nil { processQueue() }
        }
    }

    /// View layer calls this: user tapped "Allow" or "Deny".
    package func respond(status: PermissionStatus) {
        guard let req = pendingAlert else { return }
        timerTask?.cancel()
        timerTask = nil
        if !isMockMode {
            OWLPermissionBridge.respond(requestId: req.id, status: status)
        }
        pendingAlert = nil
        processQueue()
    }

    /// Mock-only: simulate receiving a permission request (for unit tests).
    package func simulateRequest(_ request: PermissionRequest) {
        guard isMockMode else { return }
        enqueue(request)
    }

    // MARK: - Private State

    private var queue: [PermissionRequest] = []
    private var timerTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var countdownStartValue: Int { max(mockConfig?.countdownStart ?? 30, 1) }
    private var countdownTickSecondsValue: TimeInterval { max(mockConfig?.countdownTickSeconds ?? 1.0, 0.001) }
    private var toastDismissSecondsValue: TimeInterval { max(mockConfig?.toastDismissSeconds ?? 3.0, 0.001) }

    // MARK: - Queue Processing

    private func processQueue() {
        guard !queue.isEmpty else {
            pendingAlert = nil
            return
        }
        let next = queue.removeFirst()
        pendingAlert = next
        countdown = countdownStartValue
        startTimer()
    }

    // MARK: - 30s Timer (Task-based, cancellable)

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: self.countdownStartValue, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: self.nanoseconds(for: self.countdownTickSecondsValue))
                guard !Task.isCancelled else { return }
                self.countdown = remaining - 1
            }
            guard !Task.isCancelled else { return }
            self.handleTimeout()
        }
    }

    private func handleTimeout() {
        guard let req = pendingAlert else { return }
        timerTask?.cancel()
        // Auto-deny
        if !isMockMode {
            OWLPermissionBridge.respond(requestId: req.id, status: .denied)
        }
        pendingAlert = nil
        showToastMessage("权限请求已超时，已自动拒绝")
        processQueue()
    }

    // MARK: - Toast (auto-dismiss after 3s)

    private func showToastMessage(_ msg: String) {
        toastTask?.cancel()
        toastMessage = msg
        showToast = true
        toastTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.nanoseconds(for: self.toastDismissSecondsValue))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.showToast = false
            }
        }
    }

    private func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }

    // MARK: - Notifications Dual Authorization

    private func handleNotificationsEnqueue(_ request: PermissionRequest) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted {
                queue.append(request)
                if pendingAlert == nil { processQueue() }
            } else {
                OWLPermissionBridge.respond(requestId: request.id, status: .denied)
            }
        case .authorized, .provisional:
            queue.append(request)
            if pendingAlert == nil { processQueue() }
        default: // .denied, .ephemeral
            OWLPermissionBridge.respond(requestId: request.id, status: .denied)
            showToastMessage("请在系统设置中允许 OWL Browser 发送通知")
        }
    }
}
