import XCTest
import PaletteCore
import PalettePlatform
@testable import PaletteApp

/// While wallpaper colours own the palette, a theme apply is refused with one
/// message and no write. The deck's `Wallpaper colours | Theme colours` control
/// is the explicit way out, and it must not race itself.
final class WallpaperSourceGuardTests: XCTestCase {
    private func config(source: ThemingSource = .wallpaper) -> PaletteConfig {
        var config = PaletteConfig()
        config.theming.enabled = true
        config.theming.source = source
        config.theming.theme = "catppuccin-mocha"
        config.theme = ThemeSelection(dark: "catppuccin-mocha", light: "catppuccin-latte")
        return config
    }

    private func themeError(_ reason: String) -> ThemingEngine.ApplyResult {
        ThemingEngine.ApplyResult(
            status: reason,
            source: "theme",
            appearance: "dark",
            written: [],
            skipped: [],
            includeLines: [],
            notices: [],
            changes: [],
            targets: [],
            error: reason
        )
    }

    // MARK: - Refusal matrix

    /// Every route asks the same question: `/theme`, `/theme apply`, Settings'
    /// Use Theme, the deck's card guard and Settings' auto-save.
    @MainActor
    func testEveryThemeRouteRefusesWhileWallpaperOwnsThePalette() {
        let routes: [(String, (ThemingSource) -> String?)] = [
            ("/theme pick", { ThemingSourceGuard.refusal(source: $0) }),
            ("/theme apply", { ThemingSourceGuard.refusal(source: $0) }),
            ("Settings Use Theme", { ThemingSourceGuard.refusal(source: $0) }),
            ("deck card", { ThemingSourceGuard.blockedReason(source: $0, target: .theme("x")) }),
            ("Settings save", { source in
                let current = self.config(source: source)
                var updated = current
                updated.theme = ThemeSelection(dark: "siri-silver")
                return AppDelegate.settingsThemeApplyRefusal(current: current, updated: updated)
            }),
        ]

        for (name, refusal) in routes {
            XCTAssertEqual(
                refusal(.wallpaper),
                "Wallpaper colours are enabled — switch Palette source to Theme "
                    + "(Settings → Theming, or the Wallpaper deck toggle) to pick a theme.",
                "\(name) must refuse with the shared message"
            )
            XCTAssertNil(refusal(.theme), "\(name) must apply under theme colours")
        }
    }

    /// A refused Settings save returns before the config write, so the file and
    /// the source stay exactly as they were.
    @MainActor
    func testRefusedSettingsSaveLeavesTheConfigAlone() {
        let current = config(source: .wallpaper)
        var updated = current
        updated.theme = ThemeSelection(dark: "siri-silver")

        let refusal = AppDelegate.settingsThemeApplyRefusal(current: current, updated: updated)
        XCTAssertEqual(refusal, ThemingSourceGuard.refusalMessage)
        XCTAssertEqual(current.theming.source, .wallpaper)
        XCTAssertNotEqual(updated.theme, current.theme)

        // A change that is not a theme apply still saves.
        var settingsOnly = current
        settingsOnly.searchPlaceholder = "Ask anything"
        XCTAssertNil(AppDelegate.settingsThemeApplyRefusal(current: current, updated: settingsOnly))

        // A save that also switches the source away from wallpaper is allowed.
        var switching = updated
        switching.theming.source = .theme
        XCTAssertNil(AppDelegate.settingsThemeApplyRefusal(current: current, updated: switching))
    }

    @MainActor
    func testWallpaperCardStillAppliesAndNoLongerPhotographsTheSource() {
        // The guard is about themes: a wallpaper card is never refused.
        XCTAssertNil(
            ThemingSourceGuard.blockedReason(source: .wallpaper, target: .wallpaper)
        )
        XCTAssertNil(
            ThemingSourceGuard.blockedReason(
                source: .wallpaper,
                target: .wallpaperFile("/tmp/wall.png")
            )
        )
    }

    // MARK: - Deck toggle

    @MainActor
    func testSwitchToThemeColoursPersistsTheSourceAndAppliesTheTheme() async {
        var saved: PaletteConfig?
        var ownTheme: [String] = []
        var crossApp: [String] = []
        var wallpaperRuns = 0
        let switcher = ThemingSourceSwitcher()
        let before = config(source: .wallpaper)

        let result = await switcher.switchSource(
            to: .theme,
            themeName: "catppuccin-mocha",
            config: before,
            saveConfig: { saved = $0 },
            applyOwnTheme: { ownTheme.append($0) },
            applyTheme: { name in
                crossApp.append(name)
                return .empty
            },
            applyWallpaper: {
                wallpaperRuns += 1
                return .empty
            }
        )

        XCTAssertEqual(saved?.theming.source, .theme, "the source is written first")
        XCTAssertEqual(result?.config.theming.source, .theme)
        XCTAssertEqual(ownTheme, ["catppuccin-mocha"])
        XCTAssertEqual(crossApp, ["catppuccin-mocha"])
        XCTAssertEqual(wallpaperRuns, 0)
        XCTAssertEqual(result?.outcome.message, "Theme colours applied")
        XCTAssertFalse(result?.outcome.failed ?? true)

        // Theme cards become applicable at once, without reopening the deck.
        let model = ThemeGalleryModel(deck: ThemeCardDeck(cards: [
            .theme(ThemeInfo(name: "catppuccin-mocha", displayName: "Catppuccin Mocha", appearance: "dark", isBuiltin: true)),
        ]))
        model.paletteSource = result?.config.theming.source ?? .wallpaper
        XCTAssertNil(model.blockedApplyReason)
    }

    @MainActor
    func testSwitchToWallpaperColoursPersistsTheSourceAndAppliesTheDesktopPalette() async {
        var saved: PaletteConfig?
        var ownTheme = 0
        var wallpaperRuns = 0
        let switcher = ThemingSourceSwitcher()

        let result = await switcher.switchSource(
            to: .wallpaper,
            themeName: "catppuccin-mocha",
            config: config(source: .theme),
            saveConfig: { saved = $0 },
            applyOwnTheme: { _ in ownTheme += 1 },
            applyTheme: { _ in .empty },
            applyWallpaper: {
                wallpaperRuns += 1
                return .empty
            }
        )

        XCTAssertEqual(saved?.theming.source, .wallpaper, "the source is written first")
        XCTAssertEqual(result?.config.theming.source, .wallpaper)
        XCTAssertEqual(wallpaperRuns, 1, "the desktop palette is applied once")
        XCTAssertEqual(ownTheme, 0, "a wallpaper switch does not apply a theme")
        XCTAssertEqual(result?.outcome.message, "Wallpaper colours applied")
        XCTAssertFalse(result?.outcome.failed ?? true)
    }

    @MainActor
    func testSwitchErrorsSurfaceInsteadOfBeingSwallowed() async {
        let switcher = ThemingSourceSwitcher()
        let result = await switcher.switchSource(
            to: .theme,
            themeName: "catppuccin-mocha",
            config: config(source: .wallpaper),
            saveConfig: { _ in },
            applyOwnTheme: { _ in },
            applyTheme: { _ in self.themeError("Theme file is unreadable.") },
            applyWallpaper: { .empty }
        )

        XCTAssertTrue(result?.outcome.failed ?? false)
        XCTAssertEqual(result?.outcome.message, "Theme file is unreadable.")
    }

    @MainActor
    func testAFailedSaveAppliesNothingAndKeepsTheOldSource() async {
        var applies = 0
        let switcher = ThemingSourceSwitcher()
        let before = config(source: .theme)
        let result = await switcher.switchSource(
            to: .wallpaper,
            themeName: "catppuccin-mocha",
            config: before,
            saveConfig: { _ in throw CocoaError(.fileWriteNoPermission) },
            applyOwnTheme: { _ in },
            applyTheme: { _ in
                applies += 1
                return .empty
            },
            applyWallpaper: {
                applies += 1
                return .empty
            }
        )

        XCTAssertEqual(applies, 0)
        XCTAssertEqual(result?.config, before, "the config is untouched")
        XCTAssertTrue(result?.outcome.failed ?? false)
    }

    /// A second press while the first switch is working is ignored: no second
    /// save and no second apply.
    @MainActor
    func testReEntryIsIgnoredWhileASwitchIsRunning() async {
        let switcher = ThemingSourceSwitcher()
        var saves = 0
        let started = expectation(description: "wallpaper apply started")
        let release = ContinuationBox()

        let first = Task { @MainActor in
            await switcher.switchSource(
                to: .wallpaper,
                themeName: "catppuccin-mocha",
                config: self.config(source: .theme),
                saveConfig: { _ in saves += 1 },
                applyOwnTheme: { _ in },
                applyTheme: { _ in .empty },
                applyWallpaper: {
                    await withCheckedContinuation { continuation in
                        release.store(continuation)
                        started.fulfill()
                    }
                    return .empty
                }
            )
        }

        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(switcher.isSwitching)

        let second = await switcher.switchSource(
            to: .theme,
            themeName: "catppuccin-mocha",
            config: config(source: .theme),
            saveConfig: { _ in saves += 1 },
            applyOwnTheme: { _ in },
            applyTheme: { _ in .empty },
            applyWallpaper: { .empty }
        )

        XCTAssertNil(second, "the second press is ignored")
        XCTAssertEqual(saves, 1, "nothing is written twice")

        release.resume()
        _ = await first.value
        XCTAssertFalse(switcher.isSwitching)
    }
}

/// Holds the continuation for the re-entry test without data races.
@MainActor
private final class ContinuationBox {
    private var continuation: CheckedContinuation<Void, Never>?

    func store(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
