import XCTest
import OWLTestKit

final class OWLIntegrationTests: XCTestCase {
    private func withHost(_ body: (AppHost) async throws -> Void) async throws {
        let host = try await AppHost.start()
        defer { host.shutdown() }
        try await body(host)
    }

    private func parseObject(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8), "Invalid UTF-8 JSON")
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any], "Expected JSON object")
    }

    private func parseArray(_ json: String) throws -> [[String: Any]] {
        let data = try XCTUnwrap(json.data(using: .utf8), "Invalid UTF-8 JSON")
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [[String: Any]], "Expected JSON array")
    }

    private func waitForJSValue(
        host: AppHost,
        expression: String,
        expected: String,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = try await host.evaluateJS(expression)
            if value == expected {
                return
            }
            await WaitHelper.sleep(0.1)
        }
        let final = try await host.evaluateJS(expression)
        XCTFail("Timed out waiting for JS value. expected=\(expected), actual=\(final), expression=\(expression)")
    }

    func testCrossLayerNavigateAndEvaluateDOM() async throws {
        try await withHost { host in
            try await host.navigateAndWait(
                "data:text/html,<title>Integration</title><input id='kw' autofocus>"
            )

            let title = try await host.evaluateJS("document.title")
            XCTAssertEqual(title, "\"Integration\"")

            try host.typeText("owl")
            await WaitHelper.sleep(0.3)
            let value = try await host.evaluateJS("document.getElementById('kw').value")
            XCTAssertEqual(value, "\"owl\"")

            XCTAssertTrue(host.currentURL.hasPrefix("data:text/html"),
                          "Expected data URL, got: \(host.currentURL)")
        }
    }

    func testCrossLayerNavigateTwiceReplacesDOM() async throws {
        try await withHost { host in
            try await host.navigateAndWait("data:text/html,<title>P1</title><div id='p1'>one</div>")
            try await host.navigateAndWait("data:text/html,<title>P2</title><div id='p2'>two</div>")

            let p2 = try await host.evaluateJS("document.getElementById('p2')?.textContent ?? 'null'")
            XCTAssertEqual(p2, "\"two\"")

            let p1 = try await host.evaluateJS("document.getElementById('p1')?.textContent ?? 'null'")
            XCTAssertEqual(p1, "\"null\"")
        }
    }

    func testCrossLayerTypeTextUpdatesInput() async throws {
        try await withHost { host in
            try await host.navigateAndWait("data:text/html,<input id='kw' autofocus>")
            try host.typeText("atlas")
            await WaitHelper.sleep(0.3)
            let value = try await host.evaluateJS("document.getElementById('kw').value")
            XCTAssertEqual(value, "\"atlas\"")
        }
    }

    func testCrossLayerFindInPageFinalCount() async throws {
        try await withHost { host in
            try await host.navigateAndWait(
                "data:text/html,<body><p>hello world</p><p>hello again</p><p>hello three</p></body>"
            )
            let result = try await host.find(query: "hello")
            XCTAssertGreaterThan(result.requestId, 0)
            XCTAssertEqual(result.matches, 3)
            XCTAssertGreaterThan(result.activeOrdinal, 0)
        }
    }

    func testCrossLayerZoomRoundTrip() async throws {
        try await withHost { host in
            try await host.navigateAndWait("data:text/html,<title>Zoom</title><h1>Zoom</h1>")
            try await host.setZoomLevel(1.0)
            await WaitHelper.sleep(0.3)
            let level = try await host.getZoomLevel()
            XCTAssertEqual(level, 1.0, accuracy: 0.01)

            try await host.setZoomLevel(0.0)
            await WaitHelper.sleep(0.3)
            let reset = try await host.getZoomLevel()
            XCTAssertEqual(reset, 0.0, accuracy: 0.01)
        }
    }

    func testCrossLayerBookmarkCRUD() async throws {
        try await withHost { host in
            let title = "Integration Bookmark"
            let url = "https://integration.example.com"
            let addedJSON = try await host.bookmarkAdd(title: title, url: url)
            let added = try parseObject(addedJSON)
            let bookmarkId = try XCTUnwrap(added["id"] as? String)
            XCTAssertEqual(added["title"] as? String, title)
            XCTAssertEqual(added["url"] as? String, url)

            let listJSON = try await host.bookmarkGetAll()
            let list = try parseArray(listJSON)
            XCTAssertTrue(list.contains { ($0["id"] as? String) == bookmarkId })

            let removed = try await host.bookmarkRemove(id: bookmarkId)
            XCTAssertTrue(removed)

            let afterJSON = try await host.bookmarkGetAll()
            let afterList = try parseArray(afterJSON)
            XCTAssertFalse(afterList.contains { ($0["id"] as? String) == bookmarkId })
        }
    }

    func testCrossLayerPermissionSetGetReset() async throws {
        try await withHost { host in
            let origin = "https://permissions.example.com"
            host.setPermission(origin: origin, type: .camera, status: .granted)
            let granted = try await host.getPermission(origin: origin, type: .camera)
            XCTAssertEqual(granted, .granted)

            host.resetPermission(origin: origin, type: .camera)
            let reset = try await host.getPermission(origin: origin, type: .camera)
            XCTAssertEqual(reset, .ask)
        }
    }

    func testCrossLayerBackForwardViaHistoryAPI() async throws {
        try await withHost { host in
            let pageA = "data:text/html,<title>PageA</title><h1 id='pg'>A</h1>"
            let pageB = "data:text/html,<title>PageB</title><h1 id='pg'>B</h1>"

            try await host.navigateAndWait(pageA)
            try await host.navigateAndWait(pageB)

            _ = try await host.evaluateJS("history.back()")
            try await waitForJSValue(host: host, expression: "document.title", expected: "\"PageA\"")

            _ = try await host.evaluateJS("history.forward()")
            try await waitForJSValue(host: host, expression: "document.title", expected: "\"PageB\"")
        }
    }
}
