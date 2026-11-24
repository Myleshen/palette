import SwiftUI

/// A SwiftUI-only spinner. The AppKit-backed `ProgressView` logs a SwiftUI
/// "maximum length doesn't satisfy min <= max" configuration fault hundreds of
/// times per session in tight rows, and it cannot be scaled without one.
struct PaletteSpinner: View {
    var size: CGFloat = 12
    var color: Color = .secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size / 8), lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false),
                value: spinning
            )
            .frame(width: size, height: size)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}
