import XCTest
import PaletteCore

final class WindowGeometryTests: XCTestCase {
    func testLandscapeFrameIsFixedForAScreen() {
        let window = WindowConfig()
        let screen = CGSize(width: 1440, height: 900)
        let size = window.launcherSize(for: screen)
        XCTAssertEqual(size.width, 864, "60% of the screen width")
        XCTAssertEqual(size.height, 540, "60% of the screen height")
        // Asking again, or with any other layout choice, cannot move it.
        var leftRail = WindowConfig()
        leftRail.providerBar = .left
        leftRail.previewLayout = .beside
        leftRail.favicons = false
        XCTAssertEqual(leftRail.launcherSize(for: screen), size)
        XCTAssertEqual(window.launcherSize(for: screen), size)
    }

    func testFrameTakesSixtyPercentOfBothAxes() {
        let window = WindowConfig()
        // The reference screen from the brief.
        let size = window.launcherSize(for: CGSize(width: 1710, height: 1073))
        XCTAssertEqual(size.width, 1_026, accuracy: 1)
        XCTAssertEqual(size.height, 643, accuracy: 1)
        XCTAssertLessThanOrEqual(size.width, 1710 * 0.6)
        XCTAssertLessThanOrEqual(size.height, 1073 * 0.6)
    }

    func testAbsoluteCapsBoundVeryLargeScreens() {
        let window = WindowConfig()
        // 60% of 2560 is 1536, 60% of 1440 is 864: the width cap wins.
        let size = window.launcherSize(for: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(size.width, 1_100)
        XCTAssertEqual(size.height, 864)
    }

    func testPortraitFrameIsNarrowerOnTheSameRule() {
        let window = WindowConfig()
        let landscape = window.launcherSize(for: CGSize(width: 1440, height: 900))
        let portrait = window.launcherSize(for: CGSize(width: 900, height: 1440))
        XCTAssertLessThan(portrait.width, landscape.width)
        XCTAssertGreaterThan(portrait.height, landscape.height)
        XCTAssertEqual(portrait.width, 540, "60% of the screen width")
        XCTAssertEqual(portrait.height, 864, "60% of the screen height")
    }

    func testFrameIsClampedToSmallScreens() {
        let window = WindowConfig()
        let size = window.launcherSize(for: CGSize(width: 400, height: 300))
        XCTAssertEqual(size.width, 352, "400 minus the margins when even 60% does not fit")
        XCTAssertEqual(size.height, 252)
        XCTAssertLessThanOrEqual(size.width, 400)
        XCTAssertLessThanOrEqual(size.height, 300)
    }

    func testTerminalFrameIsTheLauncherFrame() {
        let window = WindowConfig()
        let screen = CGSize(width: 1710, height: 1073)
        let frame = window.launcherSize(for: screen)
        XCTAssertEqual(frame.width, 1_026, "the window never changes for the terminal")
        XCTAssertEqual(frame.height, 643)
        // The pane fills that same frame, inset by one uniform gap.
        let content = WindowConfig.terminalContentSize(in: frame)
        XCTAssertEqual(content.width, frame.width - WindowConfig.terminalInset * 2)
        XCTAssertEqual(content.height, frame.height - WindowConfig.terminalInset * 2)
    }

    func testTerminalContentFillsTheAreaUnderTheSearchBar() {
        // No height share: everything left after the search pill, minus the gap.
        let content = WindowConfig.terminalContentSize(in: CGSize(width: 700, height: 500))
        XCTAssertEqual(content.width, 700 - WindowConfig.terminalInset * 2)
        XCTAssertEqual(content.height, 500 - WindowConfig.terminalInset * 2)
    }

    func testAutoPreviewReadsTheFrameWidth() {
        let window = WindowConfig()
        let landscape = window.launcherSize(for: CGSize(width: 1440, height: 900))
        XCTAssertEqual(window.resolvedPreviewLayout(frameWidth: Double(landscape.width)), .beside)
        let portrait = window.launcherSize(for: CGSize(width: 900, height: 1440))
        XCTAssertEqual(window.resolvedPreviewLayout(frameWidth: Double(portrait.width)), .below)
    }

    // MARK: - Horizontal placement

    func testPanelIsCentredOnTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1_710, height: 1_073)
        let width = WindowConfig().launcherSize(for: display.size).width
        XCTAssertEqual(width, 1_026)
        XCTAssertEqual(display.midX, 855)
        let x = LauncherPanelLayout.horizontalOrigin(
            display: display,
            visible: display,
            width: width
        )
        XCTAssertEqual(x, 342)
    }

    func testLeftDockLeavesThePanelCentredOnTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1_710, height: 1_073)
        let visible = CGRect(x: 80, y: 0, width: 1_630, height: 1_073)
        let width: CGFloat = 1_026
        let x = LauncherPanelLayout.horizontalOrigin(
            display: display,
            visible: visible,
            width: width
        )
        XCTAssertEqual(x, 342)
        XCTAssertGreaterThanOrEqual(x, visible.minX)
        XCTAssertLessThanOrEqual(x + width, visible.maxX)
    }

    func testRightDockLeavesThePanelCentredOnTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1_710, height: 1_073)
        let visible = CGRect(x: 0, y: 0, width: 1_630, height: 1_073)
        let width: CGFloat = 1_026
        let x = LauncherPanelLayout.horizontalOrigin(
            display: display,
            visible: visible,
            width: width
        )
        XCTAssertEqual(x, 342)
        XCTAssertLessThanOrEqual(x + width, visible.maxX)
        // Centring on the visible frame was the bug: 302, 40pt to the left.
        XCTAssertNotEqual(x, visible.midX - width / 2)
    }

    func testNarrowUsableAreaClampsThePanelIntoTheVisibleFrame() {
        let display = CGRect(x: 0, y: 0, width: 1_710, height: 1_073)
        let visible = CGRect(x: 0, y: 0, width: 1_310, height: 1_073)
        let width: CGFloat = 1_026
        let x = LauncherPanelLayout.horizontalOrigin(
            display: display,
            visible: visible,
            width: width
        )
        XCTAssertEqual(x, visible.maxX - LauncherPanelLayout.margin - width)
        XCTAssertEqual(x, 272)
        XCTAssertGreaterThanOrEqual(x, visible.minX + LauncherPanelLayout.margin)
        XCTAssertLessThanOrEqual(x + width, visible.maxX - LauncherPanelLayout.margin)
        // A visible frame narrower than the panel keeps its leading edge on screen.
        XCTAssertEqual(
            LauncherPanelLayout.horizontalOrigin(display: display, visible: visible, width: 1_400),
            visible.minX
        )
    }
}
