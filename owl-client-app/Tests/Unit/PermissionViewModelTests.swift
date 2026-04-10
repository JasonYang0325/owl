import XCTest
@testable import OWLBrowserLib

/// Permission ViewModel unit tests — Phase 3 权限弹窗队列 + 超时 + Toast
/// Uses MockConfig, no Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class PermissionViewModelTests: XCTestCase {
    private let fastCountdownTickSeconds: TimeInterval = 0.05

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    @discardableResult
    private func pumpUntil(
        timeout: TimeInterval,
        step: TimeInterval = 0.02,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            pump(step)
        }
        return predicate()
    }

    // MARK: - Helpers

    /// Create a PermissionViewModel with MockConfig on MainActor.
    private func makeVM(
        requests: [PermissionRequest] = [],
        simulateSystemNotificationsDenied: Bool = false,
        countdownTickSeconds: TimeInterval = 1.0,
        toastDismissSeconds: TimeInterval = 3.0
    ) -> PermissionViewModel {
        MainActor.assumeIsolated {
            PermissionViewModel(mockConfig: .init(
                simulatedRequests: requests,
                simulateSystemNotificationsDenied: simulateSystemNotificationsDenied,
                countdownTickSeconds: countdownTickSeconds,
                toastDismissSeconds: toastDismissSeconds
            ))
        }
    }

    /// Convenience: sample permission requests for tests.
    private var sampleRequests: [PermissionRequest] {
        [
            PermissionRequest(id: UInt64(1), origin: "https://meet.google.com", type: .camera),
            PermissionRequest(id: UInt64(2), origin: "https://zoom.us", type: .microphone),
            PermissionRequest(id: UInt64(3), origin: "https://maps.google.com", type: .geolocation),
        ]
    }

    // MARK: - AC-P3-1: 初始状态 + 入队后弹窗显示

    /// AC-P3-1: Initial state — pendingAlert is nil, countdown is 30, showToast is false.
    func testInitialState() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-1: Initial pendingAlert should be nil")
            XCTAssertEqual(vm.countdown, 30,
                "AC-P3-1: Initial countdown should be 30")
            XCTAssertFalse(vm.showToast,
                "AC-P3-1: Initial showToast should be false")
            XCTAssertNil(vm.toastMessage,
                "AC-P3-1: Initial toastMessage should be nil")
        }
    }

    /// AC-P3-1: enqueue a single request shows alert with correct origin and type.
    func testSingleRequest_showsAlert() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(1), origin: "https://meet.google.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNotNil(vm.pendingAlert,
                "AC-P3-1: pendingAlert should be non-nil after enqueue")
            XCTAssertEqual(vm.pendingAlert?.id, 1,
                "AC-P3-1: pendingAlert should have the enqueued request ID")
            XCTAssertEqual(vm.pendingAlert?.type, .camera,
                "AC-P3-1: pendingAlert should have the correct permission type")
            XCTAssertEqual(vm.pendingAlert?.origin, "https://meet.google.com",
                "AC-P3-1: pendingAlert should have the correct origin")
        }
    }

    /// AC-P3-1: simulateRequest (mock-only API) also triggers alert display.
    func testMockMode_simulateRequest() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(42), origin: "https://example.com", type: .geolocation)

        MainActor.assumeIsolated {
            vm.simulateRequest(req)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.pendingAlert?.id, 42,
                "AC-P3-1: simulateRequest should enqueue and display the request")
            XCTAssertEqual(vm.pendingAlert?.type, .geolocation,
                "AC-P3-1: simulateRequest should preserve the permission type")
        }
    }

    // MARK: - AC-P3-2: 允许后弹窗消失

    /// AC-P3-2: respond(.granted) clears the pending alert.
    func testAllow_clearsAlert() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(2), origin: "https://zoom.us", type: .microphone)

        MainActor.assumeIsolated {
            vm.enqueue(req)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNotNil(vm.pendingAlert,
                "Precondition: pendingAlert should be shown after enqueue")
            vm.respond(status: .granted)
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-2: pendingAlert should be nil after allowing")
        }
    }

    // MARK: - AC-P3-3: 拒绝后弹窗消失

    /// AC-P3-3: respond(.denied) clears the pending alert.
    func testDeny_clearsAlert() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(3), origin: "https://maps.google.com", type: .geolocation)

        MainActor.assumeIsolated {
            vm.enqueue(req)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNotNil(vm.pendingAlert,
                "Precondition: pendingAlert should be shown after enqueue")
            vm.respond(status: .denied)
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-3: pendingAlert should be nil after denying")
        }
    }

    // MARK: - AC-P3-4: 30s 超时自动拒绝

    /// AC-P3-4: countdown decrements from 30 after ~1 second.
    func testCountdown_decrements() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(10), origin: "https://example.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req)
            XCTAssertEqual(vm.countdown, 30,
                "AC-P3-4: Countdown should start at 30")
        }

        // Pump for ~1.2 seconds to allow at least one tick
        pump(1.2)

        MainActor.assumeIsolated {
            XCTAssertLessThan(vm.countdown, 30,
                "AC-P3-4: Countdown should have decremented after ~1 second")
            XCTAssertGreaterThanOrEqual(vm.countdown, 28,
                "AC-P3-4: Countdown should be around 28-29 after ~1 second")
        }
    }

    /// AC-P3-4: respond() cancels the timer — no toast fires after responding.
    func testRespond_cancelsTimer() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(11), origin: "https://example.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req)
            vm.respond(status: .granted)
        }

        // Wait past the point where a timeout tick would fire
        pump(1.5)

        MainActor.assumeIsolated {
            XCTAssertFalse(vm.showToast,
                "AC-P3-4: Toast should NOT appear after respond() cancels the timer")
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-4: pendingAlert should remain nil")
        }
    }

    /// AC-P3-4: Full 30s timeout auto-rejects and shows toast.
    func testTimeout_autoReject() {
        let vm = makeVM(countdownTickSeconds: fastCountdownTickSeconds)
        let req = PermissionRequest(id: UInt64(12), origin: "https://example.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req)
            XCTAssertNotNil(vm.pendingAlert,
                "Precondition: alert should be showing")
        }

        XCTAssertTrue(
            pumpUntil(timeout: 3.0) {
                MainActor.assumeIsolated {
                    vm.pendingAlert == nil && vm.showToast
                }
            },
            "AC-P3-4: timeout should auto-reject within accelerated test window"
        )

        MainActor.assumeIsolated {
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-4: pendingAlert should be nil after timeout auto-rejects")
            XCTAssertTrue(vm.showToast,
                "AC-P3-4: showToast should be true after timeout")
        }
    }

    /// AC-P3-4: Timeout toast message contains expected text.
    func testTimeout_toastMessage() {
        let vm = makeVM(countdownTickSeconds: fastCountdownTickSeconds)
        let req = PermissionRequest(id: UInt64(13), origin: "https://example.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req)
        }

        XCTAssertTrue(
            pumpUntil(timeout: 3.0) {
                MainActor.assumeIsolated {
                    vm.toastMessage?.contains("已自动拒绝") == true
                }
            },
            "AC-P3-4: timeout toast should appear within accelerated test window"
        )

        MainActor.assumeIsolated {
            XCTAssertNotNil(vm.toastMessage,
                "AC-P3-4: toastMessage should be set after timeout")
            XCTAssertTrue(vm.toastMessage?.contains("已自动拒绝") == true,
                "AC-P3-4: Toast message should contain '已自动拒绝', got: \(vm.toastMessage ?? "nil")")
        }
    }

    // MARK: - AC-P3-5: 队列化逐个弹出

    /// AC-P3-5: Two requests queued — second shows after first is responded to.
    func testQueue_secondRequestShowsAfterFirst() {
        let vm = makeVM()
        let req1 = PermissionRequest(id: UInt64(100), origin: "https://a.com", type: .camera)
        let req2 = PermissionRequest(id: UInt64(101), origin: "https://b.com", type: .microphone)

        MainActor.assumeIsolated {
            vm.enqueue(req1)
            vm.enqueue(req2)
        }
        pump()

        MainActor.assumeIsolated {
            // First request should be showing
            XCTAssertEqual(vm.pendingAlert?.id, 100,
                "AC-P3-5: First enqueued request should be shown first")

            // Respond to first
            vm.respond(status: .granted)
        }
        pump()

        MainActor.assumeIsolated {
            // Second request should now be showing
            XCTAssertEqual(vm.pendingAlert?.id, 101,
                "AC-P3-5: Second request should auto-show after first is resolved")
            XCTAssertEqual(vm.pendingAlert?.type, .microphone,
                "AC-P3-5: Second request should have correct type")
        }
    }

    /// AC-P3-5: Three requests processed in FIFO order.
    func testQueue_multipleRequestsProcessedInOrder() {
        let vm = makeVM()
        let req1 = PermissionRequest(id: UInt64(200), origin: "https://a.com", type: .camera)
        let req2 = PermissionRequest(id: UInt64(201), origin: "https://b.com", type: .microphone)
        let req3 = PermissionRequest(id: UInt64(202), origin: "https://c.com", type: .geolocation)

        MainActor.assumeIsolated {
            vm.enqueue(req1)
            vm.enqueue(req2)
            vm.enqueue(req3)
        }
        pump()

        // Process all three in order
        MainActor.assumeIsolated {
            XCTAssertEqual(vm.pendingAlert?.id, 200,
                "AC-P3-5: First request (id=200) should be shown first")
            vm.respond(status: .granted)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.pendingAlert?.id, 201,
                "AC-P3-5: Second request (id=201) should show after first is resolved")
            vm.respond(status: .denied)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.pendingAlert?.id, 202,
                "AC-P3-5: Third request (id=202) should show after second is resolved")
            vm.respond(status: .granted)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-5: After all requests resolved, pendingAlert should be nil")
        }
    }

    /// AC-P3-5: Enqueue during showing — new request queued, not immediately displayed.
    func testQueue_enqueueWhileShowing() {
        let vm = makeVM()
        let req1 = PermissionRequest(id: UInt64(300), origin: "https://a.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req1)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.pendingAlert?.id, 300,
                "Precondition: first request should be showing")

            // Enqueue a second request while first is still showing
            let req2 = PermissionRequest(id: UInt64(301), origin: "https://b.com", type: .microphone)
            vm.enqueue(req2)

            // First request should still be showing (not replaced)
            XCTAssertEqual(vm.pendingAlert?.id, 300,
                "AC-P3-5: Enqueueing while showing should not replace the current alert")
        }
    }

    /// AC-P3-5: Countdown resets to 30 when next request is dequeued.
    func testQueue_countdownResetsOnNextRequest() {
        let vm = makeVM()
        let req1 = PermissionRequest(id: UInt64(400), origin: "https://a.com", type: .camera)
        let req2 = PermissionRequest(id: UInt64(401), origin: "https://b.com", type: .microphone)

        MainActor.assumeIsolated {
            vm.enqueue(req1)
            vm.enqueue(req2)
        }

        // Wait 2 seconds so countdown decrements
        pump(2.0)

        MainActor.assumeIsolated {
            XCTAssertLessThan(vm.countdown, 30,
                "Precondition: countdown should have decremented")
            // Respond to first request — second should appear with reset countdown
            vm.respond(status: .granted)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.pendingAlert?.id, 401,
                "AC-P3-5: Second request should now be showing")
            XCTAssertEqual(vm.countdown, 30,
                "AC-P3-5: Countdown should reset to 30 for the new request")
        }
    }

    // MARK: - AC-P3-6: notifications 系统拒绝 Toast

    /// AC-P3-6: notifications request with system denied — shows toast, does not enqueue.
    func testNotifications_systemDenied_toastShown() {
        let vm = makeVM(simulateSystemNotificationsDenied: true)
        let req = PermissionRequest(id: UInt64(500), origin: "https://example.com", type: .notifications)

        MainActor.assumeIsolated {
            vm.enqueue(req)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-6: notifications request should NOT be enqueued when system denied")
            XCTAssertTrue(vm.showToast,
                "AC-P3-6: showToast should be true when system notifications denied")
            XCTAssertNotNil(vm.toastMessage,
                "AC-P3-6: toastMessage should be set")
            XCTAssertTrue(vm.toastMessage?.contains("系统设置") == true,
                "AC-P3-6: Toast should mention '系统设置', got: \(vm.toastMessage ?? "nil")")
        }
    }

    /// AC-P3-6: notifications request with system NOT denied — enqueues normally.
    func testNotifications_systemAllowed_enqueuesNormally() {
        let vm = makeVM(simulateSystemNotificationsDenied: false)
        let req = PermissionRequest(id: UInt64(501), origin: "https://example.com", type: .notifications)

        MainActor.assumeIsolated {
            vm.enqueue(req)
        }
        pump()

        MainActor.assumeIsolated {
            XCTAssertNotNil(vm.pendingAlert,
                "AC-P3-6: notifications request should be enqueued when system allowed")
            XCTAssertEqual(vm.pendingAlert?.id, 501,
                "AC-P3-6: The notifications request should be the pending alert")
            XCTAssertEqual(vm.pendingAlert?.type, .notifications,
                "AC-P3-6: The pending alert type should be .notifications")
        }
    }

    // MARK: - PermissionType 映射

    /// PermissionType.camera has correct sfSymbol.
    func testPermissionTypeMapping_camera() {
        MainActor.assumeIsolated {
            XCTAssertEqual(PermissionType.camera.sfSymbol, "camera.fill",
                "camera sfSymbol should be 'camera.fill'")
        }
    }

    /// All PermissionType cases have non-empty sfSymbol and displayName.
    func testPermissionTypeMapping_allCases() {
        MainActor.assumeIsolated {
            for type in PermissionType.allCases {
                XCTAssertFalse(type.sfSymbol.isEmpty,
                    "\(type) should have a non-empty sfSymbol")
                XCTAssertFalse(type.displayName.isEmpty,
                    "\(type) should have a non-empty displayName")
            }
        }
    }

    // MARK: - 边界场景

    /// Respond with no pending alert does not crash.
    func testRespond_noPendingAlert_noCrash() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Should be a no-op, not crash
            vm.respond(status: .granted)
            XCTAssertNil(vm.pendingAlert,
                "respond with no pending alert should leave state unchanged")

            vm.respond(status: .denied)
            XCTAssertNil(vm.pendingAlert,
                "respond with no pending alert should leave state unchanged")
        }
    }

    /// Rapid double-respond does not crash (guard let protects).
    func testRapidDoubleRespond_noCrash() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(600), origin: "https://example.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req)
            // Respond twice in rapid succession
            vm.respond(status: .granted)
            vm.respond(status: .denied)
            XCTAssertNil(vm.pendingAlert,
                "Double respond should not crash, pendingAlert should be nil")
        }
    }

    /// PermissionRequest displayOrigin extracts host from URL.
    func testDisplayOrigin_extractsHost() {
        let req = PermissionRequest(id: UInt64(700), origin: "https://meet.google.com", type: .camera)
        XCTAssertEqual(req.displayOrigin, "meet.google.com",
            "displayOrigin should extract host from URL, stripping scheme")
    }

    /// PermissionRequest displayOrigin falls back to raw origin for non-URL strings.
    func testDisplayOrigin_fallbackForNonURL() {
        let req = PermissionRequest(id: UInt64(701), origin: "not-a-url", type: .camera)
        XCTAssertEqual(req.displayOrigin, "not-a-url",
            "displayOrigin should fall back to raw origin when URL parsing fails")
    }

    // MARK: - AC-P3-2/P3-3: 响应时 pendingAlert 的 ID 与请求一致

    /// AC-P3-2: The request shown in pendingAlert before granting has the correct ID,
    /// confirming the VM is responding to the right request.
    func testAllow_respondsToCorrectRequestID() {
        let vm = makeVM()
        let req = PermissionRequest(id: UInt64(800), origin: "https://example.com", type: .camera)

        MainActor.assumeIsolated {
            vm.enqueue(req)
        }
        pump()

        MainActor.assumeIsolated {
            // Verify the alert being responded to is the one we enqueued
            XCTAssertEqual(vm.pendingAlert?.id, 800,
                "AC-P3-2: pendingAlert.id must match the enqueued request ID before granting")
            XCTAssertEqual(vm.pendingAlert?.origin, "https://example.com",
                "AC-P3-2: pendingAlert.origin must match the enqueued request before granting")
            vm.respond(status: .granted)
            XCTAssertNil(vm.pendingAlert,
                "AC-P3-2: pendingAlert should be nil after granting the correct request")
        }
    }

    /// AC-P3-3: The request shown in pendingAlert before denying has the correct ID,
    /// confirming the VM is responding to the right request.
    func testDeny_respondsToCorrectRequestID() {
        let vm = makeVM()
        let req1 = PermissionRequest(id: UInt64(801), origin: "https://a.com", type: .microphone)
        let req2 = PermissionRequest(id: UInt64(802), origin: "https://b.com", type: .geolocation)

        MainActor.assumeIsolated {
            vm.enqueue(req1)
            vm.enqueue(req2)
        }
        pump()

        MainActor.assumeIsolated {
            // Only the first request should be pending — deny it
            XCTAssertEqual(vm.pendingAlert?.id, 801,
                "AC-P3-3: pendingAlert.id must match the first enqueued request ID before denying")
            vm.respond(status: .denied)
        }
        pump()

        MainActor.assumeIsolated {
            // Second request should now be pending, first was denied
            XCTAssertEqual(vm.pendingAlert?.id, 802,
                "AC-P3-3: After denying id=801, id=802 should be the new pending alert")
        }
    }

    // MARK: - AC-P3-6: 非 notifications 类型跳过系统授权检查

    /// AC-P3-6: camera request is never blocked by system notification check —
    /// even when system notifications are denied, camera enqueues normally.
    func testNonNotificationTypes_notBlockedBySystemCheck() {
        let vm = makeVM(simulateSystemNotificationsDenied: true)

        MainActor.assumeIsolated {
            // All non-notification types should queue normally regardless of system notification state
            for (id, type) in [(UInt64(900), PermissionType.camera),
                               (UInt64(901), PermissionType.microphone),
                               (UInt64(902), PermissionType.geolocation)] {
                let req = PermissionRequest(id: id, origin: "https://example.com", type: type)
                vm.enqueue(req)
            }
        }
        pump()

        MainActor.assumeIsolated {
            // First non-notification request should be showing (not blocked by system check)
            XCTAssertNotNil(vm.pendingAlert,
                "AC-P3-6: non-notification request should enqueue even when system notifications denied")
            XCTAssertEqual(vm.pendingAlert?.id, 900,
                "AC-P3-6: camera request should be pending, not blocked by notification system check")
            XCTAssertFalse(vm.showToast,
                "AC-P3-6: system-denied toast should NOT fire for non-notification request types")
        }
    }
}
