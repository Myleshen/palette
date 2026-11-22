import AppKit
import PaletteCore
import SwiftUI

/// Brief thumbnail that appears after a capture so a screenshot is never a
/// silent "did that work?".
@MainActor
final class ScreenshotHUD {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var hovering = false
    private var onOpen: (() -> Void)?

    func show(image: NSImage, title: String, theme: Theme, onOpen: @escaping () -> Void) {
        dismiss()
        self.onOpen = onOpen

        let size = image.size
        let maxWidth: CGFloat = 260
        let maxHeight: CGFloat = 170
        let scale = min(1, min(maxWidth / max(1, size.width), maxHeight / max(1, size.height)))
        let width = max(120, size.width * scale)
        let height = size.height * scale

        let content = ScreenshotHUDContent(
            image: image,
            title: title,
            theme: theme,
            width: width,
            height: height,
            onOpen: { [weak self] in self?.activate() },
            onHover: { [weak self] in self?.setHovering($0) }
        )

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

        // The panel never becomes key, so a local monitor supplies Return and
        // Space while it is on screen. Any key also counts as activity.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let panel = self.panel else { return false }
                // Do not swallow Return or Space while another Palette window
                // (Settings, the launcher) has focus.
                if let keyWindow = NSApp.keyWindow, keyWindow !== panel { return false }
                self.extendDismissal()
                if keyCode == 36 || keyCode == 49 {
                    self.activate()
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        scheduleDismiss()
    }

    var view: NSView? { panel?.contentView }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        hovering = false
        onOpen = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func activate() {
        let open = onOpen
        dismiss()
        open?()
    }

    private func setHovering(_ value: Bool) {
        hovering = value
        if value {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleDismiss()
        }
    }

    /// Keyboard activity keeps the thumbnail around a little longer.
    private func extendDismissal() {
        guard !hovering else { return }
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.dismiss()
        }
    }
}

private struct ScreenshotHUDContent: View {
    let image: NSImage
    let title: String
    let theme: Theme
    let width: CGFloat
    let height: CGFloat
    let onOpen: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
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
                if !reduceTransparency {
                    GlassBackdrop(material: .hudWindow)
                        .allowsHitTesting(false)
                }
                shape.fill(
                    theme.color(theme.palette.elevated)
                        .opacity(reduceTransparency ? 1 : 0.8)
                )
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.color(theme.palette.border)))
        }
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .onHover(perform: onHover)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screenshot thumbnail, \(title)")
        .accessibilityHint("Press Return or Space to open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }
}
