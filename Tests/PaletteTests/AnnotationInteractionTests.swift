import AppKit
import XCTest
@testable import PalettePlatform

/// Pointer interaction on the annotator model. This branch has no shape resize
/// handles, so "resize clamps" covers the one resizing path it does have: a
/// crop rectangle clamped to the image and refused when it is too small.
@MainActor
final class AnnotationInteractionTests: XCTestCase {
    private func bitmap(width: Int = 200, height: Int = 100) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func rectangle(_ rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)) -> AnnotationShape {
        .rectangle(rect: rect, color: .systemRed, width: 0.004)
    }

    func testHitTestSelectsTheTopMostMarkAndMissesEmptyCanvas() {
        let editor = AnnotationEditor(image: bitmap(), url: nil)
        editor.add(rectangle())
        editor.add(rectangle(CGRect(x: 0.15, y: 0.15, width: 0.2, height: 0.2)))

        XCTAssertEqual(editor.hitTest(CGPoint(x: 0.2, y: 0.2)), 1, "top-most mark wins")
        XCTAssertEqual(editor.hitTest(CGPoint(x: 0.13, y: 0.13)), 0, "the first mark owns a point only it covers")
        XCTAssertNil(editor.hitTest(CGPoint(x: 0.8, y: 0.8)))
    }

    func testDeleteSelectedThenUndoRestoresTheMarks() {
        let editor = AnnotationEditor(image: bitmap(), url: nil)
        editor.add(rectangle())
        editor.add(rectangle(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)))
        editor.selected = 1

        editor.removeSelected()
        XCTAssertEqual(editor.shapes.count, 1)
        XCTAssertNil(editor.selected, "deleting clears the selection")

        editor.undo()
        XCTAssertEqual(editor.shapes.count, 2, "undo restores the deleted mark")
        // The model keeps the shape history only; `selected` stays nil after
        // undo, which is why the keyboard delete cannot fire twice on a ghost.
        XCTAssertNil(editor.selected)
    }

    func testMovingAMarkRecordsOneUndoStepAndUndoRestoresItsPosition() {
        let editor = AnnotationEditor(image: bitmap(), url: nil)
        let original = rectangle()
        editor.add(original)
        editor.selected = 0

        editor.beginChange()
        editor.replace(0, with: original.offset(by: CGPoint(x: 0.25, y: 0.1)))
        if case let .rectangle(moved, _, _) = editor.shapes[0] {
            XCTAssertEqual(moved.minX, 0.35, accuracy: 0.000_001)
        } else {
            XCTFail("expected a rectangle")
        }

        editor.undo()
        XCTAssertEqual(editor.shapes[0], original)
    }

    func testCropClampsToTheImageAndRefusesTinyRects() {
        // Too small to be a deliberate crop: no history entry, no change.
        let untouched = AnnotationEditor(image: bitmap(), url: nil)
        untouched.crop(to: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        XCTAssertFalse(untouched.canUndo, "a refused crop must not add an undo step")
        XCTAssertEqual(untouched.image.pixelSize, CGSize(width: 200, height: 100))
        XCTAssertTrue(untouched.shapes.isEmpty)

        let editor = AnnotationEditor(image: bitmap(), url: nil)
        editor.add(rectangle())

        // A rect that runs off every edge is clamped to the image, not used raw.
        editor.crop(to: CGRect(x: -0.5, y: -0.5, width: 2, height: 2))
        XCTAssertEqual(editor.image.pixelSize, CGSize(width: 200, height: 100))
        XCTAssertEqual(editor.shapes[0], rectangle(), "a full-image crop does not move the mark")

        // A crop that starts inside but ends outside is clamped to the image;
        // marks inside the kept region remap into it.
        editor.add(rectangle(CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)))
        editor.crop(to: CGRect(x: 0.8, y: 0.8, width: 0.4, height: 0.4))
        XCTAssertEqual(editor.image.pixelSize, CGSize(width: 40, height: 20))
        guard case let .rectangle(remapped, _, _) = editor.shapes[1] else {
            return XCTFail("expected a rectangle")
        }
        XCTAssertEqual(remapped.minX, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(remapped.minY, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(remapped.width, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(remapped.height, 0.25, accuracy: 0.000_001)
    }
}
