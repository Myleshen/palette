import Foundation

/// What a running app does with a freshly written palette file, and whether
/// Palette can make it happen. Pure mapping so the rows and the Apply result
/// say the same thing; the only target Palette can reload itself is kitty.
public enum ThemingReload {
    public struct Status: Sendable, Equatable {
        public enum State: String, Sendable, Equatable {
            /// Palette applied it to the running app.
            case reloaded
            /// The user has to restart, open a new session or source a file.
            case action
            /// Palette tried and the app refused.
            case failed
        }

        public var state: State
        public var message: String

        public init(state: State, message: String) {
            self.state = state
            self.message = message
        }
    }

    /// Only kitty exposes a remote control that can re-apply colours to a
    /// running instance. Ghostty has no reload signal, zellij reads its config
    /// at session start, and the rest pick the file up on their next run.
    public static func canAttempt(_ target: ThemingTarget) -> Bool {
        target == .kitty
    }

    public static func status(for target: ThemingTarget) -> Status {
        if target.isBrowser {
            return Status(
                state: .action,
                message: "Restart the browser (or relaunch it with --refresh-platform-policy)"
            )
        }
        switch target {
        case .kitty:
            return Status(state: .action, message: "Restart kitty (remote control disabled)")
        case .ghostty:
            return Status(state: .action, message: "Restart Ghostty")
        case .zellij:
            return Status(state: .action, message: "New zellij session")
        case .nvim:
            return Status(
                state: .action,
                message: "Run :source ~/.config/palette/theme/nvim.lua or restart Neovim"
            )
        case .fish:
            return Status(
                state: .action,
                message: "Open a new shell (or `source ~/.config/palette/theme/fish.fish`)"
            )
        case .starship:
            return Status(
                state: .action,
                message: "New shell (or `source ~/.config/palette/theme/starship-palette.fish`)"
            )
        case .bat:
            return Status(state: .action, message: "Next bat invocation")
        case .btop:
            return Status(state: .action, message: "Restart btop")
        case .delta:
            return Status(state: .action, message: "Next git/delta command")
        case .yazi:
            return Status(
                state: .action,
                message: "Copy the theme to ~/.config/yazi/theme.toml, then restart yazi"
            )
        case .vscode, .zed, .arc, .neovide:
            return Status(state: .action, message: target.unavailableReason ?? "Not configured yet.")
        default:
            return Status(state: .action, message: target.unavailableReason ?? "Not configured yet.")
        }
    }

    /// Kitty is the only target with a real answer from the app: `kitty @ ls`
    /// proves remote control is on, `set-colors` proves the colours landed.
    public static func kitty(remoteControl: Bool, applied: Bool) -> Status {
        guard remoteControl else {
            return Status(state: .action, message: "Restart kitty (remote control disabled)")
        }
        guard applied else {
            return Status(state: .failed, message: "Restart kitty (reload failed)")
        }
        return Status(state: .reloaded, message: "Reloaded open kitty windows")
    }
}
