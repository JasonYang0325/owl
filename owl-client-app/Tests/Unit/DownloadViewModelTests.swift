import XCTest
@testable import OWLBrowserLib

/// Download ViewModel unit tests — Phase 3 下载管理系统
/// Pure Swift tests: DownloadItem Codable, DownloadItemVM 更新/进度/速度, DownloadViewModel 列表管理
/// No Host process needed.
/// XCTest runs on main thread, so MainActor.assumeIsolated is safe.
final class DownloadViewModelTests: XCTestCase {

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - Helpers

    /// Create a DownloadItem with sensible defaults. Override fields as needed.
    private func makeItem(
        id: UInt32 = 1,
        url: String = "https://example.com/file.zip",
        filename: String = "file.zip",
        mimeType: String = "application/zip",
        totalBytes: Int64 = 1_000_000,
        receivedBytes: Int64 = 500_000,
        speedBytesPerSec: Int64 = 100_000,
        state: DownloadState = .inProgress,
        errorDescription: String? = nil,
        canResume: Bool = true,
        targetPath: String = "/tmp/file.zip"
    ) -> DownloadItem {
        DownloadItem(
            id: id, url: url, filename: filename, mimeType: mimeType,
            totalBytes: totalBytes, receivedBytes: receivedBytes,
            speedBytesPerSec: speedBytesPerSec, state: state,
            errorDescription: errorDescription, canResume: canResume,
            targetPath: targetPath
        )
    }

    /// Create a DownloadViewModel on MainActor.
    private func makeVM() -> DownloadViewModel {
        MainActor.assumeIsolated {
            DownloadViewModel()
        }
    }

    // =========================================================================
    // MARK: - AC1: DownloadItem Codable 解码/编码 + CodingKeys 映射
    // =========================================================================

    /// AC1: JSON with snake_case keys decodes correctly via CodingKeys.
    func testDownloadItem_decodesSnakeCaseJSON() throws {
        let json = """
        {
            "id": 42,
            "url": "https://example.com/big.dmg",
            "filename": "big.dmg",
            "mime_type": "application/x-apple-diskimage",
            "total_bytes": 5242880,
            "received_bytes": 2621440,
            "speed_bytes_per_sec": 524288,
            "state": 0,
            "error_description": null,
            "can_resume": true,
            "target_path": "/Users/test/Downloads/big.dmg"
        }
        """
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(DownloadItem.self, from: data)

        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.url, "https://example.com/big.dmg")
        XCTAssertEqual(item.filename, "big.dmg")
        XCTAssertEqual(item.mimeType, "application/x-apple-diskimage",
            "AC1: mime_type should map to mimeType via CodingKeys")
        XCTAssertEqual(item.totalBytes, 5_242_880,
            "AC1: total_bytes should map to totalBytes")
        XCTAssertEqual(item.receivedBytes, 2_621_440,
            "AC1: received_bytes should map to receivedBytes")
        XCTAssertEqual(item.speedBytesPerSec, 524_288,
            "AC1: speed_bytes_per_sec should map to speedBytesPerSec")
        XCTAssertEqual(item.state, .inProgress,
            "AC1: state 0 should decode to .inProgress")
        XCTAssertNil(item.errorDescription,
            "AC1: null error_description should decode to nil")
        XCTAssertTrue(item.canResume,
            "AC1: can_resume should map to canResume")
        XCTAssertEqual(item.targetPath, "/Users/test/Downloads/big.dmg",
            "AC1: target_path should map to targetPath")
    }

    /// AC1: All DownloadState enum cases decode correctly from raw Int.
    func testDownloadItem_decodesAllStates() throws {
        let states: [(Int, DownloadState)] = [
            (0, .inProgress),
            (1, .paused),
            (2, .complete),
            (3, .cancelled),
            (4, .interrupted),
        ]

        for (raw, expected) in states {
            let json = """
            {
                "id": 1, "url": "u", "filename": "f", "mime_type": "m",
                "total_bytes": 0, "received_bytes": 0, "speed_bytes_per_sec": 0,
                "state": \(raw),
                "can_resume": false, "target_path": "p"
            }
            """
            let item = try JSONDecoder().decode(DownloadItem.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(item.state, expected,
                "AC1: state \(raw) should decode to .\(expected)")
        }
    }

    /// AC1: Encode then decode round-trip produces identical DownloadItem.
    func testDownloadItem_encodeThenDecodeRoundTrip() throws {
        let original = makeItem(
            id: 99, url: "https://dl.example.com/app.zip",
            filename: "app.zip", mimeType: "application/zip",
            totalBytes: 10_000_000, receivedBytes: 3_000_000,
            speedBytesPerSec: 1_500_000, state: .paused,
            errorDescription: "Network timeout", canResume: true,
            targetPath: "/Downloads/app.zip"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.filename, original.filename)
        XCTAssertEqual(decoded.mimeType, original.mimeType)
        XCTAssertEqual(decoded.totalBytes, original.totalBytes)
        XCTAssertEqual(decoded.receivedBytes, original.receivedBytes)
        XCTAssertEqual(decoded.speedBytesPerSec, original.speedBytesPerSec)
        XCTAssertEqual(decoded.state, original.state)
        XCTAssertEqual(decoded.errorDescription, original.errorDescription)
        XCTAssertEqual(decoded.canResume, original.canResume)
        XCTAssertEqual(decoded.targetPath, original.targetPath)
    }

    /// AC1: JSON array decodes correctly (as used by getAll).
    func testDownloadItem_decodesJSONArray() throws {
        let json = """
        [
            {"id":1,"url":"u1","filename":"f1","mime_type":"m1",
             "total_bytes":100,"received_bytes":50,"speed_bytes_per_sec":10,
             "state":0,"can_resume":true,"target_path":"p1"},
            {"id":2,"url":"u2","filename":"f2","mime_type":"m2",
             "total_bytes":200,"received_bytes":200,"speed_bytes_per_sec":0,
             "state":2,"can_resume":false,"target_path":"p2"}
        ]
        """
        let items = try JSONDecoder().decode([DownloadItem].self, from: json.data(using: .utf8)!)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, 1)
        XCTAssertEqual(items[0].state, .inProgress)
        XCTAssertEqual(items[1].id, 2)
        XCTAssertEqual(items[1].state, .complete)
    }

    /// AC1: CodingKeys encode to snake_case (validates key naming in output JSON).
    func testDownloadItem_encodesToSnakeCaseKeys() throws {
        let item = makeItem()
        let data = try JSONEncoder().encode(item)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify snake_case keys are present
        XCTAssertNotNil(dict["mime_type"], "AC1: Should encode as mime_type")
        XCTAssertNotNil(dict["total_bytes"], "AC1: Should encode as total_bytes")
        XCTAssertNotNil(dict["received_bytes"], "AC1: Should encode as received_bytes")
        XCTAssertNotNil(dict["speed_bytes_per_sec"], "AC1: Should encode as speed_bytes_per_sec")
        XCTAssertNotNil(dict["can_resume"], "AC1: Should encode as can_resume")
        XCTAssertNotNil(dict["target_path"], "AC1: Should encode as target_path")

        // Verify camelCase keys are NOT present
        XCTAssertNil(dict["mimeType"], "AC1: Should NOT encode as mimeType (camelCase)")
        XCTAssertNil(dict["totalBytes"], "AC1: Should NOT encode as totalBytes (camelCase)")
    }

    // =========================================================================
    // MARK: - AC1: DownloadItemVM update(from:) 字段更新
    // =========================================================================

    /// AC1: update(from:) updates all mutable fields correctly.
    func testDownloadItemVM_updateFromItem() {
        MainActor.assumeIsolated {
            let initial = makeItem(
                id: 1, filename: "file.zip",
                totalBytes: 1_000_000, receivedBytes: 100_000,
                speedBytesPerSec: 50_000, state: .inProgress,
                errorDescription: nil, canResume: true
            )
            let vm = DownloadItemVM(from: initial)

            // Verify initial state
            XCTAssertEqual(vm.state, .inProgress)
            XCTAssertEqual(vm.receivedBytes, 100_000)
            XCTAssertNil(vm.errorDescription)
            XCTAssertTrue(vm.canResume)

            // Update with new values
            let updated = makeItem(
                id: 1, filename: "file.zip",
                totalBytes: 1_000_000, receivedBytes: 750_000,
                speedBytesPerSec: 200_000, state: .paused,
                errorDescription: "Paused by user", canResume: true
            )
            vm.update(from: updated)

            XCTAssertEqual(vm.state, .paused,
                "AC1: update(from:) should update state")
            XCTAssertEqual(vm.receivedBytes, 750_000,
                "AC1: update(from:) should update receivedBytes")
            XCTAssertEqual(vm.totalBytes, 1_000_000,
                "AC1: update(from:) should update totalBytes")
            XCTAssertEqual(vm.errorDescription, "Paused by user",
                "AC1: update(from:) should update errorDescription")
            XCTAssertTrue(vm.canResume,
                "AC1: update(from:) should update canResume")
        }
    }

    /// AC1: update(from:) clears errorDescription when new item has nil.
    func testDownloadItemVM_updateClearsError() {
        MainActor.assumeIsolated {
            let withError = makeItem(
                id: 1, state: .interrupted,
                errorDescription: "Connection lost", canResume: true
            )
            let vm = DownloadItemVM(from: withError)
            XCTAssertEqual(vm.errorDescription, "Connection lost")

            let resumed = makeItem(
                id: 1, state: .inProgress,
                errorDescription: nil, canResume: true
            )
            vm.update(from: resumed)

            XCTAssertNil(vm.errorDescription,
                "AC1: update(from:) should clear errorDescription when nil")
            XCTAssertEqual(vm.state, .inProgress)
        }
    }

    // =========================================================================
    // MARK: - AC1: DownloadItemVM progress 计算
    // =========================================================================

    /// AC1: progress is calculated correctly as receivedBytes / totalBytes.
    func testDownloadItemVM_progressCalculation() {
        MainActor.assumeIsolated {
            let item = makeItem(totalBytes: 1_000_000, receivedBytes: 500_000)
            let vm = DownloadItemVM(from: item)
            XCTAssertEqual(vm.progress, 0.5, accuracy: 0.001,
                "AC1: progress should be receivedBytes / totalBytes = 0.5")
        }
    }

    /// AC1: progress is 0 when totalBytes is 0 (unknown total size).
    func testDownloadItemVM_progressZeroTotalBytes() {
        MainActor.assumeIsolated {
            let item = makeItem(totalBytes: 0, receivedBytes: 500_000)
            let vm = DownloadItemVM(from: item)
            XCTAssertEqual(vm.progress, 0.0,
                "AC1: progress should be 0 when totalBytes is 0 (avoid div-by-zero)")
        }
    }

    /// AC1: progress is 1.0 when download is complete.
    func testDownloadItemVM_progressComplete() {
        MainActor.assumeIsolated {
            let item = makeItem(
                totalBytes: 2_000_000, receivedBytes: 2_000_000,
                state: .complete
            )
            let vm = DownloadItemVM(from: item)
            XCTAssertEqual(vm.progress, 1.0, accuracy: 0.001,
                "AC1: progress should be 1.0 when receivedBytes == totalBytes")
        }
    }

    /// AC1: progress updates correctly after update(from:).
    func testDownloadItemVM_progressUpdatesOnUpdate() {
        MainActor.assumeIsolated {
            let initial = makeItem(totalBytes: 1_000_000, receivedBytes: 0)
            let vm = DownloadItemVM(from: initial)
            XCTAssertEqual(vm.progress, 0.0, accuracy: 0.001)

            let updated = makeItem(totalBytes: 1_000_000, receivedBytes: 250_000)
            vm.update(from: updated)
            XCTAssertEqual(vm.progress, 0.25, accuracy: 0.001,
                "AC1: progress should update to 0.25 after update(from:)")
        }
    }

    // =========================================================================
    // MARK: - AC6: DownloadItemVM formatSpeed 速度格式化
    // =========================================================================

    /// AC6: formatSpeed returns B/s for small values.
    func testDownloadItemVM_formatSpeedBytes() {
        XCTAssertEqual(DownloadItemVM.formatSpeed(0), "0 B/s",
            "AC6: 0 bytes should show 0 B/s")
        XCTAssertEqual(DownloadItemVM.formatSpeed(500), "500 B/s",
            "AC6: 500 bytes should show 500 B/s")
        XCTAssertEqual(DownloadItemVM.formatSpeed(1023), "1023 B/s",
            "AC6: 1023 bytes should show 1023 B/s (below KB threshold)")
    }

    /// AC6: formatSpeed returns KB/s for kilobyte range.
    func testDownloadItemVM_formatSpeedKilobytes() {
        XCTAssertEqual(DownloadItemVM.formatSpeed(1024), "1.0 KB/s",
            "AC6: 1024 bytes should show 1.0 KB/s")
        XCTAssertEqual(DownloadItemVM.formatSpeed(512_000), "500.0 KB/s",
            "AC6: 512000 bytes should show 500.0 KB/s")
        XCTAssertEqual(DownloadItemVM.formatSpeed(1_048_575), "1024.0 KB/s",
            "AC6: Just below 1MB should still show KB/s")
    }

    /// AC6: formatSpeed returns MB/s for megabyte range.
    func testDownloadItemVM_formatSpeedMegabytes() {
        XCTAssertEqual(DownloadItemVM.formatSpeed(1_048_576), "1.0 MB/s",
            "AC6: 1048576 bytes should show 1.0 MB/s")
        XCTAssertEqual(DownloadItemVM.formatSpeed(10_485_760), "10.0 MB/s",
            "AC6: 10MB/s")
        XCTAssertEqual(DownloadItemVM.formatSpeed(104_857_600), "100.0 MB/s",
            "AC6: 100MB/s")
    }

    /// AC6: formatSpeed boundary between KB and MB.
    func testDownloadItemVM_formatSpeedKBtMBBoundary() {
        // 1024 * 1024 - 1 = 1048575 → still KB/s
        XCTAssertTrue(DownloadItemVM.formatSpeed(1_048_575).hasSuffix("KB/s"),
            "AC6: 1048575 should use KB/s")
        // 1024 * 1024 = 1048576 → MB/s
        XCTAssertTrue(DownloadItemVM.formatSpeed(1_048_576).hasSuffix("MB/s"),
            "AC6: 1048576 should use MB/s")
    }

    // =========================================================================
    // MARK: - AC3: DownloadViewModel onDownloadCreated — 新增 item 到列表顶部
    // =========================================================================

    /// AC3: onDownloadCreated inserts new item at index 0 (newest at top).
    func testViewModel_onDownloadCreated_insertsAtTop() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            let item1 = makeItem(id: 1, filename: "first.zip")
            vm.onDownloadCreated(item1)

            XCTAssertEqual(vm.items.count, 1, "AC3: Should have 1 item after first create")
            XCTAssertEqual(vm.items[0].filename, "first.zip")

            let item2 = makeItem(id: 2, filename: "second.zip")
            vm.onDownloadCreated(item2)

            XCTAssertEqual(vm.items.count, 2, "AC3: Should have 2 items after second create")
            XCTAssertEqual(vm.items[0].filename, "second.zip",
                "AC3: Newest item should be at index 0")
            XCTAssertEqual(vm.items[1].filename, "first.zip",
                "AC3: Older item should shift to index 1")
        }
    }

    /// AC3: onDownloadCreated with duplicate id updates existing instead of inserting.
    func testViewModel_onDownloadCreated_deduplicatesById() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            let item = makeItem(id: 1, filename: "file.zip", receivedBytes: 100)
            vm.onDownloadCreated(item)
            XCTAssertEqual(vm.items.count, 1)

            // Create again with same id — should update, not duplicate
            let updated = makeItem(id: 1, filename: "file.zip", receivedBytes: 500)
            vm.onDownloadCreated(updated)
            XCTAssertEqual(vm.items.count, 1,
                "AC3: Duplicate id should update existing, not insert new")
            XCTAssertEqual(vm.items[0].receivedBytes, 500,
                "AC3: Duplicate id should update receivedBytes")
        }
    }

    // =========================================================================
    // MARK: - AC2/AC3: DownloadViewModel onDownloadUpdated — 更新已有 item
    // =========================================================================

    /// AC2+AC3: onDownloadUpdated updates existing item fields.
    func testViewModel_onDownloadUpdated_updatesExisting() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Create first
            let item = makeItem(id: 1, receivedBytes: 100_000, state: .inProgress)
            vm.onDownloadCreated(item)

            // Update with new progress
            let updated = makeItem(id: 1, receivedBytes: 750_000, state: .inProgress)
            vm.onDownloadUpdated(updated)
        }
        pump(0.2)  // Allow throttle to pass

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items.count, 1,
                "AC3: Update should not create new item")
            XCTAssertEqual(vm.items[0].receivedBytes, 750_000,
                "AC2: receivedBytes should be updated")
        }
    }

    /// AC2+AC3: onDownloadUpdated with unknown id upserts (creates new).
    func testViewModel_onDownloadUpdated_upsertsUnknownId() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Update for an id that was never created
            let item = makeItem(id: 99, filename: "unknown.zip")
            vm.onDownloadUpdated(item)
        }
        pump(0.2)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items.count, 1,
                "AC3: Update for unknown id should upsert (insert)")
            XCTAssertEqual(vm.items[0].id, 99)
            XCTAssertEqual(vm.items[0].filename, "unknown.zip")
        }
    }

    // =========================================================================
    // MARK: - AC3: DownloadViewModel onDownloadRemoved — 移除 item
    // =========================================================================

    /// AC3: onDownloadRemoved removes the item from the list.
    func testViewModel_onDownloadRemoved_removesItem() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, filename: "a.zip"))
            vm.onDownloadCreated(makeItem(id: 2, filename: "b.zip"))
            vm.onDownloadCreated(makeItem(id: 3, filename: "c.zip"))
            XCTAssertEqual(vm.items.count, 3)

            vm.onDownloadRemoved(id: 2)

            XCTAssertEqual(vm.items.count, 2,
                "AC3: Should have 2 items after removing one")
            XCTAssertNil(vm.items.first(where: { $0.id == 2 }),
                "AC3: Removed item should not exist in list")
            // Remaining items are intact
            XCTAssertNotNil(vm.items.first(where: { $0.id == 1 }))
            XCTAssertNotNil(vm.items.first(where: { $0.id == 3 }))
        }
    }

    /// AC3: onDownloadRemoved with non-existent id is a no-op.
    func testViewModel_onDownloadRemoved_nonexistentIsNoop() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1))
            XCTAssertEqual(vm.items.count, 1)

            vm.onDownloadRemoved(id: 999)

            XCTAssertEqual(vm.items.count, 1,
                "AC3: Removing non-existent id should not affect list")
        }
    }

    // =========================================================================
    // MARK: - AC4: activeCount 准确反映活跃下载数
    // =========================================================================

    /// AC4: activeCount counts only .inProgress items.
    func testViewModel_activeCount_onlyCountsInProgress() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .paused))
            vm.onDownloadCreated(makeItem(id: 3, state: .complete))
            vm.onDownloadCreated(makeItem(id: 4, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 5, state: .cancelled))
            vm.onDownloadCreated(makeItem(id: 6, state: .interrupted))

            XCTAssertEqual(vm.activeCount, 2,
                "AC4: activeCount should only count .inProgress items (2 out of 6)")
        }
    }

    /// AC4: activeCount updates when item state changes.
    func testViewModel_activeCount_updatesOnStateChange() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .inProgress))
            XCTAssertEqual(vm.activeCount, 2, "AC4: Initially 2 active")

            // Item 1 completes
            vm.onDownloadCreated(makeItem(id: 1, state: .complete))
            XCTAssertEqual(vm.activeCount, 1,
                "AC4: activeCount should decrease to 1 after completion")

            // Item 2 paused
            vm.onDownloadCreated(makeItem(id: 2, state: .paused))
            XCTAssertEqual(vm.activeCount, 0,
                "AC4: activeCount should be 0 when all paused/complete")
        }
    }

    /// AC4: activeCount is 0 when list is empty.
    func testViewModel_activeCount_emptyList() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.activeCount, 0,
                "AC4: activeCount should be 0 for empty list")
        }
    }

    /// AC4: activeCount updates after onDownloadRemoved.
    func testViewModel_activeCount_updatesAfterRemoval() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .inProgress))
            XCTAssertEqual(vm.activeCount, 2)

            vm.onDownloadRemoved(id: 1)
            XCTAssertEqual(vm.activeCount, 1,
                "AC4: activeCount should decrease after removing an active item")
        }
    }

    // =========================================================================
    // MARK: - AC3: DownloadViewModel clearCompleted — 清除非活跃项
    // =========================================================================

    /// AC3: clearCompleted removes completed, cancelled, and interrupted items.
    func testViewModel_clearCompleted_removesNonActive() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .paused))
            vm.onDownloadCreated(makeItem(id: 3, state: .complete))
            vm.onDownloadCreated(makeItem(id: 4, state: .cancelled))
            vm.onDownloadCreated(makeItem(id: 5, state: .interrupted))
            XCTAssertEqual(vm.items.count, 5)

            vm.clearCompleted()

            XCTAssertEqual(vm.items.count, 2,
                "AC3: clearCompleted should keep only inProgress and paused items")
            let remainingIds = Set(vm.items.map { $0.id })
            XCTAssertTrue(remainingIds.contains(1),
                "AC3: inProgress item should remain")
            XCTAssertTrue(remainingIds.contains(2),
                "AC3: paused item should remain")
            XCTAssertFalse(remainingIds.contains(3),
                "AC3: complete item should be removed")
            XCTAssertFalse(remainingIds.contains(4),
                "AC3: cancelled item should be removed")
            XCTAssertFalse(remainingIds.contains(5),
                "AC3: interrupted item should be removed")
        }
    }

    /// AC3+AC4: clearCompleted updates activeCount.
    func testViewModel_clearCompleted_updatesActiveCount() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .complete))
            vm.onDownloadCreated(makeItem(id: 3, state: .complete))
            XCTAssertEqual(vm.activeCount, 1)

            vm.clearCompleted()

            XCTAssertEqual(vm.activeCount, 1,
                "AC4: activeCount should remain accurate after clearCompleted")
            XCTAssertEqual(vm.items.count, 1)
        }
    }

    /// AC3: clearCompleted with all items active is a no-op.
    func testViewModel_clearCompleted_allActiveIsNoop() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .paused))
            XCTAssertEqual(vm.items.count, 2)

            vm.clearCompleted()

            XCTAssertEqual(vm.items.count, 2,
                "AC3: clearCompleted should not remove inProgress or paused items")
        }
    }

    /// AC3: clearCompleted with empty list is a no-op (no crash).
    func testViewModel_clearCompleted_emptyListNoCrash() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items.count, 0)
            vm.clearCompleted()  // Should not crash
            XCTAssertEqual(vm.items.count, 0,
                "AC3: clearCompleted on empty list should be a no-op")
        }
    }

    // =========================================================================
    // MARK: - AC5: 100ms 节流验证
    // =========================================================================

    /// AC5: Rapid updates within 100ms are throttled — only first executes immediately.
    func testViewModel_throttle_rapidUpdatesThrottled() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Create initial item
            vm.onDownloadCreated(makeItem(id: 1, receivedBytes: 0, state: .inProgress))
            XCTAssertEqual(vm.items[0].receivedBytes, 0)

            // First update — should execute immediately (no prior lastUpdateTime)
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 100))
        }
        pump(0.05)  // 50ms — not enough for throttle to fire

        MainActor.assumeIsolated {
            // First update went through immediately
            XCTAssertEqual(vm.items[0].receivedBytes, 100,
                "AC5: First update should execute immediately")

            // Rapid second update within 100ms — should be deferred
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 200))
        }
        pump(0.05)  // Only 50ms since first update

        MainActor.assumeIsolated {
            // The second update may still be pending (100ms not elapsed)
            // After waiting for the throttle to fire, it should apply
        }
        pump(0.15)  // Wait for deferred update to fire (100ms sleep + margin)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items[0].receivedBytes, 200,
                "AC5: Deferred update should eventually apply after 100ms")
        }
    }

    /// AC5: Updates separated by > 100ms all execute immediately.
    func testViewModel_throttle_separatedUpdatesNotThrottled() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, receivedBytes: 0, state: .inProgress))
        }

        // First update
        MainActor.assumeIsolated {
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 100))
        }
        pump(0.15)  // Wait > 100ms

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items[0].receivedBytes, 100)
        }

        // Second update after > 100ms gap
        MainActor.assumeIsolated {
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 500))
        }
        pump(0.15)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items[0].receivedBytes, 500,
                "AC5: Updates separated by > 100ms should execute immediately")
        }
    }

    /// AC5: Throttle is per-item — concurrent downloads don't block each other.
    func testViewModel_throttle_perItemIndependent() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, receivedBytes: 0, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, receivedBytes: 0, state: .inProgress))

            // First update for item 1 — immediate
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 100))
            // First update for item 2 — also immediate (independent throttle)
            vm.onDownloadUpdated(makeItem(id: 2, receivedBytes: 200))
        }
        pump(0.15)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items.first(where: { $0.id == 1 })?.receivedBytes, 100,
                "AC5: Item 1 update should execute independently")
            XCTAssertEqual(vm.items.first(where: { $0.id == 2 })?.receivedBytes, 200,
                "AC5: Item 2 update should execute independently")
        }
    }

    // =========================================================================
    // MARK: - AC6: 速度计算 (ring buffer)
    // =========================================================================

    /// AC6: Speed uses host-provided value on first sample (insufficient history).
    func testDownloadItemVM_speedUsesHostValueInitially() {
        MainActor.assumeIsolated {
            let item = makeItem(speedBytesPerSec: 256_000)
            let vm = DownloadItemVM(from: item)

            XCTAssertEqual(vm.speed, "250.0 KB/s",
                "AC6: Initial speed should use host-provided speedBytesPerSec")
        }
    }

    /// AC6: Speed string from init uses formatSpeed correctly.
    func testDownloadItemVM_speedFormattingOnInit() {
        MainActor.assumeIsolated {
            let item = makeItem(speedBytesPerSec: 2_097_152)  // 2 MB/s
            let vm = DownloadItemVM(from: item)
            XCTAssertEqual(vm.speed, "2.0 MB/s",
                "AC6: 2MB/s should format correctly on init")
        }
    }

    // =========================================================================
    // MARK: - DownloadItemVM init verification
    // =========================================================================

    /// Verify all fields are correctly initialized from DownloadItem.
    func testDownloadItemVM_initFromItem() {
        MainActor.assumeIsolated {
            let item = makeItem(
                id: 42, url: "https://dl.example.com/app.dmg",
                filename: "app.dmg", mimeType: "application/x-apple-diskimage",
                totalBytes: 5_000_000, receivedBytes: 1_250_000,
                speedBytesPerSec: 500_000, state: .inProgress,
                errorDescription: nil, canResume: true,
                targetPath: "/Downloads/app.dmg"
            )
            let vm = DownloadItemVM(from: item)

            XCTAssertEqual(vm.id, 42)
            XCTAssertEqual(vm.filename, "app.dmg")
            XCTAssertEqual(vm.url, "https://dl.example.com/app.dmg")
            XCTAssertEqual(vm.targetPath, "/Downloads/app.dmg")
            XCTAssertEqual(vm.state, .inProgress)
            XCTAssertEqual(vm.receivedBytes, 1_250_000)
            XCTAssertEqual(vm.totalBytes, 5_000_000)
            XCTAssertEqual(vm.progress, 0.25, accuracy: 0.001)
            XCTAssertEqual(vm.speed, "488.3 KB/s")
            XCTAssertNil(vm.errorDescription)
            XCTAssertTrue(vm.canResume)
        }
    }

    // =========================================================================
    // MARK: - DownloadViewModel removeEntry (optimistic removal)
    // =========================================================================

    /// removeEntry should remove item from list immediately (optimistic UI).
    func testViewModel_removeEntry_optimisticRemoval() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, filename: "a.zip"))
            vm.onDownloadCreated(makeItem(id: 2, filename: "b.zip"))
            XCTAssertEqual(vm.items.count, 2)

            vm.removeEntry(id: 1)

            XCTAssertEqual(vm.items.count, 1,
                "removeEntry should immediately remove item from list")
            XCTAssertEqual(vm.items[0].id, 2,
                "Remaining item should be the one not removed")
        }
    }

    // =========================================================================
    // MARK: - Integration scenarios
    // =========================================================================

    /// Full lifecycle: create → update → complete → clearCompleted
    func testViewModel_fullLifecycle() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // 1. Download created
            vm.onDownloadCreated(makeItem(
                id: 1, filename: "video.mp4",
                totalBytes: 10_000_000, receivedBytes: 0,
                state: .inProgress
            ))
            XCTAssertEqual(vm.items.count, 1)
            XCTAssertEqual(vm.activeCount, 1)
            XCTAssertEqual(vm.items[0].progress, 0.0, accuracy: 0.001)
        }

        // 2. Progress update
        MainActor.assumeIsolated {
            vm.onDownloadUpdated(makeItem(
                id: 1, filename: "video.mp4",
                totalBytes: 10_000_000, receivedBytes: 5_000_000,
                state: .inProgress
            ))
        }
        pump(0.15)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items[0].receivedBytes, 5_000_000)
            XCTAssertEqual(vm.items[0].progress, 0.5, accuracy: 0.001)
            XCTAssertEqual(vm.activeCount, 1)
        }

        // 3. Download completes
        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(
                id: 1, filename: "video.mp4",
                totalBytes: 10_000_000, receivedBytes: 10_000_000,
                state: .complete
            ))
            XCTAssertEqual(vm.activeCount, 0,
                "activeCount should be 0 after completion")
            XCTAssertEqual(vm.items[0].state, .complete)
            XCTAssertEqual(vm.items[0].progress, 1.0, accuracy: 0.001)
        }

        // 4. Clear completed
        MainActor.assumeIsolated {
            vm.clearCompleted()
            XCTAssertTrue(vm.items.isEmpty,
                "clearCompleted should remove the completed item")
            XCTAssertEqual(vm.activeCount, 0)
        }
    }

    /// Multiple concurrent downloads: each maintains independent state.
    func testViewModel_multipleConcurrentDownloads() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, filename: "file1.zip", state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, filename: "file2.zip", state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 3, filename: "file3.zip", state: .inProgress))
            XCTAssertEqual(vm.items.count, 3)
            XCTAssertEqual(vm.activeCount, 3)

            // Complete one
            vm.onDownloadCreated(makeItem(id: 2, filename: "file2.zip", state: .complete))
            XCTAssertEqual(vm.activeCount, 2)

            // Pause another
            vm.onDownloadCreated(makeItem(id: 3, filename: "file3.zip", state: .paused))
            XCTAssertEqual(vm.activeCount, 1)

            // Remove the completed one
            vm.onDownloadRemoved(id: 2)
            XCTAssertEqual(vm.items.count, 2)
            XCTAssertEqual(vm.activeCount, 1)

            // Verify remaining states
            XCTAssertEqual(vm.items.first(where: { $0.id == 1 })?.state, .inProgress)
            XCTAssertEqual(vm.items.first(where: { $0.id == 3 })?.state, .paused)
        }
    }

    // =========================================================================
    // MARK: - AC6: Speed ring buffer 3-second window
    // =========================================================================

    /// AC6: Speed ring buffer uses computed speed (not host value) when samples
    /// span >0.1s. Verifies the ring buffer path in update(from:).
    func testDownloadItemVM_speedRingBuffer_overridesHostSpeed() {
        // We need vm to survive across pump() calls, so declare outside the block.
        var vm: DownloadItemVM!

        MainActor.assumeIsolated {
            let initial = makeItem(
                id: 1, totalBytes: 10_000_000, receivedBytes: 0,
                speedBytesPerSec: 0, state: .inProgress
            )
            vm = DownloadItemVM(from: initial)

            // First update: adds first ring buffer sample at receivedBytes = 0
            let update1 = makeItem(
                id: 1, totalBytes: 10_000_000, receivedBytes: 0,
                speedBytesPerSec: 0, state: .inProgress
            )
            vm.update(from: update1)
        }

        // Wait >150ms so delta time between first and next sample exceeds 0.1s threshold
        pump(0.2)

        MainActor.assumeIsolated {
            // Second update with 1MB received. Host reports 0 speed, but ring buffer
            // should compute ~1MB / 0.2s ≈ 5MB/s (actual value varies by timing).
            // The key assertion: speed should NOT be "0 B/s" because the ring buffer
            // computes a positive value from the byte delta.
            let update2 = makeItem(
                id: 1, totalBytes: 10_000_000, receivedBytes: 1_000_000,
                speedBytesPerSec: 0, state: .inProgress
            )
            vm.update(from: update2)

            // Ring buffer now has 2 samples with >0.1s gap → computed speed used.
            // Host says 0, but computed speed is ~1MB/0.2s. The speed string should
            // NOT be "0 B/s" — it should show a positive computed value.
            XCTAssertNotEqual(vm.speed, "0 B/s",
                "AC6: Ring buffer should override host speed=0 with computed positive value")
            // Verify it's in KB/s or MB/s range (1MB over ~0.2s ≈ 4-6 MB/s)
            XCTAssertTrue(vm.speed.hasSuffix("MB/s") || vm.speed.hasSuffix("KB/s"),
                "AC6: Computed speed from ring buffer should show KB/s or MB/s, got: \(vm.speed)")
        }

        // Now test the 3-second window pruning: wait >3 seconds, then update.
        // After 3s, old samples are pruned. With only one remaining sample,
        // delta time will be ~0 → falls back to host-provided speed.
        pump(3.1)

        MainActor.assumeIsolated {
            // Update with host speed = 50 KB/s. After 3s, ring buffer old samples
            // are pruned. The new sample alone means delta time ≈ 0 from the only
            // remaining sample → condition `now - first.time > 0.1` may be false
            // → falls back to host-provided speed.
            let update3 = makeItem(
                id: 1, totalBytes: 10_000_000, receivedBytes: 2_000_000,
                speedBytesPerSec: 51_200, state: .inProgress
            )
            vm.update(from: update3)

            // The ring buffer pruned samples older than 3s. The update3 sample is the
            // only one. Since there's only one sample (it is both first and latest),
            // delta time = 0 → falls back to host-provided speedBytesPerSec = 51200.
            XCTAssertEqual(vm.speed, "50.0 KB/s",
                "AC6: After 3s window expires, ring buffer should fall back to host-provided speed")
        }
    }

    // =========================================================================
    // MARK: - AC5: Removed after pending throttled update — no resurrection
    // =========================================================================

    /// AC5: When a throttled (deferred) update is pending and the same id is removed,
    /// the pending update must be cancelled — the item must NOT reappear.
    func testViewModel_removeCancelsPendingThrottledUpdate() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Create item
            vm.onDownloadCreated(makeItem(id: 1, receivedBytes: 0, state: .inProgress))
            XCTAssertEqual(vm.items.count, 1)

            // First update — executes immediately (sets lastUpdateTime)
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 100))
        }
        // Small pump to let first update apply
        pump(0.05)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items[0].receivedBytes, 100,
                "First update should apply immediately")

            // Second update within 100ms — gets DEFERRED (pending Task)
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 500))
            // The deferred update is now scheduled but hasn't fired yet.

            // Immediately remove the item BEFORE the deferred update fires
            vm.onDownloadRemoved(id: 1)
            XCTAssertEqual(vm.items.count, 0,
                "Item should be removed immediately")
        }

        // Wait long enough for any pending deferred update to fire (200ms > 100ms throttle)
        pump(0.3)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items.count, 0,
                "AC5: Removed item must NOT be resurrected by a pending throttled update")
        }
    }

    /// AC5: removeEntry (optimistic) also cancels pending throttled updates.
    func testViewModel_removeEntryCancelsPendingThrottledUpdate() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, receivedBytes: 0, state: .inProgress))

            // First update — immediate
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 100))
        }
        pump(0.05)

        MainActor.assumeIsolated {
            // Second update — deferred (within 100ms of first)
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 500))

            // Optimistic removal before deferred update fires
            vm.removeEntry(id: 1)
            XCTAssertEqual(vm.items.count, 0)
        }

        pump(0.3)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items.count, 0,
                "AC5: removeEntry should cancel pending updates — item must not reappear")
        }
    }

    // =========================================================================
    // MARK: - AC5: Throttle suppression verification
    // =========================================================================

    /// AC5: During the throttle window (<100ms), the second update is definitively
    /// NOT applied — the item retains the first update's value until the deferred
    /// Task fires after 100ms.
    func testViewModel_throttle_suppressionPhaseVerified() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, receivedBytes: 0, state: .inProgress))

            // First update — executes immediately (no prior lastUpdateTime)
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 100))
        }
        // Brief pump to process the immediate update
        pump(0.02)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items[0].receivedBytes, 100,
                "AC5: First update should execute immediately")

            // Second update within 100ms — should be DEFERRED, not applied
            vm.onDownloadUpdated(makeItem(id: 1, receivedBytes: 999))
        }

        // Pump only 30ms — well within the 100ms throttle window
        pump(0.03)

        MainActor.assumeIsolated {
            // KEY ASSERTION: the deferred update has NOT fired yet.
            // The item should still show receivedBytes = 100 (from first update),
            // NOT 999 (from the suppressed second update).
            XCTAssertEqual(vm.items[0].receivedBytes, 100,
                "AC5: Second update within 100ms must be suppressed — value should still be 100")
        }

        // Now wait for the deferred Task to fire (100ms sleep in Task + margin)
        pump(0.2)

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.items[0].receivedBytes, 999,
                "AC5: Deferred update should apply after throttle window expires")
        }
    }

    // =========================================================================
    // MARK: - Phase 4: formatBytes 字节格式化
    // =========================================================================

    /// Phase4-AC4: formatBytes returns "B" for values below 1 KB.
    func testFormatBytes_bytesRange() {
        XCTAssertEqual(DownloadItemVM.formatBytes(0), "0 B",
            "0 bytes should display as 0 B")
        XCTAssertEqual(DownloadItemVM.formatBytes(1), "1 B",
            "1 byte should display as 1 B")
        XCTAssertEqual(DownloadItemVM.formatBytes(512), "512 B",
            "512 bytes should display as 512 B")
        XCTAssertEqual(DownloadItemVM.formatBytes(1023), "1023 B",
            "1023 bytes (just below KB) should display as 1023 B")
    }

    /// Phase4-AC4: formatBytes returns "KB" for values in [1024, 1MB).
    func testFormatBytes_kilobytesRange() {
        XCTAssertEqual(DownloadItemVM.formatBytes(1024), "1.0 KB",
            "Exactly 1 KB should display as 1.0 KB")
        XCTAssertEqual(DownloadItemVM.formatBytes(1536), "1.5 KB",
            "1.5 KB")
        XCTAssertEqual(DownloadItemVM.formatBytes(512_000), "500.0 KB",
            "~500 KB")
        XCTAssertEqual(DownloadItemVM.formatBytes(1_048_575), "1024.0 KB",
            "Just below 1 MB should still display as KB")
    }

    /// Phase4-AC4: formatBytes returns "MB" for values in [1MB, 1GB).
    func testFormatBytes_megabytesRange() {
        XCTAssertEqual(DownloadItemVM.formatBytes(1_048_576), "1.0 MB",
            "Exactly 1 MB should display as 1.0 MB")
        XCTAssertEqual(DownloadItemVM.formatBytes(5_242_880), "5.0 MB",
            "5 MB")
        XCTAssertEqual(DownloadItemVM.formatBytes(104_857_600), "100.0 MB",
            "100 MB")
        XCTAssertEqual(DownloadItemVM.formatBytes(1_073_741_823), "1024.0 MB",
            "Just below 1 GB should still display as MB")
    }

    /// Phase4-AC4: formatBytes returns "GB" for values >= 1 GB.
    func testFormatBytes_gigabytesRange() {
        XCTAssertEqual(DownloadItemVM.formatBytes(1_073_741_824), "1.00 GB",
            "Exactly 1 GB should display as 1.00 GB")
        XCTAssertEqual(DownloadItemVM.formatBytes(2_684_354_560), "2.50 GB",
            "2.5 GB")
        XCTAssertEqual(DownloadItemVM.formatBytes(10_737_418_240), "10.00 GB",
            "10 GB")
    }

    /// Phase4-AC4: formatBytes boundary between KB and MB.
    func testFormatBytes_KBtoMBBoundary() {
        let belowMB = DownloadItemVM.formatBytes(1_048_575)
        XCTAssertTrue(belowMB.hasSuffix("KB"),
            "1048575 bytes should use KB suffix, got: \(belowMB)")
        let atMB = DownloadItemVM.formatBytes(1_048_576)
        XCTAssertTrue(atMB.hasSuffix("MB"),
            "1048576 bytes should use MB suffix, got: \(atMB)")
    }

    /// Phase4-AC4: formatBytes boundary between MB and GB.
    func testFormatBytes_MBtoGBBoundary() {
        let belowGB = DownloadItemVM.formatBytes(1_073_741_823)
        XCTAssertTrue(belowGB.hasSuffix("MB"),
            "1073741823 bytes should use MB suffix, got: \(belowGB)")
        let atGB = DownloadItemVM.formatBytes(1_073_741_824)
        XCTAssertTrue(atGB.hasSuffix("GB"),
            "1073741824 bytes should use GB suffix, got: \(atGB)")
    }

    /// Phase4-AC4: formatBytes handles negative input gracefully.
    func testFormatBytes_negativeInput() {
        XCTAssertEqual(DownloadItemVM.formatBytes(-1), "0 B",
            "Negative bytes should display as 0 B")
        XCTAssertEqual(DownloadItemVM.formatBytes(-1024), "0 B",
            "Negative KB should display as 0 B")
    }

    // =========================================================================
    // MARK: - Phase 4: SidebarMode.downloads 枚举
    // =========================================================================

    /// Phase4-AC1: SidebarMode.downloads case exists and is distinct.
    func testSidebarMode_downloadsExists() {
        let mode: SidebarMode = .downloads
        XCTAssertEqual(mode, .downloads,
            "SidebarMode.downloads should exist and be equatable")
        XCTAssertNotEqual(mode, .tabs,
            "downloads should be distinct from tabs")
        XCTAssertNotEqual(mode, .bookmarks,
            "downloads should be distinct from bookmarks")
        XCTAssertNotEqual(mode, .history,
            "downloads should be distinct from history")
    }

    /// Phase4-AC1: toggleSidebarMode switches to .downloads and back.
    func testSidebarMode_toggleToDownloads() {
        MainActor.assumeIsolated {
            let browserVM = BrowserViewModel()
            XCTAssertEqual(browserVM.sidebarMode, .tabs,
                "Default should be .tabs")

            browserVM.toggleSidebarMode(.downloads)
            XCTAssertEqual(browserVM.sidebarMode, .downloads,
                "After toggle(.downloads), mode should be .downloads")

            browserVM.toggleSidebarMode(.downloads)
            XCTAssertEqual(browserVM.sidebarMode, .tabs,
                "Toggling .downloads again should return to .tabs")
        }
    }

    // =========================================================================
    // MARK: - Phase 4 R1: Badge activeCount 驱动测试
    // =========================================================================

    /// Badge displays activeCount. Verify activeCount reflects the correct number
    /// for various state combinations that the UI badge would bind to.
    func testViewModel_activeCount_allInProgress() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 3, state: .inProgress))

            XCTAssertEqual(vm.activeCount, 3,
                "Badge: 3 inProgress items should show activeCount = 3")
        }
    }

    /// Badge: all non-inProgress states should yield activeCount = 0.
    func testViewModel_activeCount_allNonActive() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .paused))
            vm.onDownloadCreated(makeItem(id: 2, state: .complete))
            vm.onDownloadCreated(makeItem(id: 3, state: .cancelled))
            vm.onDownloadCreated(makeItem(id: 4, state: .interrupted))

            XCTAssertEqual(vm.activeCount, 0,
                "Badge: paused/complete/cancelled/interrupted should all yield activeCount = 0")
        }
    }

    /// Badge: mixed states — activeCount only counts .inProgress.
    func testViewModel_activeCount_mixedStatesComprehensive() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // 2 inProgress, 1 each of the others
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .paused))
            vm.onDownloadCreated(makeItem(id: 3, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 4, state: .complete))
            vm.onDownloadCreated(makeItem(id: 5, state: .cancelled))
            vm.onDownloadCreated(makeItem(id: 6, state: .interrupted))
            vm.onDownloadCreated(makeItem(id: 7, state: .paused))

            XCTAssertEqual(vm.activeCount, 2,
                "Badge: only 2 out of 7 items are inProgress")
        }
    }

    /// Badge: activeCount transitions from N to 0 as all items complete.
    func testViewModel_activeCount_transitionsToZero() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .inProgress))
            XCTAssertEqual(vm.activeCount, 2, "Badge: starts at 2")

            // First completes
            vm.onDownloadCreated(makeItem(id: 1, state: .complete))
            XCTAssertEqual(vm.activeCount, 1, "Badge: down to 1")

            // Second gets cancelled
            vm.onDownloadCreated(makeItem(id: 2, state: .cancelled))
            XCTAssertEqual(vm.activeCount, 0,
                "Badge: should be 0 when no items are inProgress")
        }
    }

    /// Badge: activeCount increases when new inProgress items are added.
    func testViewModel_activeCount_increasesOnNewDownload() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            XCTAssertEqual(vm.activeCount, 0, "Badge: starts at 0")

            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            XCTAssertEqual(vm.activeCount, 1, "Badge: 1 after first download")

            vm.onDownloadCreated(makeItem(id: 2, state: .inProgress))
            XCTAssertEqual(vm.activeCount, 2, "Badge: 2 after second download")

            // Adding a completed item should not increase activeCount
            vm.onDownloadCreated(makeItem(id: 3, state: .complete))
            XCTAssertEqual(vm.activeCount, 2,
                "Badge: adding a completed item should not change activeCount")
        }
    }

    // =========================================================================
    // MARK: - Phase 4 R1: clearCompleted 按钮可见性条件
    // =========================================================================

    /// When all items are inProgress or paused, clearCompleted removes nothing.
    /// This verifies the UI condition: "clear" button should have no effect
    /// (and thus could be hidden) when only active/paused items exist.
    func testViewModel_clearCompleted_onlyInProgressAndPaused_removesNothing() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .paused))
            vm.onDownloadCreated(makeItem(id: 3, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 4, state: .paused))

            let countBefore = vm.items.count
            vm.clearCompleted()

            XCTAssertEqual(vm.items.count, countBefore,
                "clearCompleted should remove nothing when all items are inProgress/paused")
            XCTAssertEqual(vm.items.count, 4,
                "All 4 items should remain")
        }
    }

    /// Verify the condition: items that ARE clearable = not inProgress and not paused.
    /// This is the predicate the UI uses to decide whether to show the "clear" button.
    func testViewModel_hasClearableItems_predicate() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            // Only active/paused → no clearable items
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .paused))

            let clearable1 = vm.items.filter { $0.state != .inProgress && $0.state != .paused }
            XCTAssertTrue(clearable1.isEmpty,
                "No clearable items when all are inProgress/paused")

            // Add a completed item → now there's something to clear
            vm.onDownloadCreated(makeItem(id: 3, state: .complete))

            let clearable2 = vm.items.filter { $0.state != .inProgress && $0.state != .paused }
            XCTAssertEqual(clearable2.count, 1,
                "One clearable item after adding a completed download")
            XCTAssertEqual(clearable2[0].id, 3)

            // Add interrupted and cancelled → more clearable items
            vm.onDownloadCreated(makeItem(id: 4, state: .interrupted))
            vm.onDownloadCreated(makeItem(id: 5, state: .cancelled))

            let clearable3 = vm.items.filter { $0.state != .inProgress && $0.state != .paused }
            XCTAssertEqual(clearable3.count, 3,
                "Three clearable items (complete + interrupted + cancelled)")
        }
    }

    // =========================================================================
    // MARK: - Phase 4 R1: 空状态条件
    // =========================================================================

    /// When items is empty, the UI should show an empty state placeholder.
    func testViewModel_emptyState_initiallyEmpty() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            XCTAssertTrue(vm.items.isEmpty,
                "Empty state: items should be empty on init")
            XCTAssertEqual(vm.activeCount, 0,
                "Empty state: activeCount should be 0")
        }
    }

    /// After removing all items, items.isEmpty should be true (empty state visible).
    func testViewModel_emptyState_afterRemovingAll() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .inProgress))
            vm.onDownloadCreated(makeItem(id: 2, state: .complete))
            XCTAssertFalse(vm.items.isEmpty, "Not empty state: has 2 items")

            vm.onDownloadRemoved(id: 1)
            vm.onDownloadRemoved(id: 2)

            XCTAssertTrue(vm.items.isEmpty,
                "Empty state: should be true after removing all items")
            XCTAssertEqual(vm.activeCount, 0)
        }
    }

    /// After clearCompleted removes everything, items.isEmpty is true.
    func testViewModel_emptyState_afterClearCompleted() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .complete))
            vm.onDownloadCreated(makeItem(id: 2, state: .cancelled))
            vm.onDownloadCreated(makeItem(id: 3, state: .interrupted))
            XCTAssertFalse(vm.items.isEmpty)

            vm.clearCompleted()

            XCTAssertTrue(vm.items.isEmpty,
                "Empty state: all items were clearable, list should be empty now")
        }
    }

    /// items.isEmpty is false when at least one item exists.
    func testViewModel_emptyState_notEmptyWithOneItem() {
        let vm = makeVM()

        MainActor.assumeIsolated {
            vm.onDownloadCreated(makeItem(id: 1, state: .paused))
            XCTAssertFalse(vm.items.isEmpty,
                "Empty state: should NOT show when there is at least one item")
        }
    }

    // =========================================================================
    // MARK: - Phase 4 R1: formatBytes 两实现一致性
    // =========================================================================

    /// There are two formatBytes implementations:
    ///   1. DownloadItemVM.formatBytes (static method)
    ///   2. formatBytes (free function in DownloadRow.swift)
    /// They should produce the same output for positive inputs in the shared range.
    /// Known divergence: negative input and GB precision differ by design.
    func testFormatBytes_consistency_positiveRange() {
        // Test representative values across all unit ranges
        let testValues: [Int64] = [
            0, 1, 100, 512, 1023,                        // Bytes
            1024, 1536, 10_240, 512_000, 1_048_575,      // KB
            1_048_576, 5_242_880, 104_857_600,            // MB
            1_073_741_823,                                 // Just below GB
        ]

        for bytes in testValues {
            let vmResult = DownloadItemVM.formatBytes(bytes)
            let freeResult = formatBytes(bytes)
            XCTAssertEqual(vmResult, freeResult,
                "formatBytes inconsistency at \(bytes) bytes: " +
                "DownloadItemVM='\(vmResult)' vs free function='\(freeResult)'")
        }
    }

    /// Document the known divergence: negative input handling differs.
    /// DownloadItemVM.formatBytes(-1) returns "0 B", free formatBytes(-1) returns "未知".
    func testFormatBytes_consistency_negativeInputDivergence() {
        let vmNeg = DownloadItemVM.formatBytes(-1)
        let freeNeg = formatBytes(-1)

        // Document the known difference — these are NOT equal
        XCTAssertEqual(vmNeg, "0 B",
            "DownloadItemVM.formatBytes(-1) should return '0 B'")
        XCTAssertEqual(freeNeg, "未知",
            "Free formatBytes(-1) should return '未知'")
        XCTAssertNotEqual(vmNeg, freeNeg,
            "Known divergence: negative input handling differs between implementations")
    }

    /// Document the known divergence: GB precision differs.
    /// DownloadItemVM uses "%.2f GB", free function uses "%.1f GB".
    func testFormatBytes_consistency_gbPrecisionDivergence() {
        let gbValue: Int64 = 1_073_741_824  // Exactly 1 GB
        let vmGB = DownloadItemVM.formatBytes(gbValue)
        let freeGB = formatBytes(gbValue)

        XCTAssertEqual(vmGB, "1.00 GB",
            "DownloadItemVM.formatBytes uses 2 decimal places for GB")
        XCTAssertEqual(freeGB, "1.0 GB",
            "Free formatBytes uses 1 decimal place for GB")
        XCTAssertNotEqual(vmGB, freeGB,
            "Known divergence: GB formatting precision differs between implementations")
    }
}
