import CoreGraphics
import Foundation

/// Where one card sits in the fanned hand. Values are relative to the
/// selection's centre: positive x is right, positive y is down.
public struct ThemeCardFanPlacement: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    /// Degrees; positive leans right.
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

/// The "hand of cards" proportions, following omarchy-card-picker's Hearthstone
/// layout: each step to the side moves the card along, rotates it a little and
/// lowers it, and the selection sits upright at full size on top.
public struct ThemeCardFanGeometry: Equatable, Sendable {
    /// Horizontal distance between neighbouring card centres.
    public var stepX: CGFloat
    /// Extra downward drop at one step, squared per step.
    public var arcDrop: CGFloat
    public var maxDrop: CGFloat
    /// Rotation at one step and the cap at the ends of the hand.
    public var stepRotation: Double
    public var maxRotation: Double
    /// Side cards are drawn smaller so the selected one reads as the front.
    public var sideScale: CGFloat
    /// How far the selected card rises out of the hand.
    public var selectedLift: CGFloat

    public init(
        stepX: CGFloat = 122,
        arcDrop: CGFloat = 7,
        maxDrop: CGFloat = 26,
        stepRotation: Double = 6,
        maxRotation: Double = 15,
        sideScale: CGFloat = 0.85,
        selectedLift: CGFloat = 46
    ) {
        self.stepX = stepX
        self.arcDrop = arcDrop
        self.maxDrop = maxDrop
        self.stepRotation = stepRotation
        self.maxRotation = maxRotation
        self.sideScale = sideScale
        self.selectedLift = selectedLift
    }

    public static let standard = ThemeCardFanGeometry()

    /// `deal` is the 0...1 deal-on-open progress. At 0 every card sits stacked
    /// at the centre and upright, then the spring fans it out.
    public func placement(
        relative: Int,
        reduceMotion: Bool = false,
        deal: Double = 1
    ) -> ThemeCardFanPlacement {
        let progress = min(max(deal, 0), 1)
        let distance = Double(abs(relative))
        if relative == 0 {
            return ThemeCardFanPlacement(
                x: 0,
                y: -selectedLift * CGFloat(progress),
                rotation: 0,
                scale: 1 - (1 - progress) * 0.1,
                dim: 0,
                zIndex: 1000
            )
        }
        let rotation = min(distance * stepRotation, maxRotation) * (relative < 0 ? -1 : 1)
        let drop = min(arcDrop * CGFloat(relative * relative), maxDrop)
        return ThemeCardFanPlacement(
            x: CGFloat(relative) * stepX * CGFloat(progress),
            y: (reduceMotion ? 0 : drop) * CGFloat(progress),
            rotation: reduceMotion ? 0 : rotation * progress,
            scale: sideScale - (sideScale - 0.8) * CGFloat(1 - progress),
            dim: min(0.62, 0.30 + distance * 0.05) * progress,
            zIndex: 500 - min(distance, 40)
        )
    }
}
