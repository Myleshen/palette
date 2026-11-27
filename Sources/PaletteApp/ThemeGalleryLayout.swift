import CoreGraphics
import Foundation
import PaletteCore

/// A display's two rectangles, so the deck can be laid out for a list a test
/// hands in instead of the machine's real screens.
struct ThemeDeckScreen: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Everything the deck needs for one display: the panel's frame, the card size,
/// the arc and its reach. Both the window and the SwiftUI view read this one
/// value, so they cannot disagree.
struct ThemeDeckMetrics: Equatable, Sendable {
    /// The panel in screen coordinates: full visible width, resting on the
    /// visible frame's bottom edge.
    var frame: CGRect
    /// Design card size; the cards are drawn at this size and scaled as a
    /// whole, so their type and padding shrink with them.
    var cardWidth: CGFloat
    var cardHeight: CGFloat
    /// Card scale against the 260×368 design size.
    var scale: CGFloat
    var arc: ThemeCardFanGeometry
    var reach: Int
    /// Height of the fan canvas: the deck less its chrome.
    var handHeight: CGFloat
    var bottomInset: CGFloat
    var sideInset: CGFloat
    var chromeHeight: CGFloat

    /// Where one card's rotated box lands in the fan canvas, in points: x from
    /// the hand's centre, y up from the canvas bottom. The rotation pivot is
    /// the box's bottom-centre, so the AABB is not the card's frame.
    func bounds(relative: Int, progress: Double = 1) -> CGRect {
        let placement = arc.placement(relative: relative, progress: progress)
        let width = cardWidth * scale * placement.scale
        let height = cardHeight * scale * placement.scale
        let radians = abs(placement.rotation) * .pi / 180
        let halfWidth = width / 2 * cos(radians) + height * sin(radians)
        return CGRect(
            x: placement.x - halfWidth,
            y: placement.y - width / 2 * sin(radians),
            width: halfWidth * 2,
            height: height * cos(radians) + width * sin(radians)
        )
    }

    /// The box every card must stay inside: the deck's width less the side
    /// inset, the fan canvas' height.
    var canvas: CGRect {
        CGRect(
            x: -frame.width / 2 + sideInset,
            y: 0,
            width: max(0, frame.width - 2 * sideInset),
            height: handHeight
        )
    }
}

/// One place for the gallery's frame numbers: the panel and the SwiftUI view
/// must agree or the hand letterboxes or spills past the panel edge.
///
/// The deck is a hand of cards laid on a table: it spans the whole usable width
/// of the display the pointer is on and rests on its bottom edge. Card size,
/// reach and the arc all come from that frame, so a 1024×640 laptop, a 1080×1920
/// portrait panel and a 3440×1440 ultrawide each show the whole hand.
enum ThemeGalleryLayout {
    /// Card size and hand proportions at full scale.
    static let cardWidth: CGFloat = 260
    static let cardHeight: CGFloat = 368
    static let designSkirt: CGFloat = 42
    /// Air above the selected card for its shadow.
    static let air: CGFloat = 22
    /// Vertical room the arc needs below the apex at full scale.
    static let designArcRoom: CGFloat = 80

    /// The deck takes this share of the usable screen height.
    static let heightFraction: CGFloat = 0.60
    /// Never smaller than this, so a tiny screen still shows a readable card.
    static let minimumScale: CGFloat = 0.35
    /// Header, footer and the view's vertical padding around the hand.
    static let chromeHeight: CGFloat = 88
    /// Breathing room between the last card's rotated corner and the edge.
    static let sideInset: CGFloat = 24
    static let bottomInset: CGFloat = 24
    static let minReach = 2
    static let maxReach = 9
    /// The hand never fans past this, however much room a huge display leaves.
    static let maxAngle: Double = 34

    /// One card + skirt + arc room + air, at full scale.
    static var designHandHeight: CGFloat {
        cardHeight + designSkirt + designArcRoom + air
    }

    /// How far a full-size card's rotated box reaches past its centre at the
    /// widest angle. The pivot is the bottom edge, so the top corner travels
    /// furthest.
    static var designHalfWidth: CGFloat {
        let radians = maxAngle * .pi / 180
        return (cardWidth / 2 * cos(radians) + cardHeight * sin(radians))
            * ThemeCardFanGeometry.standard.sideScale
    }

    /// A wider deck shows a wider hand. Measured against the design card, so
    /// shrinking the cards on a short screen does not inflate the reach. Two a
    /// side on a phone, three on a small laptop, nine on an ultrawide.
    static func reach(forWidth width: CGFloat) -> Int {
        let steps = ((width / 2 - sideInset) / (cardWidth * 0.55)).rounded()
        return min(maxReach, max(minReach, Int(steps)))
    }

    /// The layout for one display's usable area.
    static func metrics(in visible: CGRect) -> ThemeDeckMetrics {
        let width = max(0, visible.width)
        let height = max(0, visible.height)
        // Tall enough for one readable card plus its chrome, never taller than
        // the screen, never negative on a degenerate one.
        let minimum = chromeHeight + designHandHeight * minimumScale
        let deckHeight = min(height, max(height * heightFraction, minimum))
        let hand = max(0, deckHeight - chromeHeight)

        // Shrink the cards when the hand is short, or the display too narrow
        // for a full card and its rotated corner.
        let widthScale = (width / 2 - sideInset) / max(1, designHalfWidth)
        let scale = min(1, hand / designHandHeight, max(0.1, widthScale))
        let cardWidth = cardWidth * scale
        let cardHeight = cardHeight * scale
        let skirt = designSkirt * scale
        let air = air * scale
        // The highest the apex may sit: the selected card's top stays in.
        let apexCeiling = max(skirt, hand - cardHeight - air)

        var arc = ThemeCardFanGeometry.standard
        arc.sideScale = ThemeCardFanGeometry.standard.sideScale
        let reach = reach(forWidth: width)

        // The widest span this frame can carry: a wider deck spreads further,
        // but the outermost rotated corner must stay inside the side inset and
        // the hand may not sink below the canvas. Both are monotonic in the
        // angle, so a bisection gives the exact fit instead of a wobbling
        // fixed point.
        func halfWidth(at degrees: Double) -> CGFloat {
            let radians = degrees * .pi / 180
            return (cardWidth / 2 * cos(radians) + cardHeight * sin(radians)) * arc.sideScale
        }
        func fits(_ degrees: Double) -> Bool {
            guard degrees > 0 else { return true }
            let radians = degrees * .pi / 180
            let spread = width / 2 - sideInset - halfWidth(at: degrees)
            guard spread > 0 else { return false }
            let radius = spread / sin(radians)
            let drop = radius * (1 - cos(radians))
            let dip = cardWidth / 2 * sin(radians)
            return drop + dip <= apexCeiling - skirt + 0.001
        }
        var low = 0.0
        var high = maxAngle
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        let angle = low
        let radians = angle * .pi / 180
        let halfWidth = halfWidth(at: angle)
        let spread = max(1, width / 2 - sideInset - halfWidth)
        let radius = angle > 0 ? spread / sin(radians) : 0
        let drop = radius * (1 - cos(radians))
        let dip = cardWidth / 2 * sin(radians)
        // Rest the hand on the bottom edge unless the top of the deck clamps it.
        let apexY = min(apexCeiling, drop + dip + skirt)

        arc.radius = radius
        arc.stepAngle = angle / Double(reach)
        arc.maxAngle = angle
        arc.apexY = apexY
        arc.rise = apexY + cardHeight

        return ThemeDeckMetrics(
            frame: CGRect(x: visible.minX, y: visible.minY, width: width, height: deckHeight),
            cardWidth: Self.cardWidth,
            cardHeight: Self.cardHeight,
            scale: scale,
            arc: arc,
            reach: reach,
            handHeight: hand,
            bottomInset: bottomInset,
            sideInset: sideInset,
            chromeHeight: chromeHeight
        )
    }

    /// The display the pointer is on, falling back to the system's main screen
    /// when the pointer sits in the gap between displays.
    static func screenIndex(for point: CGPoint, screens: [CGRect], fallback: Int = 0) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let hit = screens.firstIndex(where: { $0.contains(point) }) { return hit }
        return screens.indices.contains(fallback) ? fallback : 0
    }

    /// The deck for the display under the pointer. Rebuilt on every show and on
    /// every display change, so a replugged monitor is laid out from scratch.
    static func metrics(
        for point: CGPoint,
        screens: [ThemeDeckScreen],
        fallback: Int = 0
    ) -> ThemeDeckMetrics? {
        guard let index = screenIndex(
            for: point,
            screens: screens.map(\.frame),
            fallback: fallback
        ) else { return nil }
        return metrics(in: screens[index].visibleFrame)
    }

    /// The focused preview fills the deck edge to edge; only the fan and its
    /// header get the side padding.
    static func previewFrame(in deck: CGRect) -> CGRect { deck }

    /// The panel's frame alone, for callers that do not need the fan numbers.
    static func frame(in visible: CGRect) -> CGRect { metrics(in: visible).frame }
}
