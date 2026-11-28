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
        // 200 with an error body means the model accepted and then refused the
        // request; the next model can try.
        case .http(let status, _):
            return status == 0 || status == 200 || status == 401 || status == 403
                || status == 429 || status >= 500
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
        messages: [AskMessage],
        maxTokens: Int,
        sessionID: String,
        baseURL: URL?,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> AskCompletion
}

public struct LiveAskCompleter: AskCompleting {
    public init() {}

    public func complete(
        endpoint: AskEndpoint,
        model: String,
        key: String,
        messages: [AskMessage],
        maxTokens: Int,
        sessionID: String,
        baseURL: URL?,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> AskCompletion {
        try await AskClient.complete(
            endpoint: endpoint,
            model: model,
            key: key,
            messages: messages,
            maxTokens: maxTokens,
            sessionID: sessionID,
            baseURL: baseURL,
            onDelta: onDelta
        )
    }
}

/// Parses an OpenAI-compatible SSE stream into answer deltas. `feed` accepts
/// arbitrary fragments, so a chunk split mid-line is safe; malformed lines and
/// non-answer fields (`reasoning_content`, comments, usage) are ignored.
public struct AskStreamParser {
    /// The answer text accumulated so far, exactly as the model sent it.
    public private(set) var text = ""
    /// Set by the `[DONE]` terminator.
    public private(set) var finished = false
    public private(set) var promptTokens = 0
    public private(set) var completionTokens = 0

    private var finishReason: String?
    private var buffer = ""

    public init() {}

    /// Feed a fragment of the response body; returns the answer pieces it completed.
    public mutating func feed(_ fragment: String) -> [String] {
        buffer += fragment
        var deltas: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: newline)...])
            if let delta = consume(line) { deltas.append(delta) }
        }
        return deltas
    }

    /// The finished reply. An empty stream is `.empty`, which allows fallback.
    public func completion(durationMs: Int) throws -> AskCompletion {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw AskClientError.empty }
        // A length stop means the model was cut off mid-answer; so does a
        // stream that ended without [DONE] and without any finish_reason, which
        // is what a dropped connection looks like. Some proxies also strip
        // [DONE], so mark the answer instead of throwing it away.
        let truncated = finishReason == "length"
            || (!finished && finishReason == nil)
        return AskCompletion(
            answer: truncated ? reply + "\n\n…(truncated — raise max_tokens)" : reply,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            durationMs: durationMs
        )
    }

    private mutating func consume(_ line: String) -> String? {
        guard !finished, line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            finished = true
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let usage = root["usage"] as? [String: Any] {
            promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
            completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return nil }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any],
              let piece = delta["content"] as? String,
              !piece.isEmpty else { return nil }
        text += piece
        return piece
    }
}

/// Minimal OpenAI-compatible chat-completions client. The Ask chat keeps a
/// conversation and renders the answer as it streams in.
public enum AskClient {
    /// Streaming can still stall before the first token, so a generous
    /// per-request budget.
    public static let timeout: TimeInterval = 120
    /// Hard ceiling on the whole call, a little above `timeout`, so a stalled
    /// connection cannot sit in the fallback loop forever.
    public static let deadline: TimeInterval = 130
    /// Ceiling on a non-streaming JSON body, applied while it is read so a
    /// hostile or broken endpoint cannot balloon memory.
    private static let maxResponseBytes = 2_000_000

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
        messages: [AskMessage],
        maxTokens: Int,
        sessionID: String,
        baseURL: URL? = nil,
        session: URLSession? = nil,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> AskCompletion {
        let session = session ?? defaultSession
        let base = baseURL ?? endpoint.baseURL
        let url = base.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Palette/1.8 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": max(32, maxTokens),
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        // Races the stream against `deadline` so a hung connection fails with
        // a readable error instead of blocking the chat.
        return try await withThrowingTaskGroup(of: AskCompletion.self) { group in
            group.addTask {
                try await stream(request, session: session, started: started, onDelta: onDelta)
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

    private static func stream(
        _ request: URLRequest,
        session: URLSession,
        started: Date,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> AskCompletion {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AskClientError.http(0, error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let data = (try? await collect(bytes, limit: 8_000)) ?? Data()
            let message = errorMessage(from: data)
            switch status {
            case 401, 403: throw AskClientError.invalidKey
            case 429: throw AskClientError.quota(message)
            default: throw AskClientError.http(status, message)
            }
        }

        var parser = AskStreamParser()
        var raw = Data()
        var isSSE = true
        var decided = false
        do {
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
                if !decided {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    decided = true
                    // Some OpenAI-compatible endpoints ignore `stream` and send
                    // one JSON document; buffer it and parse it at EOF.
                    isSSE = !trimmed.hasPrefix("{")
                }
                guard isSSE else {
                    let remaining = Self.maxResponseBytes - raw.count
                    if remaining > 0 {
                        raw.append(contentsOf: line.utf8.prefix(remaining))
                    }
                    if raw.count >= Self.maxResponseBytes { break }
                    raw.append(0x0A)
                    continue
                }
                for delta in parser.feed(line + "\n") { onDelta?(delta) }
                if parser.finished { break }
            }
        } catch let error as AskClientError {
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AskClientError.http(0, error.localizedDescription)
        }

        let duration = Int(Date().timeIntervalSince(started) * 1_000)
        if !isSSE, !raw.isEmpty { return try parse(raw, durationMs: duration) }
        return try parser.completion(durationMs: duration)
    }

    private static func collect(
        _ bytes: URLSession.AsyncBytes,
        limit: Int
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    public static func parse(_ data: Data, durationMs: Int) throws -> AskCompletion {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AskClientError.malformed("response was not JSON")
        }
        // Some OpenAI-compatible endpoints report a failure as a 200 with an
        // `error` body. Treat it as a request failure, not an unreadable
        // response, so the fallback chain can move on.
        if root["error"] != nil {
            let message = errorMessage(from: data)
            throw isQuotaMessage(message)
                ? AskClientError.quota(message)
                : AskClientError.http(200, message)
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

    private static func isQuotaMessage(_ message: String) -> Bool {
        let lower = message.localizedLowercase
        return lower.contains("quota") || lower.contains("usage limit") || lower.contains("rate limit")
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
