import AppKit
import Foundation

/// A mark drawn on a screenshot. Coordinates and sizes are fractions of the
/// image, so the same shape renders at any zoom or window size.
enum AnnotationShape: Equatable {
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rectangle(rect: CGRect, color: NSColor, width: CGFloat)
    case text(at: CGPoint, text: String, size: CGFloat, color: NSColor)

    var color: NSColor {
        switch self {
        case let .arrow(_, _, color, _): return color
        case let .rectangle(_, color, _): return color
        case let .text(_, _, _, color): return color
        }
    }
}

enum AnnotateTool: String, CaseIterable, Identifiable {
    case arrow
    case rectangle
    case text
    case crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        case .crop: return "crop"
        }
    }

    var title: String {
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
final class AnnotationEditor: ObservableObject {
    @Published var tool: AnnotateTool = .arrow
    @Published var color: NSColor = .systemRed
    /// Line width and text size as fractions of the image, so marks keep their
    /// weight at any resolution.
    @Published var lineWidth: CGFloat = 0.004
    @Published var shapes: [AnnotationShape] = []
    @Published private(set) var image: NSImage

    let sourceURL: URL?
    private let original: NSImage
    private var undoStack: [Snapshot] = []

    private struct Snapshot {
        var image: NSImage
        var shapes: [AnnotationShape]
    }

    init(image: NSImage, url: URL?) {
        self.image = image
        self.original = image
        self.sourceURL = url
    }

    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(Snapshot(image: image, shapes: shapes))
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    func add(_ shape: AnnotationShape) {
        pushUndo()
        shapes.append(shape)
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        image = last.image
        shapes = last.shapes
    }

    func revert() {
        pushUndo()
        image = original
        shapes = []
    }

    /// Crops destructively but remaps every mark so nothing drawn is lost.
    func crop(to rect: CGRect) {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0.02, clamped.height > 0.02 else { return }
        pushUndo()
        let size = image.size
        let pixels = CGRect(
            x: clamped.minX * size.width,
            y: clamped.minY * size.height,
            width: clamped.width * size.width,
            height: clamped.height * size.height
        )
        guard let cropped = image.cropped(to: pixels) else { return }

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

    func rendered() -> NSImage {
        let size = image.size
        let output = NSImage(size: size)
        output.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size))
        for shape in shapes {
            draw(shape, in: size)
        }
        output.unlockFocus()
        return output
    }

    private func draw(_ shape: AnnotationShape, in size: CGSize) {
        switch shape {
        case let .arrow(from, to, color, width):
            let start = CGPoint(x: from.x * size.width, y: from.y * size.height)
            let end = CGPoint(x: to.x * size.width, y: to.y * size.height)
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
                y: rect.minY * size.height,
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

    @discardableResult
    func save() throws -> URL {
        guard let sourceURL else { throw AnnotationError.noDestination }
        let data: Data?
        if ["jpg", "jpeg"].contains(sourceURL.pathExtension.lowercased()) {
            data = rendered().jpegData(compression: 0.92)
        } else {
            data = rendered().pngData()
        }
        guard let data else { throw AnnotationError.encodeFailed }
        try data.write(to: sourceURL)
        return sourceURL
    }

    func renderedPNG() -> Data? { rendered().pngData() }

    func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([rendered()])
    }

    enum AnnotationError: LocalizedError {
        case noDestination
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noDestination: return "This image has no file to save to"
            case .encodeFailed: return "Could not encode the annotated image"
            }
        }
    }
}

extension NSImage {
    fileprivate func cropped(to rect: CGRect) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cg.width) / size.width
        let pixels = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        // CGImage crop origin is bottom-left, NSImage's is top-left.
        let flipped = CGRect(
            x: pixels.minX,
            y: CGFloat(cg.height) - pixels.maxY,
            width: pixels.width,
            height: pixels.height
        )
        guard let cropped = cg.cropping(to: flipped) else { return nil }
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: flipped.width / scale, height: flipped.height / scale)
        )
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
