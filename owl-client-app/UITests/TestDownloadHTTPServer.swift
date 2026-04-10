/// Lightweight HTTP server for download XCUITests.
///
/// Uses NWListener (Network.framework) to serve test files over HTTP so that
/// XCUITests can trigger real downloads without depending on external servers.
///
/// Usage:
/// ```swift
/// let server = TestDownloadHTTPServer()
/// let port = try server.start()
/// // navigate to http://localhost:\(port)/testfile.bin
/// server.stop()
/// ```
import Foundation
import Network

final class TestDownloadHTTPServer {

    // MARK: - Configuration

    /// A route that the server can serve.
    struct Route {
        let path: String
        let contentType: String
        let body: Data
        /// Optional Content-Disposition header filename.
        let filename: String?
        /// If > 0, throttle to this many bytes per chunk with a small delay.
        let throttleBytesPerChunk: Int

        init(
            path: String,
            contentType: String = "application/octet-stream",
            body: Data,
            filename: String? = nil,
            throttleBytesPerChunk: Int = 0
        ) {
            self.path = path
            self.contentType = contentType
            self.body = body
            self.filename = filename
            self.throttleBytesPerChunk = throttleBytesPerChunk
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "TestDownloadHTTPServer")
    private var routes: [String: Route] = [:]
    private var connections: [NWConnection] = []

    /// The port the server is listening on (valid after `start()`).
    private(set) var port: UInt16 = 0

    // MARK: - Lifecycle

    /// Register a route before or after starting the server.
    func addRoute(_ route: Route) {
        routes[route.path] = route
    }

    /// Start listening on a random available port.
    /// - Returns: The port number.
    @discardableResult
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)

        // Wait up to 5 seconds for the listener to be ready.
        let result = ready.wait(timeout: .now() + 5)
        if result == .timedOut {
            throw ServerError.timeout
        }
        if let error = startError {
            throw error
        }

        guard let actualPort = listener.port?.rawValue else {
            throw ServerError.noPort
        }
        self.port = actualPort
        return actualPort
    }

    /// Stop the server and cancel all connections.
    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
    }

    // MARK: - Convenience Routes

    /// Add a simple binary file route of the given size.
    func addBinaryRoute(
        path: String,
        filename: String,
        sizeBytes: Int,
        throttle: Int = 0
    ) {
        let body = Data(repeating: 0xAB, count: sizeBytes)
        addRoute(Route(
            path: path,
            contentType: "application/octet-stream",
            body: body,
            filename: filename,
            throttleBytesPerChunk: throttle
        ))
    }

    /// Add a route that sends HTTP headers then abruptly closes the connection,
    /// simulating a network error during download.
    func addErrorRoute(path: String, filename: String, advertisedSize: Int = 50000) {
        // We store a special sentinel route; respond() checks for it.
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(advertisedSize)\r\n"
            + "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        // Body is intentionally tiny (much less than Content-Length) to trigger error.
        let partialBody = Data(repeating: 0xAB, count: 512)
        var fullData = Data(headers.utf8)
        fullData.append(partialBody)
        addRoute(Route(
            path: path,
            contentType: "application/octet-stream",
            body: fullData,
            filename: nil,           // already embedded in the raw headers
            throttleBytesPerChunk: -1 // sentinel: send raw then close
        ))
    }

    /// Add an HTML page that triggers a download via an anchor tag.
    func addDownloadPage(path: String, downloadPath: String, linkText: String = "Download") {
        let html = """
        <!DOCTYPE html>
        <html><body>
        <a id="download-link" href="\(downloadPath)">\(linkText)</a>
        </body></html>
        """
        addRoute(Route(
            path: path,
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8)
        ))
    }

    /// Add an HTML page that auto-triggers a download via JS redirect.
    /// XCUITest navigates to this page; the page immediately redirects to the download URL.
    func addAutoDownloadPage(path: String, downloadPath: String) {
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta http-equiv="refresh" content="0;url=\(downloadPath)">
        </head><body>Redirecting to download...</body></html>
        """
        addRoute(Route(
            path: path,
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8)
        ))
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }

            let requestString = String(data: data, encoding: .utf8) ?? ""
            let path = self.parseRequestPath(requestString)
            self.respond(to: path, on: connection)
        }
    }

    private func parseRequestPath(_ request: String) -> String {
        // Parse "GET /path HTTP/1.1\r\n..."
        let lines = request.split(separator: "\r\n")
        guard let firstLine = lines.first else { return "/" }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1])
    }

    private func respond(to path: String, on connection: NWConnection) {
        if let route = routes[path] {
            sendRouteResponse(route, on: connection)
        } else {
            send404(on: connection)
        }
    }

    private func sendRouteResponse(_ route: Route, on connection: NWConnection) {
        // Sentinel: throttleBytesPerChunk == -1 means "send raw body (includes headers) then close"
        if route.throttleBytesPerChunk == -1 {
            connection.send(content: route.body, contentContext: .finalMessage,
                            isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        var headers = "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: \(route.contentType)\r\n"
        headers += "Content-Length: \(route.body.count)\r\n"
        if let filename = route.filename {
            headers += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        }
        headers += "Connection: close\r\n"
        headers += "\r\n"

        let headerData = Data(headers.utf8)

        if route.throttleBytesPerChunk > 0 {
            // Throttled: send headers first, then chunks with delays.
            connection.send(content: headerData, completion: .contentProcessed { [weak self] _ in
                self?.sendChunked(
                    data: route.body,
                    chunkSize: route.throttleBytesPerChunk,
                    offset: 0,
                    on: connection
                )
            })
        } else {
            // Fast: send everything at once.
            var fullResponse = headerData
            fullResponse.append(route.body)
            connection.send(content: fullResponse, contentContext: .finalMessage,
                            isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendChunked(
        data: Data, chunkSize: Int, offset: Int, on connection: NWConnection
    ) {
        guard offset < data.count else {
            connection.send(content: nil, contentContext: .finalMessage,
                            isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let end = min(offset + chunkSize, data.count)
        let chunk = data[offset..<end]

        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            // Small delay between chunks to simulate slow download.
            self?.queue.asyncAfter(deadline: .now() + 0.05) {
                self?.sendChunked(
                    data: data, chunkSize: chunkSize,
                    offset: end, on: connection
                )
            }
        })
    }

    private func send404(on connection: NWConnection) {
        let body = "Not Found"
        var response = "HTTP/1.1 404 Not Found\r\n"
        response += "Content-Type: text/plain\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += body

        connection.send(content: Data(response.utf8), contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Errors

    enum ServerError: Error, LocalizedError {
        case timeout
        case noPort

        var errorDescription: String? {
            switch self {
            case .timeout: return "TestDownloadHTTPServer: listener did not become ready in time"
            case .noPort: return "TestDownloadHTTPServer: could not determine listening port"
            }
        }
    }
}
