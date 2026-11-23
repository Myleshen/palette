import XCTest
import PaletteCore

final class WindowGeometryTests: XCTestCase {
    func testLandscapeFrameIsFixedForAScreen() {
        let window = WindowConfig()
        let screen = CGSize(width: 1440, height: 900)
        let size = window.launcherSize(for: screen)
        XCTAssertEqual(size.width, 1_100)
        XCTAssertEqual(size.height, 852, "screen minus both 24pt margins")
        // Asking again, or with any other layout choice, cannot move it.
        var leftRail = WindowConfig()
        leftRail.providerBar = .left
        leftRail.previewLayout = .beside
        leftRail.favicons = false
        XCTAssertEqual(leftRail.launcherSize(for: screen), size)
        XCTAssertEqual(window.launcherSize(for: screen), size)
    }

    func testLandscapeHeightStopsAtTheCap() {
        let window = WindowConfig()
        // 2560×1440 leaves 1392pt of height; the frame stops at 900.
        let size = window.launcherSize(for: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(size.width, 1_100)
        XCTAssertEqual(size.height, 900)
    }

    func testPortraitFrameIsNarrowerAndFullHeight() {
        let window = WindowConfig()
        let landscape = window.launcherSize(for: CGSize(width: 1440, height: 900))
        let portrait = window.launcherSize(for: CGSize(width: 900, height: 1440))
        XCTAssertLessThan(portrait.width, landscape.width)
        XCTAssertGreaterThan(portrait.height, landscape.height)
        XCTAssertEqual(portrait.width, 720)
        XCTAssertEqual(portrait.height, 1_392)
    }

    func testFrameIsClampedToSmallScreens() {
        let window = WindowConfig()
        let size = window.launcherSize(for: CGSize(width: 400, height: 300))
        XCTAssertEqual(size.width, 352, "400 minus the margins when the cap does not fit")
        XCTAssertEqual(size.height, 252)
        XCTAssertLessThanOrEqual(size.width, 400)
        XCTAssertLessThanOrEqual(size.height, 300)
    }

    func testAutoPreviewReadsTheFrameWidth() {
        let window = WindowConfig()
        let landscape = window.launcherSize(for: CGSize(width: 1440, height: 900))
        XCTAssertEqual(window.resolvedPreviewLayout(frameWidth: Double(landscape.width)), .beside)
        let portrait = window.launcherSize(for: CGSize(width: 900, height: 1440))
        XCTAssertEqual(window.resolvedPreviewLayout(frameWidth: Double(portrait.width)), .below)
    }
}
