import Foundation
import PaletteCore
import PalettePlatform

/// Shared runtime for the two `/ask` tabs. It owns model choice, key lookup,
/// the request, and history persistence. The chat window keeps the
/// conversation; a request replays the trimmed transcript.
public actor AskService {
    private let store: PaletteStore
    private let configuration: AskConfig
    private let environment: [String: String]
    private let completer: any AskCompleting
    private var cachedSessionID: String?
    private var lastAnswer: AskRecord?

    public init(
        store: PaletteStore,
        configuration: AskConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        completer: any AskCompleting = LiveAskCompleter()
    ) {
        self.store = store
        self.configuration = configuration
        self.environment = environment
        self.completer = completer
    }

    public func selectedModel() async -> AskModel {
        if let signature = try? await store.metaValue("ask.model.signature"),
           signature == configuration.selectionSignature,
           let key = try? await store.metaValue("ask.model"),
           let model = AskModel.find(key: key) {
            return model
        }
        return configuration.selectedModel
    }

    public func selectModel(_ model: AskModel) async throws {
        try await store.setMeta("ask.model", value: model.key)
        try await store.setMeta("ask.model.signature", value: configuration.selectionSignature)
        lastAnswer = nil
    }

    public func hasAnyKey() -> Bool {
        AskEndpoint.allCases.contains { endpoint in
            AskKeychain.resolve(endpoint: endpoint, environment: environment) != nil
        }
    }

    public func hasKey(for endpoint: AskEndpoint) -> Bool {
        AskKeychain.resolve(endpoint: endpoint, environment: environment) != nil
    }

    public func recentAnswer(for question: String) -> AskRecord? {
        guard let lastAnswer, lastAnswer.question == question else { return nil }
        return lastAnswer
    }

    public func history(limit: Int = 200) async throws -> [AskRecord] {
        try await store.trimAskHistory(
            maxHistory: configuration.maxHistory,
            retentionDays: configuration.retentionDays
        )
        return try await store.askHistory(limit: limit)
    }

    public func deleteHistory(id: String) async throws {
        try await store.deleteAsk(id: id)
        if lastAnswer?.id == id { lastAnswer = nil }
    }

    /// Sends a conversation and returns the completed turn. `onDelta` receives
    /// streamed answer text; if a model fails after streaming and the loop
    /// falls back, `onReset` asks the UI to discard that partial bubble.
    public func ask(
        _ conversation: [AskMessage],
        onDelta: (@Sendable (String) -> Void)? = nil,
        onReset: (@Sendable () -> Void)? = nil
    ) async throws -> AskRecord {
        let messages = conversation.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let question = messages.last(where: { $0.role == .user })?
            .content.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else {
            throw AskClientError.empty
        }
        let selected = await selectedModel()
        let candidates = candidateModels(selected: selected)
        let sessionID = await sessionIdentifier()
        let trimmedMessages = AskConversation.trimmed(messages)
        let started = Date()
        var lastError: Error = AskClientError.missingKey
        var lastModel: AskModel?
        var attempts = 0
        var rejectedEndpoints: Set<AskEndpoint> = []

        for model in candidates where !rejectedEndpoints.contains(model.endpoint) {
            // Cancel must stop the whole chain: a cancelled request is not a
            // model failure, so it neither falls back nor lands in history.
            if Task.isCancelled { throw CancellationError() }
            // Falling back on timeouts could otherwise spend 130 s per model;
            // cap the whole ask so the panel cannot sit busy for many minutes.
            if attempts > 0, Date().timeIntervalSince(started) > 300 { break }
            guard let key = AskKeychain.resolve(endpoint: model.endpoint, environment: environment) else {
                continue
            }
            attempts += 1
            lastModel = model
            let streamed = DeltaFlag()
            let deltaSink: (@Sendable (String) -> Void)? = onDelta.map { emit in
                { piece in
                    streamed.mark()
                    emit(piece)
                }
            }
            do {
                let completion = try await completer.complete(
                    endpoint: model.endpoint,
                    model: model.id,
                    key: key,
                    messages: trimmedMessages,
                    maxTokens: configuration.maxTokens,
                    sessionID: sessionID,
                    baseURL: baseURLOverride,
                    onDelta: deltaSink
                )
                let record = try await store.insertAsk(
                    question: question,
                    answer: completion.answer,
                    model: model.id,
                    provider: model.endpoint.rawValue,
                    durationMs: completion.durationMs,
                    promptTokens: completion.promptTokens,
                    completionTokens: completion.completionTokens,
                    maxHistory: configuration.maxHistory,
                    retentionDays: configuration.retentionDays
                )
                lastAnswer = record
                return record
            } catch let error as AskClientError {
                if Task.isCancelled { throw CancellationError() }
                // A rejected key rejects that whole endpoint; do not burn the
                // remaining fallback attempts on the same account.
                if error == .invalidKey {
                    rejectedEndpoints.insert(model.endpoint)
                }
                // The next model starts a fresh answer, so the UI must not
                // append it to the failed model's partial text.
                if streamed.take() { onReset?() }
                lastError = error
                Log.shared.warn("ask \(model.id) failed: \(error.localizedDescription)", source: "ask")
                if !error.allowsFallback { break }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if streamed.take() { onReset?() }
                lastError = error
                Log.shared.warn("ask \(model.id) failed: \(error.localizedDescription)", source: "ask")
            }
        }

        if attempts == 0 {
            throw AskClientError.missingKey
        }
        // A failed re-ask must not keep showing the cached answer for it.
        if lastAnswer?.question == question { lastAnswer = nil }
        if let lastModel {
            // Keep failures next to answers (the error column) so a timeout is
            // diagnosable from Ask History as well as the log.
            _ = try? await store.insertAsk(
                question: question,
                answer: "",
                model: lastModel.id,
                provider: lastModel.endpoint.rawValue,
                durationMs: Int(Date().timeIntervalSince(started) * 1_000),
                error: lastError.localizedDescription,
                maxHistory: configuration.maxHistory,
                retentionDays: configuration.retentionDays
            )
        }
        throw lastError
    }

    private var baseURLOverride: URL? {
        guard let raw = environment["PALETTE_ASK_BASE_URL"],
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// The selected model first, then a short free-first fallback chain. The
    /// cap keeps a quota-exhausted account from turning every question into a
    /// minute of repeated requests.
    private func candidateModels(selected: AskModel) -> [AskModel] {
        guard configuration.fallback else { return [selected] }
        var result = [selected]
        var keys = Set([selected.key])
        let free = AskModel.fallbackOrder.filter(\.free)
        for model in free where result.count < 4 {
            if keys.insert(model.key).inserted { result.append(model) }
        }
        let paid = AskModel.fallbackOrder.filter { !$0.free }
        for model in paid where result.count < 12 {
            if keys.insert(model.key).inserted { result.append(model) }
        }
        return result
    }

    private func sessionIdentifier() async -> String {
        if let cachedSessionID { return cachedSessionID }
        if let stored = try? await store.metaValue("ask.session"), !stored.isEmpty {
            cachedSessionID = stored
            return stored
        }
        let value = UUID().uuidString
        try? await store.setMeta("ask.session", value: value)
        cachedSessionID = value
        return value
    }
}

/// Sendable latch so the fallback loop can ask whether a model streamed
/// anything before it failed, without trusting the closure's thread.
private final class DeltaFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let seen = value
        value = false
        return seen
    }
}
