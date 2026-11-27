import AppKit
import XCTest
@testable import PaletteApp
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

    /// The hand rides an arc: the selected card is the apex, the neighbours sit
    /// on the circle below it, and each card's rotation is the tangent there.
    func testArcKeepsTheSelectionAtTheApexAndDescendsOutward() {
        let arc = ThemeCardFanGeometry.standard
        let apex = arc.placement(relative: 0)
        XCTAssertEqual(apex.x, 0)
        XCTAssertEqual(apex.y, arc.apexY)
        XCTAssertEqual(apex.rotation, 0)
        XCTAssertEqual(apex.scale, 1)
        XCTAssertEqual(apex.dim, 0)
        XCTAssertEqual(apex.zIndex, 1000)

        for relative in 1...5 {
            let card = arc.placement(relative: relative)
            let degrees = min(Double(relative) * arc.stepAngle, arc.maxAngle)
            let radians = degrees * .pi / 180
            XCTAssertEqual(card.rotation, degrees, accuracy: 0.0001, "rotation is the arc tangent")
            XCTAssertEqual(card.x, arc.radius * sin(radians), accuracy: 0.01)
            XCTAssertEqual(
                card.y,
                arc.apexY - arc.radius * (1 - cos(radians)),
                accuracy: 0.01,
                "the pivot is on the circle"
            )
            XCTAssertLessThan(card.y, apex.y, "outer cards descend from the apex")
            XCTAssertEqual(card.dim, 0.30 + Double(relative) * 0.05, accuracy: 0.0001)

            let left = arc.placement(relative: -relative)
            XCTAssertEqual(left.x, -card.x)
            XCTAssertEqual(left.rotation, -card.rotation)
            XCTAssertEqual(left.y, card.y)
        }

        let falls = (1...6).map { arc.placement(relative: $0).y }
        XCTAssertEqual(falls, falls.sorted(by: >), "descent is monotonic")
    }

    func testArcStepClampsAtTheWidestCard() {
        let arc = ThemeCardFanGeometry.standard
        XCTAssertEqual(arc.angle(relative: 100), arc.maxAngle)
        XCTAssertEqual(arc.placement(relative: 100).rotation, arc.maxAngle)
        XCTAssertEqual(arc.placement(relative: 100).x, arc.radius * sin(arc.maxAngle * .pi / 180), accuracy: 0.01)
    }

    func testArcDealsUpFromBelowTheBottomEdge() {
        let arc = ThemeCardFanGeometry.standard
        for relative in -3...3 {
            let collapsed = arc.placement(relative: relative, progress: 0)
            XCTAssertEqual(collapsed.x, 0, "the hand starts collapsed at the centre")
            XCTAssertEqual(collapsed.y, arc.apexY - arc.rise, "and below the canvas")
            XCTAssertEqual(collapsed.rotation, 0)
            XCTAssertEqual(collapsed.dim, 0)
        }
        let mid = arc.placement(relative: 3, progress: 0.5)
        XCTAssertGreaterThan(mid.x, 0)
        XCTAssertLessThan(mid.x, arc.placement(relative: 3).x)
        XCTAssertGreaterThan(mid.y, arc.apexY - arc.rise)
        XCTAssertLessThan(mid.y, arc.placement(relative: 3).y + 1)
    }

    func testDealStaggersOuterCards() {
        let motion = ThemeDeckMotion.standard
        XCTAssertEqual(motion.progress(for: 0, deal: 1), 1)
        XCTAssertEqual(motion.progress(for: 9, deal: 0), 0)
        XCTAssertLessThan(
            motion.progress(for: 4, deal: 0.5),
            motion.progress(for: 0, deal: 0.5),
            "the middle unfolds first"
        )
        XCTAssertEqual(motion.progress(for: 9, deal: 1), 1)
    }

    func testMotionIsAShippingSpringWithAReduceMotionCrossfade() {
        let motion = ThemeDeckMotion.standard
        XCTAssertGreaterThanOrEqual(motion.response, 0.28)
        XCTAssertLessThanOrEqual(motion.response, 0.34)
        XCTAssertGreaterThan(motion.damping, 0.7)
        XCTAssertLessThan(motion.damping, 0.9)
        XCTAssertGreaterThan(motion.crossfade, 0)
        XCTAssertGreaterThan(motion.stagger, 0)
        XCTAssertGreaterThan(motion.hoverScale, 1)
    }

    // MARK: - Deck frame and hand on a table

    /// Every display the deck must handle: landscape, ultrawide, 4K, portrait,
    /// a small laptop, a side Dock's narrower visible frame and a menu bar.
    private var displays: [(String, CGRect)] {
        [
            ("1024x640 laptop", CGRect(x: 0, y: 0, width: 1024, height: 640)),
            ("1280x800", CGRect(x: 0, y: 0, width: 1280, height: 800)),
            ("1710x1073", CGRect(x: 0, y: 0, width: 1710, height: 1073)),
            ("2560x1440", CGRect(x: 0, y: 0, width: 2560, height: 1440)),
            ("3440x1440 ultrawide", CGRect(x: 0, y: 0, width: 3440, height: 1440)),
            ("3840x2160 4K", CGRect(x: 0, y: 0, width: 3840, height: 2160)),
            ("1080x1920 portrait", CGRect(x: 0, y: 0, width: 1080, height: 1920)),
            ("1200x1920 portrait", CGRect(x: 0, y: 0, width: 1200, height: 1920)),
            // Dock on the left: the usable frame starts 80 pt in.
            ("dock left 1280x800", CGRect(x: 80, y: 0, width: 1200, height: 800)),
            // Menu bar: the usable frame starts below it.
            ("menu bar 1512x945", CGRect(x: 0, y: 25, width: 1512, height: 945)),
        ]
    }

    func testDeckSpansEachDisplayAndRestsOnItsBottomEdge() {
        for (name, visible) in displays {
            let metrics = ThemeGalleryLayout.metrics(in: visible)
            XCTAssertEqual(metrics.frame.width, visible.width, name)
            XCTAssertEqual(metrics.frame.minX, visible.minX, name)
            XCTAssertEqual(metrics.frame.minY, visible.minY, name)
            XCTAssertGreaterThan(metrics.frame.height, 0, name)
            XCTAssertLessThanOrEqual(metrics.frame.height, visible.height, name)
            XCTAssertGreaterThanOrEqual(
                metrics.frame.height,
                metrics.chromeHeight + metrics.handHeight - 0.5,
                "\(name) must fit one card plus header and footer"
            )
        }
    }

    /// The panel takes the computed frame on every display: never the old
    /// 1280×720 box, never a shared-edge margin, and nothing AppKit may shrink.
    func testThePanelIsExactlyTheUsableWidth() {
        for (name, visible) in displays {
            let metrics = ThemeGalleryLayout.metrics(in: visible)
            let window = ThemeGalleryWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            window.setFrame(metrics.frame, display: false)
            XCTAssertEqual(window.frame.width, visible.width, name)
            XCTAssertEqual(window.frame.minX, visible.minX, name)
            XCTAssertEqual(window.frame.minY, visible.minY, name)
            XCTAssertEqual(window.frame.height, metrics.frame.height, name)
            XCTAssertNotEqual(window.frame.size, NSSize(width: 1280, height: 720), name)
            let constrained = window.constrainFrameRect(metrics.frame, to: nil)
            XCTAssertEqual(constrained, metrics.frame, "\(name) must not be constrained")
        }
    }

    /// The rotated AABB of every card, not its centre, has to stay in the deck.
    func testEveryRotatedCardStaysInsideTheDeck() {
        for (name, visible) in displays {
            let metrics = ThemeGalleryLayout.metrics(in: visible)
            let canvas = metrics.canvas.insetBy(dx: -0.5, dy: -0.5)
            for relative in -metrics.reach...metrics.reach {
                let box = metrics.bounds(relative: relative)
                XCTAssertTrue(
                    canvas.contains(box),
                    "\(name) card \(relative) \(box) spills out of \(canvas)"
                )
            }
            XCTAssertEqual(metrics.bounds(relative: 0).midX, 0, accuracy: 0.01, "\(name) selection is centred")
        }
    }

    func testCardScaleShrinksOnShortScreens() {
        let wide = ThemeGalleryLayout.metrics(in: CGRect(x: 0, y: 0, width: 1710, height: 1073))
        let small = ThemeGalleryLayout.metrics(in: CGRect(x: 0, y: 0, width: 1024, height: 640))
        let portrait = ThemeGalleryLayout.metrics(in: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        XCTAssertEqual(wide.scale, 1)
        XCTAssertLessThan(small.scale, 0.7, "a 640 pt screen cannot hold a full 368 pt card")
        XCTAssertGreaterThan(small.cardHeight, 0)
        XCTAssertGreaterThan(small.cardWidth, 0)
        XCTAssertEqual(portrait.scale, 1, "a tall portrait screen still fits a full card")
        XCTAssertLessThan(small.handHeight, wide.handHeight)
    }

    func testReachGrowsWithTheDeckWidth() {
        XCTAssertEqual(ThemeGalleryLayout.reach(forWidth: 1024), 3)
        XCTAssertEqual(ThemeGalleryLayout.reach(forWidth: 1080), 4)
        XCTAssertEqual(ThemeGalleryLayout.reach(forWidth: 1280), 4)
        XCTAssertEqual(ThemeGalleryLayout.reach(forWidth: 1440), 5)
        XCTAssertEqual(ThemeGalleryLayout.reach(forWidth: 1710), 6)
        XCTAssertEqual(ThemeGalleryLayout.reach(forWidth: 3440), 9)
        XCTAssertEqual(ThemeGalleryLayout.reach(forWidth: 8000), ThemeGalleryLayout.maxReach)
        let widths: [CGFloat] = [800, 1024, 1280, 1440, 1710, 2560, 3440, 5000]
        let reaches = widths.map(ThemeGalleryLayout.reach(forWidth:))
        XCTAssertEqual(reaches, reaches.sorted(), "more width never shows fewer cards")
    }

    func testPortraitUsesASteeperArcWithFewerCards() {
        let portrait = ThemeGalleryLayout.metrics(in: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        let wide = ThemeGalleryLayout.metrics(in: CGRect(x: 0, y: 0, width: 1710, height: 1073))
        XCTAssertLessThan(portrait.reach, wide.reach)
        XCTAssertGreaterThan(portrait.arc.maxAngle, wide.arc.maxAngle, "a narrow frame needs a steeper fan")
        XCTAssertGreaterThan(portrait.arc.stepAngle, wide.arc.stepAngle)
        XCTAssertLessThanOrEqual(portrait.arc.maxAngle, ThemeGalleryLayout.maxAngle)
    }

    func testTheDeckFollowsThePointerScreen() throws {
        let laptop = ThemeDeckScreen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)
        )
        let portrait = ThemeDeckScreen(
            frame: CGRect(x: -1080, y: -480, width: 1080, height: 1920),
            visibleFrame: CGRect(x: -1080, y: -480, width: 1080, height: 1920)
        )
        let onPortrait = try XCTUnwrap(ThemeGalleryLayout.metrics(
            for: CGPoint(x: -500, y: 300),
            screens: [laptop, portrait],
            fallback: 0
        ))
        XCTAssertEqual(onPortrait.frame.width, 1080)
        XCTAssertEqual(onPortrait.frame.minX, -1080)
        XCTAssertEqual(onPortrait.frame.minY, -480)

        let onLaptop = try XCTUnwrap(ThemeGalleryLayout.metrics(
            for: CGPoint(x: 400, y: 300),
            screens: [laptop, portrait],
            fallback: 1
        ))
        XCTAssertEqual(onLaptop.frame.width, 1512)

        // Between displays: the main screen answers.
        XCTAssertEqual(ThemeGalleryLayout.screenIndex(
            for: CGPoint(x: 9000, y: 9000),
            screens: [laptop.frame, portrait.frame],
            fallback: 0
        ), 0)
        XCTAssertNil(ThemeGalleryLayout.metrics(for: .zero, screens: []))
    }

    /// A display change while the deck is open re-lays it out from the new list,
    /// including falling back when the display under the pointer is unplugged.
    func testScreenChangeRelaysOutTheVisibleDeck() throws {
        let laptop = ThemeDeckScreen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 945)
        )
        let portrait = ThemeDeckScreen(
            frame: CGRect(x: 1512, y: 0, width: 1080, height: 1920),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1080, height: 1920)
        )
        let pointer = CGPoint(x: 1800, y: 400)
        let before = try XCTUnwrap(ThemeGalleryLayout.metrics(
            for: pointer,
            screens: [laptop, portrait]
        ))
        XCTAssertEqual(before.frame.width, 1080)
        XCTAssertEqual(before.frame.minX, 1512)

        // The portrait panel is unplugged: the same pointer now resolves to the
        // main display instead of keeping the dead frame.
        let after = try XCTUnwrap(ThemeGalleryLayout.metrics(
            for: pointer,
            screens: [laptop],
            fallback: 0
        ))
        XCTAssertEqual(after.frame.width, 1512)
        XCTAssertEqual(after.frame.minY, 25)
        XCTAssertNotEqual(before, after)
    }

    func testPreviewFillsTheDeck() {
        let deck = ThemeGalleryLayout.frame(in: CGRect(x: 0, y: 0, width: 1710, height: 1073))
        let preview = ThemeGalleryLayout.previewFrame(in: deck)
        XCTAssertEqual(preview, deck)
        XCTAssertEqual(preview.width, 1710)
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
        let reach = ThemeDeckReachForTests.reach
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
            for slot in deck.fanWindow(reach: ThemeDeckReachForTests.reach) {
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

/// The hand the deck shows on a 1280 pt screen, for the parse-count tests.
private enum ThemeDeckReachForTests {
    static let reach = ThemeGalleryLayout.reach(forWidth: 1280)
}
