import Foundation

/// Pasting into some remote-desktop and virtual-machine clients synthesises a
/// ⌘V that the guest turns into a literal "v". Those targets get a copy only,
/// and the user pastes with their own ⌘V.
public enum PasteTarget {
    /// Config-free: these are protocol-level quirks, not a preference.
    public static let copyOnlyBundleIDs: Set<String> = [
        "com.microsoft.rdc.macos",
        "com.citrix.receiver.icaviewer.mac",
        "com.parallels.desktop.console",
        "com.vmware.horizon",
    ]

    /// False when Palette should copy and skip the synthetic keystroke.
    public static func synthesizesKeystroke(for bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !copyOnlyBundleIDs.contains(bundleID)
    }
}
