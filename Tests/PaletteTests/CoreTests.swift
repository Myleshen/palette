import XCTest
import AppKit
import PaletteCore
import PalettePlatform
import PaletteProviders
import TOMLKit
import Carbon.HIToolbox

final class CoreTests: XCTestCase {
    func testAppLookupIsCaseInsensitive() throws {
        let path = ToolLocator.shared.appPath(named: "neovide")
        if !FileManager.default.fileExists(atPath: "/Applications/Neovide.app") {
            throw XCTSkip("Neovide is not installed on this machine")
        }
        XCTAssertEqual(path.map { ($0 as NSString).lastPathComponent }, "Neovide.app")
    }

    func testAppProviderRanksSafariExactly() async throws {
        guard FileManager.default.fileExists(atPath: "/Applications/Safari.app") else {
            throw XCTSkip("Safari is not installed on this machine")
        }
        let launcher = await MainActor.run { LauncherService() }
        let index = AppIndex()
        let apps = await index.applications()
        XCTAssertTrue(apps.contains { $0.name == "Safari" }, "App index should contain Safari")
        let provider = AppProvider(index: index, launcher: launcher)
        let items = try await provider.search(SearchRequest(text: "Safari", limit: 10, isBound: false))
        XCTAssertEqual(items.first?.title, "Safari")
    }

    func testCalculatorPrecedenceAndFunctions() {
        XCTAssertEqual(Calculator.evaluate("2 + 3 * 4")?.value, 14)
        XCTAssertEqual(Calculator.evaluate("(2 + 3) * 4")?.value, 20)
        XCTAssertEqual(Calculator.evaluate("2^3^2")?.value, 512)
        XCTAssertEqual(Calculator.evaluate("sqrt(81) + 1")?.value, 10)
        XCTAssertEqual(Calculator.evaluate("50%")?.value, 0.5)
        XCTAssertEqual(Calculator.evaluate("=10/4")?.value, 2.5)
        XCTAssertNil(Calculator.evaluate("hello"))
    }

    func testQueryParsingUsesLongestTrigger() {
        let parser = QueryParser(prefix: "/", triggers: [
            TriggerEntry(trigger: "neo", providerID: "neo"),
            TriggerEntry(trigger: "neof", providerID: "neof"),
            TriggerEntry(trigger: "zj", providerID: "zj"),
        ])

        let directories = parser.parse("/neo src/components")
        XCTAssertEqual(directories.providerID, "neo")
        XCTAssertEqual(directories.text, "src/components")

        let files = parser.parse("/neof README.md")
        XCTAssertEqual(files.providerID, "neof")
        XCTAssertEqual(files.text, "README.md")

        XCTAssertEqual(parser.parse("/neo").providerID, "neo")
        XCTAssertTrue(parser.parse("/neov").scope == .global)
        XCTAssertTrue(parser.parse("/Users/me/dev").scope == .global)
        XCTAssertEqual(parser.parse("/zj").providerID, "zj")
        XCTAssertEqual(parser.completion(for: "/ne"), "/neo ")
        XCTAssertEqual(parser.completion(for: "/z"), "/zj ")
    }

    func testRankingTiersAndMerge() {
        let exact = Ranking.score(query: "kitty", candidate: "kitty")!
        let prefix = Ranking.score(query: "kit", candidate: "kitty")!
        let substring = Ranking.score(query: "tt", candidate: "kitty")!
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, substring)

        let one = PaletteItem(id: "1", title: "Zed", score: 10, providerID: "apps")
        let two = PaletteItem(id: "2", title: "Alpha", score: 5, providerID: "apps")
        let duplicate = PaletteItem(id: "1", title: "Duplicate", score: 1, providerID: "apps")
        let merged = Ranking.merge([one, two, duplicate])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.title, "Zed")
    }

    func testScopeMatcherExcludesAndReincludes() {
        let scope = Scope(roots: ["/tmp/root"], exclude: [".git", "node_modules", "*.log"], include: ["important.log"])
        XCTAssertFalse(scope.allows(path: "/tmp/root/.git/config", isDirectory: false))
        XCTAssertFalse(scope.allows(path: "/tmp/root/node_modules/pkg/index.js", isDirectory: false))
        XCTAssertFalse(scope.allows(path: "/tmp/root/debug.log", isDirectory: false))
        XCTAssertTrue(scope.allows(path: "/tmp/root/important.log", isDirectory: false))
        XCTAssertTrue(scope.allows(path: "/tmp/root/src/main.swift", isDirectory: false))
    }

    func testConfigDefaultAndRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        let result = ConfigLoader.load(paths: paths)
        XCTAssertTrue(result.createdDefault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configFile.path))
        XCTAssertEqual(result.config.providerPrefix, "/")
        XCTAssertEqual(result.config.hotkey, "opt+space")
        XCTAssertEqual(result.config.scopes["projects"]?.roots.count, 2)
    }

    func testThemeLoaderFallsBackAndValidates() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-themes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let builtIn = ThemeLoader.load(name: "catppuccin-mocha", themesDirectory: directory)
        XCTAssertEqual(builtIn.theme.appearance, "dark")
        XCTAssertGreaterThan(builtIn.theme.palette.accent.count, 4)

        let missing = ThemeLoader.load(name: "does-not-exist", themesDirectory: directory, fallback: .defaultLight)
        XCTAssertEqual(missing.theme.name, Theme.defaultLight.name)
        XCTAssertFalse(missing.diagnostics.isEmpty)
    }

    func testParityDefaultsAndWebSearchConfigRoundTrip() throws {
        let config = PaletteConfig()
        XCTAssertFalse(config.appGrid)
        XCTAssertEqual(config.clipboard.maxEntries, 5_000)
        XCTAssertEqual(config.webSearchEngines.count, 4)
        XCTAssertEqual(config.clipboardHotkey, "opt+v")
        XCTAssertEqual(config.searchPosition, .top)
        XCTAssertEqual(config.webAppBrowser, "Helium")

        let table = try TOMLTable(string: ConfigWriter.render(config))
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertFalse(parsed.appGrid)
        XCTAssertEqual(parsed.clipboard.maxEntries, 5_000)
        XCTAssertEqual(parsed.webSearchEngines.map(\.name), config.webSearchEngines.map(\.name))
        XCTAssertEqual(parsed.clipboardHotkey, config.clipboardHotkey)
        XCTAssertEqual(parsed.searchPosition, .top)
        XCTAssertEqual(parsed.searchStyle, .classic)
        XCTAssertEqual(parsed.webAppBrowser, "Helium")
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertTrue(ThemeLoader.builtinNames.contains("gruvbox-dark"))
        XCTAssertTrue(ThemeLoader.builtinNames.contains("aetheria-pink"))

        var moved = config
        moved.searchPosition = .center
        moved.searchStyle = .pill
        moved.appSort = .frequent
        let movedTable = try TOMLTable(string: ConfigWriter.render(moved))
        var movedDiagnostics: [Diagnostic] = []
        let movedParsed = try ConfigLoader.parse(movedTable, diagnostics: &movedDiagnostics)
        XCTAssertEqual(movedParsed.searchPosition, .center)
        XCTAssertEqual(movedParsed.searchStyle, .pill)
        XCTAssertEqual(movedParsed.appSort, .frequent)
        XCTAssertTrue(movedDiagnostics.isEmpty)

        // 1.7.0 configs may still contain the removed "bottom" value.
        let legacy = try TOMLTable(string: "search_position = \"bottom\"")
        var legacyDiagnostics: [Diagnostic] = []
        let legacyParsed = try ConfigLoader.parse(legacy, diagnostics: &legacyDiagnostics)
        XCTAssertEqual(legacyParsed.searchPosition, .center)
        XCTAssertTrue(legacyDiagnostics.isEmpty)
    }

    func testWebAppBrowserValidation() {
        XCTAssertNil(BrowserCatalog.validationError(for: "Helium"),
                     "The default Helium browser should validate when installed")
        XCTAssertNotNil(BrowserCatalog.validationError(for: "Definitely Not A Browser"),
                        "Unknown browsers must fail validation instead of being saved")
        XCTAssertNotNil(BrowserCatalog.validationError(for: "Safari"),
                        "Only Chromium-based browsers are allowed for web apps")
    }

    func testLonePrefixIsNotAProviderQuery() {
        let parser = QueryParser(prefix: "/", triggers: [TriggerEntry(trigger: "zj", providerID: "zj")])
        XCTAssertEqual(parser.parse("/").text, "")
        XCTAssertTrue(parser.parse("/zj").text.isEmpty)
    }

    func testWebSearchProviderSuppressesPrefixQueries() async throws {
        let launcher = await MainActor.run { LauncherService() }
        let provider = WebSearchProvider(engines: WebSearchEngine.defaults, enabled: true, launcher: launcher)
        let rows = try await provider.search(SearchRequest(text: "swift concurrency", limit: 10, isBound: false))
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows[0].title.contains("Google"))
        let prefix = try await provider.search(SearchRequest(text: "/", limit: 10, isBound: false))
        XCTAssertTrue(prefix.isEmpty)
    }

    func testHotKeySpecNormalizesWhitespace() {
        let spec = HotKeySpec.parse("opt+ space")
        XCTAssertEqual(spec?.display, "opt+space")
        XCTAssertEqual(spec?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(spec?.modifiers, UInt32(optionKey))

        let commandSpace = HotKeySpec.parse("cmd+space")
        XCTAssertEqual(commandSpace?.display, "cmd+space")
        XCTAssertEqual(commandSpace?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(commandSpace?.modifiers, UInt32(cmdKey))
    }

    func testShortcutRecorderTurnsKeyPressIntoCanonicalSpec() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )
        let spec = event.flatMap(HotKeySpec.from(event:))
        XCTAssertEqual(spec?.display, "opt+space")
        XCTAssertEqual(spec?.keyCode, UInt32(kVK_Space))

        let commandEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )
        let commandSpec = commandEvent.flatMap(HotKeySpec.from(event:))
        XCTAssertEqual(commandSpec?.display, "cmd+space")
        XCTAssertEqual(commandSpec?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(commandSpec?.modifiers, UInt32(cmdKey))
    }

    func testEmojiCatalogIsLargeAndSearchable() async throws {
        XCTAssertGreaterThan(EmojiCatalog.all.count, 3_900)
        let star = try XCTUnwrap(EmojiCatalog.all.first { $0.glyph == "⭐" })
        XCTAssertEqual(star.appleName, "star")
        XCTAssertFalse(star.group.isEmpty)
        let provider = EmojiProvider()
        let items = try await provider.search(SearchRequest(text: "rocket", limit: 20, isBound: true))
        XCTAssertTrue(items.contains { $0.title.contains("🚀") })
        let dragons = try await provider.search(SearchRequest(text: "dragon", limit: 20, isBound: true))
        XCTAssertTrue(dragons.contains { $0.title.contains("Dragon") })
        XCTAssertFalse(dragons.contains { $0.title.contains("Triangle") })
    }

    func testThemeFileParsesIntegerMetricsAndComposition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.toml")
        try """
        extends = "default-dark"
        name = "Test"
        [window]
        width = 720
        max_height = 520
        [list]
        row_height = 40
        density = "compact"
        selection = "bar"
        [motion]
        duration_ms = 60
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = ThemeLoader.load(name: "test", themesDirectory: directory)
        XCTAssertEqual(result.theme.window.width, 720)
        XCTAssertEqual(result.theme.window.maxHeight, 520)
        XCTAssertEqual(result.theme.list.rowHeight, 40)
        XCTAssertEqual(result.theme.motion.durationMs, 60)
        XCTAssertEqual(result.theme.effectiveRowHeight, 38, accuracy: 0.01)
        XCTAssertEqual(result.theme.list.selection, "bar")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
}
