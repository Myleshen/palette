import CoreGraphics

/// Where the launcher panel sits. Pure so the centring is testable without a
/// screen.
public enum LauncherPanelLayout {
    /// Smallest gap kept between the panel and the usable screen edge.
    public static let margin: CGFloat = 12

    /// Centres the panel on the display, not on the visible frame: a Dock on
    /// one side shrinks the visible frame, and centring on that dragged the
    /// panel off the display centre. The visible frame only clamps it, and
    /// only as far as the panel needs to stay fully visible.
    public static func horizontalOrigin(
        display: CGRect,
        visible: CGRect,
        width: CGFloat
    ) -> CGFloat {
        let ideal = display.midX - width / 2
        let lower = visible.minX + margin
        let upper = visible.maxX - margin - width
        // A visible frame narrower than the panel cannot fit both margins;
        // keep the leading edge on screen instead of pushing it off.
        guard upper >= lower else { return visible.minX }
        return min(max(ideal, lower), upper)
    }
}
