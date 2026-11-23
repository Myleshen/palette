import CoreGraphics
import XCTest
import PaletteCore

/// Pin geometry is pure, so placement, cascade, clamping and the cap are pinned
/// without putting a window on screen.
final class PinnedPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)

    func testFirstPinIsCentredAtActualSize() {
        let frame = PinnedPlacement.frame(previous: nil, size: CGSize(width: 200, height: 100), screen: screen)
        XCTAssertEqual(frame, CGRect(x: 400, y: 350, width: 200, height: 100))
    }

    func testSmallScreenshotIsNotUpscaled() {
        let frame = PinnedPlacement.frame(previous: nil, size: CGSize(width: 120, height: 80), screen: screen)
        XCTAssertEqual(frame.width, 120)
        XCTAssertEqual(frame.height, 80)
    }

    func testEachPinCascadesDownAndRight() {
        let size = CGSize(width: 200, height: 100)
        let first = PinnedPlacement.frame(previous: nil, size: size, screen: screen)
        let second = PinnedPlacement.frame(previous: first, size: size, screen: screen)
        let third = PinnedPlacement.frame(previous: second, size: size, screen: screen)
        XCTAssertEqual(second.origin.x - first.origin.x, PinnedPlacement.cascade.width)
        XCTAssertEqual(second.origin.y - first.origin.y, PinnedPlacement.cascade.height)
        XCTAssertEqual(third.origin.x - second.origin.x, PinnedPlacement.cascade.width)
        XCTAssertEqual(third.origin.y - second.origin.y, PinnedPlacement.cascade.height)
    }

    func testCascadeStopsAtTheScreenEdges() {
        let nearEdge = CGRect(x: 760, y: 690, width: 200, height: 100)
        let frame = PinnedPlacement.frame(
            previous: nearEdge,
            size: CGSize(width: 200, height: 100),
            screen: screen
        )
        // Right and top margins are 24, so 1000 - 24 - 200 and 800 - 24 - 100.
        XCTAssertEqual(frame, CGRect(x: 776, y: 676, width: 200, height: 100))
    }

    func testPreviousPinOnAnotherScreenLandsOnThisOne() {
        let otherScreenPin = CGRect(x: 2_040, y: 40, width: 200, height: 100)
        let frame = PinnedPlacement.frame(
            previous: otherScreenPin,
            size: CGSize(width: 200, height: 100),
            screen: screen
        )
        // X takes the nearest edge of this screen; Y was already in range.
        XCTAssertEqual(frame.origin, CGPoint(x: 776, y: 64))
        XCTAssertTrue(screen.contains(frame))
    }

    func testOversizedScreenshotIsScaledIntoTheScreen() {
        let frame = PinnedPlacement.frame(
            previous: nil,
            size: CGSize(width: 4_000, height: 3_000),
            screen: screen
        )
        XCTAssertEqual(frame.width, 952, accuracy: 1, "screen minus both margins")
        XCTAssertEqual(frame.height, 714, accuracy: 1)
        XCTAssertTrue(screen.contains(frame))
    }

    func testClampLeavesAResizedPinOnScreen() {
        let frame = PinnedPlacement.clamp(
            CGRect(x: -60, y: 900, width: 200, height: 100),
            to: screen
        )
        XCTAssertEqual(frame.origin, CGPoint(x: 24, y: 676))
    }

    func testCapEvictsOnlyPastEightPins() {
        XCTAssertEqual(PinnedPlacement.maximumPins, 8)
        XCTAssertEqual(PinnedPlacement.evictedCount(existing: 0), 0)
        XCTAssertEqual(PinnedPlacement.evictedCount(existing: 7), 0)
        XCTAssertEqual(PinnedPlacement.evictedCount(existing: 8), 1)
        XCTAssertEqual(PinnedPlacement.evictedCount(existing: 11), 4)
    }
}
