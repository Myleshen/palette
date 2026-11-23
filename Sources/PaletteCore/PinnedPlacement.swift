import CoreGraphics
import Foundation

/// Session-only geometry for pinned screenshots: where the next pin lands and
/// when the oldest one has to go. Pure so the rules are testable without AppKit.
public enum PinnedPlacement {
    /// Each pin steps down and right from the previous one.
    public static let cascade = CGSize(width: 24, height: 24)
    /// How many pins may be on screen at once; past this the oldest closes.
    public static let maximumPins = 8
    /// Breathing room between a pin and the screen edge.
    public static let margin: CGFloat = 24

    /// The frame for the next pin, scaled down to fit `screen` and cascaded
    /// from the previous one. The first pin sits in the middle of that screen.
    public static func frame(previous: CGRect?, size: CGSize, screen: CGRect) -> CGRect {
        let fitted = fit(size, in: screen)
        let origin: CGPoint
        if let previous {
            origin = CGPoint(
                x: previous.minX + cascade.width,
                y: previous.minY + cascade.height
            )
        } else {
            origin = CGPoint(
                x: screen.midX - fitted.width / 2,
                y: screen.midY - fitted.height / 2
            )
        }
        return clamp(CGRect(origin: origin, size: fitted), to: screen)
    }

    /// How many of the oldest pins to close so `maximumPins` is never exceeded
    /// after opening one more. `existing` is the count before adding it.
    public static func evictedCount(existing: Int) -> Int {
        max(0, existing + 1 - maximumPins)
    }

    /// Keeps a frame wholly on screen, taking the nearest edge when a pin is
    /// dragged, scrolled or cascaded past it.
    public static func clamp(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var result = frame
        let inset = screen.insetBy(
            dx: min(margin, screen.width / 2),
            dy: min(margin, screen.height / 2)
        )
        result.origin.x = min(max(result.minX, inset.minX), max(inset.minX, inset.maxX - result.width))
        result.origin.y = min(max(result.minY, inset.minY), max(inset.minY, inset.maxY - result.height))
        return result
    }

    /// A screenshot larger than the screen would cover the work it was pinned
    /// to compare against, so it is scaled down; smaller ones stay 1:1.
    static func fit(_ size: CGSize, in screen: CGRect) -> CGSize {
        let available = CGSize(
            width: max(1, screen.width - margin * 2),
            height: max(1, screen.height - margin * 2)
        )
        guard size.width > 0, size.height > 0 else { return available }
        let scale = min(1, min(available.width / size.width, available.height / size.height))
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }
}
