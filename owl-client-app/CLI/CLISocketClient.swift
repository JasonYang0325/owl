import Foundation
import OWLBrowserLib
#if canImport(Darwin)
import Darwin
#endif

/// POSIX Unix socket client for CLI-to-GUI IPC.
/// Synchronous blocking calls with 5s SO_RCVTIMEO timeout.
enum CLISocketClient {

    enum CLIError: Error, CustomStringConvertible {
        case browserNotRunning(path: String)
        case connectionFailed(String)
        case handshakeFailed(String)
        case timeout
        case serverError(String)
        case protocolError(String)
        case incompatibleVersion

        var description: String {
            switch self {
            case .browserNotRunning(let path):
                return "OWL Browser is not running (no socket at \(path))"
            case .connectionFailed(let msg):
                return "Connection failed: \(msg)"
            case .handshakeFailed(let msg):
                return "Handshake failed: \(msg)"
            case .timeout:
                return "Response timeout (5s)"
            case .serverError(let msg):
                return "Server error: \(msg)"
            case .protocolError(let msg):
                return "Protocol error: \(msg)"
            case .incompatibleVersion:
                return "Incompatible CLI protocol version"
            }
        }

        var exitCode: Int32 {
            switch self {
            case .browserNotRunning, .connectionFailed: return 2
            case .timeout: return 3
            default: return 1
            }
        }
    }

    /// Discover the socket path.
    static var socketPath: String {
        let tmpDir = NSTemporaryDirectory()
        let uid = getuid()
        return (tmpDir as NSString).appendingPathComponent("owl-\(uid).sock")
    }

    /// Send a command and return the response.
    static func send(command: String, args: [String: String] = [:]) throws -> CLIResponse {
        let path = socketPath

        // Check socket exists
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.browserNotRunning(path: path)
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.connectionFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { ptr in
                for (i, byte) in pathBytes.enumerated() {
                    ptr[i] = byte
                }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let errStr = String(cString: strerror(errno))
            throw CLIError.connectionFailed(errStr)
        }

        // Set read timeout 5s
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // 1. Send handshake
        let handshake = CLIHandshake()
        let handshakeData = try CLIFraming.encode(handshake)
        guard writeAll(fd: fd, data: handshakeData) else {
            throw CLIError.connectionFailed("Failed to send handshake")
        }

        // 2. Read handshake ack
        guard let ackData = readLine(from: fd) else {
            throw CLIError.timeout
        }
        let ack = try CLIFraming.decode(CLIHandshakeAck.self, from: ackData)
        guard ack.ok, ack.version == 1 else {
            if !ack.ok {
                throw CLIError.handshakeFailed("Server rejected handshake")
            }
            throw CLIError.incompatibleVersion
        }

        // 3. Send request
        let request = CLIRequest(cmd: command, args: args)
        let requestData = try CLIFraming.encode(request)
        guard writeAll(fd: fd, data: requestData) else {
            throw CLIError.connectionFailed("Failed to send request")
        }

        // 4. Read response
        guard let responseData = readLine(from: fd) else {
            throw CLIError.timeout
        }
        let response = try CLIFraming.decode(CLIResponse.self, from: responseData)

        if !response.ok, let error = response.error {
            throw CLIError.serverError(error)
        }

        return response
    }

    // MARK: - Low-level IO

    /// Maximum message length before disconnect (DoS protection).
    private static let maxLineLength = 1_048_576  // 1 MB

    private static func readLine(from fd: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return buffer.isEmpty ? nil : buffer }
            buffer.append(byte)
            if byte == UInt8(ascii: "\n") {
                return buffer
            }
            if buffer.count > maxLineLength {
                return nil
            }
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
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
