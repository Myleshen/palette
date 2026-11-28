import Foundation

/// macOS appearance is user-wide. A light palette applied onto a dark system
/// looks like two different desktops, so Palette mirrors the palette's
/// appearance onto the system when the user allows it.
public enum SystemAppearance {
    public static func set(dark: Bool) async -> Bool {
        let script = "tell application \"System Events\" to tell appearance preferences "
            + "to set dark mode to \(dark ? "true" : "false")"
        guard let result = try? await ProcessRunner.run(
            ["/usr/bin/osascript", "-e", script], timeout: 8
        ) else { return false }
        return result.status == 0
    }
}
