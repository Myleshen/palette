import AppKit
import XCTest
@testable import PalettePlatform

@MainActor
final class IconTests: XCTestCase {
    func testIconCacheKeepsEveryRequestedSize() throws {
        let provider = IconProvider.shared
        let small = try XCTUnwrap(provider.image(for: .symbol("globe"), size: 16))
        let large = try XCTUnwrap(provider.image(for: .symbol("globe"), size: 32))

        XCTAssertEqual(small.size.width, 16, accuracy: 0.5)
        XCTAssertEqual(large.size.width, 32, accuracy: 0.5)
        // The earlier request must not be answered with the later image.
        let smallAgain = try XCTUnwrap(provider.image(for: .symbol("globe"), size: 16))
        XCTAssertEqual(smallAgain.size.width, 16, accuracy: 0.5)
    }
}
