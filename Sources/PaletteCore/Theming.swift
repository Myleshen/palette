import AppKit
import Foundation
import TOMLKit

// MARK: - Config

public enum ThemingSource: String, Sendable, Equatable, CaseIterable {
    case theme
    case wallpaper
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

    public init(
        enabled: Bool = false,
        source: ThemingSource = .theme,
        theme: String = "",
        followWallpaper: Bool = false,
        targets: [String] = ThemingTarget.phaseOne.map(\.rawValue),
        darkMode: String = "auto"
    ) {
        self.enabled = enabled
        self.source = source
        self.theme = theme
        self.followWallpaper = followWallpaper
        self.targets = targets
        self.darkMode = darkMode
    }

    public static let defaults = ThemingConfig()

    public func normalized() -> ThemingConfig {
        var value = self
        let known = Set(ThemingTarget.allCases.map(\.rawValue))
        var seen = Set<String>()
        value.targets = targets.filter { known.contains($0) && seen.insert($0).inserted }
        if !["auto", "dark", "light"].contains(value.darkMode) {
            value.darkMode = "auto"
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
        out.append("follow_wallpaper = \(value.followWallpaper)")
        out.append("# auto | dark | light")
        out.append("dark_mode = \"\(value.darkMode)\"")
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
    case neovide

    public var id: String { rawValue }

    public static let phaseOne: [ThemingTarget] = [.kitty, .ghostty, .zellij, .nvim, .fish, .starship]
    public static let phaseTwo: [ThemingTarget] = [.bat, .delta, .btop, .yazi]
    /// First-class entries that have no safe renderer yet. They stay visible so
    /// the gap is explicit instead of looking like the app is unsupported.
    public static let notYet: [ThemingTarget] = [.arc, .vscode, .zed, .neovide]
    public static let browsers: [ThemingTarget] = [.helium, .chrome, .edge, .brave, .vivaldi, .chromium, .arc]

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
        case .neovide: return "Neovide"
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
        case .starship: return "starship.toml"
        case .bat: return "bat.tmTheme"
        case .delta: return "gitconfig-delta"
        case .btop: return "btop.theme"
        case .yazi: return "yazi.toml"
        case .vscode: return "vscode.json"
        case .zed: return "zed.json"
        case .neovide: return "neovide.toml"
        default: return "\(rawValue).txt"
        }
    }

    public var isImplemented: Bool {
        if let browser { return browser.supportsThemePolicy }
        switch self {
        case .kitty, .ghostty, .zellij, .nvim, .fish, .starship, .bat, .delta, .btop, .yazi:
            return true
        case .vscode, .zed, .neovide:
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
        case .neovide: return "Covered by Neovim — no separate file."
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
            return "dofile(vim.fn.expand(\"~/.config/palette/theme/nvim.lua\"))"
        case .fish:
            return "source ~/.config/palette/theme/fish.fish"
        case .starship:
            return "Copy [palettes.palette] from ~/.config/palette/theme/starship.toml into starship.toml, then set palette = \"palette\""
        case .bat:
            return "Symlink ~/.config/palette/theme/bat.tmTheme into $(bat --config-dir)/themes/ and set BAT_THEME=\"palette\""
        case .delta:
            return "[include]\n    path = ~/.config/palette/theme/gitconfig-delta"
        case .btop:
            return "Copy ~/.config/palette/theme/btop.theme to ~/.config/btop/themes/palette.theme and set color_theme = \"palette\""
        case .yazi:
            return "Copy ~/.config/palette/theme/yazi.toml to ~/.config/yazi/theme.toml"
        case .vscode, .zed, .neovide:
            return unavailableReason ?? "Not configured yet."
        default:
            return unavailableReason ?? "Not configured yet."
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
        let hues = colors.map { readable($0, on: background, minimum: 2.5) }
        let bright = hues.map { $0.mixed(with: foreground, amount: 0.3) }
        let black = readable(background.mixed(with: foreground, amount: 0.12), on: background, minimum: 1.4)
        let brightBlack = readable(background.mixed(with: foreground, amount: 0.38), on: background, minimum: 1.7)
        let white = readable(foreground.mixed(with: background, amount: 0.14), on: background, minimum: 3)
        let brightWhite = readable(foreground, on: background, minimum: 4.5)
        var values = [black] + hues + [white, brightBlack] + bright + [brightWhite]
        values = values.enumerated().map { index, color in
            // Black slots are supposed to be dim; text slots must stay legible.
            index == 0 || index == 8 ? color : readable(color, on: background, minimum: 2.5)
        }
        return values.map(hex)
    }

    static func sixteen(_ values: [String]) -> [String] {
        var values = values
        while values.count < 16 {
            values.append(values.last ?? "#ffffff")
        }
        return Array(values.prefix(16))
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
        appearance: String = "dark"
    ) -> PalettePalette? {
        guard let pixels = pixels(from: image) else { return nil }
        return extract(pixels: pixels, appearance: appearance)
    }

    /// Pure: k-means over the sampled pixels, background by luminance for the
    /// requested appearance, foreground and accent by contrast.
    public static func extract(pixels: WallpaperPixels, appearance: String = "dark") -> PalettePalette? {
        let opaque = pixels.pixels.filter { $0.alpha > 0.5 }
        guard !opaque.isEmpty else { return nil }
        let clusters = kmeans(opaque, k: 6)
        guard !clusters.isEmpty else { return nil }

        let sorted = clusters.sorted { $0.center.luminance < $1.center.luminance }
        let backdrop = appearance == "light" ? sorted.last! : sorted.first!
        let background = backdrop.center
        let foreground = readable(bestText(on: background), on: background, minimum: 4.5)

        let accentCluster = clusters
            .filter { $0.center.contrast(with: background) >= 2 }
            .max { lhs, rhs in
                (lhs.center.saturation * sqrt(lhs.weight)) < (rhs.center.saturation * sqrt(rhs.weight))
            }
        let accent = readable(accentCluster?.center ?? foreground, on: background, minimum: 3)
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
            ansi: PalettePalette.ansi(
                background: background,
                foreground: foreground,
                appearance: appearance,
                colors: [
                    RGBA(red: 0.85, green: 0.35, blue: 0.38),
                    RGBA(red: 0.45, green: 0.76, blue: 0.52),
                    RGBA(red: 0.87, green: 0.75, blue: 0.40),
                    RGBA(red: 0.40, green: 0.62, blue: 0.95),
                    accent,
                    RGBA(red: 0.42, green: 0.75, blue: 0.82),
                ]
            )
        )
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
        var weight: Double
    }

    /// Deterministic k-means: seeds come from luminance quantiles, so the same
    /// wallpaper always produces the same palette.
    static func kmeans(_ pixels: [RGBA], k: Int, iterations: Int = 10) -> [Cluster] {
        guard !pixels.isEmpty, k > 0 else { return [] }
        let ordered = pixels.sorted { $0.luminance < $1.luminance }
        var centers: [RGBA] = (0..<k).map { index in
            let position = Int((Double(index) + 0.5) / Double(k) * Double(ordered.count - 1))
            return ordered[position]
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
        let total = Double(pixels.count)
        return centers.enumerated().compactMap { index, center in
            guard counts[index] > 0 else { return nil }
            return Cluster(center: center, weight: Double(counts[index]) / total)
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
    public var policyPlistPath: String { "/Library/Managed Preferences/\(bundleID).plist" }
    public var targetTitle: String { "\(name) (managed policy)" }

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

    public static func installCommand(paths: [String]) -> String {
        paths.map { "sudo profiles install -path \(token($0))" }.joined(separator: " && ")
    }

    public static func removeCommand(identifiers: [String]) -> String {
        identifiers.map { "sudo profiles remove -identifier \(token($0))" }.joined(separator: " && ")
    }

    public enum InstallFlow: String, Sendable, Equatable {
        /// macOS 27 removed `profiles install`; the profile is opened in
        /// System Settings and approved there.
        case systemSettings
        /// Older macOS still advertises `profiles install`, so the sudo form
        /// stays available as a legacy note and for removal.
        case legacyProfiles
    }

    public static func installFlow(majorVersion: Int) -> InstallFlow {
        majorVersion >= 27 ? .systemSettings : .legacyProfiles
    }

    /// The line shown after `open` handed the files to System Settings.
    public static func installSteps(files: [String]) -> String {
        "Opened \(files.count) profile file\(files.count == 1 ? "" : "s") in System Settings. " +
            "Approve each under General → Device Management → Profiles, then Refresh. " +
            "macOS 27 removed `profiles install`; no password prompt is needed here."
    }

    /// One seed colour per browser; Chromium derives the rest.
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
              <string>5E3C2F6A-9B7D-4C1E-8A2F-7D4B6C9E1A30</string>
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
          <string>8B1D4E7C-3A62-4F90-B5C8-1E9A7D3F6C42</string>
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
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Renderers

public struct PaletteMetadata: Sendable, Equatable {
    public var source: String
    public var theme: String
    public var appearance: String
    public var generatedAt: Date
    public var targets: [String]

    public init(
        source: String,
        theme: String,
        appearance: String,
        generatedAt: Date = Date(),
        targets: [String] = []
    ) {
        self.source = source
        self.theme = theme
        self.appearance = appearance
        self.generatedAt = generatedAt
        self.targets = targets
    }

    public var header: String {
        let stamp = ISO8601DateFormatter().string(from: generatedAt)
        return [
            "# generated by Palette — do not edit",
            "# source: \(source)\(theme.isEmpty ? "" : " · \(theme)") · \(appearance) · \(stamp)",
        ].joined(separator: "\n")
    }
}

public enum ThemingRenderer {
    public static let paletteJSONName = "palette.json"

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
        case .zellij: return zellij(palette, header: header)
        case .nvim: return nvim(palette, header: header)
        case .fish: return fish(palette, header: header)
        case .starship: return starship(palette, header: header)
        case .bat: return bat(palette, header: header)
        case .delta: return delta(palette, header: header)
        case .btop: return btop(palette, header: header)
        case .yazi: return yazi(palette, header: header)
        case .vscode, .zed, .helium, .chrome, .edge, .brave, .vivaldi, .chromium, .arc, .neovide:
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
        var out = [xmlHeader]
        out.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
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
        out.append("    minus-emph-style = normal \"\(palette.ansi[1])\"")
        out.append("    plus-style = syntax \"\(palette.background)\"")
        out.append("    plus-emph-style = normal \"\(palette.ansi[2])\"")
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
            ("download", palette.ansi[2]),
            ("upload", palette.ansi[1]),
        ]
        for (key, value) in entries {
            out.append("theme[\(key)]=\"\(value)\"")
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func yazi(_ palette: PalettePalette, header: String) -> String {
        var out = [header, ""]
        out.append("[manager]")
        out.append("cwd = { fg = \"\(palette.ansi[4])\" }")
        out.append("hovered = { fg = \"\(palette.selectionForeground)\", bg = \"\(palette.selectionBackground)\" }")
        out.append("preview_title = { fg = \"\(palette.ansi[5])\", bold = true }")
        out.append("preview = { fg = \"\(palette.foreground)\", bg = \"\(palette.surface)\" }")
        out.append("border_style = { fg = \"\(palette.border)\" }")
        out.append("")
        out.append("[status]")
        out.append("mode_normal = { fg = \"\(palette.background)\", bg = \"\(palette.ansi[4])\", bold = true }")
        out.append("mode_select = { fg = \"\(palette.background)\", bg = \"\(palette.ansi[3])\", bold = true }")
        out.append("mode_unset = { fg = \"\(palette.background)\", bg = \"\(palette.muted)\", bold = true }")
        out.append("progress_label = { fg = \"\(palette.foreground)\" }")
        out.append("")
        out.append("[which]")
        out.append("cand = { fg = \"\(palette.ansi[6])\" }")
        out.append("desc = { fg = \"\(palette.muted)\" }")
        out.append("")
        out.append("[filetype]")
        out.append("rules = [")
        out.append("  { mime = \"image/*\", fg = \"\(palette.ansi[5])\" },")
        out.append("  { mime = \"video/*\", fg = \"\(palette.ansi[1])\" },")
        out.append("  { mime = \"application/zip\", fg = \"\(palette.ansi[3])\" },")
        out.append("]")
        return out.joined(separator: "\n") + "\n"
    }

    public static func paletteJSON(palette: PalettePalette, metadata: PaletteMetadata) -> String {
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "source": metadata.source,
            "theme": metadata.theme,
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
        out.append("    }")
        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }

    private static func nvim(_ palette: PalettePalette, header: String) -> String {
        var out = [header, ""]
        out.append("local p = {")
        out.append("  bg = \"\(palette.background)\", fg = \"\(palette.foreground)\",")
        out.append("  surface = \"\(palette.surface)\", elevated = \"\(palette.elevated)\",")
        out.append("  border = \"\(palette.border)\", muted = \"\(palette.muted)\",")
        out.append("  cursor = \"\(palette.cursor)\", selection = \"\(palette.selectionBackground)\",")
        out.append("  red = \"\(palette.ansi[1])\", green = \"\(palette.ansi[2])\",")
        out.append("  yellow = \"\(palette.ansi[3])\", blue = \"\(palette.ansi[4])\",")
        out.append("  magenta = \"\(palette.ansi[5])\", cyan = \"\(palette.ansi[6])\",")
        out.append("}")
        out.append("")
        out.append("vim.g.colors_name = \"palette\"")
        out.append("local function hl(group, fg, bg)")
        out.append("  vim.api.nvim_set_hl(0, group, { fg = fg, bg = bg })")
        out.append("end")
        out.append("hl(\"Normal\", p.fg, p.bg)")
        out.append("hl(\"NormalFloat\", p.fg, p.surface)")
        out.append("hl(\"Cursor\", p.bg, p.cursor)")
        out.append("hl(\"CursorLine\", nil, p.surface)")
        out.append("hl(\"LineNr\", p.muted, p.bg)")
        out.append("hl(\"Visual\", p.fg, p.selection)")
        out.append("hl(\"Search\", p.bg, p.yellow)")
        out.append("hl(\"StatusLine\", p.fg, p.elevated)")
        out.append("hl(\"Pmenu\", p.fg, p.surface)")
        out.append("hl(\"PmenuSel\", p.bg, p.cursor)")
        out.append("hl(\"Comment\", p.muted)")
        out.append("hl(\"Constant\", p.magenta)")
        out.append("hl(\"String\", p.green)")
        out.append("hl(\"Function\", p.blue)")
        out.append("hl(\"Keyword\", p.magenta)")
        out.append("hl(\"Type\", p.cyan)")
        out.append("hl(\"Error\", p.red)")
        out.append("hl(\"WarningMsg\", p.yellow)")
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

    private static func starship(_ palette: PalettePalette, header: String) -> String {
        let names = ["black", "red", "green", "yellow", "blue", "purple", "cyan", "white"]
        var out = [header, "", "[palettes.palette]"]
        for (index, name) in names.enumerated() {
            out.append("\(name) = \"\(palette.ansi[index])\"")
        }
        out.append("bg = \"\(palette.background)\"")
        out.append("fg = \"\(palette.foreground)\"")
        out.append("accent = \"\(palette.cursor)\"")
        out.append("muted = \"\(palette.muted)\"")
        for (index, name) in names.enumerated() {
            out.append("bright-\(name) = \"\(palette.ansi[index + 8])\"")
        }
        return out.joined(separator: "\n") + "\n"
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
