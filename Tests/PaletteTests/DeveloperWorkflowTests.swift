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
        let items: [PaletteItem]
        init(id: String, trigger: String?, priority: Int = 0, isGlobal: Bool = false, items: [PaletteItem] = []) {
            descriptor = ProviderDescriptor(id: id, name: id, trigger: trigger, isGlobal: isGlobal, priority: priority)
            self.items = items
        }
        func search(_ request: SearchRequest) async throws -> [PaletteItem] { items }
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
        let yaml = ClipboardTransform.yamlFormat.apply(to: "b: 2\na: 1\n")
        XCTAssertNotNil(yaml)
        XCTAssertTrue(yaml?.contains("a: 1") == true)
        let toml = ClipboardTransform.tomlFormat.apply(to: "title = \"x\"\n")
        XCTAssertNotNil(toml)
        XCTAssertTrue(toml?.contains("title") == true)
    }

    func testTypographyAndProviderConfigRoundTrip() throws {
        var config = PaletteConfig()
        config.typography = TypographyConfig(
            uiFamily: "Avenir Next",
            monoFamily: "Menlo",
            uiSize: 15,
            monoSize: 13,
            previewSize: 16
        )
        config.providerAliases = ["apps": ["a", "launch"], "clip": ["cb"]]
        config.providerOrder = ["clip", "apps"]
        config.disabledProviders = ["port"]
        config.globalProviders = ["timer"]
        config.terminalSession = TerminalSessionConfig(multiplexer: .tmux, name: "Work", shell: "fish")
        let table = try TOMLTable(string: ConfigWriter.render(config))
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.typography, config.typography)
        XCTAssertEqual(parsed.providerAliases["apps"] ?? [], ["a", "launch"])
        XCTAssertEqual(parsed.providerOrder, ["clip", "apps"])
        XCTAssertEqual(parsed.disabledProviders, ["port"])
        XCTAssertEqual(parsed.globalProviders, ["timer"])
        XCTAssertEqual(parsed.terminalSession, config.terminalSession)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testPreviewSizeDefaultsAndClamps() throws {
        XCTAssertEqual(PaletteConfig().typography.previewSize, 13)

        var diagnostics: [Diagnostic] = []
        let high = try ConfigLoader.parse(
            TOMLTable(string: "[typography]\npreview_size = 99\n"),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(high.typography.previewSize, 24)
        let low = try ConfigLoader.parse(
            TOMLTable(string: "[typography]\npreview_size = 3\n"),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(low.typography.previewSize, 9)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testPreviewTextSizeFollowsThemeTypography() {
        XCTAssertEqual(Theme().previewTextSize, 13)
        var theme = Theme()
        theme.typography.previewSize = 17
        XCTAssertEqual(theme.previewTextSize, 17)
        theme.typography.previewSize = 99
        XCTAssertEqual(theme.previewTextSize, 24)
    }

    func testGlobalProviderConfigRoundTripAndMigration() throws {
        var config = PaletteConfig()
        config.globalProviders = ["timer"]
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(TOMLTable(string: ConfigWriter.render(config)), diagnostics: &diagnostics)
        XCTAssertEqual(parsed.globalProviders, ["timer"])
        XCTAssertTrue(diagnostics.isEmpty)

        // 2.12.x configs read `global` as extras; the untouched list upgrades.
        let legacy = try ConfigLoader.parse(
            TOMLTable(string: "[providers]\nglobal = [\"system\", \"timer\", \"awake\"]\n"),
            diagnostics: &diagnostics
        )
        XCTAssertEqual(legacy.globalProviders, PaletteConfig.defaultGlobalProviders)
        XCTAssertTrue(legacy.globalProviders.contains("calc"))
    }

    func testRegistrySkipsDisabledProviders() {
        let apps = StubProvider(id: "apps", trigger: "apps", priority: 100)
        let clip = StubProvider(id: "clip", trigger: "clip", priority: 10)
        let port = StubProvider(id: "port", trigger: "port", priority: 5)
        let registry = ProviderRegistry(providers: [apps, clip, port], prefix: "/", disabled: ["port"])
        XCTAssertEqual(registry.providers.map(\.descriptor.id), ["apps", "clip"])
        XCTAssertEqual(registry.parser.parse("/port 3000").scope, .global)
    }

    func testRegistrySearchesOnlyAllowlistedProvidersUnprefixed() async {
        let apps = StubProvider(id: "apps", trigger: "apps", priority: 100, items: [
            PaletteItem(id: "apps:safari", title: "Safari", providerID: "apps"),
        ])
        let timer = StubProvider(id: "timer", trigger: "timer", priority: 5, items: [
            PaletteItem(id: "timer:1", title: "5 minutes", providerID: "timer"),
        ])
        let bookmark = StubProvider(id: "bookmark", trigger: nil, priority: 1, isGlobal: true, items: [
            PaletteItem(id: "bookmark:1", title: "5 docs", providerID: "bookmark"),
        ])
        let registry = ProviderRegistry(providers: [apps, timer, bookmark], prefix: "/", global: ["timer"])
        XCTAssertTrue(registry.diagnostics.isEmpty)
        XCTAssertEqual(registry.globalProviderIDs, ["apps", "timer"])
        let result = await registry.search(raw: "5")
        XCTAssertEqual(Set(result.items.map(\.id)), ["apps:safari", "timer:1"])

        let empty = ProviderRegistry(providers: [apps, bookmark], prefix: "/", global: [])
        XCTAssertEqual(empty.globalProviderIDs, ["apps"])
        let fallback = await empty.search(raw: "5")
        XCTAssertEqual(fallback.items.map(\.id), ["apps:safari"])

        let unknown = ProviderRegistry(providers: [apps], prefix: "/", global: ["nope"])
        XCTAssertTrue(unknown.diagnostics.contains { $0.level == .warning && $0.message.contains("nope") })
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

    func testProcessRunnerTimeoutKillsChild() async throws {
        let start = Date()
        let result = try await ProcessRunner.run(["/bin/sleep", "5"], timeout: 0.2)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
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

    func testCommandRowsWithTheSameTitleAndExecutableGetDistinctIDs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commands-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        [[command]]
        title = "Go"
        executable = "go"
        args = ["build", "./..."]

        [[command]]
        title = "Go"
        executable = "go"
        args = ["test", "./..."]
        """.write(to: url, atomically: true, encoding: .utf8)

        let commands = CommandProvider.load(from: url)
        XCTAssertEqual(commands.count, 2)
        XCTAssertNotEqual(commands[0].id, commands[1].id)
        XCTAssertEqual(commands[0].arguments, ["build", "./..."])
        XCTAssertEqual(commands[1].arguments, ["test", "./..."])
    }
}
