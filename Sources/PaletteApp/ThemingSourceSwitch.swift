import PaletteCore
import PalettePlatform

/// The deck's `Wallpaper colours | Theme colours` control. Switching source is
/// the explicit intent that lets a theme apply run while leaving wallpaper
/// mode, so both effects live here. One switch at a time: a second press while
/// the first is working is ignored instead of racing two applies.
@MainActor
final class ThemingSourceSwitcher {
    private(set) var isSwitching = false

    /// Returns nil when a switch was already in flight.
    func switchSource(
        to source: ThemingSource,
        themeName: String,
        config: PaletteConfig,
        saveConfig: (PaletteConfig) throws -> Void,
        applyOwnTheme: (String) -> Void,
        applyTheme: (String) async -> ThemingEngine.ApplyResult,
        applyWallpaper: () async -> ThemingEngine.ApplyResult
    ) async -> (outcome: ThemeGalleryApplyOutcome, config: PaletteConfig)? {
        guard !isSwitching else { return nil }
        isSwitching = true
        defer { isSwitching = false }

        var next = config
        next.theming.source = source
        do {
            try saveConfig(next)
        } catch {
            // Nothing changed yet, so the old source stays in force.
            return (
                ThemeGalleryApplyOutcome(
                    message: "Could not save the palette source: \(error.localizedDescription)",
                    failed: true
                ),
                config
            )
        }

        let message: String
        let failed: Bool
        switch source {
        case .wallpaper:
            let result = await applyWallpaper()
            message = result.error ?? "Wallpaper colours applied"
            failed = result.error != nil
        case .theme:
            applyOwnTheme(themeName)
            let result = await applyTheme(themeName)
            message = result.error ?? "Theme colours applied"
            failed = result.error != nil
        }
        return (ThemeGalleryApplyOutcome(message: message, failed: failed), next)
    }
}
