import CoreGraphics
import Foundation

/// Where one card sits in the fanned hand. The card's bottom-centre is the
/// rotation pivot: `x` is its offset from the hand's centre, `y` is the pivot's
/// height above the fan canvas' bottom edge.
public struct ThemeCardFanPlacement: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    /// Degrees, the arc's tangent: positive leans right.
    public var rotation: Double
    public var scale: CGFloat
    /// Black overlay, 0...1.
    public var dim: Double
    public var zIndex: Double

    public init(
        x: CGFloat = 0,
        y: CGFloat = 0,
        rotation: Double = 0,
        scale: CGFloat = 1,
        dim: Double = 0,
        zIndex: Double = 500
    ) {
        self.x = x
        self.y = y
        self.rotation = rotation
        self.scale = scale
        self.dim = dim
        self.zIndex = zIndex
    }
}

/// The "hand of cards" arc, following omarchy-card-picker: the cards' bottoms
/// ride a circle whose centre sits below the deck's bottom edge, so the
/// selection is the arc's apex and its neighbours descend and tilt outward by
/// the tangent angle.
public struct ThemeCardFanGeometry: Equatable, Sendable {
    /// Radius of the card-bottom arc, in points.
    public var radius: CGFloat
    /// Degrees between neighbouring cards.
    public var stepAngle: Double
    /// Degrees at the last visible card: the step is clamped to this.
    public var maxAngle: Double
    /// Height of the selected card's pivot above the canvas bottom.
    public var apexY: CGFloat
    /// How far below the canvas the collapsed hand starts when it deals in.
    public var rise: CGFloat
    /// Side cards are drawn smaller so the selected one reads as the front.
    public var sideScale: CGFloat
    /// The scale side cards settle at once the deal is over.
    public var sideFloorScale: CGFloat
    public var dimBase: Double
    public var dimStep: Double
    public var dimMax: Double

    public init(
        radius: CGFloat = 2200,
        stepAngle: Double = 2.7,
        maxAngle: Double = 16,
        apexY: CGFloat = 164,
        rise: CGFloat = 532,
        sideScale: CGFloat = 0.85,
        sideFloorScale: CGFloat = 0.8,
        dimBase: Double = 0.30,
        dimStep: Double = 0.05,
        dimMax: Double = 0.62
    ) {
        self.radius = radius
        self.stepAngle = stepAngle
        self.maxAngle = maxAngle
        self.apexY = apexY
        self.rise = rise
        self.sideScale = sideScale
        self.sideFloorScale = sideFloorScale
        self.dimBase = dimBase
        self.dimStep = dimStep
        self.dimMax = dimMax
    }

    public static let standard = ThemeCardFanGeometry()

    /// The arc angle of one card, degrees, signed by side.
    public func angle(relative: Int) -> Double {
        let degrees = min(Double(abs(relative)) * stepAngle, maxAngle)
        return relative < 0 ? -degrees : degrees
    }

    /// `progress` is the 0...1 deal-on-open (already staggered per card by
    /// `ThemeDeckMotion`). At 0 every card sits collapsed and below the canvas,
    /// then the hand rises and fans onto the arc.
    public func placement(relative: Int, progress: Double = 1) -> ThemeCardFanPlacement {
        let p = min(max(progress, 0), 1)
        let radians = angle(relative: relative) * p * .pi / 180
        let drop = radius * (1 - cos(radians))
        let collapsed = (1 - p) * rise
        let x = radius * sin(radians)
        let y = apexY - drop - collapsed
        if relative == 0 {
            return ThemeCardFanPlacement(
                x: 0,
                y: y,
                rotation: 0,
                scale: 1 - (1 - p) * 0.08,
                dim: 0,
                zIndex: 1000
            )
        }
        let distance = Double(abs(relative))
        return ThemeCardFanPlacement(
            x: x,
            y: y,
            rotation: radians * 180 / .pi,
            scale: sideScale - (sideScale - sideFloorScale) * CGFloat(1 - p),
            dim: min(dimMax, dimBase + distance * dimStep) * p,
            zIndex: 500 - min(distance, 40)
        )
    }
}

/// Motion for the deck: one spring drives the deal and the selection, with a
/// per-card stagger on the open so the hand unfolds from the middle instead of
/// moving as one rigid bar.
public struct ThemeDeckMotion: Equatable, Sendable {
    public var response: Double
    public var damping: Double
    /// Share of the deal one step of distance waits for.
    public var stagger: Double
    public var hoverScale: CGFloat
    public var hoverLift: CGFloat
    /// Duration of the Reduce Motion crossfade, in seconds.
    public var crossfade: Double

    public init(
        response: Double = 0.33,
        damping: Double = 0.84,
        stagger: Double = 0.025,
        hoverScale: CGFloat = 1.03,
        hoverLift: CGFloat = 8,
        crossfade: Double = 0.16
    ) {
        self.response = response
        self.damping = damping
        self.stagger = stagger
        self.hoverScale = hoverScale
        self.hoverLift = hoverLift
        self.crossfade = crossfade
    }

    public static let standard = ThemeDeckMotion()

    /// The card's own share of the deal. Outer cards start a few percent later,
    /// so the fan ripples outward; still one animatable value, no timers.
    public func progress(for relative: Int, deal: Double) -> Double {
        let start = min(0.4, Double(abs(relative)) * stagger)
        let local = (deal - start) / max(0.0001, 1 - start)
        return min(max(local, 0), 1)
    }
}
