import Foundation

/// Editors that own one window per process. Handed a path through
/// LaunchServices they route it into the instance that is already open, so two
/// projects end up as two buffers in one window.
public enum EditorLaunch {
    /// Bundle names whose binary can be started again for a second window.
    private static let newInstanceApps: Set<String> = ["neovide"]

    /// Editors that keep one window and route a new path into it. Only the
    /// ones we know by name; an unknown app gets no claim in the UI.
    private static let windowReusingEditors: Set<String> = [
        "neovide", "visual studio code", "cursor", "zed", "sublime text",
        "windsurf", "fleet", "xcode",
    ]

    /// argv that opens `path` in its own instance, or nil when this app can
    /// only be handed to the running instance.
    public static func newInstanceCommand(appPath: String, path: String) -> [String]? {
        guard newInstanceApps.contains(appName(appPath).lowercased()) else { return nil }
        let binary = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(Self.appName(appPath).lowercased())
            .path
        // --fork is neovide's own flag for detaching from whoever started it,
        // so nothing in Palette stays attached to the editor process.
        return [binary, "--fork", path]
    }

    /// True when opening a second path in this editor lands in the window that
    /// is already open, so the row can say so instead of hiding it.
    public static func reusesOpenWindow(app: String) -> Bool {
        let name = appName(app).lowercased()
        return windowReusingEditors.contains(name) && !newInstanceApps.contains(name)
    }

    private static func appName(_ appPath: String) -> String {
        let name = (appPath as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
