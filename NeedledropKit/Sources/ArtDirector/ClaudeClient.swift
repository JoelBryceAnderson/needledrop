import Foundation

/// Sends Messages API requests over raw HTTP (Swift has no official Anthropic SDK).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum ClaudeError: Error, Equatable, CustomStringConvertible {
    case noAPIKey
    case http(Int, String)
    case refusal(String?)
    case truncated
    case noText
    case malformed(String)

    public var description: String {
        switch self {
        case .noAPIKey: "No Anthropic API key (Settings › Art Director)"
        case .http(let status, let message): "Claude API error \(status): \(message)"
        case .refusal(let category): "Claude declined this request\(category.map { " (\($0))" } ?? "")"
        case .truncated: "Claude's reply was cut off (max_tokens)"
        case .noText: "Claude's reply had no text"
        case .malformed(let m): "Couldn't read Claude's reply: \(m)"
        }
    }
}

/// A minimal Messages API client for one job: a structured-output request, optionally with
/// an image, and a follow-up turn when the first answer needs fixing.
public struct ClaudeClient: Sendable {
    public static let defaultModel = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    /// Refusal fallbacks re-run a declined request on Anthropic's recommended model.
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var apiKey: String
    public var model: String
    public var transport: any HTTPTransport

    public init(apiKey: String, model: String = Self.defaultModel, transport: any HTTPTransport = URLSession.shared) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public struct Reply: @unchecked Sendable {  // JSON values only
        /// The assistant content exactly as returned, to send back on a follow-up turn.
        public var content: [[String: Any]]
        public var text: String
        public var model: String
    }

    /// One request. `messages` are Messages API message objects.
    public func send(system: String, messages: [[String: Any]], schema: [String: Any],
                     effort: String = "high", maxTokens: Int = 16_000) async throws -> Reply {
        guard !apiKey.isEmpty else { throw ClaudeError.noAPIKey }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ClaudeError.http(response.statusCode, message)
        }
        // Check why it stopped before reading content.
        switch json["stop_reason"] as? String {
        case "refusal":
            throw ClaudeError.refusal((json["stop_details"] as? [String: Any])?["category"] as? String)
        case "max_tokens":
            throw ClaudeError.truncated
        default:
            break
        }
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ClaudeError.noText }
        return Reply(content: content, text: text, model: json["model"] as? String ?? model)
    }
}
