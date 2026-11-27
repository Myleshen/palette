import Foundation
import PaletteCore

/// Quits and reopens apps that only see the new palette on launch. kitty is
/// included only when its socket could not recolour it; Neovide and Ghostty are
/// included when they are running. zellij is never here: killing its server
/// ends every session, and a new session reads the palette by itself.
public struct AppRestart: Sendable {
    public struct App: Sendable, Equatable, Identifiable {
        public var name: String
        public var processName: String
        /// OS windows for a kitty process; a single app window for the others.
        public var windows: Int
        public var id: String { name }

        public init(name: String, processName: String, windows: Int = 1) {
            self.name = name
            self.processName = processName
            self.windows = windows
        }

        /// What the prompt lists, e.g. "kitty (2 windows)".
        public var label: String {
            windows > 1 ? "\(name) (\(windows) windows)" : name
        }
    }

    private let pids: @Sendable (String) async -> [Int]
    private let run: @Sendable ([String], TimeInterval) async throws -> ProcessResult
    private let wait: @Sendable (TimeInterval) async -> Void
    private let relaunch: @Sendable (App) async -> Void
    /// How long a graceful quit gets before the next step.
    private let quitTimeout: TimeInterval
    /// How long SIGTERM gets, and then SIGKILL.
    private let termTimeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(
        quitTimeout: TimeInterval = 10,
        termTimeout: TimeInterval = 3,
        pollInterval: TimeInterval = 0.2,
        pids: (@Sendable (String) async -> [Int])? = nil,
        run: @escaping @Sendable ([String], TimeInterval) async throws -> ProcessResult = { arguments, timeout in
            try await ProcessRunner.run(arguments, timeout: timeout)
        },
        wait: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        relaunch: (@Sendable (App) async -> Void)? = nil
    ) {
        self.quitTimeout = quitTimeout
        self.termTimeout = termTimeout
        self.pollInterval = pollInterval
        self.pids = pids ?? { processName in await AppRestart.processIDs(processName) }
        self.run = run
        self.wait = wait
        self.relaunch = relaunch ?? { app in await AppRestart.relaunch(app) }
    }

    public static let live = AppRestart()

    /// Both the decision and the escalation read the live process table, so a
    /// pid that exits between two polls is never signalled.
    public static func processIDs(_ processName: String) async -> [Int] {
        guard let result = try? await ProcessRunner.run(
            ["/usr/bin/pgrep", "-x", processName],
            timeout: 2
        ), result.status == 0 else { return [] }
        return result.stdoutString
            .split(whereSeparator: \.isNewline)
            .compactMap { Int($0) }
    }

    /// Decided from the live process table, so an app the user quit between
    /// Apply and the prompt is not offered.
    public func appsToRestart(
        kittyNeedsRestart: Bool,
        neovideNeedsRestart: Bool,
        ghosttyNeedsRestart: Bool
    ) async -> [App] {
        var apps: [App] = []
        if kittyNeedsRestart {
            let kittyPIDs = await pids("kitty")
            if !kittyPIDs.isEmpty {
                apps.append(App(name: "kitty", processName: "kitty", windows: kittyPIDs.count))
            }
        }
        if neovideNeedsRestart, !(await pids("neovide")).isEmpty {
            apps.append(App(name: "Neovide", processName: "neovide"))
        }
        if ghosttyNeedsRestart, !(await pids("Ghostty")).isEmpty {
            apps.append(App(name: "Ghostty", processName: "Ghostty"))
        }
        return apps
    }

    /// A graceful quit first. kitty runs detached with a zellij attach, so the
    /// AppleScript quit can leave every window running; when that happens it
    /// is escalated to SIGTERM, then SIGKILL (the user has authorised this for
    /// kitty), and only then relaunched. Editors stay graceful: force-killing
    /// one would lose an unsaved buffer, so they are merely brought forward.
    public func restart(_ apps: [App]) async -> String? {
        guard !apps.isEmpty else { return nil }
        var restarted: [String] = []
        var failed: [String] = []
        for app in apps {
            _ = try? await run(
                ["/usr/bin/osascript", "-e", Self.quitScript(for: app.name)],
                10
            )
            var remaining = await waitForExit(app.processName, timeout: quitTimeout)
            if !remaining.isEmpty, escalatesKill(app) {
                _ = try? await run(["/bin/kill", "-TERM"] + remaining.map(String.init), 3)
                remaining = await waitForExit(app.processName, timeout: termTimeout)
            }
            if !remaining.isEmpty, escalatesKill(app) {
                _ = try? await run(["/bin/kill", "-KILL"] + remaining.map(String.init), 3)
                remaining = await waitForExit(app.processName, timeout: termTimeout)
            }
            // Relaunching while an old kitty instance survives would leave two
            // of them behind; report it instead. An editor that refused to
            // quit is only brought forward, never killed.
            if remaining.isEmpty || !escalatesKill(app) {
                await relaunch(app)
                restarted.append(app.name)
            } else {
                failed.append(app.name)
            }
        }
        var parts: [String] = []
        if !restarted.isEmpty { parts.append("Restarted " + restarted.joined(separator: ", ")) }
        if !failed.isEmpty { parts.append("could not stop " + failed.joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }

    /// kitty is the only app that may be force-killed.
    private func escalatesKill(_ app: App) -> Bool {
        app.processName == "kitty"
    }

    private func waitForExit(_ processName: String, timeout: TimeInterval) async -> [Int] {
        var waited: TimeInterval = 0
        var remaining = await pids(processName)
        while !remaining.isEmpty, waited < timeout {
            await wait(pollInterval)
            waited += pollInterval
            remaining = await pids(processName)
        }
        return remaining
    }

    /// A restarted kitty goes through the same path as Palette's own terminal
    /// commands. It attaches to a fresh Palette session rather than `open -a
    /// kitty`: a running zellij session never picks up the new palette, and
    /// `zellij attach` with no name only fails once there are several sessions.
    private static func relaunch(_ app: App) async {
        guard app.processName == "kitty" else {
            _ = try? await ProcessRunner.run(["/usr/bin/open", "-a", app.name], timeout: 10)
            return
        }
        let zellij = ToolLocator.shared.path(for: "zellij") ?? "zellij"
        let command = ZellijLauncher.themedSessionScript(zellij: zellij)
        await MainActor.run {
            try? LauncherService().openTerminal(command: command, app: "kitty")
        }
    }

    /// AppleScript string literal, so an app name can never end the statement.
    public static func quitScript(for appName: String) -> String {
        "tell application \""
            + appName.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            + "\" to quit"
    }
}

/// Shown after an Apply that changed more than a reloadable app can pick up.
public struct RestartPrompt: Sendable, Equatable {
    public var apps: [AppRestart.App]

    public init(apps: [AppRestart.App]) {
        self.apps = apps
    }

    public var title: String { "Restart to finish applying" }

    /// "Restart to finish applying: kitty (2 windows), Neovide, Ghostty".
    public var message: String {
        "Restart to finish applying: " + apps.map(\.label).joined(separator: ", ")
    }

    public var primaryLabel: String { "Restart now" }
    public var secondaryLabel: String { "Later" }
}
