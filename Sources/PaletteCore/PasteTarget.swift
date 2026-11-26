import Foundation

/// Pasting into some remote-desktop and virtual-machine clients synthesises a
/// ⌘V that the guest turns into a literal "v". Those targets get a copy only,
/// and the user pastes with their own ⌘V.
public enum PasteTarget {
    /// How Palette should hand the clipboard to the target.
    public enum Route: Equatable, Sendable {
        /// Press the app's Edit ▸ Paste menu item through Accessibility.
        case menu
        /// Post a synthetic ⌘V (⌃V for an image in a terminal).
        case keystroke
        /// Clipboard only: the target mangles an injected shortcut.
        case copyOnly
    }

    /// Config-free: these are protocol-level quirks, not a preference.
    public static let copyOnlyBundleIDs: Set<String> = [
        "com.microsoft.rdc.macos",
        "com.citrix.receiver.icaviewer.mac",
        "com.parallels.desktop.console",
        "com.vmware.horizon",
    ]

    /// Terminals whose own paste path (⌃V) is what TUI editors read an image
    /// from, so an image skips the menu route there.
    public static let imageControlPasteBundleIDs: Set<String> = [
        "net.kovidgoyal.kitty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.wez.wezterm",
        "org.alacritty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
    ]

    /// Terminals that pass a keyed ⌘V through to whatever runs inside them
    /// (Neovide hands nvim `<d+v>`). They get a menu press or the clipboard
    /// only, never a bare ⌘V. Every other terminal pastes ⌘V itself.
    public static let copyOnlyWhenNoMenuBundleIDs: Set<String> = [
        "org.neovide.neovide",
    ]

    /// False when Palette should copy and skip the synthetic keystroke.
    public static func synthesizesKeystroke(for bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !copyOnlyBundleIDs.contains(bundleID)
    }

    /// Menu first: pressing Edit ▸ Paste through Accessibility is exactly what
    /// a GUI paste is, and it never reaches the target's key handling. A
    /// terminal without that item must not get a bare ⌘V, so it copies only.
    public static func route(bundleID: String?, menuAvailable: Bool, image: Bool = false) -> Route {
        guard synthesizesKeystroke(for: bundleID) else { return .copyOnly }
        if image, let bundleID, imageControlPasteBundleIDs.contains(bundleID) {
            return .keystroke
        }
        if menuAvailable { return .menu }
        if let bundleID, copyOnlyWhenNoMenuBundleIDs.contains(bundleID) { return .copyOnly }
        return .keystroke
    }
}
