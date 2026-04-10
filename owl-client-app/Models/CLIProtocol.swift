import Foundation

// MARK: - CLI IPC Protocol Models
// JSON + "\n" framed messages over Unix domain socket.

/// Handshake sent by CLI client upon connection.
package struct CLIHandshake: Codable {
    package let `protocol`: String
    package let version: Int

    package init() {
        self.protocol = "owl-cli"
        self.version = 1
    }
}

/// Handshake acknowledgment sent by server.
package struct CLIHandshakeAck: Codable {
    package let `protocol`: String
    package let version: Int
    package let ok: Bool

    package init(ok: Bool = true) {
        self.protocol = "owl-cli"
        self.version = 1
        self.ok = ok
    }
}

/// CLI request from client to server.
package struct CLIRequest: Codable {
    package let id: String
    package let cmd: String
    package let args: [String: String]

    package init(cmd: String, args: [String: String] = [:]) {
        self.id = UUID().uuidString
        self.cmd = cmd
        self.args = args
    }
}

/// CLI response from server to client.
package struct CLIResponse: Codable {
    package let id: String
    package let ok: Bool
    package let data: [String: String]?
    package let error: String?

    package static func success(id: String, data: [String: String] = [:]) -> CLIResponse {
        CLIResponse(id: id, ok: true, data: data, error: nil)
    }

    package static func failure(id: String, error: String) -> CLIResponse {
        CLIResponse(id: id, ok: false, data: nil, error: error)
    }
}

// MARK: - Framing Helpers

package enum CLIFraming {
    /// Encode a Codable value to a newline-terminated JSON Data.
    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(value)
        data.append(contentsOf: [UInt8(ascii: "\n")])
        return data
    }

    /// Decode a Codable value from JSON Data (newline stripped if present).
    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var trimmed = data
        // Strip trailing newline(s)
        while let last = trimmed.last, last == UInt8(ascii: "\n") {
            trimmed.removeLast()
        }
        return try JSONDecoder().decode(type, from: trimmed)
    }
}
