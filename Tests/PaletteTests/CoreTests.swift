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

    func testEmptyProviderAliasListDisablesDefaults() throws {
        var config = PaletteConfig()
        config.providerAliases = ["neo": []]
        let table = try TOMLTable(string: ConfigWriter.render(config))
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.providerAliases["neo"], [])
        XCTAssertEqual(parsed.providerAliases["neof"], ProviderAliases.defaults["neof"])
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testLegacySizingKeysAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-rows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)

        // 2.17.1 dropped manual sizing. Older files keep parsing, and the next
        // save rewrites [window] without the dead keys.
        try """
        visible_rows = 6
        [window]
        auto_size = false
        scale = 1.4
        width = 1200
        max_height = 400
        visible_rows = 3
        clipboard_width = 900
        preview_width = 700
        terminal_width = 1200
        provider_bar = "left"
        preview_layout = "below"
        favicons = false
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        let loaded = ConfigLoader.load(paths: paths).config
        XCTAssertEqual(loaded.window.providerBar, .left)
        XCTAssertEqual(loaded.window.previewLayout, .below)
        XCTAssertFalse(loaded.window.favicons)

        let rendered = ConfigWriter.render(loaded)
        XCTAssertFalse(rendered.contains("width ="), "the writer drops the removed sizing keys")
        XCTAssertFalse(rendered.contains("visible_rows"))
        XCTAssertFalse(rendered.contains("scale ="))
    }

    func testSSHConfigParsing() {
        let text = """
        # comment
        Host prod
          HostName 10.0.0.5
          User deploy
          Port 2222

        Host *.internal
          User nobody

        Host staging
          HostName staging.example.com
        """
        let hosts = SSHConfig.parse(text)
        XCTAssertEqual(hosts.map(\.alias), ["prod", "staging"], "wildcards are skipped")
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].port, "2222")
        XCTAssertEqual(hosts[0].destination, "deploy@prod")
        XCTAssertNil(hosts[1].user)
    }

    func testSSHConfigEmitsEveryPatternAndFollowsInclude() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        Host jump
          HostName jump.example.com
        """.write(
            to: directory.appendingPathComponent("extra.conf"),
            atomically: true,
            encoding: .utf8
        )

        let text = """
        Include extra.conf

        Host a b c
          HostName shared.example.com
          User deploy
          Port 2222

        Host after
        """
        let hosts = SSHConfig.parse(text, directory: directory)
        XCTAssertEqual(hosts.map(\.alias), ["a", "after", "b", "c", "jump"])
        XCTAssertEqual(hosts.first { $0.alias == "a" }?.hostName, "shared.example.com")
        XCTAssertEqual(hosts.first { $0.alias == "b" }?.user, "deploy")
        XCTAssertEqual(hosts.first { $0.alias == "c" }?.port, "2222")
        XCTAssertEqual(hosts.first { $0.alias == "jump" }?.hostName, "jump.example.com")
    }

    func testCaptureConfigParsesAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try """
        [capture]
        directory = "~/Pictures/Shots"
        screenshot_action = "copy"
        recording_format = "mp4"
        delay = 3
        show_clicks = true
        edit_after_capture = true
        preview_recording = false
        recording_target = "display"
        recording_display = 2
        recording_region = "10,20,300,400"
        recording_audio = true
        sound = false
        thumbnail = false
        gallery = "palette"
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        var config = ConfigLoader.load(paths: paths).config
        XCTAssertTrue(config.capture.directory.hasSuffix("Pictures/Shots"))
        XCTAssertFalse(config.capture.directory.contains("~"))
        XCTAssertEqual(config.capture.screenshotAction, .copy)
        XCTAssertEqual(config.capture.recordingFormat, "mp4")
        XCTAssertEqual(config.capture.delay, 3)
        XCTAssertTrue(config.capture.showClicks)
        XCTAssertTrue(config.capture.editAfterCapture)
        XCTAssertFalse(config.capture.previewRecording)
        XCTAssertEqual(config.capture.recordingTarget, "display")
        XCTAssertEqual(config.capture.recordingDisplay, 2)
        XCTAssertEqual(config.capture.recordingRegion, "10,20,300,400")
        XCTAssertTrue(config.capture.recordingAudio)
        XCTAssertFalse(config.capture.captureSound)
        XCTAssertFalse(config.capture.captureThumbnail)
        XCTAssertEqual(config.capture.gallery, "palette")
        XCTAssertFalse(config.capture.screenshotAction.savesFile)
        XCTAssertTrue(config.capture.screenshotAction.copiesToClipboard)

        config.capture.screenshotAction = .saveCopy
        config.capture.editAfterCapture = false
        config.capture.previewRecording = true
        config.capture.recordingTarget = "region"
        config.capture.recordingAudio = false
        try ConfigWriter.render(config).write(to: paths.configFile, atomically: true, encoding: .utf8)
        let reloaded = ConfigLoader.load(paths: paths).config
        XCTAssertEqual(reloaded.capture.screenshotAction, .saveCopy)
        XCTAssertFalse(reloaded.capture.editAfterCapture)
        XCTAssertTrue(reloaded.capture.previewRecording)
        XCTAssertEqual(reloaded.capture.recordingTarget, "region")
        XCTAssertFalse(reloaded.capture.recordingAudio)
    }

    func testOldCaptureShortcutDefaultsAreMigrated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-hotkeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try """
        screenshot_hotkey = "cmd+option+shift+s"
        recording_hotkey = "cmd+option+shift+r"
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        let config = ConfigLoader.load(paths: paths).config
        XCTAssertEqual(config.screenshotHotkey, "cmd+shift+3")
        XCTAssertEqual(config.recordingHotkey, "cmd+shift+5")
    }

    func testCustomCaptureShortcutIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-hotkeys2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try """
        screenshot_hotkey = "cmd+option+9"
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(ConfigLoader.load(paths: paths).config.screenshotHotkey, "cmd+option+9")
    }

    func testTimerDurationParsing() {
        XCTAssertEqual(TimerDuration.parse("25m"), 1500)
        XCTAssertEqual(TimerDuration.parse("90s"), 90)
        XCTAssertEqual(TimerDuration.parse("1h30m"), 5400)
        XCTAssertEqual(TimerDuration.parse("1h 30m"), 5400)
        XCTAssertEqual(TimerDuration.parse("1:30"), 90)
        XCTAssertEqual(TimerDuration.parse("1:05:00"), 3900)
        XCTAssertEqual(TimerDuration.parse("2"), 120, "a bare number means minutes")
        XCTAssertNil(TimerDuration.parse(""))
        XCTAssertNil(TimerDuration.parse("abc"))
        XCTAssertNil(TimerDuration.parse("0"))
        XCTAssertNil(TimerDuration.parse("1:75"), "seconds must be below 60")

        XCTAssertEqual(TimerDuration.format(1500), "25:00")
        XCTAssertEqual(TimerDuration.format(0), "0:00")
        XCTAssertEqual(TimerDuration.format(3900), "1:05:00")
        XCTAssertEqual(TimerDuration.format(59.2), "1:00", "rounds up so the last second is visible")

        XCTAssertEqual(TimerDuration.label(1500), "25 minutes")
        XCTAssertEqual(TimerDuration.label(5400), "1 hour 30 minutes")
    }

    func testWindowConfigParsesFromTOML() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try """
        [window]
        provider_bar = "left"
        preview_layout = "beside"
        favicons = false
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        var loaded = ConfigLoader.load(paths: paths).config
        XCTAssertEqual(loaded.window.providerBar, .left)
        XCTAssertEqual(loaded.window.previewLayout, .beside)
        XCTAssertFalse(loaded.window.favicons)

        // A settings save must round-trip the surviving [window] table.
        loaded.window.previewLayout = .below
        try ConfigWriter.render(loaded).write(to: paths.configFile, atomically: true, encoding: .utf8)
        let reloaded = ConfigLoader.load(paths: paths).config.window
        XCTAssertEqual(reloaded.providerBar, .left)
        XCTAssertEqual(reloaded.previewLayout, .below)
        XCTAssertFalse(reloaded.favicons)
    }

    func testAutoPreviewLayoutChoosesASidePerFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try "[window]\npreview_layout = \"auto\"\n"
            .write(to: paths.configFile, atomically: true, encoding: .utf8)

        let loaded = ConfigLoader.load(paths: paths).config.window
        XCTAssertEqual(loaded.previewLayout, .auto)
        // Auto reads the fixed frame, not the screen: a portrait frame is too
        // narrow for a list beside the pane, a landscape frame is not.
        let portrait = loaded.launcherSize(for: CGSize(width: 800, height: 1280))
        XCTAssertEqual(loaded.resolvedPreviewLayout(frameWidth: Double(portrait.width)), .below)
        let landscape = loaded.launcherSize(for: CGSize(width: 1440, height: 900))
        XCTAssertEqual(loaded.resolvedPreviewLayout(frameWidth: Double(landscape.width)), .beside)
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

    func testSiriThemesAreDefaultAndCatalogued() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-themes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = ThemeLoader.catalog(themesDirectory: directory)
        let silver = catalog.first { $0.name == "siri-silver" }
        let graphite = catalog.first { $0.name == "siri-graphite" }
        XCTAssertEqual(silver?.appearance, "light")
        XCTAssertEqual(silver?.displayName, "Siri Silver")
        XCTAssertEqual(graphite?.appearance, "dark")
        XCTAssertEqual(graphite?.displayName, "Siri Graphite")

        XCTAssertEqual(ThemeLoader.load(name: "siri-silver", themesDirectory: directory).theme.palette.bg, "#e9ebf0")
        XCTAssertEqual(ThemeLoader.load(name: "siri-graphite", themesDirectory: directory).theme.palette.bg, "#24262d")

        let selection = PaletteConfig().theme
        XCTAssertEqual(selection.dark, "siri-graphite")
        XCTAssertEqual(selection.light, "siri-silver")
    }

    func testWebSearchEngineBangFieldsRoundTrip() throws {
        var config = PaletteConfig()
        config.webSearchEngines[0].keyword = "goog"
        config.webSearchEngines[0].browser = "Safari"
        config.webSearchEngines[0].appMode = true
        let rendered = ConfigWriter.render(config)
        XCTAssertEqual(rendered.components(separatedBy: "app_mode = true").count - 1, 1)
        let table = try TOMLTable(string: rendered)
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.webSearchEngines[0].keyword, "goog")
        XCTAssertEqual(parsed.webSearchEngines[0].browser, "Safari")
        XCTAssertTrue(parsed.webSearchEngines[0].appMode)
        XCTAssertEqual(parsed.webSearchEngines[1].browser, "")
        XCTAssertFalse(parsed.webSearchEngines[1].appMode)
    }

    func testStockWebSearchEnginesCarryKeywords() {
        XCTAssertEqual(WebSearchEngine.defaults.map(\.keyword), ["g", "ddg", "gh", "yt"])
    }

    func testRestoringDefaultsReAddsDeletedStockEngine() {
        let engines = WebSearchEngine.defaults.filter { $0.name != "GitHub" }
        let restored = WebSearchEngine.restoringDefaults(into: engines)
        XCTAssertEqual(restored.map(\.name), ["Google", "DuckDuckGo", "YouTube", "GitHub"])
        XCTAssertEqual(restored.last?.keyword, "gh")
    }

    func testRestoringDefaultsBackfillsMissingKeyword() {
        let engines = [
            WebSearchEngine(name: "Google", urlTemplate: "https://example.com/?q={query}", browser: "Safari"),
        ]
        let restored = WebSearchEngine.restoringDefaults(into: engines)
        XCTAssertEqual(restored.first?.keyword, "g")
        XCTAssertEqual(restored.first?.urlTemplate, "https://example.com/?q={query}")
        XCTAssertEqual(restored.first?.browser, "Safari")
    }

    func testRestoringDefaultsKeepsCustomEnginesAndCustomKeywords() {
        let engines = [
            WebSearchEngine(name: "Google", urlTemplate: "https://www.google.com/search?q={query}", keyword: "goog"),
            WebSearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q={query}", keyword: "k"),
        ]
        let restored = WebSearchEngine.restoringDefaults(into: engines)
        XCTAssertEqual(restored.count, 5)
        XCTAssertEqual(restored.map(\.name), ["Google", "Kagi", "DuckDuckGo", "GitHub", "YouTube"])
        XCTAssertEqual(restored[0].keyword, "goog")
        XCTAssertEqual(restored[1].keyword, "k")
    }

    func testBackfillFillsAnEmptyKeywordOnAStockEngine() {
        let engines = [
            WebSearchEngine(name: "Google", urlTemplate: "https://www.google.com/search?q={query}"),
        ]
        let filled = WebSearchEngine.backfillingKeywords(into: engines)
        XCTAssertEqual(filled.map(\.keyword), ["g"])
        XCTAssertEqual(filled.map(\.urlTemplate), engines.map(\.urlTemplate))
    }

    func testBackfillLeavesACustomKeywordUntouched() {
        let engines = [
            WebSearchEngine(name: "Google", urlTemplate: "https://www.google.com/search?q={query}", keyword: "goog"),
        ]
        XCTAssertEqual(WebSearchEngine.backfillingKeywords(into: engines).map(\.keyword), ["goog"])
    }

    func testBackfillDoesNotResurrectADeletedStockEngine() {
        let engines = WebSearchEngine.defaults.filter { $0.name != "GitHub" }
        let filled = WebSearchEngine.backfillingKeywords(into: engines)
        XCTAssertEqual(filled.map(\.name), ["Google", "DuckDuckGo", "YouTube"])
    }

    func testBackfillLeavesACustomEngineUntouched() {
        let engines = [WebSearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q={query}")]
        let filled = WebSearchEngine.backfillingKeywords(into: engines)
        XCTAssertEqual(filled, engines)
        XCTAssertNil(filled[0].keyword)
    }

    func testLoadBackfillsKeywordsFromAPreBangConfig() throws {
        let table = try TOMLTable(string: """
        [[web_search.engines]]
        name = "Google"
        url = "https://www.google.com/search?q={query}"
        """)
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.webSearchEngines.map(\.keyword), ["g"])
    }

    func testParityDefaultsAndWebSearchConfigRoundTrip() throws {
        var config = PaletteConfig()
        config.searchPlaceholder = "Find anything"
        XCTAssertEqual(config.clipboard.maxText, 100)
        XCTAssertEqual(config.clipboard.maxImages, 20)
        XCTAssertEqual(config.clipboard.maxFiles, 20)
        XCTAssertEqual(config.webSearchEngines.count, 4)
        XCTAssertEqual(config.clipboardHotkey, "opt+v")
        XCTAssertEqual(config.terminalHotkey, "cmd+option+t")
        XCTAssertEqual(config.scratchpadHotkey, "cmd+option+s")
        XCTAssertEqual(config.askHotkey, "cmd+option+a")
        XCTAssertEqual(config.searchPosition, .top)
        XCTAssertEqual(config.webAppBrowser, "Helium")

        let table = try TOMLTable(string: ConfigWriter.render(config))
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.clipboard.maxText, 100)
        XCTAssertEqual(parsed.webSearchEngines.map(\.name), config.webSearchEngines.map(\.name))
        XCTAssertEqual(parsed.clipboardHotkey, config.clipboardHotkey)
        XCTAssertEqual(parsed.terminalHotkey, config.terminalHotkey)
        XCTAssertEqual(parsed.scratchpadHotkey, config.scratchpadHotkey)
        XCTAssertEqual(parsed.askHotkey, config.askHotkey)
        XCTAssertEqual(parsed.searchPosition, .top)
        XCTAssertEqual(parsed.webAppBrowser, "Helium")
        XCTAssertEqual(parsed.searchPlaceholder, "Find anything")
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertTrue(ThemeLoader.builtinNames.contains("gruvbox-dark"))
        XCTAssertTrue(ThemeLoader.builtinNames.contains("aetheria-pink"))
        XCTAssertEqual(parsed.providerAliases["neo"], ProviderAliases.defaults["neo"])
        XCTAssertEqual(parsed.providerAliases["neof"], ProviderAliases.defaults["neof"])

        var disabled = config
        disabled.terminalHotkey = ""
        disabled.scratchpadHotkey = ""
        disabled.askHotkey = ""
        let disabledTable = try TOMLTable(string: ConfigWriter.render(disabled))
        var disabledDiagnostics: [Diagnostic] = []
        let disabledParsed = try ConfigLoader.parse(disabledTable, diagnostics: &disabledDiagnostics)
        XCTAssertTrue(disabledParsed.terminalHotkey.isEmpty)
        XCTAssertTrue(disabledParsed.scratchpadHotkey.isEmpty)
        XCTAssertTrue(disabledParsed.askHotkey.isEmpty)
        XCTAssertTrue(disabledDiagnostics.isEmpty)

        var moved = config
        moved.searchPosition = .center
        moved.appSort = .frequent
        let movedTable = try TOMLTable(string: ConfigWriter.render(moved))
        var movedDiagnostics: [Diagnostic] = []
        let movedParsed = try ConfigLoader.parse(movedTable, diagnostics: &movedDiagnostics)
        XCTAssertEqual(movedParsed.searchPosition, .center)
        XCTAssertEqual(movedParsed.appSort, .frequent)
        XCTAssertTrue(movedDiagnostics.isEmpty)

        // Older configs may still contain removed layout keys.
        let legacy = try TOMLTable(string: "search_position = \"bottom\"")
        var legacyDiagnostics: [Diagnostic] = []
        let legacyParsed = try ConfigLoader.parse(legacy, diagnostics: &legacyDiagnostics)
        XCTAssertEqual(legacyParsed.searchPosition, .center)
        XCTAssertTrue(legacyDiagnostics.isEmpty)
    }

    func testSnippetExpansionAndLoading() throws {
        let expanded = SnippetExpansion.expand(
            "{{date}}|{{time}}|{{clipboard}}|{{unknown}}",
            now: Date(timeIntervalSince1970: 0),
            clipboard: "copied",
            home: "/home/test",
            user: "tester"
        )
        XCTAssertFalse(expanded.contains("{{date}}"))
        XCTAssertFalse(expanded.contains("{{time}}"))
        XCTAssertTrue(expanded.contains("|copied|"))
        XCTAssertTrue(expanded.hasSuffix("|{{unknown}}"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        [[snippet]]
        title = "Signature"
        keywords = ["mail"]
        text = "Best,\\nMyles"
        """.write(to: url, atomically: true, encoding: .utf8)
        let snippets = SnippetProvider.load(from: url)
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.title, "Signature")
        XCTAssertEqual(snippets.first?.keywords, ["mail"])
    }

    func testLegacyGridKeysAreIgnored() throws {
        let legacy = try TOMLTable(string: "app_grid = true\napp_grid_columns = 8")
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(legacy, diagnostics: &diagnostics)
        XCTAssertEqual(parsed, PaletteConfig())
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testWebAppBrowserValidation() {
        // Helium is the maintainer's default browser; CI runners ship without it.
        if FileManager.default.fileExists(atPath: "/Applications/Helium.app") {
            XCTAssertNil(BrowserCatalog.validationError(for: "Helium"),
                         "The default Helium browser should validate when installed")
        }
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

    func testHotKeySpecPrettyDisplayUsesKeycaps() {
        XCTAssertEqual(HotKeySpec.parse("opt+space")?.prettyDisplay, "⌥Space")
        XCTAssertEqual(HotKeySpec.parse("cmd+shift+3")?.prettyDisplay, "⌘⇧3")
        XCTAssertEqual(HotKeySpec.parse("ctrl+opt+shift+cmd+a")?.prettyDisplay, "⌘⌃⌥⇧A")
        XCTAssertEqual(HotKeySpec.parse("cmd+return")?.prettyDisplay, "⌘↩")
        // The stored/config form stays canonical.
        XCTAssertEqual(HotKeySpec.parse("cmd+shift+3")?.display, "cmd+shift+3")
    }

    func testHotkeyBindingsParseRenderAndRoundTrip() throws {
        var config = PaletteConfig()
        config.bindings = [
            HotkeyBinding(keys: "ctrl+alt+g", action: .launch, value: "Ghostty"),
            HotkeyBinding(keys: "ctrl+alt+k", action: .command, value: "echo hi >> /tmp/palette-bindings"),
            HotkeyBinding(keys: "ctrl+alt+c", action: .provider, value: "calc"),
            HotkeyBinding(keys: "ctrl+alt+d", action: .url, value: "https://example.com"),
        ]
        let rendered = ConfigWriter.render(config)
        XCTAssertEqual(rendered.components(separatedBy: "[[binding]]").count - 1, 4)
        let table = try TOMLTable(string: rendered)
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.bindings, config.bindings)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testHotkeyBindingParseSkipsInvalidRows() throws {
        let table = try TOMLTable(string: """
        [[binding]]
        keys = "ctrl+alt+g"
        action = "launch"
        value = "Ghostty"

        [[binding]]
        keys = ""
        action = "command"
        value = "echo hi"

        [[binding]]
        keys = "ctrl+alt+x"
        action = "explode"
        value = "x"

        [[binding]]
        keys = "ctrl+alt+y"
        action = "url"
        value = "https://example.com"
        """)
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(table, diagnostics: &diagnostics)
        XCTAssertEqual(parsed.bindings.map(\.keys), ["ctrl+alt+g", "ctrl+alt+y"])
        XCTAssertEqual(diagnostics.count, 2)
    }

    func testHotkeyBindingsRejectInvalidDuplicateAndReservedKeys() {
        let bindings = [
            HotkeyBinding(keys: "ctrl+alt+g", action: .launch, value: "Ghostty"),
            HotkeyBinding(keys: "alt+ctrl+g", action: .url, value: "https://example.com"),
            HotkeyBinding(keys: "ctrl+shift+nonsense", action: .command, value: "echo hi"),
            HotkeyBinding(keys: "cmd+shift+3", action: .launch, value: "Photos"),
            HotkeyBinding(keys: "ctrl+alt+k", action: .command, value: ""),
            HotkeyBinding(keys: "ctrl+alt+l", action: .provider, value: "calc"),
        ]
        let plan = HotKeyBindings.usable(bindings, reserved: ["cmd+shift+3"])
        XCTAssertEqual(plan.usable.map(\.keys), ["ctrl+alt+g", "ctrl+alt+l"])
        XCTAssertEqual(plan.issues.count, 4)
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
        // Sizing is config-owned: a theme's width/max_height are ignored.
        XCTAssertEqual(result.theme.window.width, 680)
        XCTAssertEqual(result.theme.window.maxHeight, 720)
        XCTAssertEqual(result.theme.list.rowHeight, 40)
        XCTAssertEqual(result.theme.motion.durationMs, 60)
        XCTAssertEqual(result.theme.effectiveRowHeight, 38, accuracy: 0.01)
        XCTAssertEqual(result.theme.list.selection, "bar")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testProviderBarDefaultsToTopAndRoundTrips() throws {
        XCTAssertEqual(PaletteConfig().window.providerBar, .top)
        for placement in ProviderBarPlacement.allCases {
            var config = PaletteConfig()
            config.window.providerBar = placement
            let rendered = ConfigWriter.render(config)
            XCTAssertTrue(rendered.contains("provider_bar = \"\(placement.rawValue)\""))
            var diagnostics: [Diagnostic] = []
            let parsed = try ConfigLoader.parse(
                TOMLTable(string: rendered),
                diagnostics: &diagnostics
            )
            XCTAssertEqual(parsed.window.providerBar, placement)
            XCTAssertTrue(diagnostics.isEmpty)
        }
        var parseDiagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(
            TOMLTable(string: "[window]\nprovider_bar = \"hidden\"\n"),
            diagnostics: &parseDiagnostics
        )
        XCTAssertEqual(parsed.window.providerBar, .hidden)
    }

    func testShortcutRowsRoundTripAndKeepUnknownCommands() throws {
        var config = PaletteConfig()
        config.shortcuts = [
            ShortcutBinding(command: "provider.calc", keys: "ctrl+alt+c"),
            ShortcutBinding(command: "app.quit", keys: ""),
            ShortcutBinding(command: "provider.future", keys: "ctrl+alt+f"),
        ]
        let rendered = ConfigWriter.render(config)
        XCTAssertEqual(rendered.components(separatedBy: "[[shortcut]]").count - 1, 3)
        var diagnostics: [Diagnostic] = []
        let parsed = try ConfigLoader.parse(TOMLTable(string: rendered), diagnostics: &diagnostics)
        XCTAssertEqual(parsed.shortcuts, config.shortcuts)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testShortcutResolverRejectsDuplicatesAndUnknownCommands() {
        let commands = [
            CatalogCommand(
                id: "provider.calc",
                title: "Open /calc",
                group: CommandCatalog.providerGroup,
                action: .provider(trigger: "calc")
            ),
            CatalogCommand(
                id: "app.settings",
                title: "Open Settings",
                group: CommandCatalog.appGroup,
                action: .app(.settings)
            ),
        ]
        let plan = ShortcutResolver.resolve(
            [
                ShortcutBinding(command: "provider.calc", keys: "ctrl+alt+c"),
                ShortcutBinding(command: "app.settings", keys: "alt+ctrl+c"),
                ShortcutBinding(command: "app.settings", keys: "cmd+shift+3"),
                ShortcutBinding(command: "provider.gone", keys: "ctrl+alt+g"),
                ShortcutBinding(command: "app.settings", keys: ""),
            ],
            commands: commands,
            reserved: ["cmd+shift+3"]
        )
        XCTAssertEqual(plan.resolved, [ShortcutBinding(command: "provider.calc", keys: "ctrl+alt+c")])
        XCTAssertEqual(plan.issues.count, 3)
    }

    func testCatalogIdsAreStableAndProvidersComeFromTheRegistry() {
        let commands = CommandCatalog.commands(providers: [
            CommandCatalog.ProviderEntry(id: "calc", trigger: "calc"),
            CommandCatalog.ProviderEntry(id: "apps", trigger: nil),
            CommandCatalog.ProviderEntry(id: "clip", trigger: "clip"),
        ])
        XCTAssertEqual(
            commands.map(\.id),
            ["provider.calc", "provider.clip", "app.settings", "app.reload",
             "app.toggle-launcher", "app.quit"]
        )
        XCTAssertEqual(commands.first?.title, "Open /calc")
        XCTAssertFalse(commands.contains { $0.id == "provider.apps" })
        XCTAssertEqual(CommandCatalog.commands(providers: [], prefix: ":").map(\.id),
                       ["app.settings", "app.reload", "app.toggle-launcher", "app.quit"])
    }

    func testHotKeyProbeMapsStatuses() {
        XCTAssertEqual(HotKeyProbe.classify(isLive: false, status: noErr), .available)
        XCTAssertEqual(HotKeyProbe.classify(isLive: false, status: -9878), .usedBySystem)
        XCTAssertEqual(HotKeyProbe.classify(isLive: true, status: noErr), .usedByPalette)
        // A live registration of ours must not be blamed on another app even
        // when a fresh registration would fail.
        XCTAssertEqual(HotKeyProbe.classify(isLive: true, status: -9878), .usedByPalette)
    }

    func testShortcutAvailabilityPrefersPaletteOverTheProbe() throws {
        let spec = try XCTUnwrap(HotKeySpec.parse("cmd+space"))
        var probed = false
        let palette = ShortcutAvailability.message(
            for: spec,
            ownedKeys: ["cmd+space"],
            probe: { _ in probed = true; return .usedBySystem }
        )
        XCTAssertEqual(palette, "Used by Palette")
        XCTAssertFalse(probed, "a configured key must not fall through to the probe")

        let system = ShortcutAvailability.message(
            for: spec,
            ownedKeys: ["opt+space"],
            probe: { _ in .usedBySystem }
        )
        XCTAssertEqual(system, "Already used by another app")
        let free = ShortcutAvailability.message(
            for: spec,
            ownedKeys: [],
            probe: { _ in .available }
        )
        XCTAssertNil(free)
        // Re-recording a row's own key drops it from the owned list before the
        // probe, so a live registration of ours is not reported as a conflict.
        let same = ShortcutAvailability.message(
            for: spec,
            ownedKeys: [],
            probe: { _ in .usedByPalette }
        )
        XCTAssertEqual(same, "Used by Palette", "the live probe still owns it")
    }
}
