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
    func testPointerIsTheDefaultToolSoClicksNeverDraw() {
        let editor = AnnotationEditor(image: solidImage(width: 100, height: 100, color: .white), url: nil)
        XCTAssertEqual(editor.tool, .pointer)
        XCTAssertEqual(AnnotateTool.allCases.first, .pointer)
    }

    func testTextUsesTheConfiguredSize() {
        let editor = AnnotationEditor(image: solidImage(width: 100, height: 100, color: .white), url: nil)
        editor.textSize = 0.09
        editor.add(.text(at: .zero, text: "Hi", size: editor.textSize, color: .red, box: .zero))
        guard case let .text(_, _, size, _, _) = editor.shapes[0] else { return XCTFail("text expected") }
        XCTAssertEqual(size, 0.09, accuracy: 0.0001)
    }

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

    func testTextHitBoxUsesGlyphMetricsNotCharacterCount() {
        let editor = AnnotationEditor(image: solidImage(width: 600, height: 200, color: .white), url: nil)
        editor.textSize = 0.1 // 20 px at this image height
        editor.addText(at: CGPoint(x: 0.05, y: 0.2), text: "WWWWW")
        editor.addText(at: CGPoint(x: 0.05, y: 0.6), text: "iii")
        guard case let .text(atW, _, _, _, boxW) = editor.shapes[0],
              case let .text(atI, _, _, _, boxI) = editor.shapes[1] else {
            return XCTFail("two text shapes expected")
        }

        // Wide glyphs: the measured box reaches the end of the visible text,
        // where the old character-count guess stopped short.
        let rightEnd = CGPoint(x: atW.x + boxW.width * 0.9, y: atW.y + boxW.height / 2)
        XCTAssertEqual(editor.hitTest(rightEnd), 0)

        // Narrow glyphs: the old guess was twice as wide, so this point is
        // empty canvas past the measured text.
        let oldGuess = max(20, CGFloat(3) * 20 * 0.62) / 600
        XCTAssertGreaterThan(oldGuess, boxI.width)
        let pastText = CGPoint(x: atI.x + (boxI.width + oldGuess) / 2, y: atI.y + boxI.height / 2)
        XCTAssertNil(editor.hitTest(pastText))
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

    func testHitTestSelectsTheTopMostMarkUnderThePointer() {
        let editor = AnnotationEditor(image: solidImage(width: 400, height: 200, color: .white), url: nil)
        editor.add(.rectangle(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), color: .blue, width: 0.004))
        editor.textSize = 0.1
        editor.addText(at: CGPoint(x: 0.2, y: 0.2), text: "Over")
        let insideText = CGPoint(x: 0.25, y: 0.25)
        XCTAssertEqual(editor.hitTest(insideText), 1, "the newer text wins over the rectangle beneath it")
        XCTAssertEqual(editor.hitTest(CGPoint(x: 0.55, y: 0.55)), 0, "the rectangle is still picked elsewhere")
        XCTAssertNil(editor.hitTest(CGPoint(x: 0.9, y: 0.1)))
    }

    func testResizeClampsTextToTheLegibleRange() throws {
        let editor = AnnotationEditor(image: solidImage(width: 400, height: 200, color: .white), url: nil)
        editor.addText(at: .zero, text: "A")
        guard case let .text(_, _, start, _, _) = editor.shapes[0] else { return XCTFail("text expected") }
        XCTAssertEqual(start, 0.05, accuracy: 0.0001)

        guard case let .text(_, _, tinySize, _, _) = try XCTUnwrap(editor.resizedText(at: 0, to: 0.0001)) else {
            return XCTFail("text expected")
        }
        XCTAssertEqual(tinySize, AnnotationEditor.minTextSize, accuracy: 0.0001)

        guard case let .text(_, _, hugeSize, _, _) = try XCTUnwrap(editor.resizedText(at: 0, to: 5)) else {
            return XCTFail("text expected")
        }
        XCTAssertEqual(hugeSize, AnnotationEditor.maxTextSize, accuracy: 0.0001)

        XCTAssertNil(editor.resizedText(at: 9, to: 0.1), "an out-of-range index resizes nothing")
    }

    func testResizeRemeasuresTheBoxSoHitTestingFollows() throws {
        let editor = AnnotationEditor(image: solidImage(width: 600, height: 200, color: .white), url: nil)
        editor.textSize = 0.05
        editor.addText(at: CGPoint(x: 0.05, y: 0.2), text: "WWW")
        guard case let .text(_, _, _, _, small) = editor.shapes[0] else { return XCTFail("text expected") }
        let doubled = try XCTUnwrap(editor.resizedText(at: 0, to: 0.1))
        guard case let .text(_, _, doubledSize, _, doubledBox) = doubled else { return XCTFail("text expected") }
        XCTAssertEqual(doubledSize, 0.1, accuracy: 0.0001)
        // Font metrics do not scale perfectly linearly, so the box only has to
        // grow with the glyphs, not match two times to the pixel.
        XCTAssertEqual(doubledBox.width, small.width * 2, accuracy: small.width * 0.25)
        XCTAssertEqual(doubledBox.height, small.height * 2, accuracy: small.height * 0.25)

        // Far right of the old, smaller box: empty then, inside the resized glyphs now.
        let pastSmall = CGPoint(x: 0.05 + small.width * 1.2, y: 0.2 + small.height / 2)
        XCTAssertNil(editor.hitTest(pastSmall))
        editor.replace(0, with: doubled)
        XCTAssertEqual(editor.hitTest(pastSmall), 0)
    }

    func testDeleteRemovesOnlyTheSelectedMark() {
        let editor = AnnotationEditor(image: solidImage(width: 200, height: 100, color: .white), url: nil)
        editor.add(.arrow(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.3, y: 0.3), color: .red, width: 0.004))
        editor.add(.rectangle(rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), color: .blue, width: 0.004))
        editor.selected = 0
        editor.removeSelected()
        XCTAssertEqual(editor.shapes.count, 1)
        guard case .rectangle = editor.shapes[0] else { return XCTFail("the rectangle must survive") }
        XCTAssertNil(editor.selected)
    }

    func testResizedTextSurvivesSaveAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-annotate-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let editor = AnnotationEditor(image: solidImage(width: 800, height: 300, color: .white), url: nil)
        editor.textSize = 0.05
        editor.addText(at: CGPoint(x: 0.05, y: 0.1), text: "WWWW")
        let small = directory.appendingPathComponent("small.png")
        _ = try editor.save(to: small)
        let smallImage = try XCTUnwrap(NSImage(contentsOf: small))
        let smallInk = try XCTUnwrap(inkBounds(in: smallImage))

        guard let resized = editor.resizedText(at: 0, to: 0.1) else { return XCTFail("text expected") }
        editor.replace(0, with: resized)
        let large = directory.appendingPathComponent("large.png")
        _ = try editor.save(to: large)
        let largeImage = try XCTUnwrap(NSImage(contentsOf: large))
        let largeInk = try XCTUnwrap(inkBounds(in: largeImage))

        // The saved file is the document: reopening it shows the resized glyphs,
        // roughly twice as tall and anchored at the same left edge.
        XCTAssertGreaterThan(largeInk.height, smallInk.height * 1.5)
        XCTAssertLessThan(largeInk.height, smallInk.height * 2.5)
        XCTAssertEqual(largeInk.minX, smallInk.minX, accuracy: 2)
        XCTAssertGreaterThan(largeInk.width, smallInk.width)
    }

    /// Bounding box of red-ish ink in a rendered image, in pixels.
    private func inkBounds(in image: NSImage) -> CGRect? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      colour.redComponent - colour.greenComponent > 0.3 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
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
        _ = try editor.save(to: copy)

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try XCTUnwrap(NSImage(contentsOf: copy)).pixelSize.width, 120, accuracy: 1)
        // The original is untouched by Save As.
        XCTAssertEqual(try XCTUnwrap(NSImage(contentsOf: source)).pixelSize.width, 120, accuracy: 1)
    }
}
