import Foundation
import Security

/// Claude API service with SSE streaming and Keychain storage.
actor AIService {
    static let shared = AIService()

    private let keychainAccount = "com.antlerai.owl.claude-api-key"

    // MARK: - API Key Management

    func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "AIService", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain save failed"])
        }
        cachedAPIKey = key
    }

    func loadAPIKey() -> String? {
        if let cached = cachedAPIKey { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        cachedAPIKey = key
        return key
    }

    private var cachedAPIKey: String?

    var hasAPIKey: Bool { cachedAPIKey != nil || loadAPIKey() != nil }

    // MARK: - Send Message (SSE Streaming)

    /// Streaming token result: either a token fragment or an error.
    enum StreamEvent: Sendable {
        case token(String)
        case error(Error)
    }

    /// Send a message and return an AsyncStream of token fragments.
    /// The stream finishes naturally when all tokens have been delivered.
    /// Errors are yielded as `.error` before the stream terminates.
    func sendMessage(
        _ text: String,
        history: [(role: String, content: String)],
        pageContext: String?
    ) -> AsyncStream<StreamEvent> {
        guard let apiKey = loadAPIKey() else {
            return AsyncStream { continuation in
                continuation.yield(.error(NSError(domain: "AIService", code: -1,
                                                   userInfo: [NSLocalizedDescriptionKey: "API Key 未配置"])))
                continuation.finish()
            }
        }

        var messages: [[String: String]] = []
        if let context = pageContext {
            messages.append(["role": "system", "content": "当前页面内容:\n\(context)"])
        }
        for msg in history {
            messages.append(["role": msg.role, "content": msg.content])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "stream": true,
            "messages": messages,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return AsyncStream { continuation in
                continuation.yield(.error(NSError(domain: "AIService", code: -2,
                                                   userInfo: [NSLocalizedDescriptionKey: "JSON serialization failed"])))
                continuation.finish()
            }
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData

        return AsyncStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.yield(.error(NSError(domain: "AIService", code: statusCode,
                                                           userInfo: [NSLocalizedDescriptionKey: "API error: \(statusCode)"])))
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]",
                              let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let delta = (json["delta"] as? [String: Any])?["text"] as? String
                        else { continue }

                        continuation.yield(.token(delta))
                    }

                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
