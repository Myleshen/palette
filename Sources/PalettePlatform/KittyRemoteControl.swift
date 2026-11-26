import Foundation
import PaletteCore

/// Drives a running kitty over its remote-control socket. `@ ls` answers
/// whether remote control is on at all; `@ set-colors` is the only command
/// Palette sends, so the theme file only ever contains colour directives.
public struct KittyRemoteControl: Sendable {
    public var binary: String
    private let run: @Sendable (String, [String], TimeInterval) async throws -> ProcessResult

    /// The binary can be absolute (`PALETTE_KITTY`, tests) or a name resolved
    /// through `ToolLocator`.
    public init(
        binary: String = "kitty",
        run: @escaping @Sendable (String, [String], TimeInterval) async throws -> ProcessResult = { binary, args, timeout in
            try await ProcessRunner.run([binary] + args, timeout: timeout)
        }
    ) {
        self.binary = binary
        self.run = run
    }

    public func isAvailable() async -> Bool {
        guard let result = try? await run(binary, ["@", "ls"], 2) else { return false }
        return result.status == 0
    }

    public func setColors(_ path: String) async -> Bool {
        guard let result = try? await run(binary, ["@", "set-colors", "-a", path], 3) else { return false }
        return result.status == 0
    }

    /// Always reports what the app actually said. A missing binary, remote
    /// control off, or a refused command all end as "restart kitty", never as
    /// success.
    public func reload(themeFile: String) async -> ThemingReload.Status {
        guard await isAvailable() else {
            return ThemingReload.kitty(remoteControl: false, applied: false)
        }
        return ThemingReload.kitty(remoteControl: true, applied: await setColors(themeFile))
    }
}
