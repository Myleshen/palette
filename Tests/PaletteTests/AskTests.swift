import XCTest
import Foundation
import TOMLKit
import PaletteCore
import PalettePlatform
import PaletteProviders

final class AskTests: XCTestCase {
    func testAskConfigRoundTripsWithoutSecrets() throws {
        var config = PaletteConfig()
        config.ask.endpoint = .opencodeGo
        config.ask.model = "hy3"
        config.ask.maxHistory = 42
        config.ask.retentionDays = 9
        config.ask.maxTokens = 256
        config.ask.fallback = false
        config.ask.notify = false

        let rendered = ConfigWriter.render(config)
        XCTAssertFalse(rendered.lowercased().contains("api_key"))
        XCTAssertFalse(rendered.lowercased().contains("secret"))

        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(TOMLTable(string: rendered), diagnostics: &diagnostics)
        XCTAssertEqual(parsed.ask.endpoint, .opencodeGo)
        XCTAssertEqual(parsed.ask.model, "hy3")
        XCTAssertEqual(parsed.ask.maxHistory, 42)
        XCTAssertEqual(parsed.ask.retentionDays, 9)
        XCTAssertEqual(parsed.ask.maxTokens, 256)
        XCTAssertFalse(parsed.ask.fallback)
        XCTAssertFalse(parsed.ask.notify)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testAskNotifyDefaultsOnAndParsesOff() throws {
        XCTAssertTrue(AskConfig().notify)
        XCTAssertTrue(ConfigLoader.defaultTOML().contains("notify = true"))
        let table = try TOMLTable(string: """
        [ask]
        notify = false
        """)
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertFalse(parsed.ask.notify)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testLegacyAskEndpointMigratesToGo() throws {
        let table = try TOMLTable(string: """
        [ask]
        provider = "opencode-zen"
        model = "glm-5.3-flash-free"
        """)
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.ask.endpoint, .opencodeGo)
        XCTAssertEqual(parsed.ask.model, AskModel.defaultModel.id)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testAskModelsPutFreeOptionsFirst() {
        let ordered = AskModel.fallbackOrder
        XCTAssertEqual(ordered.prefix(2).filter(\.free).count, 2)
        XCTAssertTrue(ordered.allSatisfy { $0.endpoint == .opencodeGo })
        XCTAssertEqual(AskModel.defaultModel.endpoint, .opencodeGo)
        XCTAssertTrue(AskModel.defaultModel.free)
    }

    func testAskModelListIsGoOnly() {
        let models = AskModel.models(for: .opencodeGo)
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy { $0.endpoint == .opencodeGo })
        XCTAssertEqual(models.filter(\.free).count, 4)
        XCTAssertTrue(models.contains { $0.id == "grok-4.7" })
        XCTAssertTrue(models.contains { $0.id == "gpt-6-luna" })
    }

    func testAskKeyFileRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-ask-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv("PALETTE_CONFIG_DIR", directory.path, 1)
        defer { unsetenv("PALETTE_CONFIG_DIR") }

        XCTAssertFalse(AskKeychain.hasStoredKey(for: .opencodeGo))
        XCTAssertTrue(AskKeychain.save("test-key", for: .opencodeGo))
        XCTAssertTrue(AskKeychain.hasStoredKey(for: .opencodeGo))
        XCTAssertEqual(AskKeychain.resolve(endpoint: .opencodeGo, environment: [:]), "test-key")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("ask-keys.bin").path)[.posixPermissions] as? Int,
            0o600
        )
        AskKeychain.delete(endpoint: .opencodeGo)
        XCTAssertFalse(AskKeychain.hasStoredKey(for: .opencodeGo))
    }

    func testGoModelsAreOrderedByCost() {
        let paid = AskModel.models(for: .opencodeGo).filter { !$0.free }
        XCTAssertGreaterThanOrEqual(paid.count, 14)
        let outputs = paid.map(\.outputCost)
        XCTAssertEqual(outputs, outputs.sorted())
        XCTAssertTrue(paid.contains { $0.id == "hy3" })
        XCTAssertTrue(paid.contains { $0.id == "mimo-v2.6-pro" })
        XCTAssertTrue(paid.contains { $0.id == "longcat-2.0" })
        XCTAssertTrue(paid.contains { $0.id == "glm-5.3" })
        XCTAssertFalse(paid.contains { $0.id == "glm-5.2" })
    }

    func testAskRecordMetaLineShowsModelAndUsage() {
        let record = AskRecord(
            id: "1",
            question: "q",
            answer: "a",
            model: "hy3",
            provider: "opencode-go",
            createdAt: Date(),
            durationMs: 1_250,
            promptTokens: 30,
            completionTokens: 12
        )
        XCTAssertEqual(record.metaLine, "hy3 · 1250 ms · 42 tokens")

        let untokened = AskRecord(
            id: "2",
            question: "q",
            answer: "",
            model: "beam-free",
            provider: "opencode-go",
            createdAt: Date(),
            error: "boom"
        )
        XCTAssertEqual(untokened.metaLine, "beam-free · 0 ms")
    }

    func testAskDefaultsAllowLongerAnswers() {
        XCTAssertEqual(AskConfig().maxTokens, 8_192)
        XCTAssertEqual(AskClient.timeout, 120)
        XCTAssertGreaterThanOrEqual(AskClient.deadline, AskClient.timeout)
    }

    func testAskTemplateUsesNewTokenBudget() {
        XCTAssertTrue(ConfigLoader.defaultTOML().contains("max_tokens = 8192"))
    }

    func testAskTimeoutAllowsFallback() {
        XCTAssertTrue(AskClientError.http(0, "timed out").allowsFallback)
        XCTAssertTrue(AskClientError.http(429, "").allowsFallback)
        XCTAssertTrue(AskClientError.empty.allowsFallback)
        XCTAssertFalse(AskClientError.http(400, "bad request").allowsFallback)
        XCTAssertFalse(AskClientError.malformed("nope").allowsFallback)
        XCTAssertFalse(AskClientError.missingKey.allowsFallback)
    }

    func testAskTruncatedAnswerIsMarked() throws {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":"half a thought"},
         "finish_reason":"length"}],"usage":{"completion_tokens":2048}}
        """.utf8)
        let completion = try AskClient.parse(data, durationMs: 5)
        XCTAssertTrue(completion.answer.hasPrefix("half a thought"))
        XCTAssertTrue(completion.answer.contains("truncated"))

        let complete = try AskClient.parse(Data("""
        {"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
        """.utf8), durationMs: 5)
        XCTAssertEqual(complete.answer, "done")
    }

    func testAskResponseParsing() throws {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":"  forty-two  "}}],
         "usage":{"prompt_tokens":12,"completion_tokens":3}}
        """.utf8)
        let completion = try AskClient.parse(data, durationMs: 27)
        XCTAssertEqual(completion.answer, "forty-two")
        XCTAssertEqual(completion.promptTokens, 12)
        XCTAssertEqual(completion.completionTokens, 3)
        XCTAssertEqual(completion.durationMs, 27)
    }

    func testAskResponseErrorsAndEmptyAnswers() {
        XCTAssertThrowsError(try AskClient.parse(Data("{}".utf8), durationMs: 0))
        XCTAssertThrowsError(try AskClient.parse(
            Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8), durationMs: 0
        ))
        let message = AskClient.errorMessage(from: Data(
            #"{"error":{"message":"Free usage limit reached"}}"#.utf8
        ))
        XCTAssertEqual(message, "Free usage limit reached")
    }

    func testAskEmptyContentUsesReasoning() throws {
        let reasoningContent = try AskClient.parse(Data("""
        {"choices":[{"message":{"role":"assistant","content":"","reasoning_content":"  the answer  "},
         "finish_reason":"stop"}]}
        """.utf8), durationMs: 1)
        XCTAssertEqual(reasoningContent.answer, "the answer")

        let reasoning = try AskClient.parse(Data("""
        {"choices":[{"message":{"role":"assistant","reasoning":"from reasoning"},
         "finish_reason":"stop"}]}
        """.utf8), durationMs: 1)
        XCTAssertEqual(reasoning.answer, "from reasoning")
    }

    func testAskFallbackMovesPastQuota() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let stub = StubCompleter { _, model in
            if model == "mimo-v2.6-flash" {
                throw AskClientError.quota("Free usage limit reached")
            }
            return AskCompletion(answer: "fallback answer", promptTokens: 4, completionTokens: 2, durationMs: 12)
        }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "mimo-v2.6-flash"),
            environment: ["OPENCODE_GO_API_KEY": "test"],
            completer: stub
        )
        let record = try await service.ask("hello")
        XCTAssertEqual(record.answer, "fallback answer")
        XCTAssertEqual(record.model, "beam-free")
    }

    func testAskEmptyAnswerFallsBackToNextModel() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let stub = StubCompleter { _, model in
            if model == "mimo-v2.6-flash" {
                throw AskClientError.empty
            }
            return AskCompletion(answer: "second answer", promptTokens: 1, completionTokens: 2, durationMs: 3)
        }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "mimo-v2.6-flash"),
            environment: ["OPENCODE_GO_API_KEY": "test"],
            completer: stub
        )
        let record = try await service.ask("hello")
        XCTAssertEqual(record.answer, "second answer")
        XCTAssertEqual(record.model, "beam-free")
    }

    func testAskAllEmptyAnswersSurfaceAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let stub = StubCompleter { _, _ in throw AskClientError.empty }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "hy3", fallback: false),
            environment: ["OPENCODE_GO_API_KEY": "test"],
            completer: stub
        )
        do {
            _ = try await service.ask("hello")
            XCTFail("expected an empty-answer error")
        } catch {
            XCTAssertEqual(error as? AskClientError, .empty)
            XCTAssertEqual(error.localizedDescription, "The model returned an empty answer.")
        }
    }

    func testSettingsModelWinsOverAStaleRuntimeChoice() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let first = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "beam-free")
        )
        try await first.selectModel(try XCTUnwrap(AskModel.find(id: "mimo-v2.6-pro")))
        let chosen = await first.selectedModel()
        XCTAssertEqual(chosen.id, "mimo-v2.6-pro")

        let unchanged = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "beam-free")
        )
        let remembered = await unchanged.selectedModel()
        XCTAssertEqual(remembered.id, "mimo-v2.6-pro")

        let changed = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "hy3")
        )
        let configured = await changed.selectedModel()
        XCTAssertEqual(configured.id, "hy3")
    }

    func testAskInvalidKeyStopsWithoutSpinning() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let counter = CallCounter()
        let stub = StubCompleter { _, _ in
            await counter.increment()
            throw AskClientError.invalidKey
        }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "hy3"),
            environment: ["OPENCODE_GO_API_KEY": "test"],
            completer: stub
        )
        do {
            _ = try await service.ask("hello")
            XCTFail("expected invalid key")
        } catch {
            XCTAssertEqual(error as? AskClientError, .invalidKey)
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 1)
    }

    func testAskFailureIsStoredInHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let stub = StubCompleter { _, _ in
            throw AskClientError.http(0, "No answer after 130s — the model was too slow.")
        }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "hy3", fallback: false),
            environment: ["OPENCODE_GO_API_KEY": "test"],
            completer: stub
        )
        do {
            _ = try await service.ask("slow one")
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? AskClientError, .http(0, "No answer after 130s — the model was too slow."))
        }
        let history = try await store.askHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.question, "slow one")
        XCTAssertEqual(history.first?.answer, "")
        XCTAssertEqual(history.first?.model, "hy3")
        XCTAssertEqual(history.first?.error, "No answer after 130s — the model was too slow.")
    }

    func testAskCancelStopsFallbackAndWritesNoHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let counter = CallCounter()
        let stub = StubCompleter { _, _ in
            await counter.increment()
            throw CancellationError()
        }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeGo, model: "hy3"),
            environment: ["OPENCODE_GO_API_KEY": "test"],
            completer: stub
        )
        do {
            _ = try await service.ask("cancel me")
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "a cancelled ask must not fall back to another model")
        let history = try await store.askHistory()
        XCTAssertTrue(history.isEmpty, "cancelling must not record a failure")
    }
}

private struct StubCompleter: AskCompleting {
    let handler: @Sendable (AskEndpoint, String) async throws -> AskCompletion

    func complete(
        endpoint: AskEndpoint,
        model: String,
        key: String,
        question: String,
        maxTokens: Int,
        sessionID: String,
        baseURL: URL?
    ) async throws -> AskCompletion {
        try await handler(endpoint, model)
    }
}

private actor CallCounter {
    private var count = 0

    func increment() { count += 1 }

    var value: Int { count }
}
