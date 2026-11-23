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

    public init(mode: ThemeMode = .auto, dark: String = "siri-graphite", light: String = "siri-silver") {
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
    /// `!keyword` that addresses this engine directly. Nil or empty means the
    /// engine is not bangable.
    public var keyword: String?
    /// Browser app name; empty means the system default.
    public var browser: String = ""
    /// Open bangs for this engine in the web-app browser instead of a normal
    /// tab, so a site installed as a web app answers the search.
    public var appMode: Bool = false

    public var id: String { name.lowercased() }

    public init(
        name: String,
        urlTemplate: String,
        keyword: String? = nil,
        browser: String = "",
        appMode: Bool = false
    ) {
        self.name = name
        self.urlTemplate = urlTemplate
        self.keyword = keyword
        self.browser = browser
        self.appMode = appMode
    }

    public static let defaults: [WebSearchEngine] = [
        WebSearchEngine(name: "Google", urlTemplate: "https://www.google.com/search?q={query}", keyword: "g"),
        WebSearchEngine(name: "DuckDuckGo", urlTemplate: "https://duckduckgo.com/?q={query}", keyword: "ddg"),
        WebSearchEngine(name: "GitHub", urlTemplate: "https://github.com/search?q={query}", keyword: "gh"),
        WebSearchEngine(name: "YouTube", urlTemplate: "https://www.youtube.com/results?search_query={query}", keyword: "yt"),
    ]

    /// Give a stock engine the default keyword its config predates. Engines are
    /// kept as they are otherwise: none added, removed, reordered or overwritten.
    public static func backfillingKeywords(into engines: [WebSearchEngine]) -> [WebSearchEngine] {
        engines.map { engine in
            guard (engine.keyword ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                  let stock = defaults.first(where: { $0.name == engine.name }) else { return engine }
            var filled = engine
            filled.keyword = stock.keyword
            return filled
        }
    }

    /// Re-add any missing stock engines and backfill a default keyword onto a
    /// stock engine that has none. Custom engines are preserved.
    public static func restoringDefaults(into engines: [WebSearchEngine]) -> [WebSearchEngine] {
        var result = engines
        for stock in defaults {
            if let index = result.firstIndex(where: { $0.name == stock.name }) {
                if (result[index].keyword ?? "").isEmpty {
                    result[index].keyword = stock.keyword
                }
            } else {
                result.append(stock)
            }
        }
        return result
    }

    /// Why this row cannot be written, or nil when it is usable. Names and
    /// bangs are matched case-insensitively, the way the launcher resolves
    /// them, so a second "Google" or a repeated `!g` is caught here rather
    /// than silently making the later engine unreachable.
    public func validationIssue(among engines: [WebSearchEngine]) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            return "Give the engine a name."
        }
        if !urlTemplate.contains("{query}") {
            return "The search URL needs a {query} placeholder."
        }
        if engines.filter({
            $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
        }).count > 1 {
            return "Another engine already uses this name."
        }
        let bang = (keyword ?? "").trimmingCharacters(in: .whitespaces)
        if !bang.isEmpty, engines.filter({
            ($0.keyword ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(bang) == .orderedSame
        }).count > 1 {
            return "Another engine already uses !\(bang)."
        }
        return nil
    }

    /// Builds the list to write from what is on screen, falling back to the
    /// saved value for an invalid edit and dropping rows the user deleted.
    /// A valid rename replaces the saved row at the same position; a new row
    /// past the saved list is appended.
    public static func persisting(
        _ drafts: [WebSearchEngine],
        over saved: [WebSearchEngine]
    ) -> [WebSearchEngine] {
        var merged = saved
        var kept = Set<Int>()
        for (index, engine) in drafts.enumerated() {
            if engine.validationIssue(among: drafts) == nil {
                if let match = merged.firstIndex(where: { $0.id == engine.id }) {
                    merged[match] = engine
                    kept.insert(match)
                } else if merged.indices.contains(index), !kept.contains(index) {
                    merged[index] = engine
                    kept.insert(index)
                } else {
                    merged.append(engine)
                    kept.insert(merged.count - 1)
                }
            } else if let match = merged.firstIndex(where: { $0.id == engine.id }) {
                kept.insert(match)
            } else if merged.indices.contains(index), !kept.contains(index) {
                kept.insert(index)
            }
        }
        return merged.enumerated().filter { kept.contains($0.offset) }.map(\.element)
    }
}

public struct ClipboardConfig: Sendable, Equatable {
    public var enabled: Bool
    public var maxEntries: Int
    public var pollMs: Int
    public var clearAfterMs: Int
    /// Clipboard rows older than this many days are dropped on launch and
    /// periodically. Pinned rows are kept.
    public var retentionDays: Int
    /// Total bytes of image blobs; the oldest images are evicted first.
    public var maxImageBytes: Int

    public init(
        enabled: Bool = true,
        maxEntries: Int = 5_000,
        pollMs: Int = 500,
        clearAfterMs: Int = 30_000,
        retentionDays: Int = 30,
        maxImageBytes: Int = 200 * 1024 * 1024
    ) {
        self.enabled = enabled
        self.maxEntries = maxEntries
        self.pollMs = pollMs
        self.clearAfterMs = clearAfterMs
        self.retentionDays = retentionDays
        self.maxImageBytes = maxImageBytes
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
    /// Beside when the screen is wide enough for the preview pane, below if not.
    case auto
}

/// Where the provider switcher sits: a horizontal strip above the list, the
/// vertical rail beside it, or nowhere at all (Tab still cycles providers).
public enum ProviderBarPlacement: String, Sendable, Equatable, CaseIterable {
    case top, left, hidden
}

/// Launcher geometry lives in config.toml, not the theme: themes describe how
/// things look, this describes how big they are.
public struct WindowConfig: Sendable, Equatable {
    /// Multiplier applied to every size below, like `rem`. 0.8...1.6.
    public var scale: Double = 1
    /// Size to the screen under the cursor instead of one fixed size.
    public var autoSize: Bool = true
    /// Provider switcher: top strip, left rail, or hidden.
    public var providerBar: ProviderBarPlacement = .top
    /// Points. 0 means "use the default times scale".
    public var width: Double = 0
    public var maxHeight: Double = 0
    /// Rows before scrolling. 0 means "use the default times scale".
    public var visibleRows: Int = 0
    public var clipboardWidth: Double = 0
    public var previewWidth: Double = 0
    public var terminalWidth: Double = 0
    public var previewLayout: PreviewPlacement = .auto
    /// Fetch site icons for web apps. Turning it off stops any request to the
    /// third-party favicon service; cached icons stay local.
    public var favicons: Bool = true

    public init() {}

    public static let defaultWidth: Double = 680
    public static let defaultMaxHeight: Double = 820
    public static let defaultRows: Int = 7
    public static let defaultPanelWidth: Double = 880
    public static let defaultTerminalWidth: Double = 1000

    public var effectiveScale: Double {
        scale <= 0 ? 1 : min(1.6, max(0.8, scale))
    }

    private func size(_ explicit: Double, _ fallback: Double) -> Double {
        explicit > 0 ? explicit : (fallback * effectiveScale).rounded()
    }

    /// A 13" laptop (1440×900) is the reference: 0.486 × width gives 700pt.
    /// Larger displays scale up to 1000, small ones down to 640.
    public func autoWidth(for visible: CGSize) -> Double {
        guard visible.width > 0, visible.height > 0 else { return Self.defaultWidth * effectiveScale }
        let raw = Double(visible.width) * 0.486
        return (min(1_000, max(640, raw)) * effectiveScale).rounded()
    }

    /// 900pt gets 7 rows; every 128pt of height adds one, clamped 6...11.
    public func autoRows(for visible: CGSize) -> Int {
        guard visible.height > 0 else { return Self.defaultRows }
        let fit = Int((Double(visible.height) / 128).rounded())
        return min(11, max(6, fit))
    }

    public func launcherWidth(for visible: CGSize) -> Double {
        if width > 0 { return width }
        return autoSize ? autoWidth(for: visible) : size(0, Self.defaultWidth)
    }

    public func launcherRows(for visible: CGSize) -> Int {
        if visibleRows > 0 { return min(11, max(6, visibleRows)) }
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
        if visibleRows > 0 { return min(11, max(6, visibleRows)) }
        return min(11, max(6, Int((Double(Self.defaultRows) * effectiveScale).rounded())))
    }

    public func clipboardWidth(for visible: CGSize) -> Double {
        panelWidth(clipboardWidth, Self.defaultPanelWidth, for: visible)
    }
    public func previewWidth(for visible: CGSize) -> Double {
        panelWidth(previewWidth, Self.defaultPanelWidth, for: visible)
    }

    /// The layout to actually use: `auto` falls back to below when the beside
    /// panel would not fit inside the screen minus the 24pt margins. Takes
    /// primitive widths rather than `CGSize`, which trips a SIL-deserialization
    /// bug in some toolchains when a serialized function reads `CGSize.width`.
    public func resolvedPreviewLayout(screenWidth: Double, previewPanelWidth: Double) -> PreviewPlacement {
        guard previewLayout == .auto else { return previewLayout }
        return screenWidth - 24 >= previewPanelWidth ? .beside : .below
    }
    public func terminalWidth(for visible: CGSize) -> Double {
        panelWidth(terminalWidth, Self.defaultTerminalWidth, for: visible)
    }
    public var clipboardPanelWidth: Double { size(clipboardWidth, Self.defaultPanelWidth) }
    public var previewPanelWidth: Double { size(previewWidth, Self.defaultPanelWidth) }
    public var terminalPanelWidth: Double { size(terminalWidth, Self.defaultTerminalWidth) }
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
    /// What a recording captures: screen | display | region.
    public var recordingTarget = "screen"
    /// 1-based display index, as `screencapture -D` expects.
    public var recordingDisplay = 1
    /// "x,y,w,h" in screen points, used when recordingTarget is region.
    public var recordingRegion = ""
    public var recordingAudio = false
    /// AVCaptureDevice uniqueID, as `screencapture -G` expects; empty is the system default.
    public var recordingMicrophone = ""
    /// Which captures `/shots` lists: everything in the folder or only Palette's.
    public var gallery = "all"
    /// Play a shutter sound and show the thumbnail after a screenshot.
    public var captureSound = true
    public var captureThumbnail = true
    /// Open the annotate window after a screenshot.
    public var editAfterCapture = false
    /// Open a player after a recording stops.
    public var previewRecording = true

    public init() {}
}

/// Folders `/cheat` lists, one level deep, filtered by extension.
public struct CheatsheetConfig: Sendable, Equatable {
    public var folders: [String] = []
    public var extensions: [String] = ["pdf", "html", "htm", "md", "markdown", "txt", "png", "jpg", "jpeg"]

    public init(folders: [String] = [], extensions: [String] = ["pdf", "html", "htm", "md", "markdown", "txt", "png", "jpg", "jpeg"]) {
        self.folders = folders
        self.extensions = extensions
    }
}

public struct TimerConfig: Sendable, Equatable {
    /// Preset durations in minutes, shown as rows in /timer.
    public var presets: [Int] = [5, 10, 15, 25, 30, 45, 60]
    public var sound = true
    public var notify = true

    public init() {}
}

public enum HotkeyAction: String, Sendable, Equatable, CaseIterable {
    case launch
    case command
    case provider
    case url

    public var title: String {
        switch self {
        case .launch: return "Launch app"
        case .command: return "Run command"
        case .provider: return "Open provider"
        case .url: return "Open URL"
        }
    }
}

/// One `[[binding]]` row: a global shortcut and the action it runs.
public struct HotkeyBinding: Sendable, Equatable {
    public var keys: String
    public var action: HotkeyAction
    public var value: String

    public init(keys: String, action: HotkeyAction = .launch, value: String = "") {
        self.keys = keys
        self.action = action
        self.value = value
    }
}

/// Built-in provider aliases. Settings shows these even when removed so they
/// can be re-enabled, and "Reset to defaults" restores them.
public enum ProviderAliases {
    public static let defaults: [String: [String]] = [
        "neo": ["neo", "editor"],
        "neof": ["neof", "folders"],
    ]
}

public struct PaletteConfig: Sendable, Equatable {
    public var hotkey: String
    public var clipboardHotkey: String
    public var terminalHotkey: String
    public var scratchpadHotkey: String
    public var askHotkey: String
    public var screenshotHotkey: String
    public var regionScreenshotHotkey: String
    public var windowScreenshotHotkey: String
    public var recordingHotkey: String
    public var providerPrefix: String
    /// Overrides the theme's search-field placeholder; empty inherits it.
    public var searchPlaceholder: String
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
    /// Global shortcut → action rows from `[[binding]]`.
    public var bindings: [HotkeyBinding]
    /// Catalogue command → key rows from `[[shortcut]]`.
    public var shortcuts: [ShortcutBinding]
    /// Allowlist of providers searched by a plain, unprefixed query. `apps` is
    /// always searched and need not be listed.
    public var globalProviders: [String]
    /// Provider ids whose missing-tool prompt was already answered, so the
    /// launcher never asks twice.
    public var missingToolAcknowledged: [String]
    /// Whether the user agreed to index the whole home folder. nil means the
    /// one-time consent prompt has not been shown.
    public var indexingHomeConsent: Bool?

    /// Providers a plain query searches out of the box, before user changes.
    public static let defaultGlobalProviders = [
        "calc", "search", "web", "win", "unit", "zj",
        "bookmark", "pins", "system", "timer", "awake", "cheat",
    ]

    public var terminalSession: TerminalSessionConfig
    public var timer: TimerConfig
    public var capture: CaptureConfig
    public var cheatsheets: CheatsheetConfig

    public init(
        hotkey: String = "opt+space",
        clipboardHotkey: String = "opt+v",
        terminalHotkey: String = "cmd+option+t",
        scratchpadHotkey: String = "cmd+option+s",
        askHotkey: String = "cmd+option+a",
        // Same family as the system screenshot keys, which the app takes over.
        screenshotHotkey: String = "cmd+shift+3",
        regionScreenshotHotkey: String = "cmd+shift+4",
        windowScreenshotHotkey: String = "cmd+shift+6",
        recordingHotkey: String = "cmd+shift+5",
        providerPrefix: String = "/",
        searchPlaceholder: String = "",
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
        providerAliases: [String: [String]] = ProviderAliases.defaults,
        providerOrder: [String] = [],
        disabledProviders: [String] = [],
        bindings: [HotkeyBinding] = [],
        shortcuts: [ShortcutBinding] = [],
        globalProviders: [String] = PaletteConfig.defaultGlobalProviders,
        missingToolAcknowledged: [String] = [],
        indexingHomeConsent: Bool? = nil,
        terminalSession: TerminalSessionConfig = TerminalSessionConfig(),
        timer: TimerConfig = TimerConfig(),
        capture: CaptureConfig = CaptureConfig(),
        cheatsheets: CheatsheetConfig = CheatsheetConfig()
    ) {
        self.hotkey = hotkey
        self.clipboardHotkey = clipboardHotkey
        self.terminalHotkey = terminalHotkey
        self.scratchpadHotkey = scratchpadHotkey
        self.askHotkey = askHotkey
        self.screenshotHotkey = screenshotHotkey
        self.regionScreenshotHotkey = regionScreenshotHotkey
        self.windowScreenshotHotkey = windowScreenshotHotkey
        self.recordingHotkey = recordingHotkey
        self.providerPrefix = providerPrefix
        self.searchPlaceholder = searchPlaceholder
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
        self.bindings = bindings
        self.shortcuts = shortcuts
        self.globalProviders = globalProviders
        self.missingToolAcknowledged = missingToolAcknowledged
        self.indexingHomeConsent = indexingHomeConsent
        self.terminalSession = terminalSession
        self.timer = timer
        self.capture = capture
        self.cheatsheets = cheatsheets
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
        home: String = NSHomeDirectory(),
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> PalettePaths {
        func directory(_ value: String) -> URL {
            URL(fileURLWithPath: PathExpansion.expand(value, home: home), isDirectory: true)
        }

        // The debug bundle keeps its own config so a debug run never reads or
        // writes the installed copy. PALETTE_* overrides still win.
        let debugSupport = bundleIdentifier == "dev.myleshen.palette.debug"
            ? home + "/Library/Application Support/Palette Debug"
            : nil
        let debugCache = bundleIdentifier == "dev.myleshen.palette.debug"
            ? home + "/Library/Caches/Palette Debug"
            : nil

        let configBase = environment["PALETTE_CONFIG_DIR"]
            ?? debugSupport.map { $0 + "/config" }
            ?? environment["XDG_CONFIG_HOME"].map { $0 + "/palette" }
            ?? home + "/.config/palette"
        let stateBase = environment["PALETTE_STATE_DIR"]
            ?? debugSupport.map { $0 + "/state" }
            ?? environment["XDG_STATE_HOME"].map { $0 + "/palette" }
            ?? home + "/.local/state/palette"
        let cacheBase = environment["PALETTE_CACHE_DIR"]
            ?? debugCache
            ?? (environment["PALETTE_SCRIPT"] != nil
                ? stateBase + "/cache"
                : home + "/Library/Caches/Palette")

        return PalettePaths(
            home: home,
            configDir: directory(configBase),
            stateDir: directory(stateBase),
            cacheDir: directory(cacheBase)
        )
    }

    public var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public var bookmarksFile: URL { configDir.appendingPathComponent("bookmarks.toml") }
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
    /// Set when config.toml on disk could not be parsed. Auto-apply refuses to
    /// write in this state so the user's file and comments survive.
    public var parseError: String?
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
            let backup = ConfigWriter.backupURL(for: paths.configFile)
            let message = "config.toml has an error; fix it or restore \(backup.path) before changing settings here (\(error.localizedDescription))."
            diagnostics.append(Diagnostic(.error, message, source: "config"))
            return ConfigLoadResult(
                config: PaletteConfig(),
                diagnostics: diagnostics,
                createdDefault: created,
                parseError: message
            )
        }
    }

    /// A list written before `[meta] config_version` meant extras on top of the
    /// old three globals. A list naming only providers that already default
    /// today is a deliberate narrowing from a later release, not legacy.
    static func usesLegacyGlobalSemantics(_ list: [String]) -> Bool {
        let oldBaseline: Set<String> = ["system", "timer", "awake"]
        let today = Set(PaletteConfig.defaultGlobalProviders)
        return list.allSatisfy { oldBaseline.contains($0) || !today.contains($0) }
    }

    public static func parse(_ table: TOMLTable, diagnostics: inout [Diagnostic]) throws -> PaletteConfig {
        var config = PaletteConfig()
        // Missing means a config written before the version key existed.
        let schemaVersion = table.table("meta")?.int("config_version") ?? 0

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
        if let hotkey = table.str("region_screenshot_hotkey") {
            config.regionScreenshotHotkey = hotkey
        }
        if let hotkey = table.str("window_screenshot_hotkey") {
            config.windowScreenshotHotkey = hotkey
        }
        if let hotkey = table.str("recording_hotkey") {
            config.recordingHotkey = hotkey
        }
        // 2.4 moved the capture keys onto the number row. A config that still
        // carries the old defaults was never customised, so it moves with it.
        if config.screenshotHotkey == "cmd+option+shift+s" {
            config.screenshotHotkey = "cmd+shift+3"
        }
        if config.recordingHotkey == "cmd+option+shift+r" {
            config.recordingHotkey = "cmd+shift+5"
        }
        if let prefix = table.str("provider_prefix"), !prefix.isEmpty {
            config.providerPrefix = prefix
        }
        if let placeholder = table.str("search_placeholder") {
            config.searchPlaceholder = placeholder.trimmingCharacters(in: .whitespaces)
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
                config.window.visibleRows = min(11, max(6, value))
            }
            if let value = window.number("clipboard_width"), value > 0 { config.window.clipboardWidth = value }
            if let value = window.number("preview_width"), value > 0 { config.window.previewWidth = value }
            if let value = window.number("terminal_width"), value > 0 { config.window.terminalWidth = value }
            if let raw = window.str("preview_layout"), let layout = PreviewPlacement(rawValue: raw.lowercased()) {
                config.window.previewLayout = layout
            }
            if let raw = window.str("provider_bar"),
               let placement = ProviderBarPlacement(rawValue: raw.lowercased()) {
                config.window.providerBar = placement
            }
            config.window.favicons = window.bool("favicons") ?? config.window.favicons
        }
        // 2.3.2 wrote a root-level key; keep reading it for one release.
        if let rows = table.int("visible_rows"), rows > 0, config.window.visibleRows == 0 {
            config.window.visibleRows = min(11, max(6, rows))
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
            config.capture.editAfterCapture = capture.bool("edit_after_capture") ?? config.capture.editAfterCapture
            config.capture.captureSound = capture.bool("sound") ?? config.capture.captureSound
            config.capture.captureThumbnail = capture.bool("thumbnail") ?? config.capture.captureThumbnail
            config.capture.previewRecording = capture.bool("preview_recording") ?? config.capture.previewRecording
            if let value = capture.str("recording_target"), ["screen", "display", "region"].contains(value.lowercased()) {
                config.capture.recordingTarget = value.lowercased()
            }
            if let value = capture.int("recording_display"), value >= 1 { config.capture.recordingDisplay = value }
            if let value = capture.str("recording_region") { config.capture.recordingRegion = value }
            config.capture.recordingAudio = capture.bool("recording_audio") ?? config.capture.recordingAudio
            if let value = capture.str("recording_microphone") {
                config.capture.recordingMicrophone = value.trimmingCharacters(in: .whitespaces)
            }
            if let value = capture.str("gallery"), ["all", "palette"].contains(value.lowercased()) {
                config.capture.gallery = value.lowercased()
            }
        }

        if let cheatsheets = table.table("cheatsheets") {
            config.cheatsheets.folders = (cheatsheets.strArray("folders") ?? config.cheatsheets.folders)
                .map { ($0 as NSString).expandingTildeInPath }
                .filter { !$0.isEmpty }
            if let extensions = cheatsheets.strArray("extensions") {
                let cleaned = extensions
                    .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                    .filter { !$0.isEmpty }
                if !cleaned.isEmpty { config.cheatsheets.extensions = cleaned }
            }
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
            config.missingToolAcknowledged = (providers.strArray("missing_tool_acknowledged") ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            // Absent key keeps the default allowlist, so old configs gain it;
            // an explicit `global = []` opts out of everything but apps.
            if let global = providers.strArray("global") {
                let parsed = global
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
                if parsed.isEmpty {
                    // An explicit `global = []` opts out of everything but apps.
                    config.globalProviders = []
                } else if schemaVersion < ConfigWriter.configVersion,
                          Self.usesLegacyGlobalSemantics(parsed) {
                    // Before the version key, this list meant extras on top of
                    // the built-in globals. Upgrade it to the full allowlist,
                    // keeping ids the user added themselves.
                    var merged = PaletteConfig.defaultGlobalProviders
                    for id in parsed where !merged.contains(id) {
                        merged.append(id)
                    }
                    config.globalProviders = merged
                } else {
                    config.globalProviders = parsed
                }
            }
            if let aliases = providers.table("aliases") {
                var parsed = config.providerAliases
                for key in aliases.keys {
                    let values = aliases.strArray(key) ?? []
                    let cleaned = values
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    // An explicit empty list suppresses a built-in default.
                    parsed[key] = cleaned
                }
                config.providerAliases = parsed
            }
        }

        if let indexing = table.table("indexing") {
            config.indexingHomeConsent = indexing.bool("home_consent")
        }

        // `[[binding]]` is an array of tables so shortcuts like ctrl+alt+g need
        // no quoting around the key.
        if let bindings = table.array("binding") {
            for (index, value) in bindings.enumerated() {
                guard let entry = value.table else {
                    diagnostics.append(Diagnostic(.warning, "Binding #\(index + 1) is not a table; skipped.", source: "config"))
                    continue
                }
                let keys = (entry.str("keys") ?? "").trimmingCharacters(in: .whitespaces)
                let actionName = (entry.str("action") ?? "").lowercased()
                let bindingValue = (entry.str("value") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keys.isEmpty, !bindingValue.isEmpty, let action = HotkeyAction(rawValue: actionName) else {
                    diagnostics.append(Diagnostic(
                        .warning,
                        "Binding #\(index + 1) needs keys, a known action (launch | command | provider | url), and a value; skipped.",
                        source: "config"
                    ))
                    continue
                }
                config.bindings.append(HotkeyBinding(keys: keys, action: action, value: bindingValue))
            }
        }

        // `[[shortcut]]` binds a catalogue command. Unknown ids are kept: a
        // newer build may know them, and registration reports them.
        if let shortcuts = table.array("shortcut") {
            for (index, value) in shortcuts.enumerated() {
                guard let entry = value.table else {
                    diagnostics.append(Diagnostic(.warning, "Shortcut #\(index + 1) is not a table; skipped.", source: "config"))
                    continue
                }
                let command = (entry.str("command") ?? "").trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else {
                    diagnostics.append(Diagnostic(.warning, "Shortcut #\(index + 1) needs a command; skipped.", source: "config"))
                    continue
                }
                let keys = (entry.str("keys") ?? "").trimmingCharacters(in: .whitespaces)
                config.shortcuts.append(ShortcutBinding(command: command, keys: keys))
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
                        keyword: engine.str("keyword"),
                        browser: engine.str("browser") ?? "",
                        appMode: engine.bool("app_mode") ?? false
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
            if let notify = askTable.bool("notify") {
                ask.notify = notify
            }
            if let webSearch = askTable.bool("web_search") {
                ask.webSearch = webSearch
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
            clipboard.retentionDays = max(0, clipboardTable.int("retention_days") ?? clipboard.retentionDays)
            if let bytes = clipboardTable.int("max_image_bytes") {
                clipboard.maxImageBytes = max(0, bytes)
            }
            config.clipboard = clipboard
        }

        if config.providerPrefix.count != 1 {
            diagnostics.append(Diagnostic(.warning, "provider_prefix should be one character; using '/'.", source: "config"))
            config.providerPrefix = "/"
        }

        // Configs written before 2.7.0 have stock engines with no `!keyword`.
        config.webSearchEngines = WebSearchEngine.backfillingKeywords(into: config.webSearchEngines)

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

        # Run anything from a global shortcut. A binding never replaces the
        # built-in hotkeys: use a key that is not already taken.
        # [[binding]]
        # keys = "ctrl+alt+g"
        # action = "launch"            # launch | command | provider | url
        # value = "Ghostty"

        # Give any provider or app command its own key. Add rows in Settings >
        # Shortcuts; keys = "" keeps a command explicitly unbound.
        # [[shortcut]]
        # command = "provider.calc"
        # keys = "ctrl+alt+c"

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
        max_height = 0                 # points, 0 = 820 * scale
        visible_rows = 0               # 6-11, 0 = 7 * scale
        clipboard_width = 0            # 0 = 880 * scale
        preview_width = 0
        terminal_width = 0             # 0 = 1000 * scale
        preview_layout = "auto"        # beside | below | auto
        provider_bar = "top"           # top | left | hidden
        favicons = true                # fetch web-app site icons from Google

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
        recording_target = "screen"        # screen | display | region
        recording_display = 1
        recording_region = ""
        recording_audio = false
        gallery = "all"                    # all | palette (only shot-*/rec-* files)
        sound = true                       # shutter sound after a screenshot
        thumbnail = true                   # brief thumbnail after a screenshot
        edit_after_capture = false         # open the annotate window
        preview_recording = true           # player after a recording stops

        # Folders /cheat lists, one level deep, with a QuickLook preview.
        [cheatsheets]
        folders = []
        extensions = ["pdf", "html", "htm", "md", "markdown", "txt", "png", "jpg", "jpeg"]

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
        # Plain queries search only these providers (apps always); /trigger
        # targets one.
        global = [
          "calc", "search", "web", "win", "unit", "zj",
          "bookmark", "pins", "system", "timer", "awake", "cheat",
        ]
        # Providers whose missing-tool prompt was already answered.
        missing_tool_acknowledged = []

        # Ask once before indexing the whole home folder for the file providers.
        # [indexing]
        # home_consent = true

        [providers.aliases]

        # Embedded terminal. auto uses Zellij, then tmux, then a plain shell.
        [terminal_session]
        multiplexer = "auto"           # auto | zellij | tmux | none
        name = "Palette"
        shell = ""                     # empty = fish if installed, else zsh
        font = ""                      # empty = kitty font, then theme mono
        font_size = 0                  # 0 = kitty size, then 13

        # Ask chat (⌘⌥A). The API key is never written here; it lives in an
        # encrypted local file and is entered in Settings > Ask.
        [ask]
        provider = "opencode-go"       # opencode-go | nvidia
        model = "beam-free"
        max_history = 200
        retention_days = 30
        max_tokens = 8192
        fallback = true                # use free/cheap models when quota runs out
        notify = true                  # sound and Dock bounce when an answer arrives
        web_search = true              # one web lookup per turn (composer toggle)

        # Global web search. Add or remove engines as you like; {query} is
        # replaced with the URL-encoded search text. app_mode = true opens
        # that engine's bangs in the web-app browser (Chromium-based only).
        [web_search]
        enabled = true

        [[web_search.engines]]
        name = "Google"
        url = "https://www.google.com/search?q={query}"
        keyword = "g"

        [[web_search.engines]]
        name = "DuckDuckGo"
        url = "https://duckduckgo.com/?q={query}"
        keyword = "ddg"

        [[web_search.engines]]
        name = "GitHub"
        url = "https://github.com/search?q={query}"
        keyword = "gh"

        [[web_search.engines]]
        name = "YouTube"
        url = "https://www.youtube.com/results?search_query={query}"
        keyword = "yt"

        [theme]
        mode = "auto"                 # dark | light | auto
        dark = "siri-graphite"
        light = "siri-silver"

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
        retention_days = 30
        max_image_bytes = 209715200

        # Written by Palette. Missing means the file predates schema versioning.
        [meta]
        config_version = 2

        """
    }
}

public enum ConfigWriter {
    /// Bumped when a key's on-disk meaning changes. Written as
    /// `[meta] config_version`.
    public static let configVersion = 2

    public static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    /// Saves the canonical render, keeping the exact previous file as a single
    /// rolling backup. The backup is written first: if it fails, the original
    /// file stays untouched.
    public static func write(_ config: PaletteConfig, to url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            let backup = backupURL(for: url)
            try previous.write(to: backup, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try render(config).write(to: url, atomically: true, encoding: .utf8)
    }

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
        out.append("region_screenshot_hotkey = \(quote(config.regionScreenshotHotkey))")
        out.append("window_screenshot_hotkey = \(quote(config.windowScreenshotHotkey))")
        out.append("recording_hotkey = \(quote(config.recordingHotkey))")
        out.append("provider_prefix = \(quote(config.providerPrefix))")
        out.append("search_placeholder = \(quote(config.searchPlaceholder))")
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
        if config.window.previewWidth > 0 { out.append("preview_width = \(config.window.previewWidth)") }
        if config.window.terminalWidth > 0 { out.append("terminal_width = \(config.window.terminalWidth)") }
        out.append("preview_layout = \"\(config.window.previewLayout.rawValue)\"")
        out.append("provider_bar = \"\(config.window.providerBar.rawValue)\"")
        out.append("favicons = \(config.window.favicons)")
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
        out.append("edit_after_capture = \(config.capture.editAfterCapture)")
        out.append("sound = \(config.capture.captureSound)")
        out.append("thumbnail = \(config.capture.captureThumbnail)")
        out.append("preview_recording = \(config.capture.previewRecording)")
        out.append("recording_target = \(quote(config.capture.recordingTarget))")
        out.append("recording_display = \(config.capture.recordingDisplay)")
        out.append("recording_region = \(quote(config.capture.recordingRegion))")
        out.append("recording_audio = \(config.capture.recordingAudio)")
        out.append("recording_microphone = \(quote(config.capture.recordingMicrophone))")
        out.append("gallery = \(quote(config.capture.gallery))")
        out.append("")
        out.append("[cheatsheets]")
        out.append("folders = [\(config.cheatsheets.folders.map(quote).joined(separator: ", "))]")
        out.append("extensions = [\(config.cheatsheets.extensions.map(quote).joined(separator: ", "))]")
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
        out.append("global = [\(config.globalProviders.map(quote).joined(separator: ", "))]")
        out.append("missing_tool_acknowledged = [\(config.missingToolAcknowledged.map(quote).joined(separator: ", "))]")
        out.append("")
        if let consent = config.indexingHomeConsent {
            out.append("[indexing]")
            out.append("home_consent = \(consent)")
            out.append("")
        }
        out.append("[providers.aliases]")
        for id in config.providerAliases.keys.sorted() {
            let aliases = config.providerAliases[id] ?? []
            out.append("\(quote(id)) = [\(aliases.map(quote).joined(separator: ", "))]")
        }
        out.append("")
        for binding in config.bindings {
            out.append("[[binding]]")
            out.append("keys = \(quote(binding.keys))")
            out.append("action = \(quote(binding.action.rawValue))")
            out.append("value = \(quote(binding.value))")
            out.append("")
        }
        for shortcut in config.shortcuts {
            out.append("[[shortcut]]")
            out.append("command = \(quote(shortcut.command))")
            out.append("keys = \(quote(shortcut.keys))")
            out.append("")
        }
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
        out.append("notify = \(config.ask.notify)")
        out.append("web_search = \(config.ask.webSearch)")
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
            if !engine.browser.isEmpty { out.append("browser = \(quote(engine.browser))") }
            if engine.appMode { out.append("app_mode = true") }
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
        out.append("retention_days = \(config.clipboard.retentionDays)")
        out.append("max_image_bytes = \(config.clipboard.maxImageBytes)")
        out.append("")
        out.append("[meta]")
        out.append("config_version = \(configVersion)")
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
