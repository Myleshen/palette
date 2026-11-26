import AppKit
import Foundation
import ImageIO

/// The brief capture thumbnail and the annotator need pixels, not a full-size
/// decode on the main thread. ImageIO can downsample while reading, so the HUD
/// never allocates a 6K bitmap to draw 260 points.
public enum ScreenshotThumbnail {
    /// Largest point size the HUD draws; the thumbnail is decoded to this size
    /// at the current screen scale, so Retina loses nothing and the next
    /// smaller screen does not carry a huge image.
    public static let maxPointSize = CGSize(width: 260, height: 170)

    /// Pixel edge ImageIO should produce. Pure so the size choice is testable.
    public static func maxPixelSize(scale: CGFloat) -> Int {
        let edge = max(maxPointSize.width, maxPointSize.height) * max(1, scale)
        return Int(edge.rounded(.up))
    }

    /// Full-size image for the annotator/OCR. Call off the main actor.
    public static func cgImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Downsampled image for the HUD. Call off the main actor.
    public static func image(at url: URL, scale: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(scale: scale),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let divisor = max(1, scale)
        return NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: CGFloat(cgImage.width) / divisor,
                height: CGFloat(cgImage.height) / divisor
            )
        )
    }
}
