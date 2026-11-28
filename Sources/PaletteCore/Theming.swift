import AppKit
import CryptoKit
import Foundation
import TOMLKit

// MARK: - Config

public enum ThemingSource: String, Sendable, Equatable, CaseIterable {
    case theme
    case wallpaper
}

/// Which controls the palette-source toggle leaves live. One place so the
/// greyed rows in Settings and the tests agree; a source that is off must be
/// disabled, not merely hidden, or a stale click could still apply it.
public struct ThemingSourceControls: Sendable, Equatable {
    public var themeEnabled: Bool
    public var wallpaperEnabled: Bool
    public var themeDisabledReason: String?
    public var wallpaperDisabledReason: String?

    public init(source: ThemingSource) {
        themeEnabled = source == .theme
        wallpaperEnabled = source == .wallpaper
        themeDisabledReason = themeEnabled
            ? nil
            : "Wallpaper drives the palette — switch source to pick a theme."
        wallpaperDisabledReason = wallpaperEnabled
            ? nil
            : "Theme drives the palette — switch source to follow the wallpaper."
    }
}

public enum ThemingTransparency: String, Sendable, Equatable, CaseIterable {
    case auto
    case on
    case off
}

/// `[theming]` drives the cross-app palette files under
/// `~/.config/palette/theme/`. `follow_wallpaper` only means anything when the
/// source is the wallpaper.
public struct ThemingConfig: Sendable, Equatable {
    public var enabled: Bool
    public var source: ThemingSource
    /// Empty means the theme Palette is currently showing.
    public var theme: String
    public var followWallpaper: Bool
    public var targets: [String]
    /// auto | dark | light. `auto` follows the system appearance.
    public var darkMode: String
    /// Pictures the theme cards' leading wallpaper group is built from.
    public var wallpaperDirectory: String
    /// Wallpaper extraction algorithm. Only pywal's pipeline ships: 16 sampled
    /// colours, adjusted and ordered the way pywal writes `colors.json`.
    public var extraction: String
    /// pywal `--saturate`: -1...1, 0 leaves colours alone.
    public var saturation: Double
    /// pywal `--contrast`: 1...21, 0 disables. 1.5–4.5 is the useful range.
    public var contrast: Double
    /// Keep terminal/Neovide translucency: `auto` detects it, `on` and `off`
    /// force it.
    public var transparent: ThemingTransparency

    public init(
        enabled: Bool = false,
        source: ThemingSource = .theme,
        theme: String = "",
        followWallpaper: Bool = false,
        targets: [String] = ThemingTarget.phaseOne.map(\.rawValue),
        darkMode: String = "auto",
        wallpaperDirectory: String = WallpaperLibrary.defaultDirectory,
        extraction: String = ThemingConfig.pywal,
        saturation: Double = 0,
        contrast: Double = 0,
        transparent: ThemingTransparency = .auto
    ) {
        self.enabled = enabled
        self.source = source
        self.theme = theme
        self.followWallpaper = followWallpaper
        self.targets = targets
        self.darkMode = darkMode
        self.wallpaperDirectory = wallpaperDirectory
        self.extraction = extraction
        self.saturation = saturation
        self.contrast = contrast
        self.transparent = transparent
    }

    public static let pywal = "pywal"

    public static let defaults = ThemingConfig()

    public func normalized() -> ThemingConfig {
        var value = self
        let known = Set(ThemingTarget.allCases.map(\.rawValue))
        var seen = Set<String>()
        value.targets = targets.filter { known.contains($0) && seen.insert($0).inserted }
        if !["auto", "dark", "light"].contains(value.darkMode) {
            value.darkMode = "auto"
        }
        // An empty wallpaper folder is a valid answer: the theme cards show the
        // desktop card only. Returning a missing default here silently hid the
        // user's choice.
        value.wallpaperDirectory = value.wallpaperDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.extraction.lowercased() != ThemingConfig.pywal {
            value.extraction = ThemingConfig.pywal
        }
        value.saturation = min(1, max(-1, value.saturation))
        if value.contrast != 0 && !(1...21).contains(value.contrast) {
            value.contrast = 0
        }
        return value
    }
    public static func parse(_ table: TOMLTable) -> ThemingConfig {
        var config = ThemingConfig()
        config.enabled = table.bool("enabled") ?? config.enabled
        if let raw = table.str("source")?.lowercased(), let source = ThemingSource(rawValue: raw) {
            config.source = source
        }
        config.theme = table.str("theme") ?? config.theme
        config.followWallpaper = table.bool("follow_wallpaper") ?? config.followWallpaper
        if let targets = table.strArray("targets") {
            config.targets = targets
        }
        config.darkMode = (table.str("dark_mode") ?? config.darkMode).lowercased()
        config.wallpaperDirectory = table.str("wallpaper_directory") ?? config.wallpaperDirectory
        config.extraction = table.str("extraction") ?? config.extraction
        config.saturation = table.number("saturation") ?? config.saturation
        config.contrast = table.number("contrast") ?? config.contrast
        if let raw = table.str("transparent")?.lowercased(),
           let transparent = ThemingTransparency(rawValue: raw) {
            config.transparent = transparent
        }
        return config.normalized()
    }

    /// Written back by `ConfigWriter.render`, comments included so hand-editing
    /// the file is self-explanatory.
    public func render() -> String {
        let value = normalized()
        var out: [String] = []
        out.append("[theming]")
        out.append("# One palette for the terminal and editor files listed in targets.")
        out.append("# source = \"theme\" follows the theme picker; \"wallpaper\" samples the desktop.")
        out.append("enabled = \(value.enabled)")
        out.append("source = \"\(value.source.rawValue)\"")
        out.append("theme = \(ThemingConfig.quote(value.theme))")
        out.append("# Only with source = \"wallpaper\": re-apply when the desktop image changes.")
        // A leftover true on a theme source would make the next load look like
        // wallpaper following is on; the setting only means anything for
        // source = "wallpaper".
        out.append("follow_wallpaper = \(value.source == .wallpaper ? value.followWallpaper : false)")
        out.append("# auto | dark | light")
        out.append("dark_mode = \"\(value.darkMode)\"")
        out.append("# Pictures the theme cards' Wallpapers group is built from.")
        out.append("wallpaper_directory = \(ThemingConfig.quote(value.wallpaperDirectory))")
        out.append("# Wallpaper colours use pywal's 16-colour pipeline.")
        out.append("extraction = \"\(value.extraction)\"")
        out.append("# pywal --saturate: -1.0...1.0 adds saturation, 0 leaves colours alone.")
        out.append("saturation = \(value.saturation)")
        out.append("# pywal --contrast: 0 disables; 1.5...4.5 guarantees readable ANSI colours.")
        out.append("contrast = \(value.contrast)")
        out.append("# auto keeps terminal/Neovide transparency; on | off force the nvim background.")
        out.append("transparent = \"\(value.transparent.rawValue)\"")
        out.append("targets = [\(value.targets.map(ThemingConfig.quote).joined(separator: ", "))]")
        return out.joined(separator: "\n")
    }

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Values a hand-edited file got wrong. `parse` has to keep going with
    /// safe defaults, but silently dropping a typo made the config look like it
    /// applied. Reported once at load.
    public static func diagnostics(for table: TOMLTable) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        if let targets = table.strArray("targets") {
            let known = Set(ThemingTarget.allCases.map(\.rawValue))
            for id in targets where !known.contains(id) {
                diagnostics.append(Diagnostic(
                    .warning,
                    "Unknown theming target '\(id)'; ignored.",
                    source: "config"
                ))
            }
        }
        if let raw = table.str("dark_mode"),
           !["auto", "dark", "light"].contains(raw.lowercased()) {
            diagnostics.append(Diagnostic(
                .warning,
                "Unknown theming dark_mode '\(raw)'; using auto.",
                source: "config"
            ))
        }
        if let raw = table.str("extraction"), raw.lowercased() != ThemingConfig.pywal {
            diagnostics.append(Diagnostic(
                .warning,
                "Unknown theming extraction '\(raw)'; using pywal.",
                source: "config"
            ))
        }
        if let raw = table.str("transparent"),
           ThemingTransparency(rawValue: raw.lowercased()) == nil {
            diagnostics.append(Diagnostic(
                .warning,
                "Unknown theming transparent '\(raw)'; using auto.",
                source: "config"
            ))
        }
        if let value = table.number("saturation"),
           !(value == 0 || (-1...1).contains(value)) {
            diagnostics.append(Diagnostic(
                .warning,
                "theming saturation \(value) is outside -1...1; using 0.",
                source: "config"
            ))
        }
        if let value = table.number("contrast"),
           value != 0, !(1...21).contains(value) {
            diagnostics.append(Diagnostic(
                .warning,
                "theming contrast \(value) is outside 1...21; using 0.",
                source: "config"
            ))
        }
        return diagnostics
    }
}

public extension ThemingConfig {
    /// Older builds saved the theme picker's display name, which
    /// `ThemeLoader.load` cannot find. Rewrite it to the catalogue id, falling
    /// back to the caller's current theme so Apply cannot silently write
    /// Default Dark.
    func resolvingThemeID(fallback: String, themesDirectory: URL) -> ThemingConfig {
        var value = self
        guard !value.theme.isEmpty else { return value }
        value.theme = ThemeLoader.themeID(for: value.theme, themesDirectory: themesDirectory)
            ?? ThemeLoader.themeID(for: fallback, themesDirectory: themesDirectory)
            ?? (fallback.isEmpty ? value.theme : fallback)
        return value
    }
}

// MARK: - Targets

public enum ThemingTarget: String, CaseIterable, Sendable, Equatable, Identifiable {
    case kitty
    case ghostty
    case zellij
    case nvim
    case fish
    case starship
    case bat
    case delta
    case btop
    case yazi
    case helium
    case chrome
    case edge
    case brave
    case vivaldi
    case chromium
    case arc
    case vscode
    case zed

    public var id: String { rawValue }

    public static let phaseOne: [ThemingTarget] = [.kitty, .ghostty, .zellij, .nvim, .fish, .starship]

    /// Manual targets: Palette writes and links a theme file, but the app's own
    /// config is never edited. The user points the app at the file once.
    public var isManual: Bool { self == .btop || self == .yazi }

    public var browser: ChromiumBrowser? { ChromiumBrowser.browser(for: self) }
    public var isBrowser: Bool { browser != nil }

    public var title: String {
        if let browser { return browser.targetTitle }
        switch self {
        case .kitty: return "kitty"
        case .ghostty: return "Ghostty"
        case .zellij: return "zellij"
        case .nvim: return "Neovim"
        case .fish: return "fish"
        case .starship: return "Starship"
        case .bat: return "bat"
        case .delta: return "delta"
        case .btop: return "btop"
        case .yazi: return "yazi"
        case .vscode: return "VS Code"
        case .zed: return "Zed"
        default: return rawValue
        }
    }

    public var fileName: String {
        if let browser { return browser.mobileConfigFileName }
        switch self {
        case .kitty: return "kitty.conf"
        case .ghostty: return "ghostty.conf"
        case .zellij: return "zellij.kdl"
        case .nvim: return "nvim.lua"
        case .fish: return "fish.fish"
        case .starship: return StarshipTheme.fileName
        case .bat: return "bat.tmTheme"
        case .delta: return "gitconfig-delta"
        case .btop: return "btop.theme"
        case .yazi: return "yazi.toml"
        case .vscode: return "vscode.json"
        case .zed: return "zed.json"
        default: return "\(rawValue).txt"
        }
    }

    public var isImplemented: Bool {
        if let browser { return browser.supportsThemePolicy }
        switch self {
        case .kitty, .ghostty, .zellij, .nvim, .fish, .starship, .bat, .delta, .btop, .yazi:
            return true
        case .vscode, .zed:
            return false
        default:
            return false
        }
    }

    /// Why a target cannot be generated, or nil when it can.
    public var unavailableReason: String? {
        if self == .arc { return "Unsupported — Arc does not implement BrowserThemeColor." }
        switch self {
        case .vscode: return "Not yet — VS Code needs a settings merge."
        case .zed: return "Not yet — Zed theme install is not wired."
        default: return nil
        }
    }

    public var statusLabel: String {
        if isBrowser, isImplemented { return "Managed policy" }
        return unavailableReason ?? "Ready"
    }

    /// What the app's own config needs to read the generated file. Zellij,
    /// Starship and Neovim have no include directive, so the hint says what to
    /// do instead of inventing syntax.
    public var includeHint: String {
        if let browser {
            return "No include line — managed policy \(browser.policyIdentifier)"
        }
        switch self {
        case .kitty:
            return "include ~/.config/palette/theme/kitty.conf"
        case .ghostty:
            return "config-file = ~/.config/palette/theme/ghostty.conf"
        case .zellij:
            return "Paste the theme block from ~/.config/palette/theme/zellij.kdl into ~/.config/zellij/config.kdl"
        case .nvim:
            return "dofile(vim.fn.expand(\"~/.config/palette/theme/nvim.lua\")) — also covers Neovide"
        case .fish:
            return "source ~/.config/palette/theme/fish.fish"
        case .starship:
            // Palette writes a colour-remapped copy and points Starship at it
            // through STARSHIP_CONFIG, so the user's starship.toml is never
            // edited. Fish gets this automatically; other shells set it.
            return "export STARSHIP_CONFIG=~/.config/palette/theme/starship-theme.toml (Palette does this in fish)"
        case .bat:
            return "Symlink ~/.config/palette/theme/bat.tmTheme into $(bat --config-dir)/themes/, set BAT_THEME=\"palette\" (Palette links it and runs bat cache --build)"
        case .delta:
            return "[include]\n    path = ~/.config/palette/theme/gitconfig-delta"
        case .btop:
            return "Palette links ~/.config/palette/theme/btop.theme into ~/.config/btop/themes/palette.theme; set color_theme = \"palette\" in ~/.config/btop/btop.conf once"
        case .yazi:
            return "Merge ~/.config/palette/theme/yazi.toml into ~/.config/yazi/theme.toml (copy it only if you have no theme.toml; never overwrite an existing one)"
        case .vscode, .zed:
            return unavailableReason ?? "Not configured yet."
        default:
            return unavailableReason ?? "Not configured yet."
        }
    }

    /// Exactly what Palette installs for the target, so the footer and the
    /// rows cannot describe the same target differently.
    public enum InstallKind: String, Sendable, Equatable {
        case markerBlock = "marker block"
        case policy = "managed policy"
        case generated = "generated copy"
        case manual = "manual"
    }

    public var installKind: InstallKind {
        if isBrowser { return .policy }
        switch self {
        case .starship: return .generated
        case .btop, .yazi, .vscode, .zed: return .manual
        default: return .markerBlock
        }
    }
}

// MARK: - Palette

public struct PalettePalette: Equatable, Sendable {
    public var name: String
    public var appearance: String
    public var background: String
    public var foreground: String
    public var cursor: String
    public var cursorText: String
    public var selectionBackground: String
    public var selectionForeground: String
    public var surface: String
    public var elevated: String
    public var border: String
    public var muted: String
    /// Exactly 16 entries, ANSI 0...15.
    public var ansi: [String]

    public init(
        name: String,
        appearance: String,
        background: String,
        foreground: String,
        cursor: String,
        cursorText: String,
        selectionBackground: String,
        selectionForeground: String,
        surface: String,
        elevated: String,
        border: String,
        muted: String,
        ansi: [String]
    ) {
        self.name = name
        self.appearance = appearance
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.surface = surface
        self.elevated = elevated
        self.border = border
        self.muted = muted
        self.ansi = Self.sixteen(ansi)
    }

    public init(theme: Theme) {
        let background = RGBA(hex: theme.palette.bg) ?? RGBA(red: 0.12, green: 0.12, blue: 0.15)
        let foreground = RGBA(hex: theme.palette.fg) ?? RGBA(red: 0.86, green: 0.88, blue: 0.92)
        let accent = RGBA(hex: theme.palette.accent) ?? foreground
        let accentFg = RGBA(hex: theme.palette.accentFg) ?? PalettePalette.bestText(on: accent)
        let danger = RGBA(hex: theme.palette.danger) ?? RGBA(red: 0.85, green: 0.35, blue: 0.38)
        let warning = RGBA(hex: theme.palette.warning) ?? RGBA(red: 0.87, green: 0.75, blue: 0.40)
        let success = RGBA(hex: theme.palette.success) ?? RGBA(red: 0.45, green: 0.76, blue: 0.52)
        let info = RGBA(hex: theme.palette.info) ?? RGBA(red: 0.40, green: 0.62, blue: 0.95)
        let cyan = success.mixed(with: info, amount: 0.5)
        let selectionBg = RGBA(hex: theme.palette.selectionBg) ?? RGBA(hex: theme.palette.elevated) ?? background
        let selectionFg = RGBA(hex: theme.palette.selectionFg) ?? foreground
        let muted = RGBA(hex: theme.palette.fgMuted) ?? foreground.mixed(with: background, amount: 0.35)

        let base = PalettePalette.ansi(
            background: background,
            foreground: foreground,
            appearance: theme.appearance,
            colors: [danger, success, warning, info, accent, cyan]
        )
        self.init(
            name: theme.name,
            appearance: theme.appearance,
            background: PalettePalette.hex(background),
            foreground: PalettePalette.hex(foreground),
            cursor: PalettePalette.hex(accent),
            cursorText: PalettePalette.hex(accentFg),
            selectionBackground: PalettePalette.hex(selectionBg),
            selectionForeground: PalettePalette.hex(selectionFg),
            surface: theme.palette.surface,
            elevated: theme.palette.elevated,
            border: theme.palette.border,
            muted: PalettePalette.hex(muted),
            ansi: base
        )
    }

    public static func from(theme: Theme) -> PalettePalette { PalettePalette(theme: theme) }

    /// Dark or light appearance resolved from the config and the system.
    public static func appearance(darkMode: String, systemIsDark: Bool = {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }()) -> String {
        switch darkMode.lowercased() {
        case "dark": return "dark"
        case "light": return "light"
        default: return systemIsDark ? "dark" : "light"
        }
    }

    // MARK: Colour helpers

    public static func hex(_ color: RGBA) -> String {
        func channel(_ value: Double) -> Int {
            Int((min(1, max(0, value)) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", channel(color.red), channel(color.green), channel(color.blue))
    }

    public static func bestText(on background: RGBA) -> RGBA {
        let dark = RGBA(red: 17.0 / 255, green: 17.0 / 255, blue: 17.0 / 255)
        let light = RGBA(red: 1, green: 1, blue: 1)
        return light.contrast(with: background) >= dark.contrast(with: background) ? light : dark
    }

    public static func readable(_ color: RGBA, on background: RGBA, minimum: Double) -> RGBA {
        guard color.contrast(with: background) < minimum else { return color }
        let target = bestText(on: background)
        var value = color
        for _ in 0..<24 {
            value = value.mixed(with: target, amount: 0.14)
            if value.contrast(with: background) >= minimum { return value }
        }
        return target
    }

    /// The six semantic hues plus black/white and their bright half. Every hue
    /// is nudged until it can be read on the chosen background.
    static func ansi(
        background: RGBA,
        foreground: RGBA,
        appearance: String,
        colors: [RGBA]
    ) -> [String] {
        let hues = colors.map { readable($0, on: background, minimum: 3.0) }
        let bright = hues.map { $0.mixed(with: foreground, amount: 0.3) }
        let black = readable(background.mixed(with: foreground, amount: 0.12), on: background, minimum: 1.4)
        let brightBlack = readable(background.mixed(with: foreground, amount: 0.38), on: background, minimum: 1.7)
        let white = readable(foreground.mixed(with: background, amount: 0.14), on: background, minimum: 3)
        let brightWhite = readable(foreground, on: background, minimum: 4.5)
        var values = [black] + hues + [white, brightBlack] + bright + [brightWhite]
        values = values.enumerated().map { index, color in
            // Black slots are supposed to be dim; text slots must stay legible.
            index == 0 || index == 8 ? color : readable(color, on: background, minimum: 3.0)
        }
        return values.map(hex)
    }

    /// Wallpaper palettes come from pywal, which can return the same colour in
    /// two ANSI slots. The bright half repeats the base half in pywal, so a
    /// colliding bright slot is separated by lightness, keeping its hue. Other
    /// collisions rotate in OKLCH as before. A scheme that already separates is
    /// returned untouched, so pywal parity holds.
    static func distinctANSI(_ colors: [RGBA], background: RGBA) -> [RGBA] {
        guard colors.count >= 16 else { return colors }
        let slots = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
        var values = colors
        for _ in 0..<64 {
            guard let pair = firstANSICollision(values, slots: slots) else { return values }
            if pair.1 - pair.0 == 8,
               let adjusted = lightnessAway(
                values[pair.1],
                otherSlots: slots.filter { $0 != pair.1 }.map { values[$0] },
                background: background
               ) {
                values[pair.1] = adjusted
            } else if let adjusted = rotatedAway(
                values[pair.1],
                otherSlots: slots.filter { $0 != pair.1 }.map { values[$0] },
                background: background
            ) {
                values[pair.1] = adjusted
            } else if let adjusted = rotatedAway(
                values[pair.0],
                otherSlots: slots.filter { $0 != pair.0 }.map { values[$0] },
                background: background
            ) {
                values[pair.0] = adjusted
            } else {
                return values
            }
        }
        return values
    }

    private static func firstANSICollision(_ values: [RGBA], slots: [Int]) -> (Int, Int)? {
        for (offset, first) in slots.enumerated() {
            for second in slots[(offset + 1)...] where deltaE(values[first], values[second]) < 5 {
                return (first, second)
            }
        }
        return nil
    }

    /// Moves a bright slot away from its base by lightness alone. Rotating the
    /// hue far enough to reach ΔE 5 turns a pastel magenta green; the bright
    /// half is a brightness variant, not a different colour.
    private static func lightnessAway(_ color: RGBA, otherSlots: [RGBA], background: RGBA) -> RGBA? {
        let lab = ThemeContrastRepair.oklab(color)
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let hue = atan2(lab.b, lab.a)
        let floor = min(2.5, color.contrast(with: background))
        // Away from the background keeps a dark theme's bright half brighter
        // and a light theme's darker.
        let away = lab.l < ThemeContrastRepair.oklab(background).l ? 1.0 : -1.0
        for step in 1...30 {
            for direction in [away, -away] {
                let lightness = min(1, max(0, lab.l + Double(step) * 0.02 * direction))
                let mapped = ThemeContrastRepair.gamutMapped(ThemeContrastRepair.OKLab(
                    l: lightness, a: cos(hue) * chroma, b: sin(hue) * chroma
                ))
                let candidate = RGBA(hex: hex(mapped)) ?? mapped
                guard candidate.contrast(with: background) >= floor else { continue }
                if otherSlots.allSatisfy({ deltaE(candidate, $0) >= 5 }) { return candidate }
            }
        }
        return nil
    }

    private static func rotatedAway(_ color: RGBA, otherSlots: [RGBA], background: RGBA) -> RGBA? {
        let lab = ThemeContrastRepair.oklab(color)
        let chroma = max((lab.a * lab.a + lab.b * lab.b).squareRoot(), 0.04)
        let hue = atan2(lab.b, lab.a)
        let floor = min(2.5, color.contrast(with: background))
        for step in 1...36 {
            let offset = Double(step) * 5 * Double.pi / 180
            for direction in [1.0, -1.0] {
                let angle = hue + offset * direction
                let mapped = ThemeContrastRepair.gamutMapped(ThemeContrastRepair.OKLab(
                    l: lab.l, a: cos(angle) * chroma, b: sin(angle) * chroma
                ))
                let candidate = RGBA(hex: hex(mapped)) ?? mapped
                guard candidate.contrast(with: background) >= floor else { continue }
                if otherSlots.allSatisfy({ deltaE(candidate, $0) >= 5 }) { return candidate }
            }
        }
        return nil
    }

    private static func deltaE(_ first: RGBA, _ second: RGBA) -> Double {
        let a = ThemeContrastRepair.oklab(first)
        let b = ThemeContrastRepair.oklab(second)
        return 100 * sqrt(pow(a.l - b.l, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }

    static func sixteen(_ values: [String]) -> [String] {
        var values = values
        while values.count < 16 {
            values.append(values.last ?? "#ffffff")
        }
        return Array(values.prefix(16))
    }
}

extension Theme {
    /// The launcher view of a palette that has no theme file of its own — a
    /// wallpaper extraction, or the palette another app was just given. Keeps
    /// the launcher, the embedded terminal and cross-app targets on one palette
    /// instead of two.
    public init(palette source: PalettePalette) {
        self.init()
        name = source.name.isEmpty ? "Wallpaper" : source.name
        appearance = source.appearance
        palette.bg = source.background
        palette.surface = source.surface
        palette.elevated = source.elevated
        palette.fg = source.foreground
        palette.fgMuted = source.muted
        palette.accent = source.cursor
        palette.accentFg = source.cursorText
        palette.selectionBg = source.selectionBackground
        palette.selectionFg = source.selectionForeground
        palette.border = source.border
        palette.separator = source.border
        palette.matchFg = source.ansi[5]
        // ANSI red/green/yellow/blue are the semantic hues every theme uses, so
        // a theme built here re-renders the same terminal palette.
        palette.danger = source.ansi[1]
        palette.success = source.ansi[2]
        palette.warning = source.ansi[3]
        palette.info = source.ansi[4]
        palette.badgeBg = source.elevated
        palette.badgeFg = source.foreground
        states.selected = ThemeState(bg: source.selectionBackground, fg: source.selectionForeground)
        states.hover = ThemeState(bg: source.surface)
        states.disabled = ThemeState(fg: source.muted)
        footer.hintColor = source.muted
        window.material = appearance == "light" ? "popover" : "hudWindow"
    }
}

// MARK: - Wallpaper extraction

public struct WallpaperPixels: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Row-major.
    public var pixels: [RGBA]

    public init(width: Int, height: Int, pixels: [RGBA]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum WallpaperPalette {
    /// Downscales with AppKit so a 6K wallpaper costs the same as a thumbnail.
    public static func pixels(from image: NSImage, maxDimension: Int = 64) -> WallpaperPixels? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxDimension) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )

        var pixels: [RGBA] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    pixels.append(RGBA(red: 0, green: 0, blue: 0, alpha: 0))
                    continue
                }
                pixels.append(RGBA(
                    red: Double(color.redComponent),
                    green: Double(color.greenComponent),
                    blue: Double(color.blueComponent),
                    alpha: Double(color.alphaComponent)
                ))
            }
        }
        return WallpaperPixels(width: width, height: height, pixels: pixels)
    }

    public static func extract(
        from image: NSImage,
        appearance: String = "dark",
        saturation: Double = 0,
        contrast: Double = 0
    ) -> PalettePalette? {
        guard let pixels = pixels(from: image) else { return nil }
        return extract(pixels: pixels, appearance: appearance, saturation: saturation, contrast: contrast)
    }

    /// Pure: pywal's pipeline. Quantize to 16 colours (ascending luminance, the
    /// order its ImageMagick backend returns), pour them into pywal's
    /// `color0...color15` slots, then run its dark/light adjustment, `--saturate`
    /// and `--contrast` steps. Palette's contrast clamp only touches the UI
    /// roles, never the terminal's 16 colours.
    public static func extract(
        pixels: WallpaperPixels,
        appearance: String = "dark",
        saturation: Double = 0,
        contrast: Double = 0
    ) -> PalettePalette? {
        let opaque = pixels.pixels.filter { $0.alpha > 0.5 }
        guard let scheme = pywalScheme(
            opaque,
            light: appearance == "light",
            saturation: min(1, max(-1, saturation)),
            contrast: (1...21).contains(contrast) ? contrast : 0
        ) else { return nil }

        let background = scheme[0]
        let foreground = readable(scheme[15], on: background, minimum: 4.5)
        // pywal's `special.cursor` is the foreground. Palette draws its caret and
        // its whole UI accent from this slot, so it takes the most saturated
        // terminal colour that reads on the background instead.
        let accent = readable(accentColor(in: scheme, on: background) ?? foreground, on: background, minimum: 3)
        let surface = background.mixed(with: foreground, amount: 0.06)
        let elevated = background.mixed(with: foreground, amount: 0.12)
        let border = readable(background.mixed(with: foreground, amount: 0.24), on: background, minimum: 1.8)
        let muted = readable(foreground.mixed(with: background, amount: 0.32), on: background, minimum: 3)
        let selectionBackground = elevated
        let selectionForeground = readable(foreground, on: selectionBackground, minimum: 4.5)
        let cursorText = readable(bestText(on: accent), on: accent, minimum: 4.5)

        return PalettePalette(
            name: "Wallpaper",
            appearance: appearance,
            background: hex(background),
            foreground: hex(foreground),
            cursor: hex(accent),
            cursorText: hex(cursorText),
            selectionBackground: hex(selectionBackground),
            selectionForeground: hex(selectionForeground),
            surface: hex(surface),
            elevated: hex(elevated),
            border: hex(border),
            muted: hex(muted),
            ansi: PalettePalette.distinctANSI(scheme, background: background).map(hex)
        )
    }

    /// Most saturated colour in slots 1...14 that stands off the background.
    private static func accentColor(in scheme: [RGBA], on background: RGBA) -> RGBA? {
        scheme[1...14]
            .filter { $0.contrast(with: background) >= 2 }
            .max { $0.saturation < $1.saturation }
    }

    // MARK: pywal pipeline

    /// pywal's `wal` backend quantizes with ImageMagick, whose unique-colour
    /// output is ordered dark to light. We quantize with the deterministic
    /// k-means below and sort by luminance, then use pywal's own slot layout and
    /// adjustments unchanged. With the same 16 input colours this matches
    /// pywal's `colors.json` exactly.
    static func pywalScheme(
        _ pixels: [RGBA],
        light: Bool,
        saturation: Double,
        contrast: Double
    ) -> [RGBA]? {
        guard !pixels.isEmpty else { return nil }
        var cols = kmeans(pixels, k: 16)
            .map { quantized($0.center) }
            .sorted { $0.luminance < $1.luminance }
        // A low-colour image cannot fill 16 slots. pywal16 doubles the list in
        // that case (`extend(hex_colors)`), so keep its colours instead of
        // repeating only the brightest one.
        while cols.count < 16 {
            cols.append(contentsOf: cols)
        }
        cols = Array(cols.prefix(16))

        // wal.py: raw = colors[:1] + colors[8:16] + colors[8:-1]
        var scheme = [cols[0]] + Array(cols[8..<16]) + Array(cols[8..<15])
        pywalAdjust(&scheme, light: light)
        pywalSaturate(&scheme, amount: saturation)
        pywalContrast(&scheme, ratio: contrast, light: light, average: average(pixels))
        return scheme
    }

    /// colors.py `generic_adjust` (pywal16 3.8.15, the maintained pywal on
    /// PyPI; dylanaraps' 3.3.1 differs only in its light loop, which assigns to
    /// a local and therefore does nothing).
    static func pywalAdjust(_ colors: inout [RGBA], light: Bool) {
        if light {
            colors[0] = lighten(colors[0], 0.95)
            colors[7] = darken(colors[0], 0.75)
            colors[8] = darken(colors[0], 0.25)
            colors[15] = colors[7]
        } else {
            // colors[0][1] is the red channel's high hex digit.
            if redByte(colors[0]) >= 16 {
                colors[0] = darken(colors[0], 0.40)
            }
            // A near-black background loses all hue; pywal lifts it first.
            if redByte(colors[0]) < 16 || greenByte(colors[0]) < 16 || blueByte(colors[0]) < 16 {
                colors[0] = saturate(lighten(colors[0], 0.03), to: 0.40)
            }
            colors[7] = lighten(colors[0], 0.75)
            colors[8] = saturate(lighten(colors[0], 0.35), to: 0.10)
            colors[15] = colors[7]
        }
    }

    /// colors.py `saturate_colors`: `--saturate` adds to every slot except the
    /// foreground pair, so text never turns neon.
    static func pywalSaturate(_ colors: inout [RGBA], amount: Double) {
        guard amount != 0, (-1...1).contains(amount) else { return }
        for index in colors.indices where index != 7 && index != 15 {
            colors[index] = addSaturation(colors[index], amount)
        }
    }

    /// colors.py `ensure_contrast`: `--contrast` pushes slots 1...14 past the
    /// requested W3 ratio against the image's average luminance. pywal16's
    /// light branch is unreachable (both conditions skip every colour), so the
    /// light path here does what that branch intended: darkens colours that are
    /// too light.
    static func pywalContrast(_ colors: inout [RGBA], ratio: Double, light: Bool, average: RGBA) {
        guard ratio != 0, (1...21).contains(ratio) else { return }
        let mean = quantized(average)
        let desired = light
            ? (pywalLuminance(mean) + 0.05) / ratio - 0.05
            : (pywalLuminance(mean) + 0.05) * ratio - 0.05
        guard desired < 0.99, desired > 0.01 else { return }
        for index in 1...14 {
            let luminance = pywalLuminance(colors[index])
            if light ? luminance <= desired : luminance >= desired { continue }
            colors[index] = contrastAdjusted(colors[index], luminance: desired, light: light)
        }
    }

    /// util.py `Color.w3_luminance`: the hex channel is read back as a
    /// three-decimal string (`"%.3f" % (v / 255)`), so reproduce that rounding.
    static func pywalLuminance(_ color: RGBA) -> Double {
        let (r, g, b) = bytes(color)
        func linear(_ byte: Int) -> Double {
            let value = (Double(byte) / 255 * 1000).rounded() / 1000
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// colorsys.rgb_to_hsv over the same three-decimal channels pywal's
    /// `ensure_contrast` feeds it.
    static func pywalHSV(_ color: RGBA) -> (hue: Double, saturation: Double, value: Double) {
        let (r, g, b) = bytes(color)
        func channel(_ byte: Int) -> Double { (Double(byte) / 255 * 1000).rounded() / 1000 }
        return RGBA(red: channel(r), green: channel(g), blue: channel(b)).hsv
    }

    /// colors.py `binary_luminance_adjust`, ten bisections over saturation and
    /// value in HSV.
    static func contrastAdjusted(_ color: RGBA, luminance desired: Double, light: Bool) -> RGBA {
        let (h, s, v) = pywalHSV(color)
        var sMin = s
        var sMax = s
        var vMin = v
        var vMax = v
        if light {
            sMin = s
            sMax = 1
            vMin = 0
            vMax = v
        } else if pywalLuminance(hsv(h, s, 1)) >= desired {
            vMax = 1
        } else {
            sMin = 0
            vMin = 1
            vMax = 1
        }
        var result = color
        for _ in 0..<10 {
            let midS = (sMin + sMax) / 2
            let midV = (vMin + vMax) / 2
            let candidate = hsv(h, midS, midV)
            if pywalLuminance(candidate) >= desired {
                sMin = midS
                vMax = midV
            } else {
                sMax = midS
                vMin = midV
            }
            result = candidate
        }
        return result
    }

    static func average(_ pixels: [RGBA]) -> RGBA {
        guard !pixels.isEmpty else { return RGBA(red: 0, green: 0, blue: 0) }
        let total = Double(pixels.count)
        let sums = pixels.reduce(into: (red: 0.0, green: 0.0, blue: 0.0)) { sums, pixel in
            sums.red += pixel.red
            sums.green += pixel.green
            sums.blue += pixel.blue
        }
        return RGBA(red: sums.red / total, green: sums.green / total, blue: sums.blue / total)
    }

    // MARK: pywal colour math (8-bit, truncating, as util.py does)

    private static func redByte(_ color: RGBA) -> Int { bytes(color).red }
    private static func greenByte(_ color: RGBA) -> Int { bytes(color).green }
    private static func blueByte(_ color: RGBA) -> Int { bytes(color).blue }

    static func bytes(_ color: RGBA) -> (red: Int, green: Int, blue: Int) {
        func byte(_ value: Double) -> Int {
            Int((min(1, max(0, value)) * 255).rounded())
        }
        return (byte(color.red), byte(color.green), byte(color.blue))
    }

    static func quantized(_ color: RGBA) -> RGBA {
        let (r, g, b) = bytes(color)
        return fromBytes(r, g, b)
    }

    static func fromBytes(_ red: Int, _ green: Int, _ blue: Int) -> RGBA {
        func channel(_ value: Int) -> Double { Double(min(255, max(0, value))) / 255 }
        return RGBA(red: channel(red), green: channel(green), blue: channel(blue))
    }

    /// util.py `darken_color`.
    static func darken(_ color: RGBA, _ amount: Double) -> RGBA {
        let (r, g, b) = bytes(color)
        return fromBytes(Int(Double(r) * (1 - amount)), Int(Double(g) * (1 - amount)), Int(Double(b) * (1 - amount)))
    }

    /// util.py `lighten_color`.
    static func lighten(_ color: RGBA, _ amount: Double) -> RGBA {
        let (r, g, b) = bytes(color)
        func channel(_ value: Int) -> Int { Int(Double(value) + (255 - Double(value)) * amount) }
        return fromBytes(channel(r), channel(g), channel(b))
    }

    /// util.py `saturate_color`: set saturation to an absolute value in HLS.
    static func saturate(_ color: RGBA, to amount: Double) -> RGBA {
        let (h, l, _) = color.hls
        return fromHLS(h, l, amount)
    }

    /// util.py `add_saturation`: add to saturation in HLS. pywal clamps only at
    /// ±1, so a negative result is fed to colorsys (channels can invert).
    static func addSaturation(_ color: RGBA, _ amount: Double) -> RGBA {
        let (h, l, s) = color.hls
        return fromHLS(h, l, min(1, max(-1, s + amount)))
    }

    // colorsys.hls_to_rgb / hsv_to_rgb, truncated to 8 bits like rgb_to_hex.
    static func fromHLS(_ hue: Double, _ lightness: Double, _ saturation: Double) -> RGBA {
        let m2 = lightness <= 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let m1 = 2 * lightness - m2
        func channel(_ offset: Double) -> Double {
            var hue = (hue + offset).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            if hue < 1.0 / 6 { return m1 + (m2 - m1) * hue * 6 }
            if hue < 0.5 { return m2 }
            if hue < 2.0 / 3 { return m1 + (m2 - m1) * (2.0 / 3 - hue) * 6 }
            return m1
        }
        return fromUnit(channel(1.0 / 3), channel(0), channel(-1.0 / 3))
    }

    static func hsv(_ hue: Double, _ saturation: Double, _ value: Double) -> RGBA {
        guard saturation > 0 else { return fromUnit(value, value, value) }
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return fromUnit(value, t, p)
        case 1: return fromUnit(q, value, p)
        case 2: return fromUnit(p, value, t)
        case 3: return fromUnit(p, q, value)
        case 4: return fromUnit(t, p, value)
        default: return fromUnit(value, p, q)
        }
    }

    private static func fromUnit(_ red: Double, _ green: Double, _ blue: Double) -> RGBA {
        func byte(_ value: Double) -> Int {
            Int((min(1, max(0, value)) * 255).rounded(.down))
        }
        return fromBytes(byte(red), byte(green), byte(blue))
    }

    private static func hex(_ color: RGBA) -> String { PalettePalette.hex(color) }

    private static func readable(_ color: RGBA, on background: RGBA, minimum: Double) -> RGBA {
        PalettePalette.readable(color, on: background, minimum: minimum)
    }

    private static func bestText(on background: RGBA) -> RGBA {
        PalettePalette.bestText(on: background)
    }

    struct Cluster {
        var center: RGBA
    }

    /// Deterministic k-means: seeds are picked farthest-first in RGB, so a
    /// dark wallpaper still contributes its small bright accents instead of
    /// collapsing into empty clusters. Same wallpaper, same palette.
    static func kmeans(_ pixels: [RGBA], k: Int, iterations: Int = 10) -> [Cluster] {
        guard !pixels.isEmpty, k > 0 else { return [] }
        let first = pixels.min { $0.luminance < $1.luminance } ?? pixels[0]
        var centers: [RGBA] = [first]
        while centers.count < k {
            var farthest = pixels[0]
            var farthestDistance = -1.0
            for pixel in pixels {
                let distance = centers.reduce(Double.infinity) { best, center in
                    min(best, squaredDistance(pixel, center))
                }
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthest = pixel
                }
            }
            centers.append(farthest)
        }
        var assignments = [Int](repeating: 0, count: pixels.count)

        for _ in 0..<iterations {
            var moved = false
            for (index, pixel) in pixels.enumerated() {
                var best = 0
                var bestDistance = Double.infinity
                for (centerIndex, center) in centers.enumerated() {
                    let distance = squaredDistance(pixel, center)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = centerIndex
                    }
                }
                if assignments[index] != best {
                    assignments[index] = best
                    moved = true
                }
            }
            var sums = [RGBA](repeating: RGBA(red: 0, green: 0, blue: 0), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (index, pixel) in pixels.enumerated() {
                let slot = assignments[index]
                sums[slot].red += pixel.red
                sums[slot].green += pixel.green
                sums[slot].blue += pixel.blue
                counts[slot] += 1
            }
            for index in 0..<k where counts[index] > 0 {
                let count = Double(counts[index])
                centers[index] = RGBA(
                    red: sums[index].red / count,
                    green: sums[index].green / count,
                    blue: sums[index].blue / count
                )
            }
            if !moved { break }
        }

        var counts = [Int](repeating: 0, count: k)
        for slot in assignments { counts[slot] += 1 }
        return centers.enumerated().compactMap { index, center in
            counts[index] > 0 ? Cluster(center: center) : nil
        }
    }

    private static func squaredDistance(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return red * red + green * green + blue * blue
    }
}

// MARK: - Chromium browsers

public struct ChromiumBrowser: Sendable, Equatable, Identifiable {
    public var id: String { bundleID }
    public var name: String
    public var appName: String
    public var processName: String
    public var bundleID: String
    public var target: ThemingTarget
    /// Arc does not implement the BrowserThemeColor policy, so it stays listed
    /// but disabled once found.
    public var supportsThemePolicy: Bool

    public var policyIdentifier: String { ChromiumPolicy.identifier(for: bundleID) }
    public var mobileConfigFileName: String { "\(target.rawValue)-theme.mobileconfig" }
    /// The user-owned file Palette writes silently after the one-time enable.
    public var silentPlistPath: String { ChromiumPolicy.userPlistPath(bundleID: bundleID) }
    public var targetTitle: String { "\(name) (silent managed theme)" }

    public static let catalog: [ChromiumBrowser] = [
        ChromiumBrowser(name: "Helium", appName: "Helium", processName: "Helium",
                        bundleID: "net.imput.helium", target: .helium, supportsThemePolicy: true),
        ChromiumBrowser(name: "Google Chrome", appName: "Google Chrome", processName: "Google Chrome",
                        bundleID: "com.google.Chrome", target: .chrome, supportsThemePolicy: true),
        ChromiumBrowser(name: "Microsoft Edge", appName: "Microsoft Edge", processName: "Microsoft Edge",
                        bundleID: "com.microsoft.edgemac", target: .edge, supportsThemePolicy: true),
        ChromiumBrowser(name: "Brave", appName: "Brave Browser", processName: "Brave Browser",
                        bundleID: "com.brave.Browser", target: .brave, supportsThemePolicy: true),
        ChromiumBrowser(name: "Vivaldi", appName: "Vivaldi", processName: "Vivaldi",
                        bundleID: "com.vivaldi.Vivaldi", target: .vivaldi, supportsThemePolicy: true),
        ChromiumBrowser(name: "Chromium", appName: "Chromium", processName: "Chromium",
                        bundleID: "org.chromium.Chromium", target: .chromium, supportsThemePolicy: true),
        ChromiumBrowser(name: "Arc", appName: "Arc", processName: "Arc",
                        bundleID: "company.thebrowser.Browser", target: .arc, supportsThemePolicy: false),
    ]

    public static func browser(for target: ThemingTarget) -> ChromiumBrowser? {
        catalog.first { $0.target == target }
    }

    public static func browser(forBundleID bundleID: String) -> ChromiumBrowser? {
        catalog.first { $0.bundleID == bundleID }
    }
}

public enum ChromiumPolicy {
    public static func identifier(for bundleID: String) -> String {
        "dev.myleshen.palette.chromium.\(bundleID)"
    }

    /// Every identifier Palette can install: the whole catalogue, not only the
    /// browsers currently checked, so removal cannot leave a stale policy.
    public static func allPolicyIdentifiers() -> [String] {
        ChromiumBrowser.catalog.filter(\.supportsThemePolicy).map(\.policyIdentifier)
    }

    /// The Palette identifiers still present in `profiles -P` output.
    public static func remainingIdentifiers(in profilesOutput: String) -> [String] {
        allPolicyIdentifiers().filter { profilesOutput.contains($0) }
    }

    /// Managed preference files macOS may use: device scope, then the user's
    /// own scope. `complete.plist` carries every forced preference for the
    /// user, so a profile that only writes there still counts as installed.
    public static func managedPreferencePaths(
        bundleID: String,
        user: String = NSUserName()
    ) -> [String] {
        [
            "/Library/Managed Preferences/\(bundleID).plist",
            "/Library/Managed Preferences/\(user)/\(bundleID).plist",
            "/Library/Managed Preferences/\(user)/complete.plist",
        ]
    }

    /// True when a managed-preference plist carries this browser's domain.
    /// `complete.plist` is shared by every managed domain, so its mere
    /// existence must not count as an installed browser policy.
    public static func carriesDomain(_ bundleID: String, in data: Data) -> Bool {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let root = propertyList as? [String: Any] else { return false }
        return root[bundleID] != nil
    }

    /// The seeded colour in an installed plist. `complete.plist` nests every
    /// domain, so the bundle id scopes the search first; a direct domain plist
    /// has the keys at the root.
    public static func themeColor(in data: Data, bundleID: String? = nil) -> String? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else { return nil }
        if let bundleID,
           let root = propertyList as? [String: Any],
           let domain = root[bundleID] {
            return themeColor(in: domain)
        }
        return themeColor(in: propertyList)
    }

    private static func themeColor(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let colour = dictionary["BrowserThemeColor"] as? String { return colour }
            // A real managed preference wraps the value: the payload is
            // `{ mcxdomain, source, value }`, not a bare colour like the
            // silent plist and exported profile use.
            if let payload = dictionary["BrowserThemeColor"] as? [String: Any],
               let colour = payload["value"] as? String {
                return colour
            }
            for value in dictionary.values {
                if let colour = themeColor(in: value) { return colour }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let colour = themeColor(in: value) { return colour }
            }
        }
        return nil
    }

    /// The user-scoped managed preference Palette owns after the one-time
    /// enable. Chromium reads it like any managed domain, but because the file
    /// is user-owned a later Apply can rewrite it without administrator rights.
    public static func userPlistPath(bundleID: String, user: String = NSUserName()) -> String {
        "/Library/Managed Preferences/\(user)/\(bundleID).plist"
    }

    public static func silentPlistData(colour: String) -> Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: ["BrowserThemeColor": colour],
            format: .xml,
            options: 0
        )) ?? Data()
    }

    /// Silent mode is on only when the file exists and this user can rewrite
    /// it; a root-owned leftover from a profile is not silent mode.
    public static func silentWritable(path: String, user: String = NSUserName()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountName] as? String,
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return owner == user && permissions.intValue & 0o200 != 0
    }

    public struct SilentTarget: Sendable, Equatable {
        public var bundleID: String
        public var colour: String

        public init(bundleID: String, colour: String) {
            self.bundleID = bundleID
            self.colour = colour
        }
    }

    /// The one-time password prompt. Legacy profiles go first because
    /// `profiles remove` may clean the managed-preference files macOS wrote;
    /// then the user-owned plist is created, handed to the user and seeded.
    public static func enableCommand(
        targets: [SilentTarget],
        installedIdentifiers: [String],
        user: String = NSUserName()
    ) -> String {
        var steps = installedIdentifiers.map {
            "(/usr/bin/profiles remove -identifier \(token($0)) 2>/dev/null || true)"
        }
        let directory = "/Library/Managed Preferences/\(user)"
        steps.append("mkdir -p \(token(directory))")
        for target in targets {
            let path = token(userPlistPath(bundleID: target.bundleID, user: user))
            steps.append("touch \(path)")
            steps.append("chown \(token(user)) \(path)")
            steps.append("chmod 644 \(path)")
            // `defaults write` is the plist write; the chown/chmod repeat
            // because defaults may replace the file rather than edit in place.
            steps.append("/usr/bin/defaults write \(path) BrowserThemeColor \(quoted(target.colour))")
            steps.append("chown \(token(user)) \(path)")
            steps.append("chmod 644 \(path)")
        }
        return steps.joined(separator: " && ")
    }

    /// Removal deletes only Palette's user-owned plists; no profile exists to
    /// remove once silent mode is on.
    public static func removalCommand(bundleIDs: [String], user: String = NSUserName()) -> String {
        bundleIDs.map { "rm -f \(token(userPlistPath(bundleID: $0, user: user)))" }
            .joined(separator: " && ")
    }

    public static func refreshArguments(binary: String) -> [String] {
        [binary, "--refresh-platform-policy", "--no-startup-window"]
    }

    /// Launching the app bundle's binary asks the running instance to re-read
    /// its managed preferences; `open -a` is not used because the flag must
    /// reach Chromium, not LaunchServices.
    public static func appBinary(appName: String, home: String = NSHomeDirectory()) -> String? {
        for root in ["/Applications", home + "/Applications"] {
            let bundle = Bundle(path: root + "/" + appName + ".app")
            if let executable = bundle?.executableURL?.path, FileManager.default.isExecutableFile(atPath: executable) {
                return executable
            }
        }
        return nil
    }

    /// One seed colour per browser; Chromium derives the rest.
    /// A stable UUID per browser and payload, or two profiles installed
    /// together would share a UUID and macOS would treat them as one.
    static func profileUUID(browser: ChromiumBrowser, salt: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt):\(browser.bundleID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20),
        ].joined(separator: "-")
    }

    public static func mobileConfig(browser: ChromiumBrowser, palette: PalettePalette) -> String {
        let identifier = identifier(for: browser.bundleID)
        let escaped = palette.background
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadContent</key>
          <array>
            <dict>
              <key>PayloadType</key>
              <string>com.apple.ManagedClient.preferences</string>
              <key>PayloadIdentifier</key>
              <string>\(identifier)</string>
              <key>PayloadUUID</key>
              <string>\(profileUUID(browser: browser, salt: "payload"))</string>
              <key>PayloadVersion</key>
              <integer>1</integer>
              <key>PayloadDisplayName</key>
              <string>Palette \(browser.name) theme</string>
              <key>PayloadContent</key>
              <dict>
                <key>\(browser.bundleID)</key>
                <dict>
                  <key>Forced</key>
                  <array>
                    <dict>
                      <key>mcx_preference_settings</key>
                      <dict>
                        <key>BrowserThemeColor</key>
                        <string>\(escaped)</string>
                      </dict>
                    </dict>
                  </array>
                </dict>
              </dict>
            </dict>
          </array>
          <key>PayloadType</key>
          <string>Configuration</string>
          <key>PayloadIdentifier</key>
          <string>\(identifier)</string>
          <key>PayloadUUID</key>
          <string>\(profileUUID(browser: browser, salt: "configuration"))</string>
          <key>PayloadVersion</key>
          <integer>1</integer>
          <key>PayloadDisplayName</key>
          <string>Palette \(browser.name) theme</string>
        </dict>
        </plist>
        """
    }

    /// Shell-safe enough for the display command and the single osascript call.
    public static func token(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace }) else { return value }
        return quoted(value)
    }

    /// Always quoted, for values such as `#RRGGBB` where `#` would otherwise
    /// start a shell comment.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Renderers

public struct PaletteMetadata: Sendable, Equatable {
    public var source: String
    /// The catalogue file id, so a later apply can load the same theme again.
    public var themeID: String
    public var theme: String
    public var appearance: String
    public var generatedAt: Date
    public var targets: [String]
    /// The nvim file drops Normal's background so a translucent terminal or
    /// Neovide shows through.
    public var transparentBackgrounds: Bool

    public init(
        source: String,
        theme: String,
        appearance: String,
        themeID: String = "",
        generatedAt: Date = Date(),
        targets: [String] = [],
        transparentBackgrounds: Bool = false
    ) {
        self.source = source
        self.theme = theme
        self.themeID = themeID
        self.appearance = appearance
        self.generatedAt = generatedAt
        self.targets = targets
        self.transparentBackgrounds = transparentBackgrounds
    }

    public var header: String { header(comment: "#") }

    /// Each target's real comment marker: `#` for shell/conf/TOML, `//` for
    /// KDL, `--` for Lua. Writing `#` into Lua/KDL made those files invalid.
    public func header(comment: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: generatedAt)
        let name = theme.isEmpty ? "" : " · \(theme)\(themeID.isEmpty ? "" : " (\(themeID))")"
        return [
            "\(comment) generated by Palette — do not edit",
            "\(comment) source: \(source)\(name) · \(appearance) · \(stamp)",
        ].joined(separator: "\n")
    }
}

public enum ThemingRenderer {
    public static let paletteJSONName = "palette.json"
    /// The same palette in two shapes other tools already read, so a new app
    /// costs a file read instead of an adapter. Written on every apply.
    public static let base16Name = "palette.yaml"
    public static let terminalSexyName = "palette.terminal-sexy.json"
    /// Both standard files, in the order they are written and listed.
    public static let standardExportNames = [base16Name, terminalSexyName]

    /// Text for an ANSI-coloured chip or diff emphasis. The softer #111 wins
    /// when it clears 4.5:1; otherwise pure black/white always can.
    private static func readableChipText(on background: String) -> String {
        let color = RGBA(hex: background) ?? RGBA(red: 0, green: 0, blue: 0)
        let soft = PalettePalette.bestText(on: color)
        if soft.contrast(with: color) >= 4.5 {
            return PalettePalette.hex(soft)
        }
        let black = RGBA(red: 0, green: 0, blue: 0)
        let white = RGBA(red: 1, green: 1, blue: 1)
        return PalettePalette.hex(black.contrast(with: color) >= white.contrast(with: color) ? black : white)
    }

    /// Text colour that still clears `minimum` after the value is rounded to
    /// the 8-bit hex that actually lands in the file. `readable` checks the
    /// unrounded colour, which can lose a hair in the last iteration.
    private static func readableHex(_ color: String, on background: String, minimum: Double) -> String {
        let bg = RGBA(hex: background) ?? RGBA(red: 0, green: 0, blue: 0)
        let chosen = PalettePalette.hex(
            PalettePalette.readable(RGBA(hex: color) ?? bg, on: bg, minimum: minimum)
        )
        if let rounded = RGBA(hex: chosen), rounded.contrast(with: bg) >= minimum {
            return chosen
        }
        return PalettePalette.hex(PalettePalette.bestText(on: bg))
    }

    /// nil for targets that are not configured yet, so phase two cannot
    /// silently write a half-guessed format.
    public static func contents(
        for target: ThemingTarget,
        palette: PalettePalette,
        metadata: PaletteMetadata
    ) -> String? {
        guard target.isImplemented else { return nil }
        let header = metadata.header
        switch target {
        case .kitty: return kitty(palette, header: header)
        case .ghostty: return ghostty(palette, header: header)
        case .zellij: return zellij(palette, header: metadata.header(comment: "//"))
        case .nvim:
            return nvim(
                palette,
                header: metadata.header(comment: "--"),
                transparent: metadata.transparentBackgrounds
            )
        case .fish: return fish(palette, header: header)
        case .bat: return bat(palette, header: header)
        case .delta: return delta(palette, header: header)
        case .btop: return btop(palette, header: header)
        case .yazi: return yazi(palette, header: header)
        case .starship, .vscode, .zed, .helium, .chrome, .edge, .brave, .vivaldi, .chromium, .arc:
            return nil
        }
    }

    private static func bat(_ palette: PalettePalette, header: String) -> String {
        // tmTheme is XML, so the house header becomes an XML comment.
        let xmlHeader = header
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = line.hasPrefix("# ") ? String(line.dropFirst(2)) : String(line)
                return "<!-- \(text) -->"
            }
            .joined(separator: "\n")
        // The XML declaration must come first; comments may only follow it.
        var out = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", xmlHeader]
        out.append("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">")
        out.append("<plist version=\"1.0\">")
        out.append("<dict>")
        out.append("  <key>name</key>")
        out.append("  <string>Palette</string>")
        out.append("  <key>colors</key>")
        out.append("  <dict>")
        for (key, value) in [
            ("background", palette.background),
            ("foreground", palette.foreground),
            ("cursor", palette.cursor),
            ("selectionBackground", palette.selectionBackground),
            ("selectionForeground", palette.selectionForeground),
        ] {
            out.append("    <key>\(key)</key>")
            out.append("    <string>\(value)</string>")
        }
        out.append("  </dict>")
        out.append("  <key>settings</key>")
        out.append("  <array>")
        let rules: [(String, String?, String?)] = [
            ("Comment", palette.muted, nil),
            ("String", palette.ansi[2], nil),
            ("Number", palette.ansi[3], nil),
            ("Built-in constant", palette.ansi[5], nil),
            ("Function", palette.ansi[4], nil),
            ("Keyword", palette.ansi[5], nil),
            ("Type", palette.ansi[6], nil),
            ("Variable", palette.ansi[1], nil),
        ]
        for (name, foreground, background) in rules {
            out.append("    <dict>")
            out.append("      <key>name</key>")
            out.append("      <string>\(name)</string>")
            out.append("      <key>settings</key>")
            out.append("      <dict>")
            if let foreground {
                out.append("        <key>foreground</key>")
                out.append("        <string>\(foreground)</string>")
            }
            if let background {
                out.append("        <key>background</key>")
                out.append("        <string>\(background)</string>")
            }
            out.append("      </dict>")
            out.append("    </dict>")
        }
        out.append("  </array>")
        out.append("</dict>")
        out.append("</plist>")
        return out.joined(separator: "\n") + "\n"
    }

    private static func delta(_ palette: PalettePalette, header: String) -> String {
        var out = [header, "", "[delta]"]
        out.append("    minus-style = syntax \"\(palette.background)\"")
        out.append("    minus-emph-style = normal \"\(readableChipText(on: palette.ansi[1]))\" \"\(palette.ansi[1])\"")
        out.append("    plus-style = syntax \"\(palette.background)\"")
        out.append("    plus-emph-style = normal \"\(readableChipText(on: palette.ansi[2]))\" \"\(palette.ansi[2])\"")
        out.append("    line-numbers-minus-style = \"\(palette.ansi[1])\"")
        out.append("    line-numbers-plus-style = \"\(palette.ansi[2])\"")
        out.append("    line-numbers-zero-style = \"\(palette.muted)\"")
        out.append("    file-style = \"\(palette.ansi[4])\" bold")
        out.append("    file-decoration-style = \"\(palette.ansi[4])\" ul")
        out.append("    hunk-header-style = file line-number syntax")
        out.append("    hunk-header-decoration-style = \"\(palette.border)\" box")
        out.append("    commit-decoration-style = \"\(palette.ansi[3])\" bold box ul")
        out.append("    commit-style = \"\(palette.ansi[5])\" bold")
        out.append("    minus-empty-line-marker-style = \"\(palette.muted)\"")
        out.append("    plus-empty-line-marker-style = \"\(palette.muted)\"")
        return out.joined(separator: "\n") + "\n"
    }

    private static func btop(_ palette: PalettePalette, header: String) -> String {
        var out = [header]
        let entries: [(String, String)] = [
            ("main_bg", palette.background),
            ("main_fg", palette.foreground),
            ("title", palette.foreground),
            ("hi_fg", palette.cursor),
            ("selected_bg", palette.selectionBackground),
            ("selected_fg", palette.selectionForeground),
            ("inactive_fg", palette.muted),
            ("proc_misc", palette.ansi[6]),
            ("cpu_box", palette.ansi[4]),
            ("mem_box", palette.ansi[2]),
            ("net_box", palette.ansi[5]),
            ("proc_box", palette.ansi[1]),
            ("div_line", palette.border),
            ("temp_start", palette.ansi[2]),
            ("temp_mid", palette.ansi[3]),
            ("temp_end", palette.ansi[1]),
            ("cpu_start", palette.ansi[2]),
            ("cpu_mid", palette.ansi[3]),
            ("cpu_end", palette.ansi[1]),
            ("free_start", palette.ansi[4]),
            ("free_mid", palette.ansi[6]),
            ("free_end", palette.ansi[2]),
            ("cached_start", palette.ansi[5]),
            ("cached_mid", palette.ansi[4]),
            ("cached_end", palette.ansi[6]),
            ("available_start", palette.ansi[4]),
            ("available_mid", palette.ansi[6]),
            ("available_end", palette.ansi[2]),
            ("used_start", palette.ansi[1]),
            ("used_mid", palette.ansi[3]),
            ("used_end", palette.ansi[1]),
            // btop 1.4 uses *_start/_mid/_end gradients; a bare
            // download/upload key is silently ignored.
            ("download_start", palette.ansi[4]),
            ("download_mid", palette.ansi[6]),
            ("download_end", palette.ansi[2]),
            ("upload_start", palette.ansi[5]),
            ("upload_mid", palette.ansi[4]),
            ("upload_end", palette.ansi[1]),
            ("graph_text", palette.muted),
            ("meter_bg", palette.border),
        ]
        for (key, value) in entries {
            out.append("theme[\(key)]=\"\(value)\"")
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func yazi(_ palette: PalettePalette, header: String) -> String {
        // yazi 26 schema: `[mgr]` (not `[manager]`), hover lives in
        // `[indicator]`, modes in `[mode]`, and filetype mime globs need `**/`.
        /// A chip background that cannot clear 4.5:1 with the softer #111
        /// foreground takes pure black/white instead; the background keeps its
        /// meaning either way.
        let normal = (fg: readableChipText(on: palette.ansi[4]), bg: palette.ansi[4])
        let select = (fg: readableChipText(on: palette.ansi[3]), bg: palette.ansi[3])
        let unset = (fg: readableChipText(on: palette.muted), bg: palette.muted)
        var out = [header, ""]
        out.append("[mgr]")
        out.append("cwd = { fg = \"\(palette.ansi[4])\" }")
        out.append("find_keyword = { fg = \"\(palette.ansi[3])\", bold = true }")
        out.append("border_style = { fg = \"\(palette.border)\" }")
        out.append("")
        out.append("[indicator]")
        out.append("current = { fg = \"\(palette.selectionForeground)\", bg = \"\(palette.selectionBackground)\" }")
        out.append("")
        out.append("[mode]")
        out.append("normal_main = { fg = \"\(normal.fg)\", bg = \"\(normal.bg)\", bold = true }")
        out.append("select_main = { fg = \"\(select.fg)\", bg = \"\(select.bg)\", bold = true }")
        out.append("unset_main = { fg = \"\(unset.fg)\", bg = \"\(unset.bg)\", bold = true }")
        out.append("")
        out.append("[status]")
        out.append("progress_label = { fg = \"\(palette.foreground)\" }")
        out.append("")
        out.append("[which]")
        out.append("cand = { fg = \"\(palette.ansi[6])\" }")
        out.append("desc = { fg = \"\(palette.muted)\" }")
        out.append("")
        out.append("[filetype]")
        out.append("rules = [")
        out.append("  { mime = \"**/image/*\", fg = \"\(palette.ansi[5])\" },")
        out.append("  { mime = \"**/{audio,video}/*\", fg = \"\(palette.ansi[1])\" },")
        out.append("  { mime = \"**/application/{zip,rar,7z*,tar,gzip,xz,zstd}\", fg = \"\(palette.ansi[3])\" },")
        out.append("]")
        return out.joined(separator: "\n") + "\n"
    }

    public static func paletteJSON(palette: PalettePalette, metadata: PaletteMetadata) -> String {
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "source": metadata.source,
            "theme": metadata.theme,
            "theme_id": metadata.themeID,
            "appearance": metadata.appearance,
            "generated_at": formatter.string(from: metadata.generatedAt),
            "targets": metadata.targets,
            "background": palette.background,
            "foreground": palette.foreground,
            "accent": palette.cursor,
            "ansi": palette.ansi,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The standard exports, in write order. One palette, two files: every
    /// target below still exists for live reload, these are for everything else.
    public static func standardExports(
        palette: PalettePalette,
        metadata: PaletteMetadata
    ) -> [(name: String, contents: String)] {
        [
            (base16Name, base16(palette, header: metadata.header)),
            (terminalSexyName, terminalSexy(palette)),
        ]
    }

    /// base16 slots. The palette has one muted and one foreground role, so
    /// base03/base04 both take muted and base05/base06/base07 both take
    /// foreground; base08–base0F are the ANSI hues in base16 order (red,
    /// orange, yellow, green, cyan, blue, magenta, brown), reusing the same
    /// terminal palette so the two files cannot disagree.
    ///
    /// `base01` is the elevated surface (panels, popups) and `base02` the
    /// surface behind the window, so a base16 app keeps the same elevation
    /// order as Palette's own UI.
    private static func base16(_ palette: PalettePalette, header: String) -> String {
        let slots: [(String, String)] = [
            ("base00", palette.background),
            ("base01", palette.elevated),
            ("base02", palette.surface),
            ("base03", palette.muted),
            ("base04", palette.muted),
            ("base05", palette.foreground),
            ("base06", palette.foreground),
            ("base07", palette.foreground),
            ("base08", palette.ansi[1]),
            ("base09", palette.ansi[3]),
            ("base0A", palette.ansi[3]),
            ("base0B", palette.ansi[2]),
            ("base0C", palette.ansi[6]),
            ("base0D", palette.ansi[4]),
            ("base0E", palette.ansi[5]),
            ("base0F", palette.ansi[1]),
        ]
        var out = [header, ""]
        out.append("scheme: \(yamlQuoted(palette.name))")
        out.append("author: \(yamlQuoted("Palette"))")
        for (key, value) in slots {
            out.append("\(key): \(yamlQuoted(value))")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// terminal.sexy names its slots `color_01`…`color_16` for ANSI 0…15; the
    /// cursor and selection keys are the ones its importer reads.
    private static func terminalSexy(_ palette: PalettePalette) -> String {
        var payload: [String: Any] = [
            "name": palette.name,
            "author": "Palette",
            "foreground": palette.foreground,
            "background": palette.background,
            "cursorColor": palette.cursor,
            "cursorAccentColor": palette.cursorText,
            "selectionColor": palette.selectionBackground,
            "selectionForegroundColor": palette.selectionForeground,
        ]
        for (index, color) in palette.ansi.enumerated() {
            payload[String(format: "color_%02d", index + 1)] = color
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// YAML double-quoted scalar. A theme name with a quote or backslash would
    /// otherwise make the whole scheme unparseable.
    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func kitty(_ palette: PalettePalette, header: String) -> String {
        var out = [header, ""]
        out.append("background            \(palette.background)")
        out.append("foreground            \(palette.foreground)")
        out.append("cursor                \(palette.cursor)")
        out.append("cursor_text_color     \(palette.cursorText)")
        out.append("selection_background  \(palette.selectionBackground)")
        out.append("selection_foreground  \(palette.selectionForeground)")
        for (index, color) in palette.ansi.enumerated() {
            out.append("color\(index)              \(color)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func ghostty(_ palette: PalettePalette, header: String) -> String {
        var out = [header, ""]
        out.append("background = \(palette.background)")
        out.append("foreground = \(palette.foreground)")
        out.append("cursor-color = \(palette.cursor)")
        out.append("cursor-text = \(palette.cursorText)")
        out.append("selection-background = \(palette.selectionBackground)")
        out.append("selection-foreground = \(palette.selectionForeground)")
        for (index, color) in palette.ansi.enumerated() {
            out.append("palette = \(index)=\(color)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func zellij(_ palette: PalettePalette, header: String) -> String {
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var out = [header, "", "themes {", "    palette {"]
        out.append("        fg \"\(palette.foreground)\"")
        out.append("        bg \"\(palette.background)\"")
        for (index, name) in names.enumerated() {
            out.append("        \(name) \"\(palette.ansi[index])\"")
        }
        out.append("        orange \"\(palette.ansi[3])\"")
        out.append("        gray \"\(palette.muted)\"")

        // Zellij derives none of its UI roles from fg/bg; without them the tab
        // bar, status bar and frames fall back to grey defaults.
        let emphasis = Array(palette.ansi[1...4])
        func role(_ name: String, base: String, background: String, minimum: Double) {
            out.append("        \(name) {")
            out.append("            base \"\(readableHex(base, on: background, minimum: minimum))\"")
            out.append("            background \"\(background)\"")
            for (index, color) in emphasis.enumerated() {
                out.append("            emphasis_\(index) \"\(readableHex(color, on: background, minimum: 4.5))\"")
            }
            out.append("        }")
        }
        role("text_unselected", base: palette.foreground, background: palette.background, minimum: 4.5)
        role("text_selected", base: palette.cursorText, background: palette.cursor, minimum: 4.5)
        role("ribbon_unselected", base: palette.muted, background: palette.surface, minimum: 4.5)
        role("ribbon_selected", base: palette.cursorText, background: palette.cursor, minimum: 4.5)
        role("frame_unselected", base: palette.muted, background: palette.background, minimum: 3)
        role("frame_selected", base: palette.cursor, background: palette.background, minimum: 3)
        role("frame_highlight", base: palette.cursorText, background: palette.cursor, minimum: 3)
        role("exit_code_success", base: palette.background, background: palette.ansi[2], minimum: 4.5)
        role("exit_code_error", base: palette.background, background: palette.ansi[1], minimum: 4.5)

        out.append("    }")
        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }

    private static func nvim(_ palette: PalettePalette, header: String, transparent: Bool) -> String {
        let search = (fg: readableChipText(on: palette.ansi[3]), bg: palette.ansi[3])
        var out = [header, ""]
        out.append("local p = {")
        out.append("  bg = \"\(palette.background)\", fg = \"\(palette.foreground)\",")
        out.append("  surface = \"\(palette.surface)\", elevated = \"\(palette.elevated)\",")
        out.append("  border = \"\(palette.border)\", muted = \"\(palette.muted)\",")
        out.append("  cursor = \"\(palette.cursor)\", cursorText = \"\(palette.cursorText)\",")
        out.append("  selection = \"\(palette.selectionBackground)\", selectionFg = \"\(palette.selectionForeground)\",")
        out.append("  searchFg = \"\(search.fg)\", searchBg = \"\(search.bg)\",")
        out.append("  red = \"\(palette.ansi[1])\", green = \"\(palette.ansi[2])\",")
        out.append("  yellow = \"\(palette.ansi[3])\", blue = \"\(palette.ansi[4])\",")
        out.append("  magenta = \"\(palette.ansi[5])\", cyan = \"\(palette.ansi[6])\",")
        out.append("}")
        out.append("")
        out.append("local groups = {")
        if transparent {
            // No bg: the terminal's palette background and Neovide's opacity
            // show through. Every other surface stays bounded.
            out.append("  Normal = { fg = p.fg },")
            out.append("  NormalNC = { fg = p.fg },")
        } else {
            out.append("  Normal = { fg = p.fg, bg = p.bg },")
        }
        out.append("  NormalFloat = { fg = p.fg, bg = p.surface },")
        out.append("  Cursor = { fg = p.cursorText, bg = p.cursor },")
        out.append("  CursorLine = { bg = p.surface },")
        out.append("  LineNr = { fg = p.muted, bg = p.bg },")
        out.append("  Visual = { fg = p.selectionFg, bg = p.selection },")
        out.append("  Search = { fg = p.searchFg, bg = p.searchBg },")
        out.append("  StatusLine = { fg = p.fg, bg = p.elevated },")
        out.append("  Pmenu = { fg = p.fg, bg = p.surface },")
        out.append("  PmenuSel = { fg = p.cursorText, bg = p.cursor },")
        out.append("  Comment = { fg = p.muted },")
        out.append("  Constant = { fg = p.magenta },")
        out.append("  String = { fg = p.green },")
        out.append("  Function = { fg = p.blue },")
        out.append("  Keyword = { fg = p.magenta },")
        out.append("  Type = { fg = p.cyan },")
        out.append("  Error = { fg = p.red },")
        out.append("  WarningMsg = { fg = p.yellow },")
        out.append("}")
        out.append("")
        out.append("-- Global so a reload swaps in the newest palette instead of leaving")
        out.append("-- the previous file's autocmd painting old colours.")
        out.append("_G.palette_theme_token = _G.palette_theme_token or 0")
        out.append("")
        out.append("-- The whole table on every pass: a pass is atomic, never a mixed state.")
        out.append("_G.palette_theme_apply = function()")
        out.append("  for group, colors in pairs(groups) do")
        out.append("    vim.api.nvim_set_hl(0, group, { fg = colors.fg, bg = colors.bg })")
        out.append("  end")
        out.append("end")
        out.append("")
        out.append("-- Apply now, then again next tick: plugins that paint from their own")
        out.append("-- autocmd or vim.schedule() run after us and would otherwise win.")
        out.append("-- A newer trigger bumps the token and cancels the pending pass, so a")
        out.append("-- burst of events settles on exactly one extra apply.")
        out.append("_G.palette_theme_run = function()")
        out.append("  _G.palette_theme_apply()")
        out.append("  _G.palette_theme_token = _G.palette_theme_token + 1")
        out.append("  local token = _G.palette_theme_token")
        out.append("  vim.defer_fn(function()")
        out.append("    if token == _G.palette_theme_token then _G.palette_theme_apply() end")
        out.append("  end, 120)")
        out.append("end")
        out.append("")
        out.append("-- A reload re-runs this file for new colours; it must not register")
        out.append("-- a second watcher or autocmd. It runs both passes like a trigger.")
        out.append("local reloading = _G.palette_theme_reloading")
        out.append("")
        out.append("_G.palette_theme_run()")
        out.append("vim.g.colors_name = \"palette\"")
        out.append("")
        out.append("if not reloading then")
        out.append("  -- Lazy and plugin colorschemes load after init.lua, so re-apply.")
        out.append("  vim.api.nvim_create_augroup(\"PaletteTheme\", { clear = true })")
        out.append("  vim.api.nvim_create_autocmd({ \"VimEnter\", \"ColorScheme\", \"UIEnter\" }, {")
        out.append("    group = \"PaletteTheme\",")
        out.append("    callback = function() _G.palette_theme_run() end,")
        out.append("  })")
        out.append("")
        out.append("  -- Palette rewrites this file on every theme or wallpaper change.")
        out.append("  -- The writes are atomic (a new inode), so watch the directory.")
        out.append("  if not _G.palette_theme_watching then")
        out.append("    _G.palette_theme_watching = true")
        out.append("    local uv = vim.uv or vim.loop")
        out.append("    local source = debug.getinfo(1, \"S\").source")
        out.append("    local file = vim.fn.fnamemodify(")
        out.append("      source:sub(1, 1) == \"@\" and source:sub(2)")
        out.append("        or vim.fn.expand(\"~/.config/palette/theme/nvim.lua\"),")
        out.append("      \":p\")")
        out.append("    local dir = vim.fn.fnamemodify(file, \":h\")")
        out.append("    local base = vim.fn.fnamemodify(file, \":t\")")
        out.append("    local timer, handle = uv.new_timer(), uv.new_fs_event()")
        out.append("    local busy = false")
        out.append("    local function reload()")
        out.append("      if busy then return end")
        out.append("      busy = true")
        out.append("      _G.palette_theme_reloading = true")
        out.append("      local ok, err = pcall(dofile, file)")
        out.append("      _G.palette_theme_reloading = false")
        out.append("      busy = false")
        out.append("      if not ok then")
        out.append("        vim.notify(\"Palette theme reload failed: \" .. tostring(err), vim.log.levels.WARN)")
        out.append("      end")
        out.append("    end")
        out.append("    handle:start(dir, {}, function(err, name)")
        out.append("      if err or name ~= base then return end")
        out.append("      timer:stop()")
        out.append("      timer:start(200, 0, vim.schedule_wrap(reload))")
        out.append("    end)")
        out.append("    vim.api.nvim_create_augroup(\"PaletteThemeWatch\", { clear = true })")
        out.append("    vim.api.nvim_create_autocmd(\"VimLeavePre\", {")
        out.append("      group = \"PaletteThemeWatch\",")
        out.append("      once = true,")
        out.append("      callback = function()")
        out.append("        timer:stop()")
        out.append("        timer:close()")
        out.append("        handle:stop()")
        out.append("        handle:close()")
        out.append("      end,")
        out.append("    })")
        out.append("  end")
        out.append("end")
        return out.joined(separator: "\n") + "\n"
    }

    private static func fish(_ palette: PalettePalette, header: String) -> String {
        var out = [header, ""]
        out.append("set -g fish_color_normal \(palette.foreground)")
        out.append("set -g fish_color_command \(palette.ansi[4])")
        out.append("set -g fish_color_param \(palette.ansi[6])")
        out.append("set -g fish_color_string \(palette.ansi[2])")
        out.append("set -g fish_color_variable \(palette.ansi[5])")
        out.append("set -g fish_color_error \(palette.ansi[1])")
        out.append("set -g fish_color_comment \(palette.muted)")
        out.append("set -g fish_color_keyword \(palette.ansi[5])")
        out.append("set -g fish_color_operator \(palette.ansi[4])")
        out.append("set -g fish_color_escape \(palette.ansi[6])")
        out.append("set -g fish_color_cwd \(palette.ansi[4])")
        out.append("set -g fish_color_git \(palette.ansi[2])")
        out.append("set -g fish_color_selection --background=\(palette.selectionBackground)")
        out.append("set -g fish_color_search_match --background=\(palette.elevated)")
        out.append("set -g fish_color_autosuggestion \(palette.muted)")
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Staleness

/// Generated files an older build left wrong. Launch repairs them once, quietly,
/// so an upgrading user's Neovim stops failing on `#` comments in Lua.
public enum ThemingStaleness {
    public static func reasons(
        themeID: String,
        themeDir: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        var reasons: [String] = []
        let paletteJSON = themeDir.appendingPathComponent(ThemingRenderer.paletteJSONName)
        if !themeID.isEmpty,
           let data = fileManager.contents(atPath: paletteJSON.path),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // A palette.json without theme_id predates the id fix, so the files
            // were generated from an unresolvable display name (Default Dark).
            if let written = object["theme_id"] as? String, written != themeID {
                reasons.append("palette.json theme id '\(written)' does not match '\(themeID)'")
            } else if object["theme_id"] == nil {
                reasons.append("palette.json predates theme ids")
            }
        }
        for target in [ThemingTarget.nvim, .zellij] {
            let url = themeDir.appendingPathComponent(target.fileName)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.first(where: { !$0.isWhitespace }) == "#" else { continue }
            reasons.append("\(target.fileName) still starts with #")
        }
        return reasons
    }
}

// MARK: - Colour math

extension RGBA {
    public var saturation: Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        guard maximum > 0 else { return 0 }
        return (maximum - minimum) / maximum
    }

    /// colorsys.rgb_to_hls.
    var hls: (hue: Double, lightness: Double, saturation: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, lightness, 0) }
        let delta = maximum - minimum
        let saturation = lightness <= 0.5 ? delta / (maximum + minimum) : delta / (2 - maximum - minimum)
        let redPart = (maximum - red) / delta
        let greenPart = (maximum - green) / delta
        let bluePart = (maximum - blue) / delta
        var hue: Double
        if red == maximum {
            hue = bluePart - greenPart
        } else if green == maximum {
            hue = 2 + redPart - bluePart
        } else {
            hue = 4 + greenPart - redPart
        }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return (hue, lightness, saturation)
    }

    /// colorsys.rgb_to_hsv.
    var hsv: (hue: Double, saturation: Double, value: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum
        guard delta != 0 else { return (0, saturation, maximum) }
        let redPart = (maximum - red) / delta
        let greenPart = (maximum - green) / delta
        let bluePart = (maximum - blue) / delta
        var hue: Double
        if red == maximum {
            hue = bluePart - greenPart
        } else if green == maximum {
            hue = 2 + redPart - bluePart
        } else {
            hue = 4 + greenPart - redPart
        }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return (hue, saturation, maximum)
    }

    func mixed(with other: RGBA, amount: Double) -> RGBA {
        let amount = min(1, max(0, amount))
        return RGBA(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            alpha: alpha + (other.alpha - alpha) * amount
        )
    }
}
