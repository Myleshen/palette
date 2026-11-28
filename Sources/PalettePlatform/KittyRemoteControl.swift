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

    /// `@ ls` answers one entry per OS window of that kitty process. A reply
    /// Palette cannot parse still counts as one window, because `set-colors`
    /// succeeded for it.
    public func windowCount(socket: String) async -> Int {
        guard let result = try? await run(
            binary,
            ["@", "--to", "unix:" + socket, "ls"],
            2
        ), result.status == 0,
           let data = result.stdoutString.data(using: .utf8),
           let windows = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return 1
        }
        return max(1, windows.count)
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
        // The Apply that first writes the directive or the managed listener
        // cannot reach the running kitty: it starts using them on its next
        // launch, so say that once instead of attempting a socket it refuses.
        if addedRemoteControl {
            return ThemingReload.kittyAddedRemoteControl()
        }
        let sockets = await liveSockets(configPath: configPath)
        guard !sockets.isEmpty else {
            return ThemingReload.kitty(remoteControl: false, applied: false)
        }
        return await reload(themeFile: themeFile, sockets: sockets)
    }

    /// The launch path paints a palette that is already on disk. No listening
    /// kitty means nothing to say, so it returns nil instead of a restart hint.
    public func pushExisting(themeFile: String, configPath: String? = nil) async -> ThemingReload.Status? {
        let sockets = await liveSockets(configPath: configPath)
        guard !sockets.isEmpty else { return nil }
        return await reload(themeFile: themeFile, sockets: sockets)
    }

    private func reload(themeFile: String, sockets: [String]) async -> ThemingReload.Status {
        var recoloured = 0
        for socket in sockets {
            if await setColors(themeFile, socket: socket) {
                recoloured += await windowCount(socket: socket)
            }
        }
        if recoloured > 0 {
            return ThemingReload.kittyLive(windows: recoloured)
        }
        return ThemingReload.kitty(remoteControl: true, applied: false)
    }

    // MARK: - Socket discovery

    /// kitty's own fallback when `listen_on` is absent. Palette scans the runtime
    /// directory for the name the template would produce.
    public static let defaultListenTemplate = "kitty-{kitty_pid}"

    /// Palette's own listener, written into the managed block. `$TMPDIR` is set
    /// for GUI-launched processes on macOS, so the same directory is visible to
    /// Palette and kitty without relying on the Linux `XDG_RUNTIME_DIR`.
    public static let managedListenTemplate = "palette-kitty-{kitty_pid}"

    /// The last `listen_on` wins in kitty, so the managed block's line is the
    /// one a restarted kitty actually uses.
    public static func listenTemplate(inConfig text: String) -> String? {
        let scan = listenOnLines(inConfig: text)
        guard scan.found else { return defaultListenTemplate }
        return scan.templates.last
    }

    /// Every resolvable `listen_on` name in the file, in order. Discovery uses
    /// all of them so a kitty still running with the user's old line is found
    /// too.
    public static func listenTemplates(inConfig text: String) -> [String] {
        listenOnLines(inConfig: text).templates
    }

    public static func hasListenOn(inConfig text: String) -> Bool {
        listenOnLines(inConfig: text).found
    }

    private static func listenOnLines(inConfig text: String) -> (found: Bool, templates: [String]) {
        var found = false
        var templates: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first == "listen_on" else { continue }
            found = true
            let value = parts.count > 1 ? String(parts[1]) : ""
            if let template = unixSocketTemplate(value) {
                templates.append(template)
            }
        }
        return (found, templates)
    }

    private static func unixSocketTemplate(_ value: String) -> String? {
        guard value.hasPrefix("unix:") else { return nil }
        var path = String(value.dropFirst("unix:".count))
        // `unix:${XDG_RUNTIME_DIR}/name` and `unix:${TMPDIR}name` name a file
        // in a directory Palette scans; the env prefix is not part of its name.
        for prefix in ["${XDG_RUNTIME_DIR}/", "${TMPDIR}"] {
            if let range = path.range(of: prefix) {
                path = String(path[range.upperBound...])
                break
            }
        }
        if path.hasPrefix("${XDG_RUNTIME_DIR}") {
            path = String(path.dropFirst("${XDG_RUNTIME_DIR}".count))
            path = String(path.drop(while: { $0 == "/" }))
        }
        // shortcut: only plain file names under a scanned directory are
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
        let pids = await runningKittyPIDs()
        var paths = Set<String>()
        let userConfig: String? = configPath.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }

        // The managed block's listener, in $TMPDIR (macOS) and /tmp (the
        // literal form, and where a kitty without TMPDIR puts it).
        var managedDirs: [String] = []
        if let temp = Self.scannedDirectory(environment["TMPDIR"]) { managedDirs.append(temp) }
        if let temp = Self.scannedDirectory("/tmp") { managedDirs.append(temp) }
        for directory in managedDirs {
            paths.formUnion(Self.sockets(
                template: Self.managedListenTemplate,
                in: directory,
                pids: pids
            ))
        }

        // A kitty that has not restarted since the override was installed still
        // listens on the user's own line.
        if let runtime = Self.scannedDirectory(environment["XDG_RUNTIME_DIR"]) {
            var templates: [String]
            if let userConfig {
                templates = Self.listenTemplates(inConfig: userConfig)
                if !Self.hasListenOn(inConfig: userConfig) {
                    templates = [Self.defaultListenTemplate]
                }
            } else {
                templates = [Self.defaultListenTemplate]
            }
            for template in templates where template != Self.managedListenTemplate {
                paths.formUnion(Self.sockets(template: template, in: runtime, pids: pids))
            }
        }
        return paths.sorted()
    }

    /// kitty writes into a directory, so a trailing slash is removed before it
    /// is joined with the socket's file name.
    private static func scannedDirectory(_ value: String?) -> String? {
        guard var directory = value, !directory.isEmpty else { return nil }
        while directory.hasSuffix("/") { directory.removeLast() }
        return directory.isEmpty ? nil : directory
    }

    private static func sockets(template: String, in directory: String, pids: Set<Int>) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return socketPaths(template: template, runtimeDir: directory, entries: entries, pids: pids)
    }
}
