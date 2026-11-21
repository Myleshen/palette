import AppKit
import PaletteCore
import SwiftUI

/// Brief thumbnail that appears after a capture so a screenshot is never a
/// silent "did that work?".
@MainActor
final class ScreenshotHUD {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(image: NSImage, title: String, theme: Theme, onOpen: @escaping () -> Void) {
        dismiss()

        let size = image.size
        let maxWidth: CGFloat = 260
        let maxHeight: CGFloat = 170
        let scale = min(1, min(maxWidth / max(1, size.width), maxHeight / max(1, size.height)))
        let width = max(120, size.width * scale)
        let height = size.height * scale

        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let content = VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.color(theme.palette.fgMuted))
                .lineLimit(1)
        }
        .padding(8)
        .background {
            ZStack {
                GlassBackdrop(material: .hudWindow)
                    .allowsHitTesting(false)
                shape.fill(theme.color(theme.palette.elevated).opacity(0.8))
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.color(theme.palette.border)))
        }
        .onTapGesture { onOpen() }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + 16, height: height + 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.appearance = theme.nsAppearance
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        panel.ignoresMouseEvents = false

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.minY + 24
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            dismiss()
        }
    }

    var view: NSView? { panel?.contentView }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
