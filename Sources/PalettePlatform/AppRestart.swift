import Foundation

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

    private let isRunning: @Sendable (String) async -> Bool
    private let instanceCount: @Sendable (String) async -> Int
    private let run: @Sendable ([String], TimeInterval) async throws -> ProcessResult
    private let wait: @Sendable (TimeInterval) async -> Void
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2,
        isRunning: @escaping @Sendable (String) async -> Bool = { processName in
            guard let result = try? await ProcessRunner.run(
                ["/usr/bin/pgrep", "-x", processName],
                timeout: 2
            ) else { return false }
            return result.status == 0
        },
        instanceCount: @escaping @Sendable (String) async -> Int = { processName in
            guard let result = try? await ProcessRunner.run(
                ["/usr/bin/pgrep", "-x", processName],
                timeout: 2
            ), result.status == 0 else { return 0 }
            return result.stdoutString.split(whereSeparator: \.isNewline).count
        },
        run: @escaping @Sendable ([String], TimeInterval) async throws -> ProcessResult = { arguments, timeout in
            try await ProcessRunner.run(arguments, timeout: timeout)
        },
        wait: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.isRunning = isRunning
        self.instanceCount = instanceCount
        self.run = run
        self.wait = wait
    }

    public static let live = AppRestart()

    /// Decided from the live process table, so an app the user quit between
    /// Apply and the prompt is not offered.
    public func appsToRestart(
        kittyNeedsRestart: Bool,
        neovideNeedsRestart: Bool,
        ghosttyNeedsRestart: Bool
    ) async -> [App] {
        var apps: [App] = []
        if kittyNeedsRestart, await isRunning("kitty") {
            let windows = max(1, await instanceCount("kitty"))
            apps.append(App(name: "kitty", processName: "kitty", windows: windows))
        }
        if neovideNeedsRestart, await isRunning("neovide") {
            apps.append(App(name: "Neovide", processName: "neovide"))
        }
        if ghosttyNeedsRestart, await isRunning("Ghostty") {
            apps.append(App(name: "Ghostty", processName: "Ghostty"))
        }
        return apps
    }

    /// A graceful quit: the app may ask to save. Nothing is force-killed. The
    /// quit is still followed by `open -a` after the timeout so an app that
    /// refused to quit is merely brought forward, not killed.
    public func restart(_ apps: [App]) async -> String? {
        guard !apps.isEmpty else { return nil }
        var restarted: [String] = []
        for app in apps {
            _ = try? await run(
                ["/usr/bin/osascript", "-e", Self.quitScript(for: app.name)],
                10
            )
            var waited: TimeInterval = 0
            while await isRunning(app.processName), waited < timeout {
                await wait(pollInterval)
                waited += pollInterval
            }
            _ = try? await run(["/usr/bin/open", "-a", app.name], 10)
            restarted.append(app.name)
        }
        return "Restarted " + restarted.joined(separator: ", ")
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
