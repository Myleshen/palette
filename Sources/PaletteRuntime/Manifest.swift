import Foundation
import PaletteCore
import TOMLKit

public struct PathsManifest: Sendable, Equatable {
    public var kind: PathKind
    public var scope: String
    public var openWith: String
    public var secondary: String
    public var maxResults: Int
    public var freeform: Bool

    public init(
        kind: PathKind,
        scope: String = "projects",
        openWith: String = "neovide",
        secondary: String = "reveal",
        maxResults: Int = 50,
        freeform: Bool = false
    ) {
        self.kind = kind
        self.scope = scope
        self.openWith = openWith
        self.secondary = secondary
        self.maxResults = maxResults
        self.freeform = freeform
    }
}

public struct ProviderManifest: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var trigger: String?
    public var global: Bool
    public var icon: String?
    public var keywords: [String]
    public var priority: Int
    public var engine: String?
    public var command: [String]
    public var timeoutMs: Int
    public var idleTimeoutS: Int
    public var paths: PathsManifest?
    public var directory: URL
    public var isBundled: Bool

    public init(
        id: String,
        name: String,
        trigger: String? = nil,
        global: Bool = false,
        icon: String? = nil,
        keywords: [String] = [],
        priority: Int = 0,
        engine: String? = nil,
        command: [String] = [],
        timeoutMs: Int = 2_000,
        idleTimeoutS: Int = 300,
        paths: PathsManifest? = nil,
        directory: URL = URL(fileURLWithPath: "."),
        isBundled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.global = global
        self.icon = icon
        self.keywords = keywords
        self.priority = priority
        self.engine = engine
        self.command = command
        self.timeoutMs = timeoutMs
        self.idleTimeoutS = idleTimeoutS
        self.paths = paths
        self.directory = directory
        self.isBundled = isBundled
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            name: name,
            trigger: trigger,
            isGlobal: global,
            priority: priority,
            icon: icon,
            keywords: keywords
        )
    }
}

public struct ManifestLoadResult: Sendable {
    public var manifests: [ProviderManifest]
    public var diagnostics: [Diagnostic]
}

public enum ManifestLoader {
    public static func load(bundled: URL?, user: URL) -> ManifestLoadResult {
        var diagnostics: [Diagnostic] = []
        var byID: [String: ProviderManifest] = [:]

        if let bundled {
            for manifest in scan(directory: bundled, isBundled: true, diagnostics: &diagnostics) {
                byID[manifest.id] = manifest
            }
        }
        for manifest in scan(directory: user, isBundled: false, diagnostics: &diagnostics) {
            if byID[manifest.id] != nil {
                diagnostics.append(Diagnostic(.info, "User provider '\(manifest.id)' overrides the bundled version.", source: "providers"))
            }
            byID[manifest.id] = manifest
        }

        let manifests = byID.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.id < rhs.id
        }
        return ManifestLoadResult(manifests: manifests, diagnostics: diagnostics)
    }

    private static func scan(directory: URL, isBundled: Bool, diagnostics: inout [Diagnostic]) -> [ProviderManifest] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [ProviderManifest] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            var manifestURL: URL?
            if values?.isDirectory == true {
                manifestURL = entry.appendingPathComponent("provider.toml")
            } else if entry.pathExtension == "toml" {
                manifestURL = entry
            }
            guard let manifestURL, manager.fileExists(atPath: manifestURL.path) else { continue }
            if let manifest = parse(url: manifestURL, isBundled: isBundled, diagnostics: &diagnostics) {
                results.append(manifest)
            }
        }
        return results
    }

    public static func parse(url: URL, isBundled: Bool = false, diagnostics: inout [Diagnostic]) -> ProviderManifest? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            diagnostics.append(Diagnostic(.error, "Could not read \(url.path)", source: "providers"))
            return nil
        }
        guard let table = try? TOMLTable(string: text) else {
            diagnostics.append(Diagnostic(.error, "Invalid TOML: \(url.path)", source: "providers"))
            return nil
        }

        guard let id = table.str("id"), !id.isEmpty else {
            diagnostics.append(Diagnostic(.error, "Provider manifest is missing 'id': \(url.path)", source: "providers"))
            return nil
        }
        let validID = id.range(of: "^[a-z0-9._-]+$", options: .regularExpression) != nil
        guard validID else {
            diagnostics.append(Diagnostic(.error, "Provider id '\(id)' must match [a-z0-9._-].", source: "providers"))
            return nil
        }

        let name = table.str("name") ?? id
        var trigger = table.str("trigger")?.trimmingCharacters(in: .whitespaces)
        if trigger?.isEmpty == true { trigger = nil }
        if let value = trigger, value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil {
            diagnostics.append(Diagnostic(.error, "Provider '\(id)' has an invalid trigger '\(value)'; it was ignored.", source: "providers"))
            trigger = nil
        }

        let global = table.bool("global") ?? false
        if trigger == nil, !global {
            diagnostics.append(Diagnostic(.warning, "Provider '\(id)' has no trigger and is not global; it cannot be reached.", source: "providers"))
        }

        let engine = table.str("engine")
        let command = table.strArray("command") ?? []
        var paths: PathsManifest?

        if engine == "paths" {
            let kindRaw = table.str("kind") ?? "directories"
            guard let kind = PathKind(rawValue: kindRaw) else {
                diagnostics.append(Diagnostic(.error, "Provider '\(id)' has unknown kind '\(kindRaw)'.", source: "providers"))
                return nil
            }
            paths = PathsManifest(
                kind: kind,
                scope: table.str("scope") ?? "projects",
                openWith: table.str("open_with") ?? "neovide",
                secondary: table.str("secondary") ?? "reveal",
                maxResults: max(1, table.int("max_results") ?? 50),
                freeform: table.bool("freeform") ?? false
            )
        } else if engine != nil, engine != "command" {
            diagnostics.append(Diagnostic(.error, "Provider '\(id)' uses unknown engine '\(engine ?? "")'.", source: "providers"))
            return nil
        }

        if command.isEmpty, engine != "paths" {
            diagnostics.append(Diagnostic(.error, "Provider '\(id)' needs either engine = \"paths\" or a command array.", source: "providers"))
            return nil
        }

        let manifest = ProviderManifest(
            id: id,
            name: name,
            trigger: trigger,
            global: global,
            icon: table.str("icon"),
            keywords: table.strArray("keywords") ?? [],
            priority: table.int("priority") ?? 0,
            engine: engine,
            command: command,
            timeoutMs: max(100, table.int("timeout_ms") ?? 2_000),
            idleTimeoutS: max(10, table.int("idle_timeout_s") ?? 300),
            paths: paths,
            directory: url.deletingLastPathComponent(),
            isBundled: isBundled
        )
        return manifest
    }
}
