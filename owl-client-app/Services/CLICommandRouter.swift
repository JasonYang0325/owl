import Foundation
#if canImport(OWLBridge)
import OWLBridge
#endif

/// Protocol abstracting browser control for CLI command routing.
/// BrowserViewModel conforms to this — the router never references ViewModel directly.
@MainActor
package protocol BrowserControl {
    var activeWebviewId: UInt64 { get }
    func pageInfo(tab: Int?) -> [String: String]
    func cliNavigate(url: String)
    func cliGoBack()
    func cliGoForward()
    func cliReload()
    func navStatus() -> [String: String]
    func navEvents(limit: Int) -> [NavigationEventRecord]
    func consoleMessages(level: String?, limit: Int) -> [[String: String]]
}

/// Routes CLI requests to BrowserControl actions and StorageService calls.
/// Runs on MainActor because it accesses browser state.
@MainActor
package final class CLICommandRouter {
    private let browser: BrowserControl
    private let storageService: StorageService

    package init(browser: BrowserControl, storageService: StorageService = OWLStorageBridge()) {
        self.browser = browser
        self.storageService = storageService
    }

    package func handle(_ request: CLIRequest) async -> CLIResponse {
        switch request.cmd {
        case "page.info":
            let tabArg = request.args["tab"].flatMap { Int($0) }
            let info = browser.pageInfo(tab: tabArg)
            return .success(id: request.id, data: info)

        case "navigate":
            guard let url = request.args["url"], !url.isEmpty else {
                return .failure(id: request.id, error: "Missing 'url' argument")
            }
            browser.cliNavigate(url: url)
            return .success(id: request.id)

        case "back":
            browser.cliGoBack()
            return .success(id: request.id)

        case "forward":
            browser.cliGoForward()
            return .success(id: request.id)

        case "reload":
            browser.cliReload()
            return .success(id: request.id)

        // MARK: - Storage Commands

        case "cookie.list":
            do {
                let domains = try await storageService.getCookieDomains()
                // If domain filter provided, apply it
                let filtered: [CookieDomainInfo]
                if let domainFilter = request.args["domain"], !domainFilter.isEmpty {
                    filtered = domains.filter { $0.domain.localizedCaseInsensitiveContains(domainFilter) }
                } else {
                    filtered = domains
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jsonData = try encoder.encode(filtered)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                // data["result"] is pre-encoded JSON; client must print it directly
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "cookie.list failed: \(error.localizedDescription)")
            }

        case "cookie.delete":
            guard let domain = request.args["domain"], !domain.isEmpty else {
                return .failure(id: request.id, error: "Missing 'domain' argument")
            }
            do {
                let deleted = try await storageService.deleteCookies(domain: domain)
                return .success(id: request.id, data: ["deleted": String(deleted)])
            } catch {
                return .failure(id: request.id, error: "cookie.delete failed: \(error.localizedDescription)")
            }

        case "clear-data":
            guard let typesStr = request.args["types"],
                  let typesVal = UInt32(typesStr) else {
                return .failure(id: request.id, error: "Missing or invalid 'types' argument")
            }
            guard typesVal > 0, typesVal <= 0x1F else {  // kCookies|kCache|kLocalStorage|kSessionStorage|kIndexedDB
                return .failure(id: request.id, error: "Invalid data types mask")
            }
            let startTime = request.args["start_time"].flatMap { Double($0) } ?? 0
            let endTime = request.args["end_time"].flatMap { Double($0) } ?? Date().timeIntervalSince1970
            let types = StorageDataType(rawValue: typesVal)

            do {
                let ok = try await storageService.clearData(types: types, startTime: startTime, endTime: endTime)
                return .success(id: request.id, data: ["cleared": ok ? "true" : "false"])
            } catch {
                return .failure(id: request.id, error: "clear-data failed: \(error.localizedDescription)")
            }

        case "storage.usage":
            do {
                let entries = try await storageService.getStorageUsage()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jsonData = try encoder.encode(entries)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                // data["result"] is pre-encoded JSON; client must print it directly
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "storage.usage failed: \(error.localizedDescription)")
            }

        // MARK: - Bookmark Commands

        case "bookmark.add":
            guard let url = request.args["url"], !url.isEmpty else {
                return .failure(id: request.id, error: "Missing 'url' argument")
            }
            let title = request.args["title"] ?? url
            do {
                let item = try await OWLBookmarkBridge.add(title: title, url: url)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jsonData = try encoder.encode(item)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "bookmark.add failed: \(error.localizedDescription)")
            }

        case "bookmark.list":
            do {
                var items = try await OWLBookmarkBridge.getAll()
                if let query = request.args["query"], !query.isEmpty {
                    items = items.filter {
                        $0.title.localizedCaseInsensitiveContains(query) ||
                        $0.url.localizedCaseInsensitiveContains(query)
                    }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jsonData = try encoder.encode(items)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "bookmark.list failed: \(error.localizedDescription)")
            }

        case "bookmark.remove":
            guard let id = request.args["id"], !id.isEmpty else {
                return .failure(id: request.id, error: "Missing 'id' argument")
            }
            do {
                let ok = try await OWLBookmarkBridge.remove(id: id)
                return .success(id: request.id, data: ["removed": ok ? "true" : "false"])
            } catch {
                return .failure(id: request.id, error: "bookmark.remove failed: \(error.localizedDescription)")
            }

        // MARK: - History Commands

        case "history.search":
            guard let query = request.args["query"] else {
                return .failure(id: request.id, error: "Missing 'query' argument")
            }
            let maxResults = request.args["max_results"].flatMap { Int32($0) } ?? 20
            do {
                let (entries, _) = try await OWLHistoryBridge.queryByTime(
                    query: query, maxResults: maxResults, offset: 0)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jsonData = try encoder.encode(entries)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "history.search failed: \(error.localizedDescription)")
            }

        case "history.delete":
            guard let url = request.args["url"], !url.isEmpty else {
                return .failure(id: request.id, error: "Missing 'url' argument")
            }
            do {
                let ok = try await OWLHistoryBridge.delete(url: url)
                return .success(id: request.id, data: ["deleted": ok ? "true" : "false"])
            } catch {
                return .failure(id: request.id, error: "history.delete failed: \(error.localizedDescription)")
            }

        case "history.clear":
            do {
                if let startStr = request.args["start_time"],
                   let endStr = request.args["end_time"],
                   let startTime = Double(startStr),
                   let endTime = Double(endStr) {
                    let count = try await OWLHistoryBridge.deleteRange(
                        startTime: startTime, endTime: endTime)
                    return .success(id: request.id, data: ["deleted_count": String(count)])
                } else {
                    let ok = try await OWLHistoryBridge.clear()
                    return .success(id: request.id, data: ["cleared": ok ? "true" : "false"])
                }
            } catch {
                return .failure(id: request.id, error: "history.clear failed: \(error.localizedDescription)")
            }

        // MARK: - Permission Commands

        case "permission.get":
            guard let origin = request.args["origin"], !origin.isEmpty else {
                return .failure(id: request.id, error: "Missing 'origin' argument")
            }
            guard let typeStr = request.args["type"],
                  let permType = Self.parsePermissionType(typeStr) else {
                return .failure(id: request.id, error: "Invalid 'type'. Use: camera, microphone, geolocation, notifications")
            }
            do {
                let status = try await Self.getPermission(origin: origin, type: permType)
                let statusName = Self.permissionStatusName(status)
                return .success(id: request.id, data: [
                    "origin": origin,
                    "type": typeStr,
                    "status": statusName,
                ])
            } catch {
                return .failure(id: request.id, error: "permission.get failed: \(error.localizedDescription)")
            }

        case "permission.set":
            guard let origin = request.args["origin"], !origin.isEmpty else {
                return .failure(id: request.id, error: "Missing 'origin' argument")
            }
            guard let typeStr = request.args["type"],
                  let permType = Self.parsePermissionType(typeStr) else {
                return .failure(id: request.id, error: "Invalid 'type'. Use: camera, microphone, geolocation, notifications")
            }
            guard let statusStr = request.args["status"],
                  let permStatus = Self.parsePermissionStatus(statusStr) else {
                return .failure(id: request.id, error: "Invalid 'status'. Use: granted, denied, ask")
            }
            OWLPermissionSettingsBridge.setPermission(
                origin: origin, type: permType, status: permStatus)
            return .success(id: request.id)

        case "permission.list":
            do {
                let items = try await OWLPermissionSettingsBridge.getAll()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jsonData = try encoder.encode(items)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "permission.list failed: \(error.localizedDescription)")
            }

        // MARK: - Download Commands

        case "download.list":
            do {
                let items = try await OWLDownloadBridge.getAll()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let jsonData = try encoder.encode(items)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "download.list failed: \(error.localizedDescription)")
            }

        case "download.pause":
            guard let idStr = request.args["id"], let id = UInt32(idStr) else {
                return .failure(id: request.id, error: "Missing or invalid 'id' argument")
            }
            OWLDownloadBridge.pause(id: id)
            return .success(id: request.id)

        case "download.resume":
            guard let idStr = request.args["id"], let id = UInt32(idStr) else {
                return .failure(id: request.id, error: "Missing or invalid 'id' argument")
            }
            OWLDownloadBridge.resume(id: id)
            return .success(id: request.id)

        case "download.cancel":
            guard let idStr = request.args["id"], let id = UInt32(idStr) else {
                return .failure(id: request.id, error: "Missing or invalid 'id' argument")
            }
            OWLDownloadBridge.cancel(id: id)
            return .success(id: request.id)

        // MARK: - Find Commands

        case "find":
            guard let query = request.args["query"], !query.isEmpty else {
                return .failure(id: request.id, error: "Missing 'query' argument")
            }
            let webviewId = browser.activeWebviewId
            guard webviewId != 0 else {
                return .failure(id: request.id, error: "No active web view")
            }
            let forward = request.args["forward"] != "0"
            let matchCase = request.args["match_case"] == "1"
            do {
                let requestId = try await Self.find(
                    webviewId: webviewId, query: query,
                    forward: forward, matchCase: matchCase)
                return .success(id: request.id, data: ["request_id": String(requestId)])
            } catch {
                return .failure(id: request.id, error: "find failed: \(error.localizedDescription)")
            }

        case "find.stop":
            let webviewId = browser.activeWebviewId
            guard webviewId != 0 else {
                return .failure(id: request.id, error: "No active web view")
            }
            #if canImport(OWLBridge)
            OWLBridge_StopFinding(webviewId, OWLBridgeStopFindAction_ClearSelection)
            #endif
            return .success(id: request.id)

        // MARK: - Zoom Commands

        case "zoom.get":
            let webviewId = browser.activeWebviewId
            guard webviewId != 0 else {
                return .failure(id: request.id, error: "No active web view")
            }
            do {
                let level = try await Self.getZoomLevel(webviewId: webviewId)
                return .success(id: request.id, data: ["level": String(level)])
            } catch {
                return .failure(id: request.id, error: "zoom.get failed: \(error.localizedDescription)")
            }

        case "zoom.set":
            guard let levelStr = request.args["level"],
                  let level = Double(levelStr) else {
                return .failure(id: request.id, error: "Missing or invalid 'level' argument")
            }
            let webviewId = browser.activeWebviewId
            guard webviewId != 0 else {
                return .failure(id: request.id, error: "No active web view")
            }
            do {
                try await Self.setZoomLevel(webviewId: webviewId, level: level)
                return .success(id: request.id, data: ["level": String(level)])
            } catch {
                return .failure(id: request.id, error: "zoom.set failed: \(error.localizedDescription)")
            }

        // MARK: - Navigation Status/Events Commands

        case "nav.status":
            let info = browser.navStatus()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let jsonData = try? encoder.encode(info),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return .success(id: request.id, data: ["result": jsonString])
            }
            return .success(id: request.id, data: info)

        case "nav.events":
            let limit = request.args["limit"].flatMap { Int($0) } ?? 20
            let events = browser.navEvents(limit: limit)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            do {
                let jsonData = try encoder.encode(events)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "nav.events failed: \(error.localizedDescription)")
            }

        // MARK: - Console Commands

        case "console.list":
            let limit = request.args["limit"].flatMap { Int($0) } ?? 50
            let clampedLimit = max(1, min(1000, limit))
            let level = request.args["level"]
            let messages = browser.consoleMessages(level: level, limit: clampedLimit)
            do {
                let jsonData = try JSONSerialization.data(
                    withJSONObject: messages,
                    options: [.sortedKeys]
                )
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                return .success(id: request.id, data: ["result": jsonString])
            } catch {
                return .failure(id: request.id, error: "console.list failed: \(error.localizedDescription)")
            }

        default:
            return .failure(id: request.id, error: "Unknown command: \(request.cmd)")
        }
    }

    // MARK: - Permission Helpers

    private static func parsePermissionType(_ str: String) -> PermissionType? {
        switch str.lowercased() {
        case "camera":        return .camera
        case "microphone", "mic": return .microphone
        case "geolocation", "geo", "location": return .geolocation
        case "notifications", "notification": return .notifications
        default: return nil
        }
    }

    private static func parsePermissionStatus(_ str: String) -> PermissionStatus? {
        switch str.lowercased() {
        case "granted", "allow":  return .granted
        case "denied", "deny", "block": return .denied
        case "ask", "prompt":     return .ask
        default: return nil
        }
    }

    private static func permissionStatusName(_ status: Int32) -> String {
        switch status {
        case 0: return "granted"
        case 1: return "denied"
        case 2: return "ask"
        default: return "unknown(\(status))"
        }
    }

    private static func getPermission(origin: String, type: PermissionType) async throws -> Int32 {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            final class Box {
                let value: CheckedContinuation<Int32, Error>
                init(_ v: CheckedContinuation<Int32, Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            origin.withCString { originPtr in
                OWLBridge_PermissionGet(originPtr, type.rawValue, { status, errorMsg, ctx in
                    let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                    if let errorMsg {
                        box.value.resume(throwing: NSError(
                            domain: "OWLPermission", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: String(cString: errorMsg)]))
                        return
                    }
                    box.value.resume(returning: status)
                }, ctx)
            }
        }
        #else
        return 2  // "ask" as default
        #endif
    }

    // MARK: - Find Helper

    private static func find(webviewId: UInt64, query: String,
                             forward: Bool, matchCase: Bool) async throws -> Int32 {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            final class Box {
                let value: CheckedContinuation<Int32, Error>
                init(_ v: CheckedContinuation<Int32, Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            query.withCString { queryPtr in
                OWLBridge_Find(webviewId, queryPtr, forward ? 1 : 0, matchCase ? 1 : 0,
                    { requestId, ctx in
                        let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                        box.value.resume(returning: requestId)
                    }, ctx)
            }
        }
        #else
        return 0
        #endif
    }

    // MARK: - Zoom Helpers

    private static func getZoomLevel(webviewId: UInt64) async throws -> Double {
        #if canImport(OWLBridge)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
            final class Box {
                let value: CheckedContinuation<Double, Error>
                init(_ v: CheckedContinuation<Double, Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_GetZoomLevel(webviewId, { level, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.value.resume(returning: level)
            }, ctx)
        }
        #else
        return 0.0
        #endif
    }

    private static func setZoomLevel(webviewId: UInt64, level: Double) async throws {
        #if canImport(OWLBridge)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class Box {
                let value: CheckedContinuation<Void, Error>
                init(_ v: CheckedContinuation<Void, Error>) { self.value = v }
            }
            let box = Box(cont)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            OWLBridge_SetZoomLevel(webviewId, level, { ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.value.resume()
            }, ctx)
        }
        #else
        // no-op
        #endif
    }
}
