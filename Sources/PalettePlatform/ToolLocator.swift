import Foundation
import PaletteCore

/// GUI apps do not inherit the shell PATH. Resolve tools by probing the
/// inherited environment plus the usual Homebrew and user-bin locations.
public final class ToolLocator: @unchecked Sendable {
    public static let shared = ToolLocator()

    private let lock = NSLock()
    private var cached: [String: String] = [:]
    private var extraPaths: [String] = []

    public init() {}

    public func configure(extraPaths: [String]) {
        lock.lock()
        self.extraPaths = extraPaths.map { PathExpansion.expand($0) }
        cached.removeAll()
        lock.unlock()
    }

    public func path(for tool: String) -> String? {
        if tool.contains("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }

        lock.lock()
        if let cached = cached[tool] {
            lock.unlock()
            return cached
        }
        let extra = extraPaths
        lock.unlock()

        let home = NSHomeDirectory()
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ])
        directories.append(contentsOf: extra)

        // App bundles that are useful to launch directly.
        let knownBinaries: [String: String] = [
            "kitty": "/Applications/kitty.app/Contents/MacOS/kitty",
            "neovide": "/Applications/Neovide.app/Contents/MacOS/neovide",
        ]

        var found: String?
        if let known = knownBinaries[tool], FileManager.default.isExecutableFile(atPath: known) {
            found = known
        } else {
            for directory in directories {
                let candidate = directory + "/" + tool
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    found = candidate
                    break
                }
            }
        }

        if let found {
            lock.lock()
            cached[tool] = found
            lock.unlock()
        }
        return found
    }

    public func require(_ tool: String) throws -> String {
        guard let path = path(for: tool) else {
            throw ProviderError.toolMissing(tool)
        }
        return path
    }

    /// Resolve an app name to a bundle path without launching it.
    public func appPath(named name: String) -> String? {
        let expanded = PathExpansion.expand(name)
        if expanded.contains("/"), FileManager.default.fileExists(atPath: expanded) {
            return (expanded as NSString).standardizingPath
        }

        var bundleName = expanded
        if bundleName.hasSuffix(".app") { bundleName = String(bundleName.dropLast(4)) }
        let lowercase = bundleName.lowercased()
        let home = NSHomeDirectory()
        let directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            home + "/Applications",
            home + "/Applications/Utilities",
        ]

        // Compare names case-insensitively so "neovide" finds
        // /Applications/Neovide.app and returns the real on-disk casing. This
        // matters on case-sensitive volumes and keeps logs accurate.
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.lowercased() == lowercase + ".app" {
                return ((directory + "/" + entry) as NSString).standardizingPath
            }
        }

        // Fallback for directories we cannot enumerate.
        for directory in directories {
            let candidate = directory + "/" + bundleName + ".app"
            if FileManager.default.fileExists(atPath: candidate) {
                return (candidate as NSString).standardizingPath
            }
        }
        return nil
    }
}
