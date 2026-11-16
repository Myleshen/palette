import AppKit
import Foundation

/// A mark drawn on a screenshot. Coordinates and sizes are fractions of the
/// image, so the same shape renders at any zoom or window size.
public enum AnnotationShape: Equatable {
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rectangle(rect: CGRect, color: NSColor, width: CGFloat)
    case text(at: CGPoint, text: String, size: CGFloat, color: NSColor)

    public var color: NSColor {
        switch self {
        case let .arrow(_, _, color, _): return color
        case let .rectangle(_, color, _): return color
        case let .text(_, _, _, color): return color
        }
    }

    /// Moves the shape by a fraction-of-image delta.
    public func offset(by delta: CGPoint) -> AnnotationShape {
        switch self {
        case let .arrow(from, to, color, width):
            return .arrow(
                from: CGPoint(x: from.x + delta.x, y: from.y + delta.y),
                to: CGPoint(x: to.x + delta.x, y: to.y + delta.y),
                color: color,
                width: width
            )
        case let .rectangle(rect, color, width):
            return .rectangle(rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color, width: width)
        case let .text(at, text, size, color):
            return .text(at: CGPoint(x: at.x + delta.x, y: at.y + delta.y), text: text, size: size, color: color)
        }
    }
}

public enum AnnotateTool: String, CaseIterable, Identifiable {
    case arrow
    case rectangle
    case text
    case crop

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        case .crop: return "crop"
        }
    }

    public var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .text: return "Text"
        case .crop: return "Crop"
        }
    }
}

/// Everything the annotate window edits: a base image, the marks drawn on it
/// and an undo history. Nothing touches the file until `save` or `copy`.
@MainActor
public final class AnnotationEditor: ObservableObject {
    @Published public var tool: AnnotateTool = .arrow
    @Published public var color: NSColor = .systemRed
    /// Line width and text size as fractions of the image, so marks keep their
    /// weight at any resolution.
    @Published public var lineWidth: CGFloat = 0.004
    @Published public var shapes: [AnnotationShape] = []
    /// Index of the mark under the last click, for moving and deleting.
    @Published public var selected: Int?
    @Published public private(set) var image: NSImage

    public let sourceURL: URL?
    private let original: NSImage
    private var undoStack: [Snapshot] = []

    private struct Snapshot {
        var image: NSImage
        var shapes: [AnnotationShape]
    }

    public init(image: NSImage, url: URL?) {
        self.image = image
        self.original = image
        self.sourceURL = url
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(Snapshot(image: image, shapes: shapes))
        if undoStack.count > 10 { undoStack.removeFirst() }
    }

    public func add(_ shape: AnnotationShape) {
        pushUndo()
        shapes.append(shape)
        selected = shapes.count - 1
    }

    /// A drag that moves a mark must record one undo step, not one per pixel.
    public func beginChange() {
        pushUndo()
    }

    public func replace(_ index: Int, with shape: AnnotationShape) {
        guard shapes.indices.contains(index) else { return }
        shapes[index] = shape
    }

    public func remove(at index: Int) {
        guard shapes.indices.contains(index) else { return }
        pushUndo()
        shapes.remove(at: index)
        selected = nil
    }

    public func removeSelected() {
        guard let selected else { return }
        remove(at: selected)
    }

    /// Top-most mark under a point, in image fractions. Arrows are hit along
    /// their shaft, rectangles anywhere inside, text in its estimated box.
    public func hitTest(_ point: CGPoint) -> Int? {
        for index in shapes.indices.reversed() {
            if contains(shapes[index], point) { return index }
        }
        return nil
    }

    private func contains(_ shape: AnnotationShape, _ point: CGPoint) -> Bool {
        switch shape {
        case let .arrow(from, to, _, width):
            let dx = to.x - from.x
            let dy = to.y - from.y
            let lengthSquared = dx * dx + dy * dy
            let tolerance = max(0.012, width * 2)
            guard lengthSquared > 0 else {
                return hypot(point.x - from.x, point.y - from.y) < tolerance
            }
            var t = ((point.x - from.x) * dx + (point.y - from.y) * dy) / lengthSquared
            t = min(1, max(0, t))
            let closest = CGPoint(x: from.x + t * dx, y: from.y + t * dy)
            return hypot(point.x - closest.x, point.y - closest.y) < tolerance

        case let .rectangle(rect, _, width):
            let pad = max(0.006, width)
            return rect.insetBy(dx: -pad, dy: -pad).contains(point)

        case let .text(at, text, size, _):
            let pixels = image.pixelSize
            guard pixels.width > 0, pixels.height > 0 else { return false }
            let height = size * pixels.height
            let boxWidth = max(height, Double(text.count) * height * 0.62)
            let rect = CGRect(
                x: at.x * pixels.width,
                y: at.y * pixels.height,
                width: boxWidth,
                height: height * 1.3
            )
            let inPixels = CGPoint(x: point.x * pixels.width, y: point.y * pixels.height)
            return rect.contains(inPixels)
        }
    }

    public func undo() {
        guard let last = undoStack.popLast() else { return }
        image = last.image
        shapes = last.shapes
    }

    public func revert() {
        pushUndo()
        image = original
        shapes = []
    }

    /// Crops destructively but remaps every mark so nothing drawn is lost.
    public func crop(to rect: CGRect) {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0.02, clamped.height > 0.02 else { return }
        pushUndo()
        guard let cropped = image.cropped(toFraction: clamped) else { return }

        func remap(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - clamped.minX) / clamped.width,
                y: (point.y - clamped.minY) / clamped.height
            )
        }
        shapes = shapes.map { shape in
            switch shape {
            case let .arrow(from, to, color, width):
                return .arrow(from: remap(from), to: remap(to), color: color, width: width)
            case let .rectangle(rect, color, width):
                let new = CGRect(
                    x: (rect.minX - clamped.minX) / clamped.width,
                    y: (rect.minY - clamped.minY) / clamped.height,
                    width: rect.width / clamped.width,
                    height: rect.height / clamped.height
                )
                return .rectangle(rect: new, color: color, width: width)
            case let .text(at, text, size, color):
                return .text(at: remap(at), text: text, size: size, color: color)
            }
        }
        image = cropped
    }

    // MARK: - Output

    public func rendered() -> NSImage {
        let points = image.size
        let pixels = image.pixelSize
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Draw in pixels, not points: on a 2x display a 100 pt image has a
        // 200 px rep, and using points left three quarters of it transparent.
        image.draw(in: CGRect(origin: .zero, size: pixels))
        for shape in shapes {
            draw(shape, in: pixels)
        }
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: points)
        output.addRepresentation(rep)
        return output
    }

    private func draw(_ shape: AnnotationShape, in size: CGSize) {
        switch shape {
        case let .arrow(from, to, color, width):
            // Fractions are top-left; this context is bottom-left.
            let start = CGPoint(x: from.x * size.width, y: (1 - from.y) * size.height)
            let end = CGPoint(x: to.x * size.width, y: (1 - to.y) * size.height)
            let line = max(1, width * size.width)
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = line
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: end)
            path.stroke()

            // Arrow head: two barbs either side of the shaft.
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(line * 4.5, 12)
            let barb = CGFloat.pi / 7
            let headPath = NSBezierPath()
            headPath.lineWidth = line
            headPath.lineCapStyle = .round
            headPath.move(to: CGPoint(x: end.x - head * cos(angle - barb), y: end.y - head * sin(angle - barb)))
            headPath.line(to: end)
            headPath.line(to: CGPoint(x: end.x - head * cos(angle + barb), y: end.y - head * sin(angle + barb)))
            headPath.stroke()

        case let .rectangle(rect, color, width):
            let target = CGRect(
                x: rect.minX * size.width,
                y: (1 - rect.maxY) * size.height,
                width: rect.width * size.width,
                height: rect.height * size.height
            )
            color.setStroke()
            let path = NSBezierPath(rect: target)
            path.lineWidth = max(1, width * size.width)
            path.stroke()

        case let .text(at, text, sizeFraction, color):
            let fontSize = max(6, sizeFraction * size.height)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            // AppKit draws from the bottom-left; the model stores top-left.
            let box = string.boundingRect(
                with: NSSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            string.draw(at: CGPoint(
                x: at.x * size.width,
                y: size.height - (at.y * size.height) - box.height
            ))
        }
    }

    public func save(to url: URL) throws -> URL {
        let data: Data?
        if ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
            data = rendered().jpegData(compression: 0.92)
        } else {
            data = rendered().pngData()
        }
        guard let data else { throw AnnotationError.encodeFailed }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return url
    }

    @discardableResult
    public func save() throws -> URL {
        guard let sourceURL else { throw AnnotationError.noDestination }
        let data: Data?
        if ["jpg", "jpeg"].contains(sourceURL.pathExtension.lowercased()) {
            data = rendered().jpegData(compression: 0.92)
        } else {
            data = rendered().pngData()
        }
        guard let data else { throw AnnotationError.encodeFailed }
        let temp = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: temp)
        return sourceURL
    }

    public func renderedPNG() -> Data? { rendered().pngData() }

    public func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([rendered()])
    }

    public enum AnnotationError: LocalizedError {
        case noDestination
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .noDestination: return "This image has no file to save to"
            case .encodeFailed: return "Could not encode the annotated image"
            }
        }
    }
}

extension NSImage {
    /// Backing pixel size, which differs from `size` on Retina screenshots.
    public var pixelSize: CGSize {
        if let rep = representations.first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }

    /// Crops by fraction, working entirely in pixels. Asking for a CGImage
    /// through `cgImage(forProposedRect:)` rasters at the screen scale, which
    /// upscaled a 1x screenshot on a 2x display.
    fileprivate func cropped(toFraction rect: CGRect) -> NSImage? {
        guard let tiff = tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff),
              let cg = source.cgImage else { return nil }
        let width = CGFloat(source.pixelsWide)
        let height = CGFloat(source.pixelsHigh)
        let crop = CGRect(
            x: rect.minX * width,
            y: rect.minY * height,
            width: rect.width * width,
            height: rect.height * height
        )
        guard let output = cg.cropping(to: crop) else { return nil }
        let image = NSImage(size: NSSize(width: size.width * rect.width, height: size.height * rect.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: output))
        return image
    }

    fileprivate func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    fileprivate func jpegData(compression: Double) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
}
