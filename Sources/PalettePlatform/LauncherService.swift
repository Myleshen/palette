import AppKit
import PaletteCore

@MainActor
public final class LauncherService {
    public init() {}

    public func openPath(_ path: String) {
        let url = URL(fileURLWithPath: PathExpansion.expand(path))
        NSWorkspace.shared.open(url)
    }

    public func openPath(_ path: String, with app: String) throws {
        let expanded = PathExpansion.expand(path)
        let url = URL(fileURLWithPath: expanded)

        if let appPath = ToolLocator.shared.appPath(named: app) {
            // Editors that reuse their window would put a second project into
            // the window already open; start their binary again instead.
            // LaunchServices would otherwise route the path to the running one.
            if let command = EditorLaunch.newInstanceCommand(appPath: appPath, path: expanded),
               FileManager.default.isExecutableFile(atPath: command[0]) {
                // A GUI app inherits launchd's minimal PATH, so the editor
                // cannot find Homebrew's nvim. Hand it the tool directories.
                let toolPath = Self.toolPathEnvironment["PATH"] ?? ""
                try ProcessRunner.launch(command, environment: ["PATH": toolPath])
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // GUI apps inherit launchd's minimal PATH, so Neovide cannot find
            // Homebrew's nvim. Hand the usual tool directories to the child.
            configuration.environment = Self.toolPathEnvironment
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: configuration) { _, error in
                if let error {
                    Log.shared.error("open with \(app) failed: \(error.localizedDescription)", source: "launcher")
                }
            }
            return
        }

        if app.contains("/"), FileManager.default.isExecutableFile(atPath: app) {
            try ProcessRunner.launch([app, expanded])
            return
        }

        if let executable = ToolLocator.shared.path(for: app) {
            try ProcessRunner.launch([executable, expanded])
            return
        }

        throw ProviderError.failed("Could not find app '\(app)'")
    }

    private static var toolPathEnvironment: [String: String] {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>()
        var parts: [String] = []
        for part in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + current.split(separator: ":").map(String.init)
        where seen.insert(part).inserted {
            parts.append(part)
        }
        return ["PATH": parts.joined(separator: ":")]
    }

    public func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: PathExpansion.expand(path))])
    }

    @discardableResult
    public func openURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "x-apple.systempreferences"].contains(scheme) else {
            Log.shared.warn("Refusing to open URL: \(string)", source: "launcher")
            return false
        }
        guard NSWorkspace.shared.open(url) else {
            Log.shared.error("No application could open \(string)", source: "launcher")
            return false
        }
        return true
    }

    /// Opens a link in `browser` (or the default when nil/empty). An uninstalled
    /// browser or a failed launch falls back to the default and reports which one
    /// ran, so the panel only closes once something actually opened.
    @discardableResult
    public func openURL(_ string: String, with browser: String?) async -> URLOpenOutcome {
        let name = browser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return openURL(string) ? .opened : .failed("no application accepted it")
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            // Mailto and settings panes have no browser to pick; let the system route them.
            return openURL(string) ? .opened : .failed("the address is not valid")
        }
        let appPath = ToolLocator.shared.appPath(named: name)
        switch BrowserOpenPlan.plan(browser: name, installed: appPath != nil) {
        case .systemDefault:
            return openURL(string) ? .opened : .failed("no application accepted it")
        case .fallback(let missing):
            return openInDefault(url, requested: missing)
        case .browser(let resolved):
            guard let appPath else {
                return openInDefault(url, requested: resolved)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.environment = Self.toolPathEnvironment
            do {
                _ = try await NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: URL(fileURLWithPath: appPath),
                    configuration: configuration
                )
                Log.shared.info("Opened \(url.absoluteString) in \(resolved)", source: "launcher")
                return .opened
            } catch {
                Log.shared.error("open in \(resolved) failed: \(error.localizedDescription)", source: "launcher")
                return openInDefault(url, requested: resolved)
            }
        }
    }

    /// The fallback warning is the log line that proves the default browser ran.
    private func openInDefault(_ url: URL, requested: String) -> URLOpenOutcome {
        Log.shared.warn("Browser \(requested) could not open the link; opening the default browser", source: "launcher")
        guard NSWorkspace.shared.open(url) else {
            Log.shared.error("No application could open \(url.absoluteString)", source: "launcher")
            return .failed("no application accepted it")
        }
        return .openedInDefault(requested: requested)
    }

    /// Opens a saved web app in its own Chromium app window, not a browser tab.
    /// A failed app window falls back to a normal tab and says which one ran.
    @discardableResult
    public func openWebApp(_ string: String, browser: String) async -> URLOpenOutcome {
        if let spec = WebAppLauncher.launchSpec(urlString: string, browser: browser) {
            do {
                try ProcessRunner.launch([spec.executable] + spec.arguments)
                Log.shared.info("Opened \(string) as a web app in \(browser)", source: "launcher")
                return .opened
            } catch {
                Log.shared.error("Web app launch failed: \(error.localizedDescription)", source: "launcher")
            }
        } else {
            Log.shared.warn("Could not build an app window for \(string) in \(browser)", source: "launcher")
        }
        switch await openURL(string, with: browser) {
        case .opened:
            return .openedAsTab(browser: browser)
        case .openedInDefault(let name):
            return .openedInDefault(requested: name)
        case .openedAsTab:
            return .openedAsTab(browser: browser)
        case .failed(let reason):
            return .failed(reason)
        }
    }

    public func run(_ argv: [String], cwd: String? = nil) throws {
        guard !argv.isEmpty else { return }
        try ProcessRunner.launch(argv, cwd: cwd)
    }

    public func quitApp(path: String) {
        let target = PathExpansion.expand(path)
        for app in NSWorkspace.shared.runningApplications
        where app.bundleURL?.path == target {
            app.terminate()
        }
    }

    public func uninstallApp(path: String) throws {
        let target = URL(fileURLWithPath: PathExpansion.expand(path))
        var trashed: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
    }

    public func activateApp(path: String) {
        let url = URL(fileURLWithPath: PathExpansion.expand(path))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.shared.error("activate failed: \(error.localizedDescription)", source: "launcher")
            }
        }
    }

    public func openTerminal(command: String, app: String) throws {
        let name = app.lowercased()
        if name.contains("kitty") {
            guard let kitty = ToolLocator.shared.path(for: "kitty")
                ?? ToolLocator.shared.appPath(named: app).map({ $0 + "/Contents/MacOS/kitty" }) else {
                throw ProviderError.toolMissing("kitty")
            }
            let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
            try ProcessRunner.launch([
                kitty, "--detach", "/bin/zsh", "-lic",
                "\(escaped); exec /bin/zsh -l",
            ])
            return
        }

        guard name == "terminal" || name == "terminal.app" else {
            throw ProviderError.failed("Unsupported terminal '\(app)'; use kitty or Terminal")
        }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        try ProcessRunner.launch(["/usr/bin/osascript", "-e", script])
    }
}

public struct AppRecord: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bundleID: String?
    public var keywords: [String]
}

public actor AppIndex {
    private var cached: [AppRecord] = []
    private var cachedAt: Date = .distantPast
    private let maxAge: TimeInterval = 300

    public init() {}

    public func applications(force: Bool = false) -> [AppRecord] {
        if !force, Date().timeIntervalSince(cachedAt) < maxAge, !cached.isEmpty {
            return cached
        }
        cached = Self.scan()
        cachedAt = Date()
        return cached
    }

    public func refresh() -> [AppRecord] {
        cached = Self.scan()
        cachedAt = Date()
        return cached
    }

    private static func scan() -> [AppRecord] {
        let home = NSHomeDirectory()
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            home + "/Applications",
        ]

        var records: [String: AppRecord] = [:]
        let manager = FileManager.default

        func add(_ url: URL) {
            guard url.pathExtension == "app" else { return }
            let path = (url.path as NSString).standardizingPath
            guard records[path] == nil else { return }
            let bundle = Bundle(url: url)
            func bundleName(_ key: String) -> String? {
                guard let value = bundle?.object(forInfoDictionaryKey: key) as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            let name = bundleName("CFBundleDisplayName")
                ?? bundleName("CFBundleName")
                ?? url.deletingPathExtension().lastPathComponent
            let bundleID = bundle?.bundleIdentifier
            // CoreServices contains helper bundles named by reverse-DNS ID;
            // they are not launchable user apps and only add noise.
            guard !(name.contains(".") && name.first?.isLowercase == true) else { return }
            var keywords = [url.deletingPathExtension().lastPathComponent, name]
            if let bundleID { keywords.append(bundleID) }
            records[path] = AppRecord(name: name, path: path, bundleID: bundleID, keywords: keywords)
        }

        for root in roots {
            // The URL-based directory API skips some symlinked apps (Safari),
            // so enumerate names and build URLs ourselves.
            guard let names = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() {
                let entry = URL(fileURLWithPath: root).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    add(entry)
                    continue
                }
                guard let children = try? manager.contentsOfDirectory(atPath: entry.path) else { continue }
                for child in children.sorted() where child.hasSuffix(".app") {
                    add(entry.appendingPathComponent(child))
                }
            }
        }

        // Finder is the one user-facing app that lives in CoreServices; the
        // rest of that directory is helper daemons, not launchable apps.
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))

        return records.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
