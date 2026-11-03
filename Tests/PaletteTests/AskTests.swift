import XCTest
import Foundation
import TOMLKit
import PaletteCore
import PalettePlatform
import PaletteProviders

final class AskTests: XCTestCase {
    func testAskConfigRoundTripsWithoutSecrets() throws {
        var config = PaletteConfig()
        config.ask.endpoint = .openai
        config.ask.model = "gpt-4o-mini"
        config.ask.maxHistory = 42
        config.ask.retentionDays = 9
        config.ask.maxTokens = 256
        config.ask.fallback = false

        let rendered = ConfigWriter.render(config)
        XCTAssertFalse(rendered.lowercased().contains("api_key"))
        XCTAssertFalse(rendered.lowercased().contains("secret"))

        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(TOMLTable(string: rendered), diagnostics: &diagnostics)
        XCTAssertEqual(parsed.ask.endpoint, .openai)
        XCTAssertEqual(parsed.ask.model, "gpt-4o-mini")
        XCTAssertEqual(parsed.ask.maxHistory, 42)
        XCTAssertEqual(parsed.ask.retentionDays, 9)
        XCTAssertEqual(parsed.ask.maxTokens, 256)
        XCTAssertFalse(parsed.ask.fallback)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testAskModelsPutFreeOptionsFirst() {
        let ordered = AskModel.fallbackOrder
        XCTAssertEqual(ordered.prefix(11).filter(\.free).count, 11)
        XCTAssertTrue(ordered.contains { !$0.free && $0.endpoint == .opencodeGo })
        XCTAssertTrue(ordered.contains { $0.endpoint == .openai })
        XCTAssertEqual(AskModel.defaultModel.endpoint, .opencodeZen)
        XCTAssertTrue(AskModel.defaultModel.free)
    }

    func testAskModelListIsScopedToTheSelectedEndpoint() {
        let openAI = AskModel.models(for: .openai)
        XCTAssertFalse(openAI.isEmpty)
        XCTAssertTrue(openAI.allSatisfy { $0.endpoint == .openai })

        let zen = AskModel.models(for: .opencodeZen)
        XCTAssertTrue(zen.allSatisfy { $0.endpoint == .opencodeZen })
        XCTAssertTrue(zen.allSatisfy(\.free))
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

    func testAskFallbackMovesPastQuota() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let stub = StubCompleter { _, model in
            if model == "glm-5.3-flash-free" {
                throw AskClientError.quota("Free usage limit reached")
            }
            return AskCompletion(answer: "fallback answer", promptTokens: 4, completionTokens: 2, durationMs: 12)
        }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeZen, model: "glm-5.3-flash-free"),
            environment: ["OPENCODE_API_KEY": "test"],
            completer: stub
        )
        let record = try await service.ask("hello")
        XCTAssertEqual(record.answer, "fallback answer")
        XCTAssertEqual(record.model, "deepseek-v4.1-flash-free")
    }

    func testSettingsModelWinsOverAStaleRuntimeChoice() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let first = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeZen, model: "glm-5.3-flash-free")
        )
        try await first.selectModel(try XCTUnwrap(AskModel.find(id: "mimo-v2.6-flash-free")))
        let chosen = await first.selectedModel()
        XCTAssertEqual(chosen.id, "mimo-v2.6-flash-free")

        let unchanged = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeZen, model: "glm-5.3-flash-free")
        )
        let remembered = await unchanged.selectedModel()
        XCTAssertEqual(remembered.id, "mimo-v2.6-flash-free")

        let changed = AskService(
            store: store,
            configuration: AskConfig(endpoint: .openai, model: "gpt-4o-mini")
        )
        let configured = await changed.selectedModel()
        XCTAssertEqual(configured.endpoint, .openai)
        XCTAssertEqual(configured.id, "gpt-4o-mini")
    }

    func testAskInvalidKeySkipsTheRestOfTheEndpoint() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("palette-ask-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try PaletteStore(path: url.path)
        let counter = CallCounter()
        let stub = StubCompleter { endpoint, _ in
            await counter.increment()
            if endpoint == .opencodeZen {
                throw AskClientError.invalidKey
            }
            return AskCompletion(answer: "go answer", promptTokens: 1, completionTokens: 1, durationMs: 5)
        }
        let service = AskService(
            store: store,
            configuration: AskConfig(endpoint: .opencodeZen, model: "glm-5.3-flash-free"),
            environment: ["OPENCODE_API_KEY": "zen", "OPENCODE_GO_API_KEY": "go"],
            completer: stub
        )
        let record = try await service.ask("hello")
        XCTAssertEqual(record.provider, AskEndpoint.opencodeGo.rawValue)
        let calls = await counter.value
        XCTAssertEqual(calls, 2)
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
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
