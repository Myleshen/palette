import Foundation
import PaletteCore
import PalettePlatform

public struct PathsProviderConfiguration: Sendable, Equatable {
    public var id: String
    public var name: String
    public var trigger: String?
    public var global: Bool
    public var icon: String?
    public var keywords: [String]
    public var priority: Int
    public var kind: PathKind
    public var scopeName: String
    public var openWith: String
    public var secondary: String
    public var maxResults: Int
    public var terminalApp: String
    public var freeform: Bool

    public init(
        id: String,
        name: String,
        trigger: String?,
        global: Bool = false,
        icon: String? = nil,
        keywords: [String] = [],
        priority: Int = 0,
        kind: PathKind,
        scopeName: String = "projects",
        openWith: String = "neovide",
        secondary: String = "reveal",
        maxResults: Int = 50,
        terminalApp: String = "kitty",
        freeform: Bool = false
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.global = global
        self.icon = icon
        self.keywords = keywords
        self.priority = priority
        self.kind = kind
        self.scopeName = scopeName
        self.openWith = openWith
        self.secondary = secondary
        self.maxResults = maxResults
        self.terminalApp = terminalApp
        self.freeform = freeform
    }
}

/// One scope's paths, ready to rank: the flat list plus the directory flags
/// captured during the walk.
private struct PathSnapshot: Sendable {
    let paths: [String]
    let directories: Set<String>
    /// True when the rows came from a live walk, which already validated them.
    let verified: Bool

    init(entries: [PathEntry], verified: Bool) {
        var paths: [String] = []
        paths.reserveCapacity(entries.count)
        var directories: Set<String> = []
        for entry in entries {
            paths.append(entry.path)
            if entry.isDirectory { directories.insert(entry.path) }
        }
        self.paths = paths
        self.directories = directories
        self.verified = verified
    }
}

private actor PathCache {
    private struct Entry {
        var date: Date
        var snapshot: PathSnapshot
    }

    private struct InFlight {
        let id: UUID
        let task: Task<PathSnapshot, Error>
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: InFlight] = [:]
    private let ttl: TimeInterval = 60

    func snapshot(for key: String) -> PathSnapshot? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.date) < ttl else { return nil }
        return entry.snapshot
    }

    /// One walk per key: a keystroke that lands mid-scan joins the running task
    /// instead of cancelling it. The walk is an unstructured task, so a
    /// cancelled caller only abandons its wait.
    func snapshot(
        for key: String,
        loading load: @Sendable @escaping () async throws -> PathSnapshot
    ) async throws -> PathSnapshot {
        if let cached = snapshot(for: key) { return cached }
        if let running = inFlight[key] { return try await running.task.value }

        let id = UUID()
        let task = Task { [weak self] () throws -> PathSnapshot in
            do {
                let snapshot = try await load()
                await self?.store(snapshot, key: key, id: id)
                return snapshot
            } catch {
                await self?.clear(key: key, id: id)
                throw error
            }
        }
        inFlight[key] = InFlight(id: id, task: task)
        return try await task.value
    }

    private func store(_ snapshot: PathSnapshot, key: String, id: UUID) {
        entries[key] = Entry(date: Date(), snapshot: snapshot)
        if inFlight[key]?.id == id { inFlight[key] = nil }
    }

    private func clear(key: String, id: UUID) {
        if inFlight[key]?.id == id { inFlight[key] = nil }
    }
}

/// Persists one enumeration per scope signature so the first bound query after
/// a launch doesn't pay for the cold `fd` walk. A file is ignored once it is
/// 24 h old; the next search then rescans and rewrites it.
public struct PathDiskCache: Sendable {
    public static let maxAge: TimeInterval = 24 * 60 * 60
    private static let version = 1
    private static let maxEntries = 100_000
    private static let maxBytes = 64 * 1024 * 1024

    private struct File: Codable {
        var version: Int
        var signature: String
        var created: Date
        var directories: [String]
        var files: [String]
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(signature: String, now: Date = Date()) -> [PathEntry]? {
        guard let data = try? Data(contentsOf: url(for: signature)),
              data.count <= Self.maxBytes,
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == Self.version,
              file.signature == signature,
              now.timeIntervalSince(file.created) < Self.maxAge,
              file.directories.count + file.files.count <= Self.maxEntries else {
            return nil
        }
        return file.directories.map { PathEntry(path: $0, isDirectory: true) }
            + file.files.map { PathEntry(path: $0, isDirectory: false) }
    }

    public func save(_ entries: [PathEntry], signature: String) {
        guard !entries.isEmpty, entries.count <= Self.maxEntries else { return }
        let file = File(
            version: Self.version,
            signature: signature,
            created: Date(),
            directories: entries.lazy.filter(\.isDirectory).map(\.path),
            files: entries.lazy.filter { !$0.isDirectory }.map(\.path)
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        let url = url(for: signature)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // shortcut: a failed write only means the next launch rescans
        try? data.write(to: url, options: .atomic)
    }

    private func url(for signature: String) -> URL {
        // FNV-1a: `hashValue` is seeded per process and would miss every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in signature.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return directory
            .appendingPathComponent("Paths", isDirectory: true)
            .appendingPathComponent("\(String(hash, radix: 16)).json")
    }
}

public final class PathsProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor: ProviderDescriptor
    public let configuration: PathsProviderConfiguration

    private let scope: Scope
    private let enumerator: any PathEnumerating
    private let ranker: any FuzzyPathRanking
    private let launcher: LauncherService
    private let diskCache: PathDiskCache
    private let cache = PathCache()

    public init(
        configuration: PathsProviderConfiguration,
        scope: Scope,
        launcher: LauncherService,
        cacheDirectory: URL,
        enumerator: any PathEnumerating = FDEnumerator(),
        ranker: any FuzzyPathRanking = FzfRanker()
    ) {
        self.configuration = configuration
        self.scope = scope
        self.launcher = launcher
        self.diskCache = PathDiskCache(directory: cacheDirectory)
        self.enumerator = enumerator
        self.ranker = ranker
        self.descriptor = ProviderDescriptor(
            id: configuration.id,
            name: configuration.name,
            trigger: configuration.trigger,
            isGlobal: configuration.global,
            priority: configuration.priority,
            icon: configuration.icon,
            keywords: configuration.keywords
        )
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let missing = ["fd", "fzf"].filter { ToolLocator.shared.path(for: $0) == nil }
        if !missing.isEmpty {
            guard request.isBound else { return [] }
            return [installRow(missing: missing)]
        }

        if let browsed = try await browseItems(for: request.text, limit: request.limit) {
            return browsed
        }

        let snapshot = try await snapshot()
        guard !snapshot.paths.isEmpty else {
            return freeformItems(for: request.text)
        }
        let ranked = try await ranker.rank(
            paths: snapshot.paths,
            query: request.text,
            limit: min(configuration.maxResults, max(1, request.limit))
        )

        var items = ranked.enumerated().map { index, path in
            item(
                for: path,
                rank: index,
                isDirectory: snapshot.verified ? snapshot.directories.contains(path) : nil
            )
        }
        for extra in freeformItems(for: request.text) where !items.contains(where: { $0.id == extra.id }) {
            items.insert(extra, at: 0)
        }
        return items
    }

    /// Loads the disk cache or walks the scope now. Called at launch so the
    /// first bound query is warm.
    public func prewarm() async {
        guard ToolLocator.shared.path(for: "fd") != nil else { return }
        _ = try? await snapshot()
    }

    private var cacheKey: String { "\(configuration.scopeName):\(configuration.kind.rawValue)" }

    /// Identifies the walk: every field that changes which paths `fd` sees.
    private var scopeSignature: String {
        [
            configuration.kind.rawValue,
            scope.roots.joined(separator: ","),
            scope.exclude.joined(separator: ","),
            scope.include.joined(separator: ","),
            "hidden:\(scope.includeHidden)",
            "depth:\(scope.maxDepth)",
            "gitignore:\(scope.respectGitignore)",
        ].joined(separator: "|")
    }

    private func snapshot() async throws -> PathSnapshot {
        let signature = scopeSignature
        let disk = diskCache
        let enumerator = self.enumerator
        let scope = self.scope
        let kind = configuration.kind
        return try await cache.snapshot(for: cacheKey) {
            if let cached = disk.load(signature: signature) {
                return PathSnapshot(entries: cached, verified: false)
            }
            let entries = try await enumerator.enumerateEntries(scope: scope, kind: kind)
            disk.save(entries, signature: signature)
            return PathSnapshot(entries: entries, verified: true)
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if action.kind == .custom, action.value.text == "install" {
            try await MainActor.run {
                try launcher.openTerminal(command: "brew install fd fzf", app: configuration.terminalApp)
            }
            return
        }
        guard case .object(let payload) = action.value,
              let path = payload["path"],
              let app = payload["app"] else { return }
        try await MainActor.run {
            try launcher.openPath(path, with: app)
        }
    }

    /// `known` comes straight from the enumeration, which already stat'ed the
    /// path; browse and freeform rows pass nil and get one stat.
    private func item(for path: String, rank: Int, isDirectory known: Bool? = nil) -> PaletteItem {
        let isDirectory: Bool
        if let known {
            isDirectory = known
        } else {
            var flag: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &flag)
            isDirectory = flag.boolValue
        }
        let name = (path as NSString).lastPathComponent
        let trimmed = Self.displayPath(path)
        let ext = (path as NSString).pathExtension

        var actions: [PaletteAction] = [
            PaletteAction(
                id: "open",
                title: "Open with \(configuration.openWith)",
                kind: .openPathWith,
                value: .object(["path": path, "app": configuration.openWith])
            ),
        ]

        switch configuration.secondary.lowercased() {
        case "open":
            actions.append(PaletteAction(id: "open-default", title: "Open", kind: .openPath, value: .text(path)))
        case "copy":
            actions.append(PaletteAction(id: "copy", title: "Copy Path", kind: .copyText, value: .text(path)))
        default:
            actions.append(PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .reveal, value: .text(path)))
        }

        if !actions.contains(where: { $0.kind == .reveal }) {
            actions.append(PaletteAction(id: "reveal-extra", title: "Reveal in Finder", kind: .reveal, value: .text(path)))
        }
        if !actions.contains(where: { $0.kind == .copyText }) {
            actions.append(PaletteAction(id: "copy-extra", title: "Copy Path", kind: .copyText, value: .text(path)))
        }
        let terminalPath = isDirectory ? path : (path as NSString).deletingLastPathComponent
        actions.append(PaletteAction(
            id: "term-here",
            title: "Open in Embedded Terminal",
            kind: .custom,
            value: .object(["path": terminalPath])
        ))

        return PaletteItem(
            id: path,
            title: name,
            subtitle: trimmed,
            icon: isDirectory ? .symbol("folder.fill") : .file(path),
            badge: isDirectory ? "folder" : (ext.isEmpty ? nil : ext.uppercased()),
            score: 1_000 - Double(rank),
            actions: actions,
            preview: .files(paths: [path]),
            providerID: configuration.id,
            providerName: configuration.name
        )
    }

    /// `~/dev/` browses that directory breadth-first: direct children first,
    /// then the next level. This keeps navigation predictable instead of
    /// letting fzf scatter deep paths above the folder you are standing in.
    private func browseItems(for query: String, limit: Int) async throws -> [PaletteItem]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("/"), !trimmed.isEmpty else { return nil }

        let dir: String
        if trimmed.hasPrefix("/") {
            dir = (trimmed as NSString).standardizingPath
        } else if trimmed.hasPrefix("~") {
            dir = PathExpansion.expand(trimmed)
        } else if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            dir = ((NSHomeDirectory() + "/" + trimmed) as NSString).standardizingPath
        } else {
            dir = ((NSHomeDirectory() + "/" + trimmed) as NSString).standardizingPath
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let browseScope = Scope(
            roots: [dir],
            exclude: scope.exclude,
            include: scope.include,
            includeHidden: scope.includeHidden,
            maxDepth: min(scope.maxDepth, 3),
            respectGitignore: scope.respectGitignore
        )
        var paths = try await enumerator.enumerate(scope: browseScope, kind: configuration.kind)
        try Task.checkCancellation()

        let manager = FileManager.default
        paths.sort { lhs, rhs in
            let lhsDepth = lhs.dropFirst(dir.count).filter { $0 == "/" }.count
            let rhsDepth = rhs.dropFirst(dir.count).filter { $0 == "/" }.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            var lhsDir: ObjCBool = false
            var rhsDir: ObjCBool = false
            manager.fileExists(atPath: lhs, isDirectory: &lhsDir)
            manager.fileExists(atPath: rhs, isDirectory: &rhsDir)
            if lhsDir.boolValue != rhsDir.boolValue { return lhsDir.boolValue }
            return (lhs as NSString).lastPathComponent.localizedStandardCompare((rhs as NSString).lastPathComponent) == .orderedAscending
        }
        let cap = max(1, min(configuration.maxResults, max(1, limit)))
        return paths.prefix(cap).enumerated().map { index, path in
            item(for: path, rank: -1_000 + index)
        }
    }

    private func freeformItems(for query: String) -> [PaletteItem] {
        guard configuration.freeform else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("/") else { return [] }

        let expanded: String
        if trimmed.hasPrefix("/") {
            expanded = (trimmed as NSString).standardizingPath
        } else if trimmed.hasPrefix("~") {
            expanded = PathExpansion.expand(trimmed)
        } else if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") || trimmed.contains("/") {
            expanded = ((NSHomeDirectory() + "/" + trimmed) as NSString).standardizingPath
        } else {
            expanded = NSHomeDirectory() + "/" + trimmed
        }

        guard PathFilter.isUsable(expanded, expected: configuration.kind) else { return [] }
        return [item(for: expanded, rank: -1_000)]
    }

    /// `~`-abbreviated path, shared by every provider that shows one.
    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func installRow(missing: [String]) -> PaletteItem {
        PaletteItem(
            id: "install-tools",
            title: "Install fd and fzf",
            subtitle: "Missing \(missing.joined(separator: " and ")) — run brew install fd fzf",
            icon: .symbol("exclamationmark.triangle"),
            score: 10_000,
            actions: [
                PaletteAction(
                    id: "install",
                    title: "Open Terminal and Install",
                    kind: .custom,
                    value: .text("install")
                ),
            ],
            providerID: configuration.id,
            providerName: configuration.name
        )
    }
}
