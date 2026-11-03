import XCTest
import Foundation
import TOMLKit
import PaletteCore
import PalettePlatform
import PaletteProviders
import PaletteRuntime

final class DeveloperWorkflowTests: XCTestCase {
    private final class StubProvider: PaletteProvider, @unchecked Sendable {
        let descriptor: ProviderDescriptor
        init(id: String, trigger: String?, priority: Int = 0) {
            descriptor = ProviderDescriptor(id: id, name: id, trigger: trigger, isGlobal: false, priority: priority)
        }
        func search(_ request: SearchRequest) async throws -> [PaletteItem] { [] }
    }

    func testClipboardTransforms() {
        XCTAssertEqual(ClipboardTransform.trim.apply(to: "  hi \n"), "hi")
        XCTAssertEqual(ClipboardTransform.uppercase.apply(to: "abc"), "ABC")
        XCTAssertEqual(ClipboardTransform.base64Encode.apply(to: "hi"), "aGk=")
        XCTAssertEqual(ClipboardTransform.base64Decode.apply(to: "aGk="), "hi")
        XCTAssertEqual(ClipboardTransform.slug.apply(to: "Hello, Wörld!"), "hello-world")
        XCTAssertEqual(ClipboardTransform.dedupeLines.apply(to: "a\nb\na"), "a\nb")
        XCTAssertEqual(ClipboardTransform.sortLines.apply(to: "b\na"), "a\nb")
        XCTAssertEqual(ClipboardTransform.shellQuote.apply(to: "it's"), "'it'\\''s'")
        XCTAssertEqual(ClipboardTransform.markdownLink.apply(to: "Label\nhttps://example.com"), "[Label](https://example.com)")
        XCTAssertNotNil(ClipboardTransform.jsonPretty.apply(to: "{\"b\":1,\"a\":2}"))
        XCTAssertNil(ClipboardTransform.jsonPretty.apply(to: "not json"))
        XCTAssertEqual(ClipboardTransform.stripANSI.apply(to: "\u{001B}[31mred\u{001B}[0m"), "red")
    }

    func testTypographyAndProviderConfigRoundTrip() throws {
        var config = PaletteConfig()
        config.typography = TypographyConfig(uiFamily: "Avenir Next", monoFamily: "Menlo", uiSize: 15, monoSize: 13)
        config.providerAliases = ["apps": ["a", "launch"], "clip": ["cb"]]
        config.providerOrder = ["clip", "apps"]
        let table = try TOMLTable(string: ConfigWriter.render(config))
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.typography, config.typography)
        XCTAssertEqual(parsed.providerAliases["apps"] ?? [], ["a", "launch"])
        XCTAssertEqual(parsed.providerOrder, ["clip", "apps"])
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testRegistryAliasesAndConfiguredOrder() {
        let apps = StubProvider(id: "apps", trigger: "apps", priority: 100)
        let clip = StubProvider(id: "clip", trigger: "clip", priority: 10)
        let registry = ProviderRegistry(
            providers: [apps, clip],
            prefix: "/",
            aliases: ["apps": ["launch"]],
            order: ["clip", "apps"]
        )
        XCTAssertEqual(registry.providers.map(\.descriptor.id), ["clip", "apps"])
        let parsed = registry.parser.parse("/launch safari")
        XCTAssertEqual(parsed.providerID, "apps")
        XCTAssertEqual(parsed.text, "safari")
    }

    func testLocalWebAppURLsNormalize() {
        XCTAssertEqual(WebAppURL.normalize("http://localhost:5871")?.absoluteString, "http://localhost:5871")
        XCTAssertEqual(WebAppURL.normalize("http://127.0.0.1:5871")?.absoluteString, "http://127.0.0.1:5871")
        XCTAssertNil(WebAppURL.normalize("not a url"))
    }

    func testCommandManifestLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commands-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        [[command]]
        title = "Go Test"
        keywords = ["go", "test"]
        executable = "go"
        args = ["test", "./..."]
        cwd = "~/dev/project"
        terminal = true
        confirm = true
        """.write(to: url, atomically: true, encoding: .utf8)

        let commands = CommandProvider.load(from: url)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].title, "Go Test")
        XCTAssertEqual(commands[0].arguments, ["test", "./..."])
        XCTAssertEqual(commands[0].workingDirectory, "~/dev/project")
        XCTAssertTrue(commands[0].confirm)
    }
}
