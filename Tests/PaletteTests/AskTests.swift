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
        XCTAssertEqual(models.filter(\.free).count, 2)
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
        XCTAssertGreaterThanOrEqual(paid.count, 15)
        let outputs = paid.map(\.outputCost)
        XCTAssertEqual(outputs, outputs.sorted())
        XCTAssertTrue(paid.contains { $0.id == "hy3" })
        XCTAssertTrue(paid.contains { $0.id == "mimo-v2.6-pro" })
        XCTAssertTrue(paid.contains { $0.id == "longcat-2.0" })
        XCTAssertTrue(paid.contains { $0.id == "glm-5.2" })
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
