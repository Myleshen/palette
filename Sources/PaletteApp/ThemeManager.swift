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
    /// The theme being loaded, once that has taken longer than 100 ms, so a
    /// visible UI can say "Applying theme…" instead of looking stuck.
    @Published public private(set) var applyingTheme: String?
    /// Called the same way as `applyingTheme`, for surfaces without a binding.
    public var onSlowApply: ((String) -> Void)?

    public let paths: PalettePaths
    public var selection: ThemeSelection
    public var typography = TypographyConfig()
    public var searchPlaceholder = ""
    public var onChange: ((Theme) -> Void)?

    private let store: PaletteStore?
    private var applyTask: Task<Void, Never>?
    private var slowApplyTask: Task<Void, Never>?
    private var generation = 0

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

    /// The file id of the theme on screen, not its display name: `.auto` and a
    /// live preview resolve to the id a config write or another app can load.
    public var currentThemeID: String {
        let reference: String
        if let overrideName {
            reference = overrideName
        } else {
            switch selection.mode {
            case .dark: reference = selection.dark
            case .light: reference = selection.light
            case .auto: reference = Self.appearanceIsDark ? selection.dark : selection.light
            }
        }
        return ThemeLoader.themeID(for: reference, themesDirectory: paths.themesDir) ?? reference
    }

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

    /// Applies a picked theme. `completion` runs after the load finishes, on
    /// the main actor, so a caller that needs the resolved appearance (the
    /// `/theme` config write) does not have to load the theme twice.
    public func select(_ name: String, completion: ((Theme) -> Void)? = nil) {
        overrideName = name
        apply(completion: completion)
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

    /// Parsing runs off the main actor; the resolved theme is applied back on
    /// it. A newer call wins over an older one that finishes late, so typing in
    /// a typography field cannot apply themes out of order.
    private func apply(completion: ((Theme) -> Void)? = nil) {
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
        let directory = paths.themesDir
        let typography = self.typography
        let placeholder = searchPlaceholder
        generation += 1
        let token = generation
        applyTask?.cancel()
        slowApplyTask?.cancel()
        applyTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ThemeLoader.load(name: name, themesDirectory: directory, fallback: fallback)
            }.value
            guard !Task.isCancelled, let self, token == self.generation else { return }
            self.slowApplyTask?.cancel()
            self.slowApplyTask = nil
            self.applyingTheme = nil
            self.finish(result, typography: typography, placeholder: placeholder, completion: completion)
        }
        slowApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self, token == self.generation else { return }
            self.applyingTheme = name
            self.onSlowApply?(name)
        }
    }

    private func finish(
        _ result: ThemeLoadResult,
        typography: TypographyConfig,
        placeholder: String,
        completion: ((Theme) -> Void)?
    ) {
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
        if !placeholder.isEmpty {
            resolved.search.placeholder = placeholder
        }
        if typography.uiSize > 0 {
            resolved.typography.size = typography.uiSize
            resolved.typography.subtitleSize = max(9, typography.uiSize - 2)
        }
        if typography.monoSize > 0 {
            resolved.typography.monoSize = typography.monoSize
        }
        if typography.previewSize > 0 {
            resolved.typography.previewSize = typography.previewSize
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
        completion?(theme)
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
