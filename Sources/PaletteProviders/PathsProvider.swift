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
    /// Hard cap on one walk; the disk cache refuses bigger snapshots.
    public var maxEntries: Int
    /// How long an in-memory snapshot is served before a background refresh.
    public var refreshInterval: TimeInterval
    /// The 2.18 home-indexing consent. The whole-home walk is skipped without it.
    public var homeIndexingAllowed: Bool

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
        freeform: Bool = false,
        maxEntries: Int = FDEnumerator.defaultMaxEntries,
        refreshInterval: TimeInterval = 300,
        homeIndexingAllowed: Bool = false
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
        self.maxEntries = maxEntries
        self.refreshInterval = refreshInterval
        self.homeIndexingAllowed = homeIndexingAllowed
    }
}

/// One scope's paths, ready to rank: the flat list plus the directory flags
/// captured during the walk.
private struct PathSnapshot: Sendable {
    let paths: [String]
    let directories: Set<String>
    /// True when the rows came from a live walk, which already validated them.
    let verified: Bool
    let builtAt: Date

    init(entries: [PathEntry], verified: Bool, builtAt: Date = Date()) {
        var paths: [String] = []
        paths.reserveCapacity(entries.count)
        var directories: Set<String> = []
        directories.reserveCapacity(entries.count / 8)
        for entry in entries {
            paths.append(entry.path)
            if entry.isDirectory { directories.insert(entry.path) }
        }
        self.paths = paths
        self.directories = directories
        self.verified = verified
        self.builtAt = builtAt
    }
}

/// The last good snapshot plus the one in-flight refresh. A keystroke reads
/// the snapshot under the lock and never waits on `fd`.
private final class PathIndexState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PathSnapshot?
    private var refreshing = false
    private var diskLoad: Task<Void, Never>?
    private var homeAllowed: Bool

    init(homeAllowed: Bool) {
        self.homeAllowed = homeAllowed
    }

    func current() -> PathSnapshot? {
        lock.withLock { snapshot }
    }

    func allowHome() {
        lock.withLock { homeAllowed = true }
    }

    func homeIsAllowed() -> Bool {
        lock.withLock { homeAllowed }
    }

    func storeLoaded(_ loaded: PathSnapshot) {
        lock.withLock {
            // A walk that finished first is newer than the disk cache.
            if snapshot == nil { snapshot = loaded }
        }
    }

    func diskLoadTask() -> Task<Void, Never>? {
        lock.withLock { diskLoad }
    }

    func setDiskLoad(_ task: Task<Void, Never>) {
        lock.withLock { diskLoad = task }
    }

    /// Returns true when this call owns the refresh.
    func beginRefresh() -> Bool {
        lock.withLock {
            guard !refreshing else { return false }
            refreshing = true
            return true
        }
    }

    /// Returns true when a refresh was in flight, so exactly one completion
    /// notifies the host.
    func finishRefresh(_ fresh: PathSnapshot) -> Bool {
        lock.withLock {
            snapshot = fresh
            let wasRefreshing = refreshing
            refreshing = false
            return wasRefreshing
        }
    }

    func endRefresh() {
        lock.withLock { refreshing = false }
    }
}

/// Persists one enumeration per scope signature so the first bound query after
/// a launch doesn't pay for the cold `fd` walk. A file is ignored once it is
/// 24 h old; the next search then rescans and rewrites it.
public struct PathDiskCache: Sendable {
    public static let maxAge: TimeInterval = 24 * 60 * 60
    private static let version = 1
    // shortcut: a snapshot above this is not cached (the walk cap is 150k);
    // raise both together if the cap grows.
    private static let maxEntries = 200_000
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

    /// Blocking JSON decode: callers must be off the main thread.
    public func load(signature: String, now: Date = Date()) -> [PathEntry]? {
        guard let data = try? Data(contentsOf: url(for: signature), options: .mappedIfSafe),
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
    /// Posted once per finished refresh with the provider id. The host re-runs
    /// the current query so results replace the "Indexing files…" row without
    /// the user retyping.
    public static let indexUpdatedNotification = Notification.Name("palette.pathsIndexUpdated")
    /// Below this a per-keystroke `fzf` process costs more than a scan.
    public static let fzfThreshold = 20_000

    public let descriptor: ProviderDescriptor
    public let configuration: PathsProviderConfiguration

    private let scope: Scope
    private let enumerator: any PathEnumerating
    private let ranker: any FuzzyPathRanking
    private let launcher: LauncherService
    private let diskCache: PathDiskCache
    private let index: PathIndexState

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
        self.index = PathIndexState(homeAllowed: configuration.homeIndexingAllowed)
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
        #if DEBUG
        // A keystroke must never do I/O on the main thread: fd/stat, fzf and the
        // cache decode all run on the caller's background executor.
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let missing = pathToolMissing
        if !missing.isEmpty {
            guard request.isBound else { return [] }
            return [installRow(missing: missing)]
        }

        if let browsed = try await browseItems(for: request.text, limit: request.limit) {
            return browsed
        }

        if let snapshot = await snapshotServingRefresh() {
            return try await rankedItems(snapshot: snapshot, request: request)
        }

        guard request.isBound else { return freeformItems(for: request.text) }
        let fallback = canIndex ? indexingRow() : homeConsentRow()
        return freeformItems(for: request.text) + [fallback]
    }

    /// `fd` is required; `fzf` is optional and only used above the threshold.
    private var pathToolMissing: [String] {
        ToolLocator.shared.path(for: "fd") == nil ? ["fd"] : []
    }

    /// True when this provider walks the whole home folder, which is the walk
    /// that raises macOS folder prompts.
    public var indexesHomeFolder: Bool {
        scope.expandedRoots.contains(NSHomeDirectory())
    }

    /// Keystrokes and the notch between them share one flag.
    private var canIndex: Bool {
        !indexesHomeFolder || index.homeIsAllowed()
    }

    /// Loads the disk cache and refreshes now. Called at launch so the first
    /// bound query is served from memory; the walk itself never runs on the
    /// caller's actor and never blocks a query.
    public func prewarm(homeConsent: Bool) async {
        if homeConsent { index.allowHome() }
        guard ToolLocator.shared.path(for: "fd") != nil, canIndex else { return }
        await loadDiskCache()
        if let snapshot = index.current(),
           snapshot.verified,
           Date().timeIntervalSince(snapshot.builtAt) < configuration.refreshInterval {
            return
        }
        startRefresh()
    }

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

    /// The last snapshot, never waiting on a walk. A stale one is served as-is
    /// while exactly one refresh runs in the background.
    private func snapshotServingRefresh() async -> PathSnapshot? {
        if let snapshot = index.current() {
            if !snapshot.verified
                || Date().timeIntervalSince(snapshot.builtAt) >= configuration.refreshInterval {
                startRefresh()
            }
            return snapshot
        }
        await loadDiskCache()
        if let snapshot = index.current() {
            startRefresh()
            return snapshot
        }
        startRefresh()
        return nil
    }

    /// One JSON decode per launch, off the main thread, shared by every
    /// keystroke that lands while it is still running.
    private func loadDiskCache() async {
        let task: Task<Void, Never>
        if let existing = index.diskLoadTask() {
            task = existing
        } else {
            let disk = diskCache
            let signature = scopeSignature
            let index = self.index
            task = Task.detached(priority: .utility) {
                guard let entries = disk.load(signature: signature) else { return }
                index.storeLoaded(PathSnapshot(entries: entries, verified: false))
            }
            index.setDiskLoad(task)
        }
        await task.value
    }

    private func startRefresh() {
        guard canIndex, index.beginRefresh() else { return }
        let enumerator = self.enumerator
        let scope = self.scope
        let kind = configuration.kind
        let cap = max(1, configuration.maxEntries)
        let signature = scopeSignature
        let disk = diskCache
        let index = self.index
        let providerID = configuration.id
        let scopeLabel = scope.roots.joined(separator: ",")

        // The start line always lands, so a hung build leaves a breadcrumb in
        // palette.log; the finish line carries the size and duration.
        Log.shared.info("Index build started scope=\(scopeLabel) cap=\(cap)", source: "paths")
        Task.detached(priority: .utility) {
            let started = Date()
            do {
                let entries = try await enumerator.enumerateEntries(scope: scope, kind: kind, maxEntries: cap)
                try Task.checkCancellation()
                let duration = Date().timeIntervalSince(started)
                disk.save(entries, signature: signature)
                let finished = index.finishRefresh(PathSnapshot(entries: entries, verified: true))
                Log.shared.info(
                    "Index build finished scope=\(scopeLabel) entries=\(entries.count) duration=\(String(format: "%.1f", duration))s",
                    source: "paths"
                )
                if finished {
                    NotificationCenter.default.post(name: Self.indexUpdatedNotification, object: providerID)
                }
            } catch {
                index.endRefresh()
                Log.shared.warn(
                    "Index build failed scope=\(scopeLabel) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error.localizedDescription)",
                    source: "paths"
                )
            }
        }
    }

    private func rankedItems(snapshot: PathSnapshot, request: SearchRequest) async throws -> [PaletteItem] {
        let limit = min(configuration.maxResults, max(1, request.limit))
        let ranker: any FuzzyPathRanking = snapshot.paths.count < Self.fzfThreshold
            || ToolLocator.shared.path(for: "fzf") == nil
            ? RankingPathRanker()
            : self.ranker
        let ranked = try await ranker.rank(
            paths: snapshot.paths,
            query: request.text,
            limit: limit
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

        // Editor rows should not pretend a second project opens in its own
        // window when the editor can only reuse the one that is open.
        let subtitle = EditorLaunch.reusesOpenWindow(app: configuration.openWith)
            ? trimmed + " · reuses the open window"
            : trimmed

        return PaletteItem(
            id: path,
            title: name,
            subtitle: subtitle,
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

    private func indexingRow() -> PaletteItem {
        PaletteItem(
            id: "\(configuration.id):indexing",
            title: "Indexing files…",
            subtitle: "Results appear when the \(configuration.scopeName) scan finishes",
            icon: .symbol("hourglass"),
            score: 10_000,
            providerID: configuration.id,
            providerName: configuration.name
        )
    }

    private func homeConsentRow() -> PaletteItem {
        PaletteItem(
            id: "\(configuration.id):home-consent",
            title: "Home indexing is off",
            subtitle: "Turn on “Index my home folder” in Settings › File indexing",
            icon: .symbol("lock.shield"),
            score: 10_000,
            trouble: ItemTrouble(
                title: "Home indexing is off",
                detail: "Palette only walks ~ after you opt in.",
                settingsAnchor: "providers-indexing"
            ),
            providerID: configuration.id,
            providerName: configuration.name
        )
    }

    private func installRow(missing: [String]) -> PaletteItem {
        PaletteItem(
            id: "install-tools",
            title: "Install fd",
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
