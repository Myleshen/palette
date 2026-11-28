import Foundation
import TOMLKit

public struct RGBA: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "transparent" {
            self = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        let characters = Array(value)
        func component(_ slice: ArraySlice<Character>) -> Double? {
            guard let number = Int(String(slice), radix: 16) else { return nil }
            return Double(number) / (slice.count == 1 ? 15 : 255)
        }
        switch characters.count {
        case 3, 4:
            guard let r = component(characters[0...0]),
                  let g = component(characters[1...1]),
                  let b = component(characters[2...2]) else { return nil }
            let a = characters.count == 4 ? component(characters[3...3]) : 1
            guard let alpha = a else { return nil }
            self = RGBA(red: r, green: g, blue: b, alpha: alpha)
        case 6, 8:
            guard let r = component(characters[0...1]),
                  let g = component(characters[2...3]),
                  let b = component(characters[4...5]) else { return nil }
            let a = characters.count == 8 ? component(characters[6...7]) : 1
            guard let alpha = a else { return nil }
            self = RGBA(red: r, green: g, blue: b, alpha: alpha)
        default:
            return nil
        }
    }

    public var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: RGBA) -> Double {
        let first = luminance
        let second = other.luminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

public struct ThemePalette: Equatable, Sendable {
    public var bg = "#1e1e2e"
    public var surface = "#181825"
    public var elevated = "#313244"
    public var fg = "#cdd6f4"
    public var fgMuted = "#a6adc8"
    public var accent = "#cba6f7"
    public var accentFg = "#1e1e2e"
    public var selectionBg = "#313244"
    public var selectionFg = "#cdd6f4"
    public var matchFg = "#f5c2e7"
    public var border = "#45475a"
    public var separator = "#31324480"
    public var danger = "#f38ba8"
    public var warning = "#f9e2af"
    public var success = "#a6e3a1"
    public var info = "#89b4fa"
    public var badgeBg = "#45475a"
    public var badgeFg = "#cdd6f4"
    public init() {}
}

public struct ThemeWindow: Equatable, Sendable {
    public var width: Double = 680
    public var maxHeight: Double = 720
    public var anchor = "top"
    public var offsetY: Double = 120
    public var offsetYPercent = false
    public var cornerRadius: Double = 14
    public var material = "hudWindow"
    public var opacity: Double = 0.98
    public var borderWidth: Double = 1
    public var shadow = true
    public var glass = true
    public var glassOpacity: Double = 0.7
    public init() {}
}

public struct ThemeSearch: Equatable, Sendable {
    public var height: Double = 56
    public var placeholder = "Search apps, files, commands…"
    public var showIcon = true
    public init() {}
}

public struct ThemeList: Equatable, Sendable {
    public var rowHeight: Double = 44
    public var spacing: Double = 2
    public var density = "comfortable"
    public var showIcons = true
    public var iconSize: Double = 20
    public var iconStyle = "original"
    public var showSubtitles = true
    public var selection = "fill"
    public var columns = 1
    public var showScrollbar = true
    /// Rows the panel shows before scrolling. Clamped to 6...11; drives panel height.
    public var visibleRows = 7
    public init() {}
}

public struct ThemeTypography: Equatable, Sendable {
    public var family = "SF Pro Text"
    public var size: Double = 14
    public var subtitleSize: Double = 12
    public var mono = "JetBrains Mono"
    public var monoSize: Double = 12
    public var previewSize: Double = 13
    public var matchWeight = "semibold"
    public init() {}
}

public struct ThemeState: Equatable, Sendable {
    public var bg: String?
    public var fg: String?
    public init(bg: String? = nil, fg: String? = nil) {
        self.bg = bg
        self.fg = fg
    }
}

public struct ThemeStates: Equatable, Sendable {
    public var selected = ThemeState(bg: "#45475a", fg: "#cdd6f4")
    public var hover = ThemeState(bg: "#313244")
    public var disabled = ThemeState(fg: "#6c7086")
    public init() {}
}

public struct ThemeMotion: Equatable, Sendable {
    public var durationMs: Double = 120
    public var style = "fade"
    public init() {}
}

public struct ThemeFooter: Equatable, Sendable {
    public var show = true
    public var hintColor = "#a6adc8"
    public init() {}
}

public struct Theme: Equatable, Sendable {
    public var name = "Default Dark"
    public var appearance = "dark"
    public var palette = ThemePalette()
    public var window = ThemeWindow()
    public var search = ThemeSearch()
    public var list = ThemeList()
    public var typography = ThemeTypography()
    public var states = ThemeStates()
    public var motion = ThemeMotion()
    public var footer = ThemeFooter()
    public init() {}

    /// Compact density tightens rows without changing the theme's explicit
    /// row height. The search bar and footer keep their configured sizes.
    public var effectiveRowHeight: Double {
        guard list.density.lowercased() == "compact" else { return list.rowHeight }
        let floor = list.showSubtitles ? 38.0 : 30.0
        return max(floor, list.rowHeight * 0.82)
    }

    public var effectiveIconSize: Double {
        list.density.lowercased() == "compact" ? max(14, list.iconSize * 0.86) : list.iconSize
    }

    /// Point size every preview surface reads: clipboard, paths, atlas,
    /// snippets, media captions and the Ask transcript.
    public var previewTextSize: Double {
        min(24, max(9, typography.previewSize))
    }

    public static let defaultDark = Theme()

    public static let defaultLight: Theme = {
        var theme = Theme()
        theme.name = "Default Light"
        theme.appearance = "light"
        theme.palette.bg = "#ffffff"
        theme.palette.surface = "#f4f4f5"
        theme.palette.elevated = "#ffffff"
        theme.palette.fg = "#18181b"
        theme.palette.fgMuted = "#52525b"
        theme.palette.accent = "#7c3aed"
        theme.palette.accentFg = "#ffffff"
        theme.palette.selectionBg = "#e4e4e7"
        theme.palette.selectionFg = "#18181b"
        theme.palette.matchFg = "#9333ea"
        theme.palette.border = "#d4d4d8"
        theme.palette.separator = "#e4e4e780"
        theme.palette.badgeBg = "#e4e4e7"
        theme.palette.badgeFg = "#3f3f46"
        theme.palette.danger = "#da7693"
        theme.palette.warning = "#a79362"
        theme.palette.success = "#68a264"
        theme.palette.info = "#6c95d9"
        theme.states.selected = ThemeState(bg: "#e4e4e7", fg: "#18181b")
        theme.states.hover = ThemeState(bg: "#f4f4f5")
        theme.states.disabled = ThemeState(fg: "#a1a1aa")
        theme.footer.hintColor = "#52525b"
        theme.window.material = "popover"
        return theme
    }()
}

public struct ThemeLoadResult: Sendable {
    public var theme: Theme
    public var diagnostics: [Diagnostic]

    public init(theme: Theme, diagnostics: [Diagnostic]) {
        self.theme = theme
        self.diagnostics = diagnostics
    }
}

public struct ThemeInfo: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var appearance: String
    public var isBuiltin: Bool
    public init(name: String, displayName: String, appearance: String, isBuiltin: Bool) {
        self.name = name
        self.displayName = displayName
        self.appearance = appearance
        self.isBuiltin = isBuiltin
    }
}

public enum ThemeLoader {
    public static let builtinNames = [
        "default-dark", "default-light", "catppuccin-mocha", "catppuccin-latte",
        "gruvbox-dark", "gruvbox-light", "aetheria-pink", "siri-silver",
        "siri-graphite",
    ]

    /// Bundled resource themes ship inside the app and next to the package, so
    /// they need no first-run copy into the user's themes directory.
    public static var bundledThemesDirectory: URL? {
        guard let themes = PalettePaths.resolve().bundledResources()?
            .appendingPathComponent("Themes", isDirectory: true) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: themes.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return themes
    }

    public static func bundledThemeNames(
        themesDirectory: URL? = ThemeLoader.bundledThemesDirectory
    ) -> [String] {
        guard let themesDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: themesDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "toml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public static func load(
        name: String,
        themesDirectory: URL,
        bundledThemesDirectory: URL? = ThemeLoader.bundledThemesDirectory,
        fallback: Theme = .defaultDark
    ) -> ThemeLoadResult {
        let key = cacheKey(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory, fallback: fallback)
        if let cached = cachedTheme(for: key) {
            return cached
        }
        var diagnostics: [Diagnostic] = []
        var theme = resolve(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory, fallback: fallback, visited: [], diagnostics: &diagnostics)
        for change in ThemeContrastRepair.repair(&theme).changes {
            diagnostics.append(Diagnostic(
                .warning,
                "Theme '\(theme.name)': \(change.field) \(change.original) had \(ratio(change.before)):1; using \(change.repaired) (\(ratio(change.after)):1).",
                source: "theme"
            ))
        }
        validate(theme, diagnostics: &diagnostics)
        let result = ThemeLoadResult(theme: theme, diagnostics: diagnostics)
        store(result, for: key)
        return result
    }

    /// The file id a stored theme reference names. A reference that loads as-is
    /// is already an id; anything else (the display name an older Settings
    /// build saved, or a label without its section prefix) is matched against
    /// the catalogue so the loader gets a name it can find.
    public static func themeID(
        for reference: String,
        themesDirectory: URL,
        bundledThemesDirectory: URL? = ThemeLoader.bundledThemesDirectory
    ) -> String? {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if exists(named: value, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory) {
            return value
        }
        let themes = catalog(themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory)
        if let match = themes.first(where: { $0.displayName == value }) { return match.name }
        return themes.first { $0.shortDisplayName == value }?.name
    }

    private static func exists(named name: String, themesDirectory: URL, bundledThemesDirectory: URL?) -> Bool {
        if builtinNames.contains(name) { return true }
        let user = themesDirectory.appendingPathComponent(name).appendingPathExtension("toml")
        if FileManager.default.fileExists(atPath: user.path) { return true }
        guard let bundledThemesDirectory else { return false }
        let bundled = bundledThemesDirectory.appendingPathComponent(name).appendingPathExtension("toml")
        return FileManager.default.fileExists(atPath: bundled.path)
    }

    // MARK: - Full-parse cache

    /// Parsing a theme allocates its whole palette, so the browser keeps only
    /// what the visible rows and the preview asked for. The key carries file
    /// stamps so editing or replacing a theme invalidates its entry.
    private struct CacheKey: Hashable {
        var name: String
        var themesDirectory: String
        var bundledThemesDirectory: String?
        var fallback: String
        var stamp: String
    }

    private static let cacheLock = NSLock()
    private static var loadCache: [CacheKey: ThemeLoadResult] = [:]
    private static var loadOrder: [CacheKey] = []
    private static let loadCacheLimit = 48
    private static var parseCount = 0
    private static var catalogCount = 0

    private static func cacheKey(
        name: String,
        themesDirectory: URL,
        bundledThemesDirectory: URL?,
        fallback: Theme
    ) -> CacheKey {
        CacheKey(
            name: name,
            themesDirectory: themesDirectory.standardizedFileURL.path,
            bundledThemesDirectory: bundledThemesDirectory?.standardizedFileURL.path,
            fallback: fallback.name,
            stamp: fileStamp(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory)
        )
    }

    private static func fileStamp(name: String, themesDirectory: URL, bundledThemesDirectory: URL?) -> String {
        let directoryDate = modificationDate(themesDirectory)?.timeIntervalSince1970 ?? 0
        let user = themesDirectory.appendingPathComponent(name).appendingPathExtension("toml")
        if let date = modificationDate(user) {
            return "user-\(date.timeIntervalSince1970)-\(directoryDate)"
        }
        if let bundledThemesDirectory {
            let directoryDate = modificationDate(bundledThemesDirectory)?.timeIntervalSince1970 ?? 0
            let bundled = bundledThemesDirectory.appendingPathComponent(name).appendingPathExtension("toml")
            if let date = modificationDate(bundled) {
                return "bundled-\(date.timeIntervalSince1970)-\(directoryDate)"
            }
        }
        // Built-in sources are compiled into the app and cannot change.
        return "builtin"
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func cachedTheme(for key: CacheKey) -> ThemeLoadResult? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let result = loadCache[key] else { return nil }
        if let index = loadOrder.firstIndex(of: key) {
            loadOrder.remove(at: index)
            loadOrder.append(key)
        }
        return result
    }

    private static func store(_ result: ThemeLoadResult, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if loadCache[key] != nil {
            loadCache[key] = result
            return
        }
        if loadOrder.count >= loadCacheLimit, let oldest = loadOrder.first {
            loadOrder.removeFirst()
            loadCache.removeValue(forKey: oldest)
        }
        loadOrder.append(key)
        loadCache[key] = result
        parseCount += 1
    }

    internal static func resetCachesForTesting() {
        cacheLock.lock()
        loadCache.removeAll()
        loadOrder.removeAll()
        parseCount = 0
        catalogCount = 0
        cacheLock.unlock()
        bundledCatalogLock.lock()
        bundledCatalogCache.removeAll()
        bundledCatalogLock.unlock()
    }

    internal static var fullParseCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return parseCount
    }

    internal static var catalogCallCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return catalogCount
    }

    internal static var cachedThemeCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return loadCache.count
    }

    private static func ratio(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    public static func catalog(
        themesDirectory: URL,
        bundledThemesDirectory: URL? = ThemeLoader.bundledThemesDirectory
    ) -> [ThemeInfo] {
        cacheLock.lock()
        catalogCount += 1
        cacheLock.unlock()
        var infos: [ThemeInfo] = []
        var index: [String: Int] = [:]
        // A user file with a bundled theme's name replaces its catalogue entry,
        // matching resolution order where the user directory wins.
        func add(_ info: ThemeInfo) {
            if let existing = index[info.name] {
                infos[existing] = info
            } else {
                index[info.name] = infos.count
                infos.append(info)
            }
        }

        for name in builtinNames {
            var diagnostics: [Diagnostic] = []
            let theme = resolve(name: name, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory, fallback: .defaultDark, visited: [], diagnostics: &diagnostics)
            add(ThemeInfo(name: name, displayName: theme.name, appearance: theme.appearance, isBuiltin: true))
        }

        if let bundledThemesDirectory {
            for info in bundledCatalog(bundledThemesDirectory) {
                add(info)
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(at: themesDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "toml" {
                let name = file.deletingPathExtension().lastPathComponent
                guard !builtinNames.contains(name) else { continue }
                add(themeInfo(at: file, name: name, isBuiltin: false))
            }
        }
        return infos.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Bundled resources never change while the app runs, so parsing their
    /// headers once keeps catalog lookups cheap with hundreds of themes.
    private static let bundledCatalogLock = NSLock()
    private static var bundledCatalogCache: [String: [ThemeInfo]] = [:]

    private static func bundledCatalog(_ directory: URL) -> [ThemeInfo] {
        let key = directory.standardizedFileURL.path
        bundledCatalogLock.lock()
        if let cached = bundledCatalogCache[key] {
            bundledCatalogLock.unlock()
            return cached
        }
        bundledCatalogLock.unlock()

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let infos = files.filter { $0.pathExtension == "toml" }
            .map { themeInfo(at: $0, name: $0.deletingPathExtension().lastPathComponent, isBuiltin: true) }

        bundledCatalogLock.lock()
        bundledCatalogCache[key] = infos
        bundledCatalogLock.unlock()
        return infos
    }

    private static func themeInfo(at file: URL, name: String, isBuiltin: Bool) -> ThemeInfo {
        var display = name
        var appearance = "dark"
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let table = try? TOMLTable(string: text) {
            display = table.str("name") ?? display
            appearance = table.str("appearance") ?? appearance
        }
        return ThemeInfo(name: name, displayName: display, appearance: appearance, isBuiltin: isBuiltin)
    }

    private static func resolve(
        name: String,
        themesDirectory: URL,
        bundledThemesDirectory: URL?,
        fallback: Theme,
        visited: Set<String>,
        diagnostics: inout [Diagnostic]
    ) -> Theme {
        guard !visited.contains(name) else {
            diagnostics.append(Diagnostic(.error, "Theme inheritance cycle at '\(name)'; using fallback.", source: "theme"))
            return fallback
        }
        var visited = visited
        visited.insert(name)

        if name == "default-dark" { return .defaultDark }
        if name == "default-light" { return .defaultLight }

        if let source = builtinSource(name) {
            return parseSource(source, name: name, base: name.contains("latte") ? .defaultLight : .defaultDark, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory, visited: visited, diagnostics: &diagnostics, fallback: fallback)
        }

        let file = themesDirectory.appendingPathComponent(name).appendingPathExtension("toml")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            return parseSource(text, name: name, base: fallback, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory, visited: visited, diagnostics: &diagnostics, fallback: fallback)
        }
        if let bundledThemesDirectory {
            let bundled = bundledThemesDirectory.appendingPathComponent(name).appendingPathExtension("toml")
            if let text = try? String(contentsOf: bundled, encoding: .utf8) {
                return parseSource(text, name: name, base: .defaultDark, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory, useAppearanceBase: true, visited: visited, diagnostics: &diagnostics, fallback: fallback)
            }
        }
        diagnostics.append(Diagnostic(.warning, "Theme '\(name)' not found; using fallback.", source: "theme"))
        return fallback
    }

    private static func parseSource(
        _ text: String,
        name: String,
        base: Theme,
        themesDirectory: URL,
        bundledThemesDirectory: URL?,
        useAppearanceBase: Bool = false,
        visited: Set<String>,
        diagnostics: inout [Diagnostic],
        fallback: Theme
    ) -> Theme {
        guard let table = try? TOMLTable(string: text) else {
            diagnostics.append(Diagnostic(.error, "Theme '\(name)' is not valid TOML; using fallback.", source: "theme"))
            return fallback
        }

        var resolvedBase = base
        if let parent = table.str("extends"), !parent.isEmpty, parent != name {
            resolvedBase = resolve(name: parent, themesDirectory: themesDirectory, bundledThemesDirectory: bundledThemesDirectory, fallback: base, visited: visited, diagnostics: &diagnostics)
        } else if useAppearanceBase {
            // Ported terminal themes declare their own appearance and inherit
            // the matching Palette defaults instead of the caller's fallback.
            resolvedBase = table.str("appearance")?.lowercased() == "light" ? .defaultLight : .defaultDark
        }

        return parse(table, name: name, base: resolvedBase, diagnostics: &diagnostics)
    }

    public static func parse(_ table: TOMLTable, name: String, base: Theme, diagnostics: inout [Diagnostic]) -> Theme {
        var theme = base
        theme.name = table.str("name") ?? name
        if let appearance = table.str("appearance") {
            theme.appearance = appearance.lowercased()
        }

        if let paletteTable = table.table("palette") {
            applyColor(&theme.palette.bg, paletteTable, "bg", &diagnostics)
            applyColor(&theme.palette.surface, paletteTable, "surface", &diagnostics)
            applyColor(&theme.palette.elevated, paletteTable, "elevated", &diagnostics)
            applyColor(&theme.palette.fg, paletteTable, "fg", &diagnostics)
            applyColor(&theme.palette.fgMuted, paletteTable, "fg_muted", &diagnostics)
            applyColor(&theme.palette.accent, paletteTable, "accent", &diagnostics)
            applyColor(&theme.palette.accentFg, paletteTable, "accent_fg", &diagnostics)
            applyColor(&theme.palette.selectionBg, paletteTable, "selection_bg", &diagnostics)
            applyColor(&theme.palette.selectionFg, paletteTable, "selection_fg", &diagnostics)
            applyColor(&theme.palette.matchFg, paletteTable, "match_fg", &diagnostics)
            applyColor(&theme.palette.border, paletteTable, "border", &diagnostics)
            applyColor(&theme.palette.separator, paletteTable, "separator", &diagnostics)
            applyColor(&theme.palette.danger, paletteTable, "danger", &diagnostics)
            applyColor(&theme.palette.warning, paletteTable, "warning", &diagnostics)
            applyColor(&theme.palette.success, paletteTable, "success", &diagnostics)
            applyColor(&theme.palette.info, paletteTable, "info", &diagnostics)
            applyColor(&theme.palette.badgeBg, paletteTable, "badge_bg", &diagnostics)
            applyColor(&theme.palette.badgeFg, paletteTable, "badge_fg", &diagnostics)
        }

        if let window = table.table("window") {
            theme.window.anchor = window.str("anchor") ?? theme.window.anchor
            if let offset = window.str("offset_y"), offset.hasSuffix("%") {
                theme.window.offsetY = Double(offset.dropLast()) ?? theme.window.offsetY
                theme.window.offsetYPercent = true
            } else if let offset = window.number("offset_y") ?? window.int("offset_y").map(Double.init) {
                theme.window.offsetY = offset
                theme.window.offsetYPercent = false
            }
            theme.window.cornerRadius = window.number("corner_radius") ?? theme.window.cornerRadius
            theme.window.material = window.str("material") ?? theme.window.material
            theme.window.opacity = window.number("opacity") ?? theme.window.opacity
            theme.window.borderWidth = window.number("border_width") ?? theme.window.borderWidth
            theme.window.shadow = window.bool("shadow") ?? theme.window.shadow
            theme.window.glass = window.bool("glass") ?? theme.window.glass
            if let value = window.number("glass_opacity") {
                theme.window.glassOpacity = min(1, max(0, value))
            }
        }

        if let search = table.table("search") {
            theme.search.height = search.number("height") ?? theme.search.height
            theme.search.placeholder = search.str("placeholder") ?? theme.search.placeholder
            theme.search.showIcon = search.bool("show_icon") ?? theme.search.showIcon
        }

        if let list = table.table("list") {
            theme.list.rowHeight = list.number("row_height") ?? theme.list.rowHeight
            theme.list.spacing = list.number("spacing") ?? theme.list.spacing
            theme.list.density = list.str("density") ?? theme.list.density
            theme.list.showIcons = list.bool("show_icons") ?? theme.list.showIcons
            theme.list.iconSize = list.number("icon_size") ?? theme.list.iconSize
            theme.list.iconStyle = list.str("icon_style") ?? theme.list.iconStyle
            theme.list.showSubtitles = list.bool("show_subtitles") ?? theme.list.showSubtitles
            theme.list.selection = list.str("selection") ?? theme.list.selection
            theme.list.columns = max(1, list.int("columns") ?? theme.list.columns)
            theme.list.showScrollbar = list.bool("show_scrollbar") ?? theme.list.showScrollbar
        }

        if let typography = table.table("typography") {
            theme.typography.family = typography.str("family") ?? theme.typography.family
            theme.typography.size = typography.number("size") ?? theme.typography.size
            theme.typography.subtitleSize = typography.number("subtitle_size") ?? theme.typography.subtitleSize
            theme.typography.mono = typography.str("mono") ?? theme.typography.mono
            theme.typography.monoSize = typography.number("mono_size") ?? theme.typography.monoSize
            if let previewSize = typography.number("preview_size"), previewSize > 0 {
                theme.typography.previewSize = min(24, max(9, previewSize))
            }
            theme.typography.matchWeight = typography.str("match_weight") ?? theme.typography.matchWeight
        }

        if let states = table.table("states") {
            parseState(states.table("selected"), into: &theme.states.selected, diagnostics: &diagnostics)
            parseState(states.table("hover"), into: &theme.states.hover, diagnostics: &diagnostics)
            parseState(states.table("disabled"), into: &theme.states.disabled, diagnostics: &diagnostics)
        }

        if let motion = table.table("motion") {
            theme.motion.durationMs = motion.number("duration_ms") ?? theme.motion.durationMs
            theme.motion.style = motion.str("style") ?? theme.motion.style
        }

        if let footer = table.table("footer") {
            theme.footer.show = footer.bool("show") ?? theme.footer.show
            if footer.str("hint_color") != nil {
                var value = theme.footer.hintColor
                applyColor(&value, footer, "hint_color", &diagnostics)
                theme.footer.hintColor = value
            }
        }

        // Derived values.
        if table.table("palette")?.str("selection_fg") == nil {
            theme.palette.selectionFg = theme.palette.fg
        }
        if table.table("palette")?.str("accent_fg") == nil {
            if let accent = RGBA(hex: theme.palette.accent) {
                // Contrast, not a luminance guess: mid-tone accents need dark text.
                theme.palette.accentFg = accent.contrast(with: RGBA(red: 1, green: 1, blue: 1))
                    > accent.contrast(with: RGBA(red: 17.0 / 255, green: 17.0 / 255, blue: 17.0 / 255))
                    ? "#ffffff"
                    : "#111111"
            }
        }

        return theme
    }

    private static func parseState(_ table: TOMLTable?, into state: inout ThemeState, diagnostics: inout [Diagnostic]) {
        guard let table else { return }
        if let bg = table.str("bg") {
            if RGBA(hex: bg) != nil {
                state.bg = bg
            } else {
                diagnostics.append(Diagnostic(.warning, "Invalid color '\(bg)' for states bg.", source: "theme"))
            }
        }
        if let fg = table.str("fg") {
            if RGBA(hex: fg) != nil {
                state.fg = fg
            } else {
                diagnostics.append(Diagnostic(.warning, "Invalid color '\(fg)' for states fg.", source: "theme"))
            }
        }
    }

    private static func applyColor(_ target: inout String, _ table: TOMLTable, _ key: String, _ diagnostics: inout [Diagnostic]) {
        guard let raw = table.str(key) else { return }
        if RGBA(hex: raw) == nil {
            diagnostics.append(Diagnostic(.warning, "Invalid color '\(raw)' for \(key); keeping \(target).", source: "theme"))
            return
        }
        target = raw
    }

    private static func validate(_ theme: Theme, diagnostics: inout [Diagnostic]) {
        func check(_ value: String, on backdrop: String, minimum: Double, _ label: String) {
            guard let backdrop = RGBA(hex: backdrop), let color = RGBA(hex: value) else { return }
            // A background mid-way between black and white cannot meet every
            // bar; the bar is capped instead of warning forever.
            let target = min(minimum, ThemeContrastRepair.maximumContrast(on: backdrop))
            let actual = color.contrast(with: backdrop)
            if actual < target - 0.000_001 {
                diagnostics.append(Diagnostic(
                    .warning,
                    "Theme '\(theme.name)' has low \(label) contrast (\(ratio(actual)):1, needs \(ratio(target)):1).",
                    source: "theme"
                ))
            }
        }

        let bg = theme.palette.bg
        check(theme.palette.fg, on: bg, minimum: ThemeContrastThresholds.body, "body text")
        check(theme.palette.fgMuted, on: bg, minimum: ThemeContrastThresholds.muted, "muted text")
        check(theme.palette.fgMuted, on: theme.palette.surface, minimum: ThemeContrastThresholds.muted, "muted text on surface")
        check(theme.footer.hintColor, on: theme.palette.surface, minimum: ThemeContrastThresholds.muted, "footer text on surface")
        // Accent is repaired against bg, surface and elevated where one colour
        // can clear all three. The hard bar is the body background; a port with
        // opposite-side surfaces cannot satisfy both and is left at its best.
        check(theme.palette.accent, on: bg, minimum: ThemeContrastThresholds.accent, "accent")
        check(theme.palette.accentFg, on: theme.palette.accent, minimum: ThemeContrastThresholds.accentFg, "accent text")
        check(theme.palette.selectionFg, on: theme.palette.selectionBg, minimum: ThemeContrastThresholds.selection, "selection")
        check(theme.palette.badgeFg, on: theme.palette.badgeBg, minimum: ThemeContrastThresholds.badge, "badge")
        for (value, label) in [
            (theme.palette.danger, "danger"), (theme.palette.warning, "warning"),
            (theme.palette.success, "success"), (theme.palette.info, "info"),
        ] {
            check(value, on: bg, minimum: ThemeContrastThresholds.semantic, label)
        }
        if let selectedBg = theme.states.selected.bg, let selectedFg = theme.states.selected.fg {
            check(selectedFg, on: selectedBg, minimum: ThemeContrastThresholds.selectedRow, "selected-row")
        }
    }

    private static func builtinSource(_ name: String) -> String? {
        switch name {
        case "default-dark", "default-light":
            return nil
        case "catppuccin-mocha":
            return """
            name = "Catppuccin Mocha"
            appearance = "dark"
            extends = "default-dark"

            [palette]
            bg = "#1e1e2e"
            surface = "#181825"
            elevated = "#313244"
            fg = "#cdd6f4"
            fg_muted = "#a6adc8"
            accent = "#cba6f7"
            accent_fg = "#1e1e2e"
            selection_bg = "#45475a"
            selection_fg = "#cdd6f4"
            match_fg = "#f5c2e7"
            border = "#45475a"
            separator = "#31324480"
            danger = "#f38ba8"
            warning = "#f9e2af"
            success = "#a6e3a1"
            info = "#89b4fa"
            badge_bg = "#45475a"
            badge_fg = "#cdd6f4"

            [states.selected]
            bg = "#45475a"
            fg = "#cdd6f4"
            [states.hover]
            bg = "#313244"
            [states.disabled]
            fg = "#6c7086"
            """
        case "catppuccin-latte":
            return """
            name = "Catppuccin Latte"
            appearance = "light"
            extends = "default-light"

            [palette]
            bg = "#eff1f5"
            surface = "#e6e9ef"
            elevated = "#ffffff"
            fg = "#4c4f69"
            fg_muted = "#65687d"
            accent = "#8738ee"
            accent_fg = "#ffffff"
            selection_bg = "#ccd0da"
            selection_fg = "#4c4f69"
            match_fg = "#ea76cb"
            border = "#bcc0cc"
            separator = "#ccd0da80"
            danger = "#d20f39"
            warning = "#c67a00"
            success = "#3e9e29"
            info = "#1e66f5"
            badge_bg = "#ccd0da"
            badge_fg = "#4c4f69"

            [states.selected]
            bg = "#ccd0da"
            fg = "#4c4f69"
            [states.hover]
            bg = "#e6e9ef"
            [states.disabled]
            fg = "#9ca0b0"
            [window]
            material = "popover"
            """
        case "gruvbox-dark":
            return """
            name = "Gruvbox Dark"
            appearance = "dark"
            extends = "default-dark"

            [palette]
            bg = "#282828"
            surface = "#1d2021"
            elevated = "#3c3836"
            fg = "#ebdbb2"
            fg_muted = "#a89984"
            accent = "#fabd2f"
            accent_fg = "#282828"
            selection_bg = "#504945"
            selection_fg = "#fbf1c7"
            match_fg = "#fe8019"
            border = "#504945"
            separator = "#3c383680"
            danger = "#fb4934"
            warning = "#fabd2f"
            success = "#b8bb26"
            info = "#83a598"
            badge_bg = "#504945"
            badge_fg = "#ebdbb2"

            [states.selected]
            bg = "#504945"
            fg = "#fbf1c7"
            [states.hover]
            bg = "#3c3836"
            [states.disabled]
            fg = "#665c54"
            """
        case "gruvbox-light":
            return """
            name = "Gruvbox Light"
            appearance = "light"
            extends = "default-light"

            [palette]
            bg = "#fbf1c7"
            surface = "#f2e5bc"
            elevated = "#fff7d6"
            fg = "#3c3836"
            fg_muted = "#71645b"
            accent = "#905b00"
            accent_fg = "#fbf1c7"
            selection_bg = "#d5c4a1"
            selection_fg = "#3c3836"
            match_fg = "#af3a03"
            border = "#bdae93"
            separator = "#d5c4a180"
            danger = "#9d0006"
            warning = "#b57614"
            success = "#79740e"
            info = "#076678"
            badge_bg = "#d5c4a1"
            badge_fg = "#3c3836"

            [states.selected]
            bg = "#d5c4a1"
            fg = "#3c3836"
            [states.hover]
            bg = "#ebdbb2"
            [states.disabled]
            fg = "#a89984"
            [window]
            material = "popover"
            """
        case "aetheria-pink":
            return """
            name = "Aetheria Pink"
            appearance = "dark"
            extends = "default-dark"

            [palette]
            bg = "#1b1018"
            surface = "#231820"
            elevated = "#33262f"
            fg = "#f2dde8"
            fg_muted = "#dabfd0"
            accent = "#ffacea"
            accent_fg = "#5d0055"
            selection_bg = "#ec4dd7"
            selection_fg = "#2c0027"
            match_fg = "#ffb2b7"
            border = "#a28a99"
            separator = "#54414e80"
            danger = "#ffb4ab"
            warning = "#ffb2b7"
            success = "#ffacea"
            info = "#ffb2b7"
            badge_bg = "#78296c"
            badge_fg = "#f898e2"

            [states.selected]
            bg = "#ec4dd7"
            fg = "#2c0027"
            [states.hover]
            bg = "#33262f"
            [states.disabled]
            fg = "#a28a99"
            """
        case "siri-silver":
            return """
            name = "Siri Silver"
            appearance = "light"
            extends = "default-light"

            [palette]
            bg = "#e9ebf0"
            surface = "#f5f6f9"
            elevated = "#ffffff"
            fg = "#1b1d23"
            fg_muted = "#5b6170"
            accent = "#435fdb"
            accent_fg = "#ffffff"
            selection_bg = "#d6dae3"
            selection_fg = "#14161b"
            match_fg = "#7a5cff"
            border = "#c3c8d2"
            separator = "#bfc4ce80"
            danger = "#cb6885"
            warning = "#9a8555"
            success = "#5b9457"
            info = "#5f88ca"
            badge_bg = "#d6dae3"
            badge_fg = "#2a2d34"

            [states.selected]
            bg = "#d6dae3"
            fg = "#14161b"
            [states.hover]
            bg = "#eef0f4"
            [states.disabled]
            fg = "#9aa0ab"

            [window]
            glass = true
            glass_opacity = 0.72

            [footer]
            hint_color = "#5b6170"
            """
        case "siri-graphite":
            return """
            name = "Siri Graphite"
            appearance = "dark"
            extends = "default-dark"

            [palette]
            bg = "#24262d"
            surface = "#2b2e36"
            elevated = "#333743"
            fg = "#e7e9ee"
            fg_muted = "#a3a8b3"
            accent = "#7c9cff"
            accent_fg = "#0d0f14"
            selection_bg = "#3a3f4a"
            selection_fg = "#f0f2f6"
            match_fg = "#9db4ff"
            border = "#464b57"
            separator = "#3a3f4a80"
            badge_bg = "#464b57"
            badge_fg = "#e7e9ee"

            [states.selected]
            bg = "#3a3f4a"
            fg = "#f0f2f6"
            [states.hover]
            bg = "#2b2e36"
            [states.disabled]
            fg = "#767c88"

            [window]
            glass = true
            glass_opacity = 0.7

            [footer]
            hint_color = "#a3a8b3"
            """
        default:
            return nil
        }
    }
}
