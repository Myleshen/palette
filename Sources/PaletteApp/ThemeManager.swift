import AppKit
import Combine
import Foundation
import PaletteCore
import PalettePlatform

@MainActor
public final class ThemeManager: ObservableObject {
    @Published public private(set) var theme: Theme
    @Published public private(set) var diagnostics: [Diagnostic] = []
    @Published public private(set) var overrideName: String?

    public let paths: PalettePaths
    public var selection: ThemeSelection
    public var typography = TypographyConfig()
    public var searchPlaceholder = ""
    public var onChange: ((Theme) -> Void)?

    private let store: PaletteStore?

    public init(paths: PalettePaths, selection: ThemeSelection, store: PaletteStore?) {
        self.paths = paths
        self.selection = selection
        self.store = store
        let appearanceDark = ThemeManager.appearanceIsDark
        let fallback = appearanceDark ? Theme.defaultDark : Theme.defaultLight
        let name: String
        switch selection.mode {
        case .dark: name = selection.dark
        case .light: name = selection.light
        case .auto: name = appearanceDark ? selection.dark : selection.light
        }
        let result = ThemeLoader.load(name: name, themesDirectory: paths.themesDir, fallback: fallback)
        self.theme = result.theme
        self.diagnostics = result.diagnostics
    }

    /// The theme actually on screen: resolves `.auto` to the theme it picked
    /// and a previewed theme to itself, so `/theme` can mark it.
    public var currentThemeID: String { theme.name }

    public func restore() async {
        guard let store else { return }
        // Older builds used this meta key for a preview. The `/theme` pick is
        // persisted into config now, so drop the stale key and leave config as
        // the only source of truth.
        if (try? await store.metaValue("theme.override")) != nil {
            overrideName = nil
            try? await store.setMeta("theme.override", value: nil)
        }
    }

    public func select(_ name: String) {
        overrideName = name
        apply()
    }

    public func resetToConfig() {
        overrideName = nil
        apply()
    }

    /// A config save is authoritative: a live `/theme` pick must not shadow it.
    public func updateSelection(_ selection: ThemeSelection) {
        let changed = selection != self.selection
        self.selection = selection
        if changed, overrideName != nil {
            resetToConfig()
        } else {
            apply()
        }
    }

    public func reload() {
        apply()
    }

    public func systemAppearanceChanged() {
        guard overrideName == nil, selection.mode == .auto else { return }
        apply()
    }

    private func apply() {
        let appearanceDark = ThemeManager.appearanceIsDark
        let name: String
        if let overrideName {
            name = overrideName
        } else {
            switch selection.mode {
            case .dark: name = selection.dark
            case .light: name = selection.light
            case .auto: name = appearanceDark ? selection.dark : selection.light
            }
        }
        let fallback = appearanceDark ? Theme.defaultDark : Theme.defaultLight
        let result = ThemeLoader.load(name: name, themesDirectory: paths.themesDir, fallback: fallback)
        var resolved = result.theme
        var diagnostics = result.diagnostics
        if !typography.uiFamily.isEmpty {
            resolved.typography.family = typography.uiFamily
            if !Self.fontExists(typography.uiFamily) {
                diagnostics.append(Diagnostic(.warning, "Font '\(typography.uiFamily)' is not installed; using the system font.", source: "theme"))
            }
        }
        if !typography.monoFamily.isEmpty {
            resolved.typography.mono = typography.monoFamily
            if !Self.fontExists(typography.monoFamily) {
                diagnostics.append(Diagnostic(.warning, "Mono font '\(typography.monoFamily)' is not installed; using the system font.", source: "theme"))
            }
        }
        if !searchPlaceholder.isEmpty {
            resolved.search.placeholder = searchPlaceholder
        }
        if typography.uiSize > 0 {
            resolved.typography.size = typography.uiSize
            resolved.typography.subtitleSize = max(9, typography.uiSize - 2)
        }
        if typography.monoSize > 0 {
            resolved.typography.monoSize = typography.monoSize
        }
        theme = resolved
        self.diagnostics = diagnostics
        // The status-bar and main menus have no palette, so AppKit only gets the
        // theme's light/dark. Panels keep their own per-window appearance.
        NSApp.appearance = NSAppearance(named: resolved.appearance == "light" ? .aqua : .darkAqua)
        for diagnostic in diagnostics where diagnostic.level != .info {
            Log.shared.warn(diagnostic.message, source: "theme")
        }
        onChange?(theme)
    }

    private static func fontExists(_ family: String) -> Bool {
        let name = family.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "System", name != "SF Pro Text" else { return true }
        return NSFont(name: name, size: 14) != nil
            || NSFontManager.shared.availableFontFamilies.contains(name)
    }

    /// `apply()` pins `NSApp.appearance` to the theme, so the system pref has to
    /// be read directly or auto mode would freeze on the last applied theme.
    private static var appearanceIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }
}
