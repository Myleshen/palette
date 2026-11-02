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
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
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

    public func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: PathExpansion.expand(path))])
    }

    public func openURL(_ string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            Log.shared.warn("Refusing to open URL: \(string)", source: "launcher")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    public func openURL(_ string: String, with browser: String?) -> Bool {
        guard let browser, !browser.isEmpty,
              let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            openURL(string)
            return false
        }
        guard let appPath = ToolLocator.shared.appPath(named: browser) else {
            Log.shared.warn("Browser \(browser) is not installed; opening the default browser", source: "launcher")
            openURL(string)
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: configuration) { _, error in
            if let error {
                Log.shared.error("open in \(browser) failed: \(error.localizedDescription)", source: "launcher")
            }
        }
        return true
    }

    public func run(_ argv: [String], cwd: String? = nil) throws {
        guard !argv.isEmpty else { return }
        try ProcessRunner.launch(argv, cwd: cwd)
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
