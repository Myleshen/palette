import Foundation
import PaletteCore

/// Drives a running kitty over its remote-control socket. Palette's managed
/// block turns `allow_remote_control socket-only` on, so after one restart
/// every running kitty has a unix socket under `$XDG_RUNTIME_DIR`; Palette
/// finds it from the user's `listen_on` template and sends only `set-colors`.
public struct KittyRemoteControl: Sendable {
    public var binary: String
    /// Filesystem sockets are discovered through this environment, not the
    /// app's real one, so tests can point at a sandbox runtime directory.
    private let environment: [String: String]
    private let runningKittyPIDs: @Sendable () async -> Set<Int>
    private let run: @Sendable (String, [String], TimeInterval) async throws -> ProcessResult

    /// The binary can be absolute (`PALETTE_KITTY`, tests) or a name resolved
    /// through `ToolLocator`.
    public init(
        binary: String = "kitty",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runningKittyPIDs: @escaping @Sendable () async -> Set<Int> = {
            guard let result = try? await ProcessRunner.run(["pgrep", "-x", "kitty"], timeout: 2),
                  result.status == 0 else { return [] }
            return Set(
                result.stdoutString
                    .split(whereSeparator: \.isNewline)
                    .compactMap { Int($0) }
            )
        },
        run: @escaping @Sendable (String, [String], TimeInterval) async throws -> ProcessResult = { binary, args, timeout in
            try await ProcessRunner.run([binary] + args, timeout: timeout)
        }
    ) {
        self.binary = binary
        self.environment = environment
        self.runningKittyPIDs = runningKittyPIDs
        self.run = run
    }

    /// `--to` names the socket, because kitty's default socket is only in the
    /// environment of a process it started.
    public func setColors(_ path: String, socket: String) async -> Bool {
        guard let result = try? await run(
            binary,
            ["@", "--to", "unix:" + socket, "set-colors", "-a", path],
            3
        ) else { return false }
        return result.status == 0
    }

    /// Always reports what the app actually said. No discoverable socket, a
    /// refused command or a missing binary all end as "restart kitty", never as
    /// success. `addedRemoteControl` is true for the Apply that first wrote the
    /// directive: that running kitty starts listening only on its next launch.
    public func reload(
        themeFile: String,
        configPath: String? = nil,
        addedRemoteControl: Bool = false
    ) async -> ThemingReload.Status {
        let sockets = await liveSockets(configPath: configPath)
        if !sockets.isEmpty {
            var recoloured = 0
            for socket in sockets {
                if await setColors(themeFile, socket: socket) { recoloured += 1 }
            }
            if recoloured > 0 {
                return ThemingReload.kittyLive(windows: recoloured)
            }
            return ThemingReload.kitty(remoteControl: true, applied: false)
        }
        if addedRemoteControl {
            return ThemingReload.kittyAddedRemoteControl()
        }
        return ThemingReload.kitty(remoteControl: false, applied: false)
    }

    // MARK: - Socket discovery

    /// kitty's own fallback when `listen_on` is absent. Palette scans the runtime
    /// directory for the name the template would produce.
    public static let defaultListenTemplate = "kitty-{kitty_pid}"

    /// The file-name part of `listen_on unix:…`. Nil means kitty listens
    /// somewhere Palette cannot scan (`tcp:`, an abstract `@` socket, `none`)
    /// or names an absolute path outside `$XDG_RUNTIME_DIR`.
    public static func listenTemplate(inConfig text: String) -> String? {
        var found = false
        var template: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first == "listen_on" else { continue }
            found = true
            let value = parts.count > 1 ? String(parts[1]) : ""
            template = unixSocketTemplate(value)
        }
        return found ? template : defaultListenTemplate
    }

    private static func unixSocketTemplate(_ value: String) -> String? {
        guard value.hasPrefix("unix:") else { return nil }
        var path = String(value.dropFirst("unix:".count))
        // `unix:${XDG_RUNTIME_DIR}/name` names a file in the directory Palette
        // scans; the prefix is not part of that file's name.
        if let range = path.range(of: "${XDG_RUNTIME_DIR}/") {
            path = String(path[range.upperBound...])
        } else if path.hasPrefix("${XDG_RUNTIME_DIR}") {
            path = String(path.dropFirst("${XDG_RUNTIME_DIR}".count))
            path = String(path.drop(while: { $0 == "/" }))
        }
        // shortcut: only plain file names under the runtime directory are
        // matched. An absolute or nested socket path is left to the restart hint.
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("@") else { return nil }
        return path
    }

    /// Matches directory entries against the template and keeps only sockets
    /// whose `{kitty_pid}` belongs to a running kitty. Stale socket files from
    /// a crashed instance are ignored.
    public static func socketPaths(
        template: String,
        runtimeDir: String,
        entries: [String],
        pids: Set<Int>
    ) -> [String] {
        guard template.contains("{kitty_pid}") else { return [] }
        let pattern = template
            .components(separatedBy: "{kitty_pid}")
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "([0-9]+)")
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$") else { return [] }
        return entries.compactMap { entry -> String? in
            let range = NSRange(entry.startIndex..., in: entry)
            guard let match = regex.firstMatch(in: entry, range: range),
                  match.numberOfRanges == 2,
                  let pidRange = Range(match.range(at: 1), in: entry),
                  let pid = Int(entry[pidRange]),
                  pids.contains(pid) else { return nil }
            return runtimeDir + "/" + entry
        }.sorted()
    }

    private func liveSockets(configPath: String?) async -> [String] {
        guard let runtimeDir = environment["XDG_RUNTIME_DIR"], !runtimeDir.isEmpty else { return [] }
        let config = configPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let template = config.flatMap(Self.listenTemplate(inConfig:)) ?? Self.defaultListenTemplate
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: runtimeDir) else { return [] }
        return Self.socketPaths(
            template: template,
            runtimeDir: runtimeDir,
            entries: entries,
            pids: await runningKittyPIDs()
        )
    }
}
