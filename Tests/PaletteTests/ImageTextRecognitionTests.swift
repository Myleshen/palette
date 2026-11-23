import CoreGraphics
import XCTest
@testable import PalettePlatform

/// Post-processing is pure, so ordering, joining and link rules are pinned with
/// synthetic observations instead of a camera or a real Vision run.
final class ImageTextRecognitionTests: XCTestCase {
    private func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 0.1, _ height: CGFloat = 0.05) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func testLinesAreOrderedTopToBottom() {
        // Vision's origin is bottom-left: the highest maxY is the top of the image.
        let observations = [
            ImageTextObservation(text: "bottom", boundingBox: box(0.1, 0.10)),
            ImageTextObservation(text: "top", boundingBox: box(0.1, 0.90)),
            ImageTextObservation(text: "middle", boundingBox: box(0.1, 0.50)),
        ]
        let result = ImageTextRecognition.compose(observations: observations)
        XCTAssertEqual(result.lines, ["top", "middle", "bottom"])
        XCTAssertEqual(result.text, "top\nmiddle\nbottom")
    }

    func testFragmentsOnOneLineJoinLeftToRight() {
        let observations = [
            ImageTextObservation(text: "World", boundingBox: box(0.60, 0.895)),
            ImageTextObservation(text: "Hello", boundingBox: box(0.10, 0.90)),
            ImageTextObservation(text: "Second line", boundingBox: box(0.10, 0.50)),
        ]
        let result = ImageTextRecognition.compose(observations: observations)
        XCTAssertEqual(result.lines, ["Hello World", "Second line"])
        XCTAssertEqual(result.text, "Hello World\nSecond line")
    }

    func testEmptyObservationsProduceEmptyText() {
        let result = ImageTextRecognition.compose(observations: [], barcodes: [])
        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.links, [])
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.isEmpty)
        XCTAssertNil(result.firstLink)
    }

    func testLinksAreExtractedFromTextAndBarcodesWithoutDuplicates() {
        let observations = [
            ImageTextObservation(
                text: "Visit https://example.com/docs now",
                boundingBox: box(0.1, 0.80, 0.8)
            ),
            ImageTextObservation(
                text: "Repeat https://example.com/docs",
                boundingBox: box(0.1, 0.60, 0.8)
            ),
        ]
        let result = ImageTextRecognition.compose(
            observations: observations,
            barcodes: ["https://example.com/docs", "https://example.com/docs"]
        )
        XCTAssertEqual(result.links, ["https://example.com/docs"])
    }

    func testNonHTTPSLinksAreRejected() {
        let observations = [
            ImageTextObservation(
                text: "mailto:me@example.com file:///etc/passwd javascript:alert(1)",
                boundingBox: box(0.1, 0.80, 0.8)
            ),
        ]
        let result = ImageTextRecognition.compose(
            observations: observations,
            barcodes: ["mailto:me@example.com", "file:///etc/passwd"]
        )
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertFalse(ImageTextRecognition.isOpenable("mailto:me@example.com"))
        XCTAssertFalse(ImageTextRecognition.isOpenable("file:///etc/passwd"))
        XCTAssertFalse(ImageTextRecognition.isOpenable("javascript:alert(1)"))
        XCTAssertFalse(ImageTextRecognition.isOpenable("www.example.com"))
        XCTAssertTrue(ImageTextRecognition.isOpenable("https://example.com/a"))
        XCTAssertTrue(ImageTextRecognition.isOpenable("  HTTP://Example.com  "))
    }

    func testBarcodePayloadsBecomeTextWhenTheyAreNotLinks() {
        let result = ImageTextRecognition.compose(observations: [], barcodes: ["https://example.com", "4006381333931"])
        XCTAssertEqual(result.lines, ["4006381333931"])
        XCTAssertEqual(result.text, "4006381333931")
        XCTAssertEqual(result.links, ["https://example.com"])
    }

    func testDuplicateBarcodeTextIsNotRepeated() {
        let observations = [
            ImageTextObservation(text: "4006381333931", boundingBox: box(0.1, 0.5)),
        ]
        let result = ImageTextRecognition.compose(observations: observations, barcodes: ["4006381333931"])
        XCTAssertEqual(result.lines, ["4006381333931"])
    }
}
