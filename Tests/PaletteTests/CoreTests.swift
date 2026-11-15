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

    func testLegacyRootVisibleRowsStillClamps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palette-rows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PalettePaths(
            home: root.path,
            configDir: root.appendingPathComponent("config"),
            stateDir: root.appendingPathComponent("state"),
            cacheDir: root.appendingPathComponent("cache")
        )
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)

        // 2.3.2 wrote this key at the root; it still maps into [window].
        try "visible_rows = 6\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigLoader.load(paths: paths).config.window.visibleRows, 6)

        try "visible_rows = 99\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigLoader.load(paths: paths).config.window.visibleRows, 10)

        try "visible_rows = 2\n".write(to: paths.configFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigLoader.load(paths: paths).config.window.visibleRows, 5)
    }

    func testUnitConversion() throws {
        let km = try XCTUnwrap(Units.parse("10 km in mi"))
        XCTAssertEqual(Units.convert(km), 6.2137, accuracy: 0.001)
        let temp = try XCTUnwrap(Units.parse("72 f to c"))
        XCTAssertEqual(Units.convert(temp), 22.2222, accuracy: 0.001)
        let data = try XCTUnwrap(Units.parse("1.5 gib in mb"))
        XCTAssertEqual(Units.convert(data), 1610.612, accuracy: 0.01)
        XCTAssertNil(Units.parse("10 km in kg"), "different kinds do not convert")
        XCTAssertNil(Units.parse("banana"))
        XCTAssertTrue(try XCTUnwrap(Units.parse("20 usd in eur")).isCurrency)
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

    func testWindowConfigScaleAndOverrides() {
        var window = WindowConfig()
        XCTAssertEqual(window.launcherWidth, 680)
        XCTAssertEqual(window.launcherMaxHeight, 720)
        XCTAssertEqual(window.launcherRows, 7)
        XCTAssertEqual(window.terminalPanelWidth, 1000)

        window.scale = 1.25
        XCTAssertEqual(window.launcherWidth, 850)
        XCTAssertEqual(window.launcherMaxHeight, 900)
        XCTAssertEqual(window.launcherRows, 9)
        XCTAssertEqual(window.clipboardPanelWidth, 1100)

        window.width = 900
        XCTAssertEqual(window.launcherWidth, 900, "explicit width wins over scale")

        window.scale = 3
        XCTAssertEqual(window.effectiveScale, 1.6, "scale clamps to 1.6")
        window.visibleRows = 20
        XCTAssertEqual(window.launcherRows, 10, "rows clamp to 10")
    }

    func testAutoSizeFollowsTheScreen() {
        var window = WindowConfig()
        window.autoSize = true

        // MacBook 13" (landscape 1470 x 830 usable)
        XCTAssertEqual(window.launcherWidth(for: CGSize(width: 1470, height: 830)), 662)
        XCTAssertEqual(window.launcherRows(for: CGSize(width: 1470, height: 830)), 6)

        // 1440p ultrawide
        XCTAssertEqual(window.launcherWidth(for: CGSize(width: 5120, height: 1400)), 980)
        XCTAssertEqual(window.launcherRows(for: CGSize(width: 5120, height: 1400)), 9)

        // Portrait 1080 x 1920: most of the width, fewer rows than it could fit
        XCTAssertEqual(window.launcherWidth(for: CGSize(width: 1080, height: 1880)), 886)
        XCTAssertEqual(window.launcherRows(for: CGSize(width: 1080, height: 1880)), 10)

        // An explicit width still wins over auto
        window.width = 900
        XCTAssertEqual(window.launcherWidth(for: CGSize(width: 1470, height: 830)), 900)

        // Turning auto off falls back to the fixed default
        window.width = 0
        window.autoSize = false
        XCTAssertEqual(window.launcherWidth(for: CGSize(width: 1470, height: 830)), 680)
        XCTAssertEqual(window.launcherRows(for: CGSize(width: 1470, height: 830)), 7)
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
        scale = 1.2
        width = 900
        visible_rows = 9
        terminal_width = 1200
        preview_layout = "beside"
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)

        var loaded = ConfigLoader.load(paths: paths).config
        XCTAssertEqual(loaded.window.scale, 1.2)
        XCTAssertEqual(loaded.window.width, 900)
        XCTAssertEqual(loaded.window.visibleRows, 9)
        XCTAssertEqual(loaded.window.terminalWidth, 1200)
        XCTAssertEqual(loaded.window.launcherWidth, 900)
        XCTAssertEqual(loaded.window.launcherRows, 9)
        XCTAssertEqual(loaded.window.previewLayout, .beside)

        // A settings save must round-trip the [window] table.
        loaded.window.scale = 1.1
        loaded.window.askWidth = 1_000
        try ConfigWriter.render(loaded).write(to: paths.configFile, atomically: true, encoding: .utf8)
        let reloaded = ConfigLoader.load(paths: paths).config.window
        XCTAssertEqual(reloaded.scale, 1.1)
        XCTAssertEqual(reloaded.width, 900)
        XCTAssertEqual(reloaded.askWidth, 1_000)
        XCTAssertEqual(reloaded.previewLayout, .beside)
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
        XCTAssertEqual(config.clipboard.maxEntries, 5_000)
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
        XCTAssertEqual(parsed.clipboard.maxEntries, 5_000)
        XCTAssertEqual(parsed.webSearchEngines.map(\.name), config.webSearchEngines.map(\.name))
        XCTAssertEqual(parsed.clipboardHotkey, config.clipboardHotkey)
        XCTAssertEqual(parsed.terminalHotkey, config.terminalHotkey)
        XCTAssertEqual(parsed.scratchpadHotkey, config.scratchpadHotkey)
        XCTAssertEqual(parsed.askHotkey, config.askHotkey)
        XCTAssertEqual(parsed.searchPosition, .top)
        XCTAssertEqual(parsed.webAppBrowser, "Helium")
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertTrue(ThemeLoader.builtinNames.contains("gruvbox-dark"))
        XCTAssertTrue(ThemeLoader.builtinNames.contains("aetheria-pink"))
        XCTAssertEqual(parsed.providerAliases["neo"], ["neo", "editor"])
        XCTAssertEqual(parsed.providerAliases["neof"], ["neof", "folders"])

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
}
