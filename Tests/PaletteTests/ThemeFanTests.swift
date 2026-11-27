import AppKit
import XCTest
@testable import PaletteCore
import PalettePlatform
import TOMLKit

/// The fanned hand: geometry, filtering, favourites, the wallpaper group and
/// the routes an Enter takes. AppKit is only used to make a tiny real picture.
final class ThemeFanTests: XCTestCase {
    private var root: URL!

    private var bundledDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-theme-fan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func info(_ name: String, _ displayName: String, builtin: Bool = true) -> ThemeInfo {
        ThemeInfo(name: name, displayName: displayName, appearance: "dark", isBuiltin: builtin)
    }

    private var sampleCatalog: ThemeBrowserCatalog {
        ThemeBrowserCatalog(themes: [
            info("ghostty-dracula", "Ghostty · Dracula"),
            info("omarchy-nord", "Omarchy · Nord"),
            info("ghostty-nord", "Ghostty · Nord"),
            info("my-blue", "My Blue", builtin: false),
        ])
    }

    private func writeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        return url
    }

    private func writePNG(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let data = try XCTUnwrap(representation?.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }

    // MARK: - Fan geometry

    func testFanGeometryOffsetsAndRotations() {
        let geometry = ThemeCardFanGeometry.standard
        let centre = geometry.placement(relative: 0)
        XCTAssertEqual(centre.x, 0)
        XCTAssertEqual(centre.y, -geometry.selectedLift)
        XCTAssertEqual(centre.rotation, 0)
        XCTAssertEqual(centre.scale, 1)
        XCTAssertEqual(centre.dim, 0)
        XCTAssertEqual(centre.zIndex, 1000)

        let right = geometry.placement(relative: 1)
        XCTAssertEqual(right.x, geometry.stepX)
        XCTAssertEqual(right.y, geometry.arcDrop)
        XCTAssertEqual(right.rotation, 6)
        XCTAssertEqual(right.scale, 0.85)
        XCTAssertEqual(right.dim, 0.35, accuracy: 0.0001)

        let left = geometry.placement(relative: -1)
        XCTAssertEqual(left.x, -geometry.stepX)
        XCTAssertEqual(left.rotation, -6)

        // Four steps would be 24° uncapped; the hand stops at 15° and the arc
        // stops at maxDrop so the outer cards stay on screen.
        let far = geometry.placement(relative: 4)
        XCTAssertEqual(far.rotation, geometry.maxRotation)
        XCTAssertEqual(far.y, geometry.maxDrop)
        XCTAssertEqual(far.x, geometry.stepX * 4)
    }

    func testFanGeometryFlattensForReduceMotion() {
        let geometry = ThemeCardFanGeometry.standard
        let far = geometry.placement(relative: 3, reduceMotion: true)
        XCTAssertEqual(far.rotation, 0)
        XCTAssertEqual(far.y, 0)
        XCTAssertEqual(far.x, geometry.stepX * 3)
        XCTAssertEqual(far.scale, geometry.sideScale)
    }

    func testFanGeometryDealsFromTheCentre() {
        let geometry = ThemeCardFanGeometry.standard
        for relative in -3...3 {
            let stacked = geometry.placement(relative: relative, deal: 0)
            XCTAssertEqual(stacked.x, 0, "every card starts stacked at the centre")
            XCTAssertEqual(stacked.rotation, 0)
            XCTAssertEqual(stacked.dim, 0)
        }
        XCTAssertEqual(geometry.placement(relative: 0, deal: 0).y, 0)
        XCTAssertEqual(geometry.placement(relative: 0, deal: 1).scale, 1)
    }

    // MARK: - Filter and favourites

    func testFilterIsCaseInsensitiveSubstring() {
        var deck = ThemeCardDeck(catalog: sampleCatalog)
        deck.query = "NORD"
        XCTAssertEqual(deck.count, 2)
        XCTAssertEqual(Set(deck.visible.map(\.displayName)), ["Omarchy · Nord", "Ghostty · Nord"])
        XCTAssertEqual(deck.selected, 0, "typing selects the first match")

        deck.query = "dracula"
        XCTAssertEqual(deck.visible.map(\.themeID), ["ghostty-dracula"])

        deck.query = "wallpaper"
        XCTAssertEqual(deck.count, 0, "Colors mode never shows the desktop card")

        deck.query = "no such theme"
        XCTAssertEqual(deck.count, 0)
        XCTAssertEqual(deck.current, .wallpaper, "an empty hand still has a safe current card")

        deck.query = ""
        XCTAssertEqual(deck.count, deck.visible.count)
        XCTAssertEqual(deck.visible.count, 4, "four themes, no wallpapers in Colors mode")
    }

    func testFavouritesViewAndToggle() {
        var deck = ThemeCardDeck(catalog: sampleCatalog)
        deck.query = "nord"
        XCTAssertEqual(deck.current.displayName, "Ghostty · Nord")
        XCTAssertFalse(deck.isCurrentFavourite)

        deck.toggleFavourite()
        XCTAssertTrue(deck.isCurrentFavourite)
        XCTAssertTrue(deck.favourites.contains("theme:ghostty-nord"))

        deck.favouritesOnly = true
        XCTAssertEqual(deck.count, 1)
        XCTAssertEqual(deck.current.displayName, "Ghostty · Nord")

        deck.toggleFavourite()
        XCTAssertEqual(deck.count, 0)
        XCTAssertFalse(deck.favourites.contains("theme:ghostty-nord"))
    }

    func testFavouritesPersistInUserDefaults() throws {
        let suite = "palette-fan-favourites-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeCardFavourites(defaults: defaults)
        XCTAssertTrue(store.keys.isEmpty)

        XCTAssertEqual(store.toggle("theme:nord"), ["theme:nord"])
        XCTAssertEqual(store.toggle("wallpaper-file:/tmp/a.png"), ["theme:nord", "wallpaper-file:/tmp/a.png"])

        // A fresh reader sees what the first one saved.
        let reloaded = ThemeCardFavourites(defaults: defaults)
        XCTAssertEqual(reloaded.keys, ["theme:nord", "wallpaper-file:/tmp/a.png"])

        XCTAssertEqual(reloaded.toggle("theme:nord"), ["wallpaper-file:/tmp/a.png"])
        XCTAssertEqual(ThemeCardFavourites(defaults: defaults).keys, ["wallpaper-file:/tmp/a.png"])
    }

    // MARK: - Wallpapers

    func testWallpaperListingKeepsPicturesAndVideosInOrder() throws {
        _ = try writeFile("b-image.png")
        _ = try writeFile("a-image.JPG")
        _ = try writeFile("clip.MOV")
        _ = try writeFile("notes.txt")
        _ = try writeFile("theme.toml")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested.png"),
            withIntermediateDirectories: true
        )

        let files = WallpaperLibrary.files(in: root)
        XCTAssertEqual(files.map(\.name), ["a-image.JPG", "b-image.png", "clip.MOV"])
        XCTAssertEqual(files.map(\.isVideo), [false, false, true])
    }

    func testWallpaperDeckLeadsWithFilesAndDotsTheDesktopOne() throws {
        let current = try writeFile("current.png")
        let other = try writeFile("other.jpg")
        let video = try writeFile("loop.mp4")
        let deck = ThemeCardDeck(
            catalog: sampleCatalog,
            wallpapers: [current, other, video],
            currentDesktop: current,
            mode: .wallpapers
        )

        XCTAssertEqual(deck.cards.prefix(4).map(\.sectionTitle), ["Wallpapers", "Wallpapers", "Wallpapers", "Ghostty"])
        XCTAssertEqual(deck.cards.first?.displayName, "current.png")
        XCTAssertEqual(deck.cards.first?.target, .wallpaperFile(current.path))
        XCTAssertEqual(deck.cards[1].target, .wallpaperFile(other.path))
        XCTAssertTrue(deck.cards.first?.isWallpaper == true)
        XCTAssertEqual(deck.count, 3, "Wallpapers mode hides the themes")

        var selected = deck
        selected.selected = 0
        XCTAssertEqual(selected.current.target, .wallpaperFile(current.path))
        selected.selected = 1
        XCTAssertEqual(selected.current.target, .wallpaperFile(other.path))
        selected.selected = 2
        XCTAssertEqual(selected.current.target, .wallpaperFile(video.path))

        let colors = ThemeCardDeck(
            catalog: sampleCatalog,
            wallpapers: [current, other, video],
            currentDesktop: current
        )
        XCTAssertEqual(colors.count, 4)
        XCTAssertEqual(colors.current.themeID, "ghostty-dracula")
    }

    func testWallpaperFallbackCardWhenFolderEmptyOrDesktopMissing() throws {
        let empty = ThemeCardDeck(catalog: sampleCatalog, wallpapers: [], currentDesktop: nil)
        XCTAssertEqual(empty.cards.first, .wallpaper)
        XCTAssertEqual(empty.cards.first?.target, .wallpaper)

        let current = try writeFile("current.png")
        let missing = try writeFile("gone.png")
        let deck = ThemeCardDeck(
            catalog: sampleCatalog,
            wallpapers: [missing],
            currentDesktop: current
        )
        XCTAssertEqual(deck.cards.first, .wallpaper, "the desktop picture is not in the folder")
        XCTAssertEqual(deck.cards[1].displayName, "gone.png")

        let listed = ThemeCardDeck(catalog: sampleCatalog, wallpapers: [current], currentDesktop: current)
        XCTAssertNotEqual(listed.cards.first, .wallpaper)
    }

    func testWallpaperCardFilesAreSentAsFileRoutes() throws {
        let picture = try writeFile("picture.png")
        var deck = ThemeCardDeck(
            catalog: sampleCatalog,
            wallpapers: [picture],
            currentDesktop: picture,
            mode: .wallpapers
        )
        deck.selected = 0
        XCTAssertEqual(deck.current.target, .wallpaperFile(picture.path))

        var themeDeck = ThemeCardDeck(catalog: sampleCatalog, currentTheme: "Ghostty · Dracula")
        XCTAssertEqual(themeDeck.current.target, .theme("ghostty-dracula"))
        themeDeck.jumpToLast()
        XCTAssertEqual(themeDeck.current.target, .theme("my-blue"), "custom themes sit last")
    }

    func testWallpaperDirectoryConfigRoundTrip() throws {
        XCTAssertEqual(ThemingConfig().wallpaperDirectory, WallpaperLibrary.defaultDirectory)
        XCTAssertEqual(WallpaperLibrary.defaultDirectory, "~/wallpapers")

        var config = ThemingConfig()
        config.wallpaperDirectory = "~/Pictures/Walls"
        let table = try TOMLTable(string: config.render())
        let parsed = ThemingConfig.parse(try XCTUnwrap(table.table("theming")))
        XCTAssertEqual(parsed.wallpaperDirectory, "~/Pictures/Walls")
        XCTAssertTrue(config.render().contains("wallpaper_directory = \"~/Pictures/Walls\""))

        var blank = ThemingConfig()
        blank.wallpaperDirectory = "  "
        XCTAssertEqual(blank.normalized().wallpaperDirectory, "", "an empty folder must stay empty")

        let defaults = try TOMLTable(string: ConfigLoader.defaultTOML())
        let theming = try XCTUnwrap(defaults.table("theming"))
        XCTAssertEqual(theming.str("wallpaper_directory"), "~/wallpapers")
    }

    // MARK: - Lazy work

    func testOnlyTheFanWindowIsParsed() throws {
        guard FileManager.default.fileExists(atPath: bundledDirectory.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        ThemeLoader.resetCachesForTesting()
        let catalog = ThemeBrowserCatalog(themes: ThemeLoader.catalog(
            themesDirectory: root,
            bundledThemesDirectory: bundledDirectory
        ))
        XCTAssertGreaterThan(catalog.count, 900)

        let wallpapers = [try writeFile("one.png"), try writeFile("two.jpg")]
        var deck = ThemeCardDeck(
            catalog: catalog,
            wallpapers: wallpapers,
            currentDesktop: wallpapers[0],
            mode: .colors
        )
        let reach = ThemeGalleryReachForTests.reach
        var parsed = Set<String>()
        func parseWindow() {
            for slot in deck.fanWindow(reach: reach) { parsed.insert(slot.card.cacheKey) }
        }

        parseWindow()
        XCTAssertEqual(deck.fanWindow(reach: reach).count, reach * 2 + 1)
        XCTAssertEqual(parsed.count, reach * 2 + 1, "942 themes, only the hand parsed")

        deck.move(by: 1)
        parseWindow()
        XCTAssertEqual(parsed.count, reach * 2 + 2, "a flip parses one new card, not the hand again")

        deck.move(by: 300)
        parseWindow()
        XCTAssertEqual(
            parsed.count,
            (reach * 2 + 2) + reach * 2 + 1,
            "a jump parses the window it lands on, never the 942-card deck"
        )
    }

    func testThumbnailIsDecodedOncePerCard() async throws {
        let picture = try writePNG("thumb.png")
        let loader = CardImageLoader()
        let first = await loader.thumbnail(for: picture)
        let second = await loader.thumbnail(for: picture)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let count = await loader.loadCount(for: picture)
        XCTAssertEqual(count, 1, "the second card body reads the cache")

        let missing = try writeFile("broken.png")
        let broken = await loader.thumbnail(for: missing)
        XCTAssertNil(broken, "an unreadable picture asks the card for its glyph")
        let brokenCount = await loader.loadCount(for: missing)
        XCTAssertEqual(brokenCount, 1)
    }

    // MARK: - Timings

    func testOpenAndFlipTimingsWith942Cards() throws {
        guard FileManager.default.fileExists(atPath: bundledDirectory.path) else {
            throw XCTSkip("bundled themes are missing")
        }
        ThemeLoader.resetCachesForTesting()
        let clock = ContinuousClock()
        var catalog = ThemeBrowserCatalog(themes: [])
        let catalogueTime = clock.measure {
            catalog = ThemeBrowserCatalog(themes: ThemeLoader.catalog(
                themesDirectory: root,
                bundledThemesDirectory: bundledDirectory
            ))
        }
        let wallpapers = (0..<12).map { root.appendingPathComponent("wall-\($0).png") }
        var deck = ThemeCardDeck(
            catalog: catalog,
            wallpapers: wallpapers,
            currentDesktop: wallpapers[0],
            mode: .colors
        )

        var palettes: [String: ThemeCardPalette] = [:]
        let openTime = clock.measure {
            _ = ThemeCardDeck(
                catalog: catalog,
                wallpapers: wallpapers,
                currentDesktop: wallpapers[0],
                mode: .colors
            )
            for slot in deck.fanWindow(reach: ThemeGalleryReachForTests.reach) {
                guard let name = slot.card.themeID else { continue }
                palettes[slot.card.cacheKey] = ThemeCardPalette(theme: ThemeLoader.load(
                    name: name,
                    themesDirectory: root,
                    bundledThemesDirectory: bundledDirectory
                ).theme)
            }
        }

        let flips = 1_000
        let flipTime = clock.measure {
            for _ in 0..<flips {
                deck.move(by: 1)
                _ = palettes[deck.current.cacheKey]
            }
        }

        let perFlip = seconds(flipTime) / Double(flips)
        print(
            "Fan deck Colors: \(catalog.count) themes · "
                + "catalogue \(milliseconds(catalogueTime)) ms · open "
                + "\(milliseconds(openTime)) ms · warm flip \(microseconds(perFlip)) µs"
        )
        XCTAssertLessThan(perFlip, 0.001, "a warm flip is a dictionary lookup")
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f", seconds(duration) * 1_000)
    }

    private func microseconds(_ value: Double) -> String {
        String(format: "%.1f", value * 1_000_000)
    }
}

/// Mirrors the app's `ThemeGalleryLayout.reach`; the layout lives in the
/// executable, so the tests keep their own copy of this one number.
private enum ThemeGalleryReachForTests {
    static let reach = 3
}
