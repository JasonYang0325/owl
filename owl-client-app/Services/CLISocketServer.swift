import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Unix domain socket server for CLI IPC.
/// Starts listening on `$TMPDIR/owl-{uid}.sock` when the GUI launches.
/// Each connection is handled in an independent Task.
@MainActor
package final class CLISocketServer {
    package let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var router: CLICommandRouter?
    private var running = false

    package init() {
        let tmpDir = NSTemporaryDirectory()
        let uid = getuid()
        self.socketPath = (tmpDir as NSString).appendingPathComponent("owl-\(uid).sock")
    }

    package func start(router: CLICommandRouter) {
        guard !running else { return }
        self.router = router

        // Clean up stale socket
        unlink(socketPath.cString(using: .utf8))

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("%@", "[OWL-CLI] Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("%@", "[OWL-CLI] Socket path too long: \(socketPath)")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { ptr in
                for (i, byte) in pathBytes.enumerated() {
                    ptr[i] = byte
                }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("%@", "[OWL-CLI] Failed to bind socket: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Restrict socket file to owner only
        chmod(socketPath, 0o600)

        // Listen
        guard listen(fd, 5) == 0 else {
            NSLog("%@", "[OWL-CLI] Failed to listen: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        running = true
        NSLog("%@", "[OWL-CLI] Server listening on \(socketPath)")

        // Accept loop in background
        let listenFDCopy = fd
        acceptTask = Task.detached { [weak self] in
            await self?.acceptLoop(fd: listenFDCopy)
        }
    }

    package func stop() {
        running = false
        acceptTask?.cancel()
        acceptTask = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath.cString(using: .utf8))
        NSLog("%@", "[OWL-CLI] Server stopped")
    }

    // MARK: - Accept Loop

    private nonisolated func acceptLoop(fd: Int32) async {
        while !Task.isCancelled {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(fd, sockaddrPtr, &clientLen)
                }
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                if Task.isCancelled { break }
                NSLog("%@", "[OWL-CLI] Accept failed: \(String(cString: strerror(errno)))")
                break
            }

            // Handle each connection in its own task
            Task.detached { [weak self] in
                await self?.handleConnection(clientFD)
            }
        }
    }

    // MARK: - Connection Handler

    private nonisolated func handleConnection(_ fd: Int32) async {
        defer { close(fd) }

        // Set read timeout (5s)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // 1. Read handshake
        guard let handshakeData = readLine(from: fd) else {
            NSLog("%@", "[OWL-CLI] Failed to read handshake")
            return
        }

        do {
            let handshake = try CLIFraming.decode(CLIHandshake.self, from: handshakeData)
            guard handshake.protocol == "owl-cli", handshake.version == 1 else {
                NSLog("%@", "[OWL-CLI] Invalid handshake: protocol=\(handshake.protocol) version=\(handshake.version)")
                let nack = try CLIFraming.encode(CLIHandshakeAck(ok: false))
                _ = writeAll(fd: fd, data: nack)
                return
            }

            // Send ack
            let ack = try CLIFraming.encode(CLIHandshakeAck(ok: true))
            guard writeAll(fd: fd, data: ack) else {
                NSLog("%@", "[OWL-CLI] Failed to write handshake ack")
                return
            }
        } catch {
            NSLog("%@", "[OWL-CLI] Handshake decode error: \(error)")
            return
        }

        // 2. Request/response loop
        while !Task.isCancelled {
            guard let requestData = readLine(from: fd) else {
                break  // Client disconnected or timeout
            }

            do {
                let request = try CLIFraming.decode(CLIRequest.self, from: requestData)

                // Route on MainActor via the router (handle is async)
                let response: CLIResponse
                if let router = await MainActor.run(body: { [weak self] in self?.router }) {
                    response = await router.handle(request)
                } else {
                    response = .failure(id: request.id, error: "Server shutting down")
                }

                let responseData = try CLIFraming.encode(response)
                guard writeAll(fd: fd, data: responseData) else {
                    break
                }
            } catch {
                NSLog("%@", "[OWL-CLI] Request error: \(error)")
                break
            }
        }
    }

    // MARK: - Low-level IO

    /// Read bytes until newline delimiter. Returns data including the newline.
    /// Disconnects if message exceeds 1 MB without a newline (DoS protection).
    private static let maxLineLength = 1_048_576  // 1 MB

    private nonisolated func readLine(from fd: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return buffer.isEmpty ? nil : buffer }
            buffer.append(byte)
            if byte == UInt8(ascii: "\n") {
                return buffer
            }
            if buffer.count > Self.maxLineLength {
                NSLog("%@", "[OWL-CLI] Message exceeded \(Self.maxLineLength) bytes without newline, disconnecting")
                return nil
            }
        }
    }

    /// Write all data to fd. Returns true on success.
    private nonisolated func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return false }
            var offset = 0
            let total = data.count
            while offset < total {
                let n = write(fd, ptr + offset, total - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
