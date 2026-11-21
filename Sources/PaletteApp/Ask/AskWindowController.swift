import AppKit
import PaletteCore
import PalettePlatform
import PaletteProviders
import SwiftUI

/// A dedicated ask window: a conversation transcript with a composer. The
/// panel stays the place you start it; this is where the chat lives.
@MainActor
final class AskWindowController: NSWindowController, NSWindowDelegate {
    private let state: AskWindowState
    var onClose: (() -> Void)?

    init(
        service: AskService,
        question: String,
        model: AskModel,
        themeManager: ThemeManager,
        notify: Bool
    ) {
        let theme = themeManager.theme
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        // Utility panels hide themselves when another app takes focus; a chat
        // must stay on screen while you read or copy from it.
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilitySubrole(.dialog)
        window.title = "Ask"
        window.appearance = theme.nsAppearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = theme.nsColor(theme.palette.bg)
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 420)
        state = AskWindowState(
            service: service,
            question: question,
            model: model,
            notify: notify,
            isKey: { [weak window] in window?.isKeyWindow ?? false }
        )
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: AskWindowView(
            state: state,
            themeManager: themeManager,
            close: { [weak self] in self?.close() }
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(theme: Theme) {
        window?.appearance = theme.nsAppearance
        window?.backgroundColor = theme.nsColor(theme.palette.bg)
    }

    /// Closing the window must also stop the request, or a slow model would
    /// keep the app busy with nobody waiting for the answer.
    func windowWillClose(_ notification: Notification) {
        state.cancel()
        onClose?()
    }

    /// The Cancel button and the scripted `cancel` step share this path.
    func cancelRequest() {
        state.stop()
    }

    func show(below panelFrame: NSRect? = nil) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        position(below: panelFrame)
        showWindow(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        if let window {
            Log.shared.info(
                "Ask window at \(window.frame), visible=\(window.isVisible), hidesOnDeactivate=\(window.hidesOnDeactivate)",
                source: "app"
            )
        }
        state.start()
    }

    /// Under the launcher when the screen has room, above or beside it
    /// otherwise, so the launcher and the answer stay usable together.
    private func position(below panelFrame: NSRect?) {
        guard let window else { return }
        guard let panelFrame else {
            window.center()
            return
        }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panelFrame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        let margin: CGFloat = 12
        var origin = NSPoint(x: panelFrame.midX - size.width / 2, y: panelFrame.minY - margin - size.height)
        if origin.y < visible.minY + margin {
            origin.y = panelFrame.maxY + margin
        }
        if origin.y + size.height > visible.maxY - margin {
            // No room above or below: stand beside the panel instead.
            origin.y = panelFrame.midY - size.height / 2
            let right = panelFrame.maxX + margin
            origin.x = right + size.width <= visible.maxX - margin
                ? right
                : panelFrame.minX - margin - size.width
        }
        origin.x = min(max(visible.minX + margin, origin.x), visible.maxX - size.width - margin)
        origin.y = min(max(visible.minY + margin, origin.y), visible.maxY - size.height - margin)
        window.setFrameOrigin(origin)
    }
}
