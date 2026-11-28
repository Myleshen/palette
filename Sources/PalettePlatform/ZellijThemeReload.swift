import Foundation

/// Zellij has no config watcher, but it can switch its active theme at runtime
/// (`set-dark-theme` / `set-light-theme`) from the `theme_dark` / `theme_light`
/// keys. Palette writes both to point at its own theme, then asks every running
/// session to switch, so an open session picks up a new palette without being
/// restarted.
public enum ZellijThemeReload {
    public static func sessions(binary: String) async -> [String] {
        guard let result = try? await ProcessRunner.run(
            [binary, "list-sessions", "-n", "-s"], timeout: 5
        ), result.status == 0 else { return [] }
        return result.stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("EXITED") }
    }

    /// Returns how many sessions accepted the switch.
    public static func reload(binary: String, appearance: String) async -> Int {
        let action = appearance == "light" ? "set-light-theme" : "set-dark-theme"
        var switched = 0
        for name in await sessions(binary: binary) {
            if let result = try? await ProcessRunner.run(
                [binary, "--session", name, "action", action], timeout: 4
            ), result.status == 0 {
                switched += 1
            }
        }
        return switched
    }
}
