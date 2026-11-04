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

public struct PaletteConfig: Sendable, Equatable {
    public var hotkey: String
    public var clipboardHotkey: String
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
    public var appSort: AppSort
    public var ask: AskConfig
    public var typography: TypographyConfig
    public var providerAliases: [String: [String]]
    public var providerOrder: [String]
    public var disabledProviders: [String]

    public init(
        hotkey: String = "opt+space",
        clipboardHotkey: String = "opt+v",
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
        appSort: AppSort = .alphabetical,
        ask: AskConfig = AskConfig(),
        typography: TypographyConfig = TypographyConfig(),
        providerAliases: [String: [String]] = [:],
        providerOrder: [String] = [],
        disabledProviders: [String] = []
    ) {
        self.hotkey = hotkey
        self.clipboardHotkey = clipboardHotkey
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
        self.appSort = appSort
        self.ask = ask
        self.typography = typography
        self.providerAliases = providerAliases
        self.providerOrder = providerOrder
        self.disabledProviders = disabledProviders
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
        if let hotkey = table.str("clipboard_hotkey"), !hotkey.isEmpty {
            config.clipboardHotkey = hotkey
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

        if let providers = table.table("providers") {
            config.providerOrder = providers.strArray("order") ?? []
            config.disabledProviders = (providers.strArray("disabled") ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0 != "apps" }
            if let aliases = providers.table("aliases") {
                var parsed: [String: [String]] = [:]
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

        # One-shot AI answers (/ask). The API key is never written here; it
        # lives in the macOS Keychain and is entered in Settings > Ask.
        [ask]
        provider = "opencode-zen"      # opencode-zen | opencode-go | openai
        model = "glm-5.3-flash-free"
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
        out.append("provider_prefix = \(quote(config.providerPrefix))")
        out.append("tools_path = [\(config.toolsPath.map(quote).joined(separator: ", "))]")
        out.append("terminal = \(quote(config.terminal))")
        out.append("terminal_app = \(quote(config.terminalApp))")
        out.append("editor_open_with = \(quote(config.editorOpenWith))")
        out.append("search_position = \(quote(config.searchPosition.rawValue))")
        out.append("web_app_browser = \(quote(config.webAppBrowser))")
        out.append("app_sort = \(quote(config.appSort.rawValue))")
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
