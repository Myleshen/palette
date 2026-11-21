import Foundation
import PaletteCore

public struct AskCompletion: Sendable, Equatable {
    public var answer: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var durationMs: Int

    public init(answer: String, promptTokens: Int, completionTokens: Int, durationMs: Int) {
        self.answer = answer
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.durationMs = durationMs
    }
}

public enum AskClientError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case quota(String)
    case http(Int, String)
    case malformed(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an API key in Settings → Ask."
        case .invalidKey: return "The API key was rejected. Replace it in Settings → Ask."
        case .quota(let message):
            // Providers return a long marketing sentence when a free allowance
            // runs out. The status line only has room for the useful part.
            if message.localizedCaseInsensitiveContains("usage limit")
                || message.localizedCaseInsensitiveContains("quota") {
                return "Free quota used up. Pick a small paid model or try again later."
            }
            return message.isEmpty ? "The free quota is used up." : message
        case .http(let status, let message):
            return message.isEmpty ? "The AI endpoint returned HTTP \(status)." : message
        case .malformed(let message): return "Could not read the AI response: \(message)"
        case .empty: return "The model returned an empty answer."
        }
    }

    /// Whether another model or endpoint could reasonably answer instead.
    public var allowsFallback: Bool {
        switch self {
        case .quota, .invalidKey: return true
        // Status 0 means the request never got a response: a timeout or a
        // dropped connection. Another model may well answer in time.
        case .http(let status, _):
            return status == 0 || status == 401 || status == 403 || status == 429 || status >= 500
        case .missingKey, .malformed: return false
        // An empty reply is model-specific (some reasoning models do it); the
        // next model in the chain may answer normally.
        case .empty: return true
        }
    }
}

/// Injectable seam for the fallback loop. Production uses the real endpoint;
/// tests use a stub so quota and invalid-key handling stay deterministic.
public protocol AskCompleting: Sendable {
    func complete(
        endpoint: AskEndpoint,
        model: String,
        key: String,
        question: String,
        maxTokens: Int,
        sessionID: String,
        baseURL: URL?
    ) async throws -> AskCompletion
}

public struct LiveAskCompleter: AskCompleting {
    public init() {}

    public func complete(
        endpoint: AskEndpoint,
        model: String,
        key: String,
        question: String,
        maxTokens: Int,
        sessionID: String,
        baseURL: URL?
    ) async throws -> AskCompletion {
        try await AskClient.complete(
            endpoint: endpoint,
            model: model,
            key: key,
            question: question,
            maxTokens: maxTokens,
            sessionID: sessionID,
            baseURL: baseURL
        )
    }
}

/// Minimal OpenAI-compatible chat-completions client. `/ask` is deliberately
/// one-shot and non-streaming: quick answers are easier to persist and render
/// when the whole reply arrives at once.
public enum AskClient {
    /// Non-streaming full generation is slow, so a generous per-request budget.
    public static let timeout: TimeInterval = 120
    /// Hard ceiling on the whole call, a little above `timeout`, so a stalled
    /// connection cannot sit in the fallback loop forever.
    public static let deadline: TimeInterval = 130

    /// Dedicated session: `URLSession.shared` defaults to a 60 s resource
    /// timeout, which would silently undercut the values above.
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }()

    public static func complete(
        endpoint: AskEndpoint,
        model: String,
        key: String,
        question: String,
        maxTokens: Int,
        sessionID: String,
        baseURL: URL? = nil,
        session: URLSession? = nil
    ) async throws -> AskCompletion {
        let session = session ?? defaultSession
        let base = baseURL ?? endpoint.baseURL
        let url = base.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Palette/1.8 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": question]],
            "max_tokens": max(32, maxTokens),
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let data: Data
        let status: Int
        do {
            (data, status) = try await send(request, session: session)
        } catch let error as AskClientError {
            throw error
        } catch {
            throw AskClientError.http(0, error.localizedDescription)
        }
        let duration = Int(Date().timeIntervalSince(started) * 1_000)
        guard status == 200 else {
            let message = errorMessage(from: data)
            switch status {
            case 401, 403: throw AskClientError.invalidKey
            case 429: throw AskClientError.quota(message)
            default: throw AskClientError.http(status, message)
            }
        }
        return try parse(data, durationMs: duration)
    }

    /// Races the request against `deadline` so a hung connection fails with a
    /// readable error instead of blocking `/ask`.
    private static func send(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, Int) {
        try await withThrowingTaskGroup(of: (Data, Int).self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw AskClientError.http(0, "No answer after \(Int(deadline))s — the model was too slow.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AskClientError.http(0, "The AI endpoint sent no response.")
            }
            return first
        }
    }

    public static func parse(_ data: Data, durationMs: Int) throws -> AskCompletion {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AskClientError.malformed("response was not JSON")
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AskClientError.malformed("response had no choices")
        }
        let answer: String
        if let text = message["content"] as? String {
            answer = text
        } else if let parts = message["content"] as? [[String: Any]] {
            answer = parts.compactMap { part in
                (part["text"] as? String) ?? (part["content"] as? String)
            }.joined()
        } else {
            answer = ""
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reasoning models can leave `content` empty and put the text in a
        // reasoning field. That is still an answer worth showing.
        let reasoning = ["reasoning_content", "reasoning"]
            .compactMap { (message[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let reply = trimmed.isEmpty ? (reasoning ?? "") : trimmed
        guard !reply.isEmpty else { throw AskClientError.empty }
        // A length stop means the model was cut off mid-answer; never present
        // that as a complete reply.
        let truncated = choices.first?["finish_reason"] as? String == "length"
        let usage = root["usage"] as? [String: Any]
        return AskCompletion(
            answer: truncated ? reply + "\n\n…(truncated — raise max_tokens)" : reply,
            promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
            completionTokens: usage?["completion_tokens"] as? Int ?? 0,
            durationMs: durationMs
        )
    }

    public static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300)
                .description ?? ""
        }
        if let error = root["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String) ?? ""
        }
        if let error = root["error"] as? String { return error }
        if let message = root["message"] as? String { return message }
        return ""
    }
}
