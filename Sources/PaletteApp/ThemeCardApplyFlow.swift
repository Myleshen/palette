import PaletteCore
import PalettePlatform

/// One wallpaper card's apply, with its effects injected. The deck and the
/// tests run the same three steps in the same order: the picture first, then
/// the config's source, then a single palette run for Palette and, when the
/// master switch is on, the generated app files.
@MainActor
enum ThemeCardApplyFlow {
    static func wallpaperFile(
        path: String,
        name: String,
        config: PaletteConfig,
        setDesktopPicture: (String) -> Bool,
        saveConfig: (PaletteConfig) throws -> Void,
        applyPalette: (ThemingConfig) async -> ThemingEngine.ApplyResult
    ) async -> (outcome: ThemeGalleryApplyOutcome, config: PaletteConfig) {
        guard setDesktopPicture(path) else {
            return (
                ThemeGalleryApplyOutcome(
                    message: "Could not set \(name) as the desktop picture.",
                    failed: true
                ),
                config
            )
        }
        var next = config
        next.theming = WallpaperCardPolicy.wallpaperConfig(from: config.theming)
        do {
            try saveConfig(next)
        } catch {
            // The picture is already on the desktop; the next config write
            // repairs the source rather than undoing the apply.
            Log.shared.warn(
                "Could not save the palette source: \(error.localizedDescription)",
                source: "theming"
            )
        }
        let result = await applyPalette(next.theming)
        let outcome = ThemeGalleryApplyOutcome(
            message: result.error.map { WallpaperCardPolicy.failedMessage(name: name, reason: $0) }
                ?? WallpaperCardPolicy.appliedMessage(name: name),
            failed: result.error != nil
        )
        return (outcome, next)
    }
}
