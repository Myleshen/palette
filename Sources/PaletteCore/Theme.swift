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
    public var maxHeight: Double = 480
    public var anchor = "top"
    public var offsetY: Double = 120
    public var offsetYPercent = false
    public var cornerRadius: Double = 14
    public var material = "hudWindow"
    public var opacity: Double = 0.98
    public var borderWidth: Double = 1
    public var shadow = true
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
    public init() {}
}

public struct ThemeTypography: Equatable, Sendable {
    public var family = "SF Pro Text"
    public var size: Double = 14
    public var subtitleSize: Double = 12
    public var mono = "JetBrains Mono"
    public var monoSize: Double = 12
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
        theme.states.selected = ThemeState(bg: "#e4e4e7", fg: "#18181b")
        theme.states.hover = ThemeState(bg: "#f4f4f5")
        theme.states.disabled = ThemeState(fg: "#a1a1aa")
        theme.footer.hintColor = "#52525b"
        theme.window.material = "popover"
        return theme
    }()
}

public struct ThemeLoadResult {
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
        "gruvbox-dark", "gruvbox-light", "aetheria-pink",
    ]

    public static func load(
        name: String,
        themesDirectory: URL,
        fallback: Theme = .defaultDark
    ) -> ThemeLoadResult {
        var diagnostics: [Diagnostic] = []
        let theme = resolve(name: name, themesDirectory: themesDirectory, fallback: fallback, visited: [], diagnostics: &diagnostics)
        validate(theme, diagnostics: &diagnostics)
        return ThemeLoadResult(theme: theme, diagnostics: diagnostics)
    }

    public static func catalog(themesDirectory: URL) -> [ThemeInfo] {
        var infos: [ThemeInfo] = []
        for name in builtinNames {
            let appearance = name.contains("light") || name.contains("latte") ? "light" : "dark"
            let display = name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
            infos.append(ThemeInfo(name: name, displayName: display, appearance: appearance, isBuiltin: true))
        }

        guard let files = try? FileManager.default.contentsOfDirectory(at: themesDirectory, includingPropertiesForKeys: nil) else {
            return infos
        }
        for file in files where file.pathExtension == "toml" {
            let name = file.deletingPathExtension().lastPathComponent
            guard !builtinNames.contains(name) else { continue }
            var display = name
            var appearance = "dark"
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let table = try? TOMLTable(string: text) {
                display = table.str("name") ?? display
                appearance = table.str("appearance") ?? appearance
            }
            infos.append(ThemeInfo(name: name, displayName: display, appearance: appearance, isBuiltin: false))
        }
        return infos.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func resolve(
        name: String,
        themesDirectory: URL,
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
            return parseSource(source, name: name, base: name.contains("latte") ? .defaultLight : .defaultDark, themesDirectory: themesDirectory, visited: visited, diagnostics: &diagnostics, fallback: fallback)
        }

        let file = themesDirectory.appendingPathComponent(name).appendingPathExtension("toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            diagnostics.append(Diagnostic(.warning, "Theme '\(name)' not found; using fallback.", source: "theme"))
            return fallback
        }
        return parseSource(text, name: name, base: fallback, themesDirectory: themesDirectory, visited: visited, diagnostics: &diagnostics, fallback: fallback)
    }

    private static func parseSource(
        _ text: String,
        name: String,
        base: Theme,
        themesDirectory: URL,
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
            resolvedBase = resolve(name: parent, themesDirectory: themesDirectory, fallback: base, visited: visited, diagnostics: &diagnostics)
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
            theme.window.width = window.number("width") ?? theme.window.width
            theme.window.maxHeight = window.number("max_height") ?? theme.window.maxHeight
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
                theme.palette.accentFg = accent.luminance > 0.5 ? "#111111" : "#ffffff"
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
        guard let background = RGBA(hex: theme.palette.bg),
              let foreground = RGBA(hex: theme.palette.fg) else { return }
        if background.contrast(with: foreground) < 4.5 {
            diagnostics.append(Diagnostic(.warning, "Theme '\(theme.name)' has low body text contrast.", source: "theme"))
        }
        if let selectionBg = RGBA(hex: theme.palette.selectionBg),
           let selectionFg = RGBA(hex: theme.palette.selectionFg),
           selectionBg.contrast(with: selectionFg) < 4.5 {
            diagnostics.append(Diagnostic(.warning, "Theme '\(theme.name)' has low selection contrast.", source: "theme"))
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
            fg_muted = "#6c6f85"
            accent = "#8839ef"
            accent_fg = "#ffffff"
            selection_bg = "#ccd0da"
            selection_fg = "#4c4f69"
            match_fg = "#ea76cb"
            border = "#bcc0cc"
            separator = "#ccd0da80"
            danger = "#d20f39"
            warning = "#df8e1d"
            success = "#40a02b"
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
            fg_muted = "#7c6f64"
            accent = "#b57614"
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
        default:
            return nil
        }
    }
}
