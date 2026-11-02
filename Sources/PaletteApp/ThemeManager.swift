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

    public var currentThemeID: String {
        if let overrideName { return overrideName }
        switch selection.mode {
        case .dark: return selection.dark
        case .light: return selection.light
        case .auto: return ""
        }
    }

    public func restore() async {
        guard let store else { return }
        // A `/theme` pick is a live preview, not a persisted override. Config is
        // authoritative on launch, so clear any override saved by older builds.
        if let saved = try? await store.metaValue("theme.override"), !saved.isEmpty {
            overrideName = nil
            try? await store.setMeta("theme.override", value: nil)
            apply()
        }
    }

    public func select(_ name: String) {
        overrideName = name
        apply()
    }

    public func resetToConfig() {
        overrideName = nil
        apply()
        Task { [store] in
            try? await store?.setMeta("theme.override", value: nil)
        }
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
        theme = result.theme
        diagnostics = result.diagnostics
        for diagnostic in result.diagnostics where diagnostic.level != .info {
            Log.shared.warn(diagnostic.message, source: "theme")
        }
        onChange?(theme)
    }

    private static var appearanceIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
