import XCTest
import Foundation
import PaletteCore
import PaletteRuntime

private actor TestBridge: HostBridge {
    private var notes: [String] = []

    func lastNotification() -> String? { notes.last }

    func prompt(kind: PromptKind, title: String, placeholder: String?) async -> String? { nil }

    func notify(_ message: String) async {
        notes.append(message)
    }

    func copyToClipboard(_ text: String, concealed: Bool, clearAfterMs: Int?) async {}
}

final class ExternalProviderTests: XCTestCase {
    func testNDJSONRoundTrip() async throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Examples/hello/main.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "Example provider missing at \(script.path)")

        let bridge = TestBridge()
        let manifest = ProviderManifest(
            id: "hello",
            name: "Hello Provider",
            trigger: "hello",
            engine: "command",
            command: ["/usr/bin/env", "python3", script.path],
            timeoutMs: 4_000,
            directory: script.deletingLastPathComponent()
        )
        let provider = ExternalProvider(manifest: manifest, host: bridge)
        let items = try await provider.search(SearchRequest(text: "world", limit: 10, isBound: true))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Hello from world")
        XCTAssertEqual(items.first?.providerID, "hello")

        if let item = items.first {
            try await provider.activate(item, action: item.primaryAction!)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let lastNotification = await bridge.lastNotification()
        XCTAssertEqual(lastNotification, "Hello from the example provider")
        await provider.shutdown()
    }
}
