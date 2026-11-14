import Foundation
import TOMLKit

public enum ThemeMode: String, Sendable, Equatable {
    case dark, light, auto
}

public enum AppSort: String, Sendable, Equatable, CaseIterable {
    case alphabetical
    case frequent
}

public struct ThemeSelection: Sendable, Equatable {
    public var mode: ThemeMode
    public var dark: String
    public var light: String

    public init(mode: ThemeMode = .auto, dark: String = "catppuccin-mocha", light: String = "catppuccin-latte") {
        self.mode = mode
        self.dark = dark
        self.light = light
    }
}

public enum SearchPosition: String, Sendable, Equatable, CaseIterable {
    case top, center
}

public enum TerminalMultiplexer: String, Sendable, Equatable, CaseIterable {
    case auto
    case zellij
    case tmux
    case none
}

public struct TerminalSessionConfig: Sendable, Equatable {
    public var multiplexer: TerminalMultiplexer
    public var name: String
    /// Empty means fish when installed, otherwise the login zsh.
    public var shell: String
    public var font: String
    public var fontSize: Double

    public init(
        multiplexer: TerminalMultiplexer = .auto,
        name: String = "Palette",
        shell: String = "",
        font: String = "",
        fontSize: Double = 0
    ) {
        self.multiplexer = multiplexer
        self.name = name
        self.shell = shell
        self.font = font
        self.fontSize = fontSize
    }
}

public struct WebSearchEngine: Sendable, Equatable, Identifiable {
    public var name: String
    public var urlTemplate: String
    public var keyword: String?

    public var id: String { name.lowercased() }

    public init(name: String, urlTemplate: String, keyword: String? = nil) {
        self.name = name
        self.urlTemplate = urlTemplate
        self.keyword = keyword
    }

    public static let defaults: [WebSearchEngine] = [
        WebSearchEngine(name: "Google", urlTemplate: "https://www.google.com/search?q={query}"),
        WebSearchEngine(name: "DuckDuckGo", urlTemplate: "https://duckduckgo.com/?q={query}"),
        WebSearchEngine(name: "GitHub", urlTemplate: "https://github.com/search?q={query}"),
        WebSearchEngine(name: "YouTube", urlTemplate: "https://www.youtube.com/results?search_query={query}"),
    ]
}

public struct ClipboardConfig: Sendable, Equatable {
    public var enabled: Bool
    public var maxEntries: Int
    public var pollMs: Int
    public var clearAfterMs: Int

    public init(enabled: Bool = true, maxEntries: Int = 5_000, pollMs: Int = 500, clearAfterMs: Int = 30_000) {
        self.enabled = enabled
        self.maxEntries = maxEntries
        self.pollMs = pollMs
        self.clearAfterMs = clearAfterMs
    }
}

public struct TypographyConfig: Sendable, Equatable {
    public var uiFamily: String
    public var monoFamily: String
    public var uiSize: Double
    public var monoSize: Double

    public init(uiFamily: String = "", monoFamily: String = "", uiSize: Double = 0, monoSize: Double = 0) {
        self.uiFamily = uiFamily
        self.monoFamily = monoFamily
        self.uiSize = uiSize
        self.monoSize = monoSize
    }
}

/// Where the clipboards/Ask preview sits relative to the list.
public enum PreviewPlacement: String, Sendable, Equatable {
    case beside
    case below
}

/// Launcher geometry lives in config.toml, not the theme: themes describe how
/// things look, this describes how big they are.
public struct WindowConfig: Sendable, Equatable {
    /// Multiplier applied to every size below, like `rem`. 0.8...1.6.
    public var scale: Double = 1
    /// Size to the screen under the cursor instead of one fixed size.
    public var autoSize: Bool = true
    /// Points. 0 means "use the default times scale".
    public var width: Double = 0
    public var maxHeight: Double = 0
    /// Rows before scrolling. 0 means "use the default times scale".
    public var visibleRows: Int = 0
    public var clipboardWidth: Double = 0
    public var askWidth: Double = 0
    public var previewWidth: Double = 0
    public var terminalWidth: Double = 0
    public var scratchpadWidth: Double = 0
    public var previewLayout: PreviewPlacement = .beside

    public init() {}

    public static let defaultWidth: Double = 680
    public static let defaultMaxHeight: Double = 720
    public static let defaultRows: Int = 7
    public static let defaultPanelWidth: Double = 880
    public static let defaultTerminalWidth: Double = 1000

    public var effectiveScale: Double {
        scale <= 0 ? 1 : min(1.6, max(0.8, scale))
    }

    private func size(_ explicit: Double, _ fallback: Double) -> Double {
        explicit > 0 ? explicit : (fallback * effectiveScale).rounded()
    }

    /// Landscape gets a centered column; portrait and near-square screens get
    /// most of the width, since there is little of it.
    public func autoWidth(for visible: CGSize) -> Double {
        guard visible.width > 0, visible.height > 0 else { return Self.defaultWidth * effectiveScale }
        let aspect = visible.width / visible.height
        let fraction = aspect < 1.2 ? 0.82 : 0.45
        let raw = Double(visible.width) * fraction
        return (min(980, max(620, raw)) * effectiveScale).rounded()
    }

    /// ~6 rows per 900 points of screen height: a laptop gets 6, a 1440p
    /// display 10. Clamped to the same 5...10 the manual setting uses.
    public func autoRows(for visible: CGSize) -> Int {
        guard visible.height > 0 else { return Self.defaultRows }
        let fit = Int((Double(visible.height) / 150).rounded())
        return min(10, max(5, fit))
    }

    public func launcherWidth(for visible: CGSize) -> Double {
        if width > 0 { return width }
        return autoSize ? autoWidth(for: visible) : size(0, Self.defaultWidth)
    }

    public func launcherRows(for visible: CGSize) -> Int {
        if visibleRows > 0 { return min(10, max(5, visibleRows)) }
        return autoSize ? autoRows(for: visible) : launcherRows
    }

    /// Per-view widths keep the same proportions as the main panel.
    public func panelWidth(_ explicit: Double, _ fallback: Double, for visible: CGSize) -> Double {
        if explicit > 0 { return explicit }
        guard autoSize else { return (fallback * effectiveScale).rounded() }
        return (autoWidth(for: visible) * (fallback / Self.defaultWidth)).rounded()
    }

    public var launcherWidth: Double { size(width, Self.defaultWidth) }
    public var launcherMaxHeight: Double { size(maxHeight, Self.defaultMaxHeight) }

    public var launcherRows: Int {
        if visibleRows > 0 { return min(10, max(5, visibleRows)) }
        return min(10, max(5, Int((Double(Self.defaultRows) * effectiveScale).rounded())))
    }

    public func clipboardWidth(for visible: CGSize) -> Double {
        panelWidth(clipboardWidth, Self.defaultPanelWidth, for: visible)
    }
    public func askWidth(for visible: CGSize) -> Double {
        panelWidth(askWidth, Self.defaultPanelWidth, for: visible)
    }
    public func previewWidth(for visible: CGSize) -> Double {
        panelWidth(previewWidth, Self.defaultPanelWidth, for: visible)
    }
    public func terminalWidth(for visible: CGSize) -> Double {
        panelWidth(terminalWidth, Self.defaultTerminalWidth, for: visible)
    }
    public func scratchpadWidth(for visible: CGSize) -> Double {
        panelWidth(scratchpadWidth, Self.defaultPanelWidth, for: visible)
    }

    public var clipboardPanelWidth: Double { size(clipboardWidth, Self.defaultPanelWidth) }
    public var askPanelWidth: Double { size(askWidth, Self.defaultPanelWidth) }
    public var previewPanelWidth: Double { size(previewWidth, Self.defaultPanelWidth) }
    public var terminalPanelWidth: Double { size(terminalWidth, Self.defaultTerminalWidth) }
    public var scratchpadPanelWidth: Double { size(scratchpadWidth, Self.defaultPanelWidth) }
}

public enum CaptureAction: String, Sendable, Equatable {
    case save
    case copy
    case saveCopy = "save-copy"
    case preview

    public var savesFile: Bool { self == .save || self == .saveCopy || self == .preview }
    public var copiesToClipboard: Bool { self == .copy || self == .saveCopy }
}

public struct CaptureConfig: Sendable, Equatable {
    public var directory = "~/Pictures/Palette"
    public var screenshotFormat = "png"          // png | jpg
    public var screenshotAction: CaptureAction = .saveCopy
    public var recordingFormat = "mov"           // mov | mp4
    public var recordingAction: CaptureAction = .save
    public var delay: Double = 0                 // seconds before a screenshot
    public var hidePalette = true
    public var captureCursor = false
    public var showClicks = false

    public init() {}
}

public struct TimerConfig: Sendable, Equatable {
    /// Preset durations in minutes, shown as rows in /timer.
    public var presets: [Int] = [5, 10, 15, 25, 30, 45, 60]
    public var sound = true
    public var notify = true

    public init() {}
}

public struct PaletteConfig: Sendable, Equatable {
    public var hotkey: String
    public var clipboardHotkey: String
    public var terminalHotkey: String
    public var scratchpadHotkey: String
    public var askHotkey: String
    public var screenshotHotkey: String
    public var recordingHotkey: String
    public var providerPrefix: String
    public var toolsPath: [String]
    public var terminal: String
    public var terminalApp: String
    public var editorOpenWith: String
    public var theme: ThemeSelection
    public var scopes: [String: Scope]
    public var clipboard: ClipboardConfig
    public var webSearchEnabled: Bool
    public var webSearchEngines: [WebSearchEngine]
    public var searchPosition: SearchPosition
    public var webAppBrowser: String
    public var window: WindowConfig
    public var appSort: AppSort
    public var ask: AskConfig
    public var typography: TypographyConfig
    public var providerAliases: [String: [String]]
    public var providerOrder: [String]
    public var disabledProviders: [String]
    public var terminalSession: TerminalSessionConfig
    public var timer: TimerConfig
    public var capture: CaptureConfig

    public init(
        hotkey: String = "opt+space",
        clipboardHotkey: String = "opt+v",
        terminalHotkey: String = "cmd+option+t",
        scratchpadHotkey: String = "cmd+option+s",
        askHotkey: String = "cmd+option+a",
        screenshotHotkey: String = "cmd+option+shift+s",
        recordingHotkey: String = "cmd+option+shift+r",
        providerPrefix: String = "/",
        toolsPath: [String] = [],
        terminal: String = "kitty",
        terminalApp: String = "kitty",
        editorOpenWith: String = "neovide",
        theme: ThemeSelection = ThemeSelection(),
        scopes: [String: Scope] = ["projects": .projects, "home": .home],
        clipboard: ClipboardConfig = ClipboardConfig(),
        webSearchEnabled: Bool = true,
        webSearchEngines: [WebSearchEngine] = WebSearchEngine.defaults,
        searchPosition: SearchPosition = .top,
        webAppBrowser: String = "Helium",
        window: WindowConfig = WindowConfig(),
        appSort: AppSort = .alphabetical,
        ask: AskConfig = AskConfig(),
        typography: TypographyConfig = TypographyConfig(),
        providerAliases: [String: [String]] = [
            "neo": ["neo", "editor"],
            "neof": ["neof", "folders"],
        ],
        providerOrder: [String] = [],
        disabledProviders: [String] = [],
        terminalSession: TerminalSessionConfig = TerminalSessionConfig(),
        timer: TimerConfig = TimerConfig(),
        capture: CaptureConfig = CaptureConfig()
    ) {
        self.hotkey = hotkey
        self.clipboardHotkey = clipboardHotkey
        self.terminalHotkey = terminalHotkey
        self.scratchpadHotkey = scratchpadHotkey
        self.askHotkey = askHotkey
        self.screenshotHotkey = screenshotHotkey
        self.recordingHotkey = recordingHotkey
        self.providerPrefix = providerPrefix
        self.toolsPath = toolsPath
        self.terminal = terminal
        self.terminalApp = terminalApp
        self.editorOpenWith = editorOpenWith
        self.theme = theme
        self.scopes = scopes
        self.clipboard = clipboard
        self.webSearchEnabled = webSearchEnabled
        self.webSearchEngines = webSearchEngines
        self.searchPosition = searchPosition
        self.webAppBrowser = webAppBrowser
        self.window = window
        self.appSort = appSort
        self.ask = ask
        self.typography = typography
        self.providerAliases = providerAliases
        self.providerOrder = providerOrder
        self.disabledProviders = disabledProviders
        self.terminalSession = terminalSession
        self.timer = timer
        self.capture = capture
    }
}

public struct PalettePaths: Sendable {
    public var home: String
    public var configDir: URL
    public var stateDir: URL
    public var cacheDir: URL

    public init(home: String, configDir: URL, stateDir: URL, cacheDir: URL) {
        self.home = home
        self.configDir = configDir
        self.stateDir = stateDir
        self.cacheDir = cacheDir
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> PalettePaths {
        func directory(_ value: String) -> URL {
            URL(fileURLWithPath: PathExpansion.expand(value, home: home), isDirectory: true)
        }

        let configBase = environment["PALETTE_CONFIG_DIR"]
            ?? environment["XDG_CONFIG_HOME"].map { $0 + "/palette" }
            ?? home + "/.config/palette"
        let stateBase = environment["PALETTE_STATE_DIR"]
            ?? environment["XDG_STATE_HOME"].map { $0 + "/palette" }
            ?? home + "/.local/state/palette"
        let cacheBase = environment["PALETTE_CACHE_DIR"]
            ?? home + "/Library/Caches/Palette"

        return PalettePaths(
            home: home,
            configDir: directory(configBase),
            stateDir: directory(stateBase),
            cacheDir: directory(cacheBase)
        )
    }

    public var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public var providersDir: URL { configDir.appendingPathComponent("providers", isDirectory: true) }
    public var themesDir: URL { configDir.appendingPathComponent("themes", isDirectory: true) }
    public var databaseFile: URL { stateDir.appendingPathComponent("palette.sqlite") }
    public var logsDir: URL { stateDir.appendingPathComponent("logs", isDirectory: true) }
    public var logFile: URL { logsDir.appendingPathComponent("palette.log") }

    public func createDirectories() throws {
        let manager = FileManager.default
        for url in [configDir, providersDir, themesDir, stateDir, logsDir, cacheDir] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Resources live in the app bundle in release builds, and next to the
    /// package during `swift run` and tests.
    public func bundledResources() -> URL? {
        if let url = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: url.appendingPathComponent("Themes").path) {
            return url
        }
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }
}

public struct ConfigLoadResult: Sendable {
    public var config: PaletteConfig
    public var diagnostics: [Diagnostic]
    public var createdDefault: Bool
}

public enum ConfigLoader {
    public static func load(paths: PalettePaths) -> ConfigLoadResult {
        var diagnostics: [Diagnostic] = []
        var created = false

        try? paths.createDirectories()

        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            do {
                try defaultTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
                created = true
            } catch {
                diagnostics.append(Diagnostic(.error, "Could not write default config: \(error.localizedDescription)", source: "config"))
            }
        }

        guard let text = try? String(contentsOf: paths.configFile, encoding: .utf8) else {
            diagnostics.append(Diagnostic(.warning, "Using built-in defaults; config.toml could not be read.", source: "config"))
            return ConfigLoadResult(config: PaletteConfig(), diagnostics: diagnostics, createdDefault: created)
        }

        do {
            let table = try TOMLTable(string: text)
            let config = try parse(table, diagnostics: &diagnostics)
            return ConfigLoadResult(config: config, diagnostics: diagnostics, createdDefault: created)
        } catch {
            diagnostics.append(Diagnostic(.error, "Invalid config.toml: \(error.localizedDescription). Using defaults.", source: "config"))
            return ConfigLoadResult(config: PaletteConfig(), diagnostics: diagnostics, createdDefault: created)
        }
    }

    public static func parse(_ table: TOMLTable, diagnostics: inout [Diagnostic]) throws -> PaletteConfig {
        var config = PaletteConfig()

        if let hotkey = table.str("hotkey"), !hotkey.isEmpty {
            config.hotkey = hotkey
        }
        if let hotkey = table.str("clipboard_hotkey") {
            config.clipboardHotkey = hotkey
        }
        if let hotkey = table.str("terminal_hotkey") {
            config.terminalHotkey = hotkey
        }
        if let hotkey = table.str("scratchpad_hotkey") {
            config.scratchpadHotkey = hotkey
        }
        if let hotkey = table.str("ask_hotkey") {
            config.askHotkey = hotkey
        }
        if let hotkey = table.str("screenshot_hotkey") {
            config.screenshotHotkey = hotkey
        }
        if let hotkey = table.str("recording_hotkey") {
            config.recordingHotkey = hotkey
        }
        if let prefix = table.str("provider_prefix"), !prefix.isEmpty {
            config.providerPrefix = prefix
        }
        if let tools = table.strArray("tools_path") {
            config.toolsPath = tools
        }
        if let terminal = table.str("terminal"), !terminal.isEmpty {
            config.terminal = terminal
        }
        if let terminalApp = table.str("terminal_app"), !terminalApp.isEmpty {
            config.terminalApp = terminalApp
        }
        if let editor = table.str("editor_open_with"), !editor.isEmpty {
            config.editorOpenWith = editor
        }
        if let position = table.str("search_position") {
            // `bottom` was removed in 1.7.1; keep old configs working by
            // treating them as centered instead of dropping the setting.
            let value = position.lowercased()
            if value == "bottom" {
                config.searchPosition = .center
            } else if let parsed = SearchPosition(rawValue: value) {
                config.searchPosition = parsed
            }
        }
        if let browser = table.str("web_app_browser"), !browser.isEmpty {
            config.webAppBrowser = browser
        }
        if let sort = table.str("app_sort"), let parsed = AppSort(rawValue: sort.lowercased()) {
            config.appSort = parsed
        }
        if let window = table.table("window") {
            config.window.autoSize = window.bool("auto_size") ?? config.window.autoSize
            if let value = window.number("scale"), value > 0 { config.window.scale = value }
            if let value = window.number("width"), value > 0 { config.window.width = value }
            if let value = window.number("max_height"), value > 0 { config.window.maxHeight = value }
            if let value = window.int("visible_rows"), value > 0 {
                config.window.visibleRows = min(10, max(5, value))
            }
            if let value = window.number("clipboard_width"), value > 0 { config.window.clipboardWidth = value }
            if let value = window.number("ask_width"), value > 0 { config.window.askWidth = value }
            if let value = window.number("preview_width"), value > 0 { config.window.previewWidth = value }
            if let value = window.number("terminal_width"), value > 0 { config.window.terminalWidth = value }
            if let value = window.number("scratchpad_width"), value > 0 { config.window.scratchpadWidth = value }
            if let raw = window.str("preview_layout"), let layout = PreviewPlacement(rawValue: raw.lowercased()) {
                config.window.previewLayout = layout
            }
        }
        // 2.3.2 wrote a root-level key; keep reading it for one release.
        if let rows = table.int("visible_rows"), rows > 0, config.window.visibleRows == 0 {
            config.window.visibleRows = min(10, max(5, rows))
        }

        if let typography = table.table("typography") {
            if let value = typography.str("ui_family") {
                config.typography.uiFamily = value.trimmingCharacters(in: .whitespaces)
            }
            if let value = typography.str("mono_family") {
                config.typography.monoFamily = value.trimmingCharacters(in: .whitespaces)
            }
            if let value = typography.number("ui_size"), value > 0 {
                config.typography.uiSize = min(48, max(9, value))
            }
            if let value = typography.number("mono_size"), value > 0 {
                config.typography.monoSize = min(48, max(9, value))
            }
        }

        if let capture = table.table("capture") {
            if let value = capture.str("directory"), !value.isEmpty {
                config.capture.directory = (value as NSString).expandingTildeInPath
            }
            if let value = capture.str("screenshot_format"), ["png", "jpg"].contains(value.lowercased()) {
                config.capture.screenshotFormat = value.lowercased()
            }
            if let value = capture.str("screenshot_action"), let action = CaptureAction(rawValue: value.lowercased()) {
                config.capture.screenshotAction = action
            }
            if let value = capture.str("recording_format"), ["mov", "mp4"].contains(value.lowercased()) {
                config.capture.recordingFormat = value.lowercased()
            }
            if let value = capture.str("recording_action"), let action = CaptureAction(rawValue: value.lowercased()) {
                config.capture.recordingAction = action
            }
            if let value = capture.number("delay"), value >= 0 { config.capture.delay = value }
            config.capture.hidePalette = capture.bool("hide_palette") ?? config.capture.hidePalette
            config.capture.captureCursor = capture.bool("capture_cursor") ?? config.capture.captureCursor
            config.capture.showClicks = capture.bool("show_clicks") ?? config.capture.showClicks
        }

        if let timer = table.table("timer") {
            if let presets = timer["presets"]?.array {
                let values = presets.compactMap { $0.int }.filter { $0 > 0 && $0 <= 24 * 60 }
                if !values.isEmpty { config.timer.presets = values }
            }
            config.timer.sound = timer.bool("sound") ?? config.timer.sound
            config.timer.notify = timer.bool("notify") ?? config.timer.notify
        }

        if let providers = table.table("providers") {
            config.providerOrder = providers.strArray("order") ?? []
            config.disabledProviders = (providers.strArray("disabled") ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0 != "apps" }
            if let aliases = providers.table("aliases") {
                var parsed = config.providerAliases
                for key in aliases.keys {
                    let values = aliases.strArray(key) ?? []
                    let cleaned = values
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if !cleaned.isEmpty { parsed[key] = cleaned }
                }
                config.providerAliases = parsed
            }
        }

        if let terminalTable = table.table("terminal_session") {
            var session = config.terminalSession
            if let raw = terminalTable.str("multiplexer"),
               let value = TerminalMultiplexer(rawValue: raw.lowercased()) {
                session.multiplexer = value
            }
            if let name = terminalTable.str("name"), !name.isEmpty {
                session.name = name
            }
            if let shell = terminalTable.str("shell") {
                session.shell = shell
            }
            if let font = terminalTable.str("font") {
                session.font = font
            }
            if let size = terminalTable.number("font_size"), size > 0 {
                session.fontSize = max(8, min(48, size))
            }
            config.terminalSession = session
        }

        if let web = table.table("web_search") {
            if let enabled = web.bool("enabled") {
                config.webSearchEnabled = enabled
            }
            if let engines = web.array("engines") {
                let parsed = engines.compactMap { value -> WebSearchEngine? in
                    guard let engine = value.table,
                          let name = engine.str("name"),
                          let url = engine.str("url"),
                          !name.isEmpty, url.contains("{query}") else { return nil }
                    return WebSearchEngine(
                        name: name,
                        urlTemplate: url,
                        keyword: engine.str("keyword")
                    )
                }
                if !parsed.isEmpty { config.webSearchEngines = parsed }
            }
        }

        if let askTable = table.table("ask") {
            var ask = config.ask
            if let raw = askTable.str("provider"),
               let endpoint = AskEndpoint(rawValue: raw.lowercased()) {
                ask.endpoint = endpoint
            }
            if let model = askTable.str("model"), !model.isEmpty {
                ask.model = model
            }
            if let count = askTable.int("max_history") {
                ask.maxHistory = max(1, min(20_000, count))
            }
            if let days = askTable.int("retention_days") {
                ask.retentionDays = max(1, min(3_650, days))
            }
            if let tokens = askTable.int("max_tokens") {
                ask.maxTokens = max(32, min(8_192, tokens))
            }
            if let fallback = askTable.bool("fallback") {
                ask.fallback = fallback
            }
            if AskModel.find(id: ask.model)?.endpoint != ask.endpoint {
                ask.model = AskModel.defaultModel.id
            }
            config.ask = ask
        }

        if let themeTable = table.table("theme") {
            var theme = config.theme
            if let mode = themeTable.str("mode"), let parsed = ThemeMode(rawValue: mode.lowercased()) {
                theme.mode = parsed
            } else if themeTable.str("mode") != nil {
                diagnostics.append(Diagnostic(.warning, "Unknown theme mode; using auto.", source: "config"))
            }
            if let dark = themeTable.str("dark"), !dark.isEmpty { theme.dark = dark }
            if let light = themeTable.str("light"), !light.isEmpty { theme.light = light }
            config.theme = theme
        }

        if let scopesTable = table.table("scopes") {
            var scopes: [String: Scope] = [:]
            for (name, value) in scopesTable {
                guard let scopeTable = value.table else { continue }
                let roots = scopeTable.strArray("roots") ?? []
                if roots.isEmpty {
                    diagnostics.append(Diagnostic(.warning, "Scope '\(name)' has no roots; skipped.", source: "config"))
                    continue
                }
                scopes[name] = Scope(
                    roots: roots,
                    exclude: scopeTable.strArray("exclude") ?? Scope.defaultExcludes,
                    include: scopeTable.strArray("include") ?? [],
                    includeHidden: scopeTable.bool("include_hidden") ?? false,
                    maxDepth: scopeTable.int("max_depth") ?? 12,
                    respectGitignore: scopeTable.bool("respect_gitignore") ?? false
                )
            }
            if !scopes.isEmpty { config.scopes = scopes }
        }
        if config.scopes["home"] == nil {
            config.scopes["home"] = .home
        }

        if let clipboardTable = table.table("clipboard") {
            var clipboard = config.clipboard
            clipboard.enabled = clipboardTable.bool("enabled") ?? clipboard.enabled
            clipboard.maxEntries = max(10, clipboardTable.int("max_entries") ?? clipboard.maxEntries)
            clipboard.pollMs = max(150, clipboardTable.int("poll_ms") ?? clipboard.pollMs)
            clipboard.clearAfterMs = max(0, clipboardTable.int("clear_after_ms") ?? clipboard.clearAfterMs)
            config.clipboard = clipboard
        }

        if config.providerPrefix.count != 1 {
            diagnostics.append(Diagnostic(.warning, "provider_prefix should be one character; using '/'.", source: "config"))
            config.providerPrefix = "/"
        }

        return config
    }

    public static func defaultTOML() -> String {
        """
        # Palette configuration
        # Reload with ⌘R (or restart the app).

        # opt+space, cmd+space, ctrl+space, opt+shift+space, …
        hotkey = "opt+space"

        # Opens the clipboard browser with a live preview. Set to "" to disable.
        clipboard_hotkey = "opt+v"

        # Optional global shortcuts. Set either to "" to disable it.
        terminal_hotkey = "cmd+option+t"
        scratchpad_hotkey = "cmd+option+s"
        ask_hotkey = "cmd+option+a"

        # Shared prefix. Every provider trigger is appended to this character.
        provider_prefix = "/"

        # Extra directories to search for fd, fzf, bw, zellij, kitty.
        tools_path = []

        # Terminal used by /zj and /bw (kitty or Terminal), and the app name
        # used by `open -a`.
        terminal = "kitty"
        terminal_app = "kitty"

        # App or absolute command used by /neo and /neof.
        editor_open_with = "neovide"

        # Where the launcher opens: top | center.
        search_position = "top"

        # Search field shape: pill (floating Siri-style surfaces, default) | classic.

        # Chromium-based browser used for web apps. Defaults to Helium.
        web_app_browser = "Helium"
        app_sort = "alphabetical"      # alphabetical | frequent

        # Launcher size. scale multiplies every size below, like rem.
        # 0 means "use the default times scale".
        [window]
        auto_size = true               # size to the screen under the cursor
        scale = 1.0                    # 0.8 - 1.6
        width = 0                      # points, 0 = 680 * scale
        max_height = 0                 # points, 0 = 720 * scale
        visible_rows = 0               # 5-10, 0 = 7 * scale
        clipboard_width = 0            # 0 = 880 * scale
        ask_width = 0
        preview_width = 0
        terminal_width = 0             # 0 = 1000 * scale
        scratchpad_width = 0
        preview_layout = "beside"      # beside | below

        # Screenshots and recordings.
        [capture]
        directory = "~/Pictures/Palette"
        screenshot_format = "png"          # png | jpg
        screenshot_action = "save-copy"    # save | copy | save-copy | preview
        recording_format = "mov"           # mov | mp4
        recording_action = "save"          # save | copy | save-copy | preview
        delay = 0                          # seconds before a screenshot
        hide_palette = true
        capture_cursor = false
        show_clicks = false

        # Timer presets (minutes), and what happens when one finishes.
        [timer]
        presets = [5, 10, 15, 25, 30, 45, 60]
        sound = true
        notify = true

        # Font overrides. Empty family or 0 size inherits the active theme.
        [typography]
        ui_family = ""
        mono_family = ""
        ui_size = 0
        mono_size = 0

        # Provider tab order and optional trigger aliases.
        [providers]
        order = []
        disabled = []

        [providers.aliases]

        # Embedded terminal. auto uses Zellij, then tmux, then a plain shell.
        [terminal_session]
        multiplexer = "auto"           # auto | zellij | tmux | none
        name = "Palette"
        shell = ""                     # empty = fish if installed, else zsh
        font = ""                      # empty = kitty font, then theme mono
        font_size = 0                  # 0 = kitty size, then 13

        # One-shot AI answers (/ask). The API key is never written here; it
        # lives in an encrypted local file and is entered in Settings > Ask.
        [ask]
        provider = "opencode-go"       # OpenCode Go (requires a Go key)
        model = "beam-free"
        max_history = 200
        retention_days = 30
        max_tokens = 512
        fallback = true                # use free/cheap models when quota runs out

        # Global web search. Add or remove engines as you like; {query} is
        # replaced with the URL-encoded search text.
        [web_search]
        enabled = true

        [[web_search.engines]]
        name = "Google"
        url = "https://www.google.com/search?q={query}"

        [[web_search.engines]]
        name = "DuckDuckGo"
        url = "https://duckduckgo.com/?q={query}"

        [[web_search.engines]]
        name = "GitHub"
        url = "https://github.com/search?q={query}"

        [[web_search.engines]]
        name = "YouTube"
        url = "https://www.youtube.com/results?search_query={query}"

        [theme]
        mode = "auto"                 # dark | light | auto
        dark = "catppuccin-mocha"
        light = "catppuccin-latte"

        [scopes.projects]
        roots = ["~/dev", "~/dot-files"]
        exclude = [
          "node_modules", ".git", ".build", "target", ".next", "dist",
          "Library", ".cache", ".venv", "venv", "__pycache__", "DerivedData",
          "*.app", "*.framework", "*.dSYM",
        ]
        include = []
        include_hidden = false
        max_depth = 12
        respect_gitignore = false

        [scopes.home]
        roots = ["~"]
        exclude = [
          "node_modules", ".git", ".build", "target", ".next", "dist",
          "Library", ".cache", ".venv", "venv", "__pycache__", "DerivedData",
          "*.app", "*.framework", "*.dSYM", ".Trash", "Movies", "Music",
          "Pictures",
        ]
        include = []
        include_hidden = false
        max_depth = 12
        respect_gitignore = false

        [clipboard]
        enabled = true
        max_entries = 5000
        poll_ms = 500
        clear_after_ms = 30000

        """
    }
}

public enum ConfigWriter {
    public static func render(_ config: PaletteConfig) -> String {
        var out: [String] = []
        out.append("# Palette configuration")
        out.append("")
        out.append("hotkey = \(quote(config.hotkey))")
        out.append("clipboard_hotkey = \(quote(config.clipboardHotkey))")
        out.append("terminal_hotkey = \(quote(config.terminalHotkey))")
        out.append("scratchpad_hotkey = \(quote(config.scratchpadHotkey))")
        out.append("ask_hotkey = \(quote(config.askHotkey))")
        out.append("screenshot_hotkey = \(quote(config.screenshotHotkey))")
        out.append("recording_hotkey = \(quote(config.recordingHotkey))")
        out.append("provider_prefix = \(quote(config.providerPrefix))")
        out.append("tools_path = [\(config.toolsPath.map(quote).joined(separator: ", "))]")
        out.append("terminal = \(quote(config.terminal))")
        out.append("terminal_app = \(quote(config.terminalApp))")
        out.append("editor_open_with = \(quote(config.editorOpenWith))")
        out.append("search_position = \(quote(config.searchPosition.rawValue))")
        out.append("web_app_browser = \(quote(config.webAppBrowser))")
        out.append("app_sort = \(quote(config.appSort.rawValue))")
        out.append("")
        out.append("[window]")
        out.append("auto_size = \(config.window.autoSize)")
        out.append("scale = \(config.window.scale)")
        if config.window.width > 0 { out.append("width = \(config.window.width)") }
        if config.window.maxHeight > 0 { out.append("max_height = \(config.window.maxHeight)") }
        if config.window.visibleRows > 0 { out.append("visible_rows = \(config.window.visibleRows)") }
        if config.window.clipboardWidth > 0 { out.append("clipboard_width = \(config.window.clipboardWidth)") }
        if config.window.askWidth > 0 { out.append("ask_width = \(config.window.askWidth)") }
        if config.window.previewWidth > 0 { out.append("preview_width = \(config.window.previewWidth)") }
        if config.window.terminalWidth > 0 { out.append("terminal_width = \(config.window.terminalWidth)") }
        if config.window.scratchpadWidth > 0 { out.append("scratchpad_width = \(config.window.scratchpadWidth)") }
        out.append("preview_layout = \"\(config.window.previewLayout.rawValue)\"")
        out.append("")
        out.append("[capture]")
        out.append("directory = \(quote(config.capture.directory))")
        out.append("screenshot_format = \(quote(config.capture.screenshotFormat))")
        out.append("screenshot_action = \(quote(config.capture.screenshotAction.rawValue))")
        out.append("recording_format = \(quote(config.capture.recordingFormat))")
        out.append("recording_action = \(quote(config.capture.recordingAction.rawValue))")
        out.append("delay = \(config.capture.delay)")
        out.append("hide_palette = \(config.capture.hidePalette)")
        out.append("capture_cursor = \(config.capture.captureCursor)")
        out.append("show_clicks = \(config.capture.showClicks)")
        out.append("")
        out.append("[timer]")
        out.append("presets = [\(config.timer.presets.map(String.init).joined(separator: ", "))]")
        out.append("sound = \(config.timer.sound)")
        out.append("notify = \(config.timer.notify)")
        out.append("")
        out.append("[typography]")
        out.append("ui_family = \(quote(config.typography.uiFamily))")
        out.append("mono_family = \(quote(config.typography.monoFamily))")
        out.append("ui_size = \(config.typography.uiSize)")
        out.append("mono_size = \(config.typography.monoSize)")
        out.append("")
        out.append("[providers]")
        out.append("order = [\(config.providerOrder.map(quote).joined(separator: ", "))]")
        out.append("disabled = [\(config.disabledProviders.map(quote).joined(separator: ", "))]")
        out.append("")
        out.append("[providers.aliases]")
        for id in config.providerAliases.keys.sorted() {
            guard let aliases = config.providerAliases[id], !aliases.isEmpty else { continue }
            out.append("\(quote(id)) = [\(aliases.map(quote).joined(separator: ", "))]")
        }
        out.append("")
        out.append("[terminal_session]")
        out.append("multiplexer = \(quote(config.terminalSession.multiplexer.rawValue))")
        out.append("name = \(quote(config.terminalSession.name))")
        out.append("shell = \(quote(config.terminalSession.shell))")
        out.append("font = \(quote(config.terminalSession.font))")
        out.append("font_size = \(config.terminalSession.fontSize)")
        out.append("")
        out.append("[ask]")
        out.append("provider = \(quote(config.ask.endpoint.rawValue))")
        out.append("model = \(quote(config.ask.model))")
        out.append("max_history = \(config.ask.maxHistory)")
        out.append("retention_days = \(config.ask.retentionDays)")
        out.append("max_tokens = \(config.ask.maxTokens)")
        out.append("fallback = \(config.ask.fallback)")
        out.append("")
        out.append("[theme]")
        out.append("mode = \(quote(config.theme.mode.rawValue))")
        out.append("dark = \(quote(config.theme.dark))")
        out.append("light = \(quote(config.theme.light))")
        out.append("")
        out.append("[web_search]")
        out.append("enabled = \(config.webSearchEnabled)")
        for engine in config.webSearchEngines {
            out.append("")
            out.append("[[web_search.engines]]")
            out.append("name = \(quote(engine.name))")
            out.append("url = \(quote(engine.urlTemplate))")
            if let keyword = engine.keyword { out.append("keyword = \(quote(keyword))") }
        }
        for name in config.scopes.keys.sorted() {
            guard let scope = config.scopes[name] else { continue }
            out.append("")
            out.append("[scopes.\(name)]")
            out.append("roots = [\(scope.roots.map(quote).joined(separator: ", "))]")
            out.append("exclude = [\(scope.exclude.map(quote).joined(separator: ", "))]")
            out.append("include = [\(scope.include.map(quote).joined(separator: ", "))]")
            out.append("include_hidden = \(scope.includeHidden)")
            out.append("max_depth = \(scope.maxDepth)")
            out.append("respect_gitignore = \(scope.respectGitignore)")
        }
        out.append("")
        out.append("[clipboard]")
        out.append("enabled = \(config.clipboard.enabled)")
        out.append("max_entries = \(config.clipboard.maxEntries)")
        out.append("poll_ms = \(config.clipboard.pollMs)")
        out.append("clear_after_ms = \(config.clipboard.clearAfterMs)")
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

// MARK: - TOML helpers

public extension TOMLTable {
    func str(_ key: String) -> String? { self[key]?.string }
    func int(_ key: String) -> Int? { self[key]?.int }
    func double(_ key: String) -> Double? { self[key]?.double }
    func number(_ key: String) -> Double? {
        if let value = self[key]?.double { return value }
        if let value = self[key]?.int { return Double(value) }
        return nil
    }
    func bool(_ key: String) -> Bool? { self[key]?.bool }
    func table(_ key: String) -> TOMLTable? { self[key]?.table }
    func array(_ key: String) -> TOMLArray? { self[key]?.array }

    func strArray(_ key: String) -> [String]? {
        guard let array = self[key]?.array else { return nil }
        return array.compactMap { $0.string }
    }
}
