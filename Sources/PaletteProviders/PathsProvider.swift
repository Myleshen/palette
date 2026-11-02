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

private actor PathCache {
    private struct Entry {
        var date: Date
        var paths: [String]
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 60

    func paths(for key: String) -> [String]? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.date) < ttl else { return nil }
        return entry.paths
    }

    func store(_ paths: [String], for key: String) {
        entries[key] = Entry(date: Date(), paths: paths)
    }

    func removeAll() {
        entries.removeAll()
    }
}

public final class PathsProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor: ProviderDescriptor
    public let configuration: PathsProviderConfiguration

    private let scope: Scope
    private let enumerator: any PathEnumerating
    private let ranker: any FuzzyPathRanking
    private let launcher: LauncherService
    private let cache = PathCache()

    public init(
        configuration: PathsProviderConfiguration,
        scope: Scope,
        launcher: LauncherService,
        enumerator: any PathEnumerating = FDEnumerator(),
        ranker: any FuzzyPathRanking = FzfRanker()
    ) {
        self.configuration = configuration
        self.scope = scope
        self.launcher = launcher
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
            return [installRow(missing: missing)]
        }

        let key = "\(configuration.scopeName):\(configuration.kind.rawValue)"
        if let browsed = try await browseItems(for: request.text, limit: request.limit) {
            return browsed
        }

        var paths = await cache.paths(for: key)
        if paths == nil {
            let enumerated = try await enumerator.enumerate(scope: scope, kind: configuration.kind)
            try Task.checkCancellation()
            await cache.store(enumerated, for: key)
            paths = enumerated
        }

        guard let paths, !paths.isEmpty else {
            return freeformItems(for: request.text)
        }
        let ranked = try await ranker.rank(
            paths: paths,
            query: request.text,
            limit: min(configuration.maxResults, max(1, request.limit))
        )

        var items = ranked.enumerated().map { index, path in
            item(for: path, rank: index)
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

    private func item(for path: String, rank: Int) -> PaletteItem {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        manager.fileExists(atPath: path, isDirectory: &isDirectory)
        let name = (path as NSString).lastPathComponent
        let trimmed = displayPath(path)
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

        return PaletteItem(
            id: path,
            title: name,
            subtitle: trimmed,
            icon: isDirectory.boolValue ? .symbol("folder.fill") : .file(path),
            badge: isDirectory.boolValue ? "folder" : (ext.isEmpty ? nil : ext.uppercased()),
            score: 1_000 - Double(rank),
            actions: actions,
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

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return [] }
        switch configuration.kind {
        case .directories where !isDirectory.boolValue: return []
        case .files where isDirectory.boolValue: return []
        default: break
        }
        return [item(for: expanded, rank: -1_000)]
    }

    private func displayPath(_ path: String) -> String {
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
