import AppKit
import PaletteCore

/// One way to put a Palette window on screen. A scripted run (`PALETTE_SCRIPT`)
/// must leave the user's desktop and focus alone: its windows sit at the back of
/// the normal level and the app never activates.
@MainActor
public enum WindowPresentation {
    public static var isScripted: Bool {
        ProcessInfo.processInfo.environment["PALETTE_SCRIPT"] != nil
    }

    public static func present(_ window: NSWindow) {
        if isScripted {
            window.level = .normal
            window.orderBack(nil)
            Log.shared.info(
                "Script mode: '\(window.title)' shown without activation (appActive=\(NSApp.isActive))",
                source: "app"
            )
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
