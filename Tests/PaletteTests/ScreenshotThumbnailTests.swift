import AppKit
import XCTest
@testable import PalettePlatform

final class ScreenshotThumbnailTests: XCTestCase {
    func testMaxPixelSizeFollowsTheHUDAtScreenScale() {
        XCTAssertEqual(ScreenshotThumbnail.maxPixelSize(scale: 1), 260)
        XCTAssertEqual(ScreenshotThumbnail.maxPixelSize(scale: 2), 520)
        XCTAssertEqual(ScreenshotThumbnail.maxPixelSize(scale: 0), 260, "a bad scale never shrinks below points")
    }

    func testThumbnailIsDownsampledAndWrappedForTheHUD() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-thumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("shot.png")
        try solidImage(width: 2000, height: 1000).write(to: url)

        let image = try XCTUnwrap(ScreenshotThumbnail.image(at: url, scale: 2))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 520)
        XCTAssertEqual(cgImage.width, 520)
        XCTAssertEqual(cgImage.height, 260)
        // Points, so the HUD lays it out at the size it drew last time.
        XCTAssertEqual(image.size.width, 260, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 130, accuracy: 0.5)

        let full = try XCTUnwrap(ScreenshotThumbnail.cgImage(at: url))
        XCTAssertEqual(full.width, 2000)
        XCTAssertEqual(full.height, 1000)
    }

    private func solidImage(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }
}
