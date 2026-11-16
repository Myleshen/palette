import AppKit
import XCTest
@testable import PalettePlatform

/// The annotator stores marks as top-left fractions but AppKit draws from the
/// bottom left, and crop used to flip CGImage rects a second time. These tests
/// read the rendered pixels, so a mirroring regression fails here.
@MainActor
final class AnnotationTests: XCTestCase {
    /// Bitmap-backed so the pixel size is exact on any display scale; an
    /// `NSImage(size:)` plus `lockFocus` doubles on a 2x screen and used to
    /// make these assertions fail for the wrong reason.
    private func bitmapImage(width: Int, height: Int, draw: (NSRect) -> Void) -> NSImage {
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
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func solidImage(width: Int, height: Int, color: NSColor) -> NSImage {
        bitmapImage(width: width, height: height) { rect in
            color.setFill()
            rect.fill()
        }
    }

    private func twoToneImage(width: Int = 100, height: Int = 100) -> NSImage {
        bitmapImage(width: width, height: height) { rect in
            NSColor.red.setFill()
            // Top half in top-left coordinates == the high half in AppKit's space.
            NSRect(x: 0, y: rect.height / 2, width: rect.width, height: rect.height / 2).fill()
            NSColor.blue.setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: rect.height / 2).fill()
        }
    }

    private func pixel(_ image: NSImage, x: Int, y: Int) -> NSColor {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return NSColor.clear
        }
        return colour
    }

    /// Marks are thin and anti-aliased, so look in a small box rather than at
    /// one exact pixel.
    private func contains(_ image: NSImage, channel: KeyPath<NSColor, CGFloat>, around point: CGPoint, radius: Int = 3) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = Int(point.x) + dx
                let y = Int(point.y) + dy
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let value = colour[keyPath: channel]
                let other = channel == \NSColor.redComponent ? colour.greenComponent : colour.redComponent
                if value - other > 0.3 { return true }
            }
        }
        return false
    }

    func testRenderedArrowStaysWhereThePreviewShowedIt() throws {
        let editor = AnnotationEditor(image: solidImage(width: 200, height: 100, color: .white), url: nil)
        // Top-left quarter, drawn downwards to the right.
        editor.add(.arrow(
            from: CGPoint(x: 0.1, y: 0.1),
            to: CGPoint(x: 0.9, y: 0.4),
            color: .red,
            width: 0.01
        ))
        let output = editor.rendered()
        XCTAssertTrue(contains(output, channel: \NSColor.redComponent, around: CGPoint(x: 20, y: 10)), "arrow starts top-left")
        XCTAssertTrue(contains(output, channel: \NSColor.redComponent, around: CGPoint(x: 100, y: 25)), "arrow crosses the middle")
        XCTAssertTrue(contains(output, channel: \NSColor.redComponent, around: CGPoint(x: 178, y: 40)), "arrow ends lower right")
        let below = pixel(output, x: 30, y: 90)
        XCTAssertTrue(
            below.redComponent > 0.9 && abs(below.redComponent - below.greenComponent) < 0.05,
            "bottom left stays white, not a mirrored mark"
        )
    }

    func testRectangleRendersInTheTopRight() throws {
        let editor = AnnotationEditor(image: solidImage(width: 200, height: 100, color: .white), url: nil)
        editor.add(.rectangle(
            rect: CGRect(x: 0.5, y: 0.1, width: 0.4, height: 0.3),
            color: .green,
            width: 0.01
        ))
        let output = editor.rendered()
        XCTAssertTrue(contains(output, channel: \NSColor.greenComponent, around: CGPoint(x: 100, y: 10)), "top edge of the box")
        XCTAssertTrue(contains(output, channel: \NSColor.greenComponent, around: CGPoint(x: 178, y: 40)), "bottom edge of the box")
        let below = pixel(output, x: 100, y: 80)
        XCTAssertTrue(
            below.redComponent > 0.9 && abs(below.redComponent - below.greenComponent) < 0.05,
            "nothing below the box"
        )
    }

    func testCropKeepsTheTopLeftRegion() throws {
        let editor = AnnotationEditor(image: twoToneImage(), url: nil)
        editor.crop(to: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        let output = editor.rendered()
        XCTAssertEqual(output.pixelSize.width, 100, accuracy: 1)
        XCTAssertEqual(output.pixelSize.height, 50, accuracy: 1)
        XCTAssertGreaterThan(pixel(output, x: 50, y: 25).redComponent, 0.5, "the red top half is kept")
    }

    func testCropRemapsMarksInsteadOfDroppingThem() throws {
        let editor = AnnotationEditor(image: solidImage(width: 200, height: 200, color: .white), url: nil)
        editor.add(.arrow(
            from: CGPoint(x: 0.5, y: 0.5),
            to: CGPoint(x: 0.7, y: 0.7),
            color: .red,
            width: 0.01
        ))
        // Halve the image, keeping the bottom-right quadrant where the arrow is.
        editor.crop(to: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(editor.shapes.count, 1)
        guard case let .arrow(from, to, _, _) = editor.shapes[0] else {
            return XCTFail("arrow should survive the crop")
        }
        XCTAssertEqual(from.x, 0, accuracy: 0.01)
        XCTAssertEqual(from.y, 0, accuracy: 0.01)
        XCTAssertEqual(to.x, 0.4, accuracy: 0.01)
    }

    func testUndoRestoresTheImageAndTheMarks() throws {
        let editor = AnnotationEditor(image: twoToneImage(), url: nil)
        editor.crop(to: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(editor.image.pixelSize.width, 50, accuracy: 1)
        editor.undo()
        XCTAssertEqual(editor.image.pixelSize.width, 100, accuracy: 1)
    }

    func testSaveOverwritesTheOriginalAtPixelSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-annotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("shot.png")
        let source = solidImage(width: 240, height: 120, color: .white)
        guard let data = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not build the source png")
        }
        try png.write(to: url)

        let editor = AnnotationEditor(image: source, url: url)
        editor.add(.rectangle(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), color: .red, width: 0.01))
        try editor.save()

        let saved = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertEqual(saved.pixelSize.width, 240, accuracy: 1)
        XCTAssertEqual(saved.pixelSize.height, 120, accuracy: 1)
    }
}

// MARK: - Selection

extension AnnotationTests {
    func testHitTestFindsAnArrowOnItsShaft() {
        let editor = AnnotationEditor(image: solidImage(width: 200, height: 100, color: .white), url: nil)
        editor.add(.arrow(from: CGPoint(x: 0.1, y: 0.2), to: CGPoint(x: 0.9, y: 0.2), color: .red, width: 0.004))
        XCTAssertEqual(editor.hitTest(CGPoint(x: 0.5, y: 0.2)), 0)
        XCTAssertNil(editor.hitTest(CGPoint(x: 0.5, y: 0.6)))
    }

    func testHitTestFindsARectangleInsideAndNotOutside() {
        let editor = AnnotationEditor(image: solidImage(width: 200, height: 100, color: .white), url: nil)
        editor.add(.rectangle(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4), color: .blue, width: 0.004))
        XCTAssertEqual(editor.hitTest(CGPoint(x: 0.3, y: 0.3)), 0)
        XCTAssertNil(editor.hitTest(CGPoint(x: 0.8, y: 0.8)))
    }

    func testTranslateMovesOnlyTheSelectedMark() {
        let editor = AnnotationEditor(image: solidImage(width: 200, height: 100, color: .white), url: nil)
        editor.add(.arrow(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.2, y: 0.2), color: .red, width: 0.004))
        editor.add(.rectangle(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), color: .blue, width: 0.004))
        editor.replace(1, with: editor.shapes[1].offset(by: CGPoint(x: 0.1, y: -0.1)))
        guard case let .rectangle(rect, _, _) = editor.shapes[1] else { return XCTFail("rect expected") }
        XCTAssertEqual(rect.minX, 0.6, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0.4, accuracy: 0.001)
        guard case let .arrow(from, _, _, _) = editor.shapes[0] else { return XCTFail("arrow expected") }
        XCTAssertEqual(from.x, 0.1, accuracy: 0.001, "the other mark must not move")
    }

    func testDeleteRemovesTheSelectedMarkAndUndoBringsItBack() {
        let editor = AnnotationEditor(image: solidImage(width: 100, height: 100, color: .white), url: nil)
        editor.add(.rectangle(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), color: .red, width: 0.004))
        editor.selected = 0
        editor.removeSelected()
        XCTAssertTrue(editor.shapes.isEmpty)
        editor.undo()
        XCTAssertEqual(editor.shapes.count, 1)
    }

    func testSaveAsWritesANewFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-save-as-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.png")
        try XCTUnwrap(solidImage(width: 120, height: 60, color: .white).tiffRepresentation).write(to: source)

        let editor = AnnotationEditor(image: try XCTUnwrap(NSImage(contentsOf: source)), url: source)
        editor.add(.rectangle(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), color: .red, width: 0.01))

        let copy = directory.appendingPathComponent("copy.png")
        try editor.save(to: copy)

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try XCTUnwrap(NSImage(contentsOf: copy)).pixelSize.width, 120, accuracy: 1)
        // The original is untouched by Save As.
        XCTAssertEqual(try XCTUnwrap(NSImage(contentsOf: source)).pixelSize.width, 120, accuracy: 1)
    }
}
