import AppKit
import PaletteCore
import PaletteProviders
import SwiftUI

/// A dedicated ask window: one question, one answer, no conversation. The
/// panel stays the place you type; this is where the answer lands.
@MainActor
final class AskWindowController: NSWindowController, NSWindowDelegate {
    private let state: AskWindowState
    var onClose: (() -> Void)?

    init(service: AskService, question: String, model: AskModel, themeManager: ThemeManager) {
        let theme = themeManager.theme
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
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
        state = AskWindowState(service: service, question: question, model: model)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: AskWindowView(
            state: state,
            themeManager: themeManager,
            close: { [weak self] in self?.close() }
        ))
        window.center()
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
        state.cancel()
    }

    func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        showWindow(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        state.start()
    }
}
