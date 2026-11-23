import Foundation
import PaletteCore
import PalettePlatform
import TOMLKit

/// The `[[roots]]` blocks of devx's config.
public enum DevxConfig {
    public struct Root: Equatable {
        public var name: String
        public var path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public static func roots(from toml: String) -> [Root] {
        guard let table = try? TOMLTable(string: toml),
              let entries = table["roots"]?.array else { return [] }
        return entries.compactMap { value in
            guard let row = value.table,
                  let name = row["name"]?.string,
                  let path = row["path"]?.string,
                  !name.isEmpty, !path.isEmpty else { return nil }
            return Root(name: name, path: path)
        }
    }
}

/// A single path component safe to `mkdir` under a devx root.
public enum ProjectName {
    public static func validate(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        return name
    }
}

/// Fast project switcher. Mutations go through devx when it is installed, so
/// its worktree and overlay safety checks stay authoritative.
public final class ProjectProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "proj",
        name: "Projects",
        trigger: "proj",
        isGlobal: false,
        priority: 56,
        icon: "symbol:folder.badge.gearshape"
    )

    private struct Project {
        var name: String
        var path: String
        var isWorktree: Bool
    }

    /// What the preview pane shows for a project. One shell round trip per
    /// project, cached with the project list.
    struct GitState: Sendable {
        var branch: String
        var lastCommit: String
        var worktrees: [String]
        var changes: Int

        var preview: String {
            var lines = ["Branch \(branch)"]
            if !lastCommit.isEmpty { lines.append("Last commit \(lastCommit)") }
            lines.append("Changes \(changes)")
            if worktrees.count > 1 {
                lines.append("Worktrees \(worktrees.joined(separator: ", "))")
            }
            return lines.joined(separator: "\n")
        }
    }

    private let launcher: LauncherService
    private let bridge: HostBridge
    private let terminal: String
    private actor Cache {
        var projects: [Project] = []
        var at = Date.distantPast
        func update(_ projects: [Project]) { self.projects = projects; at = Date() }
        func invalidate() { at = .distantPast }
    }
    private let cache = Cache()

    /// Git state is only ever read off the row path: `search` returns the list
    /// from whatever is cached, and the selected row's preview is fetched by the
    /// host afterwards. Five minutes plus the checkout's own HEAD/index mtimes,
    /// so a commit or a branch switch shows up on the next look.
    private actor GitCache {
        private var states: [String: (state: GitState, fingerprint: String, at: Date)] = [:]
        private let ttl: TimeInterval = 300

        private func fresh(_ path: String) -> GitState? {
            guard let entry = states[path],
                  Date().timeIntervalSince(entry.at) < ttl,
                  entry.fingerprint == ProjectProvider.fingerprint(path: path) else { return nil }
            return entry.state
        }

        /// Only what is already warm. Never runs a command.
        func cached(for paths: [String]) -> [String: GitState] {
            var result: [String: GitState] = [:]
            for path in paths {
                if let state = fresh(path) { result[path] = state }
            }
            return result
        }

        /// One row's state, cached or fetched now.
        func state(for path: String) async -> GitState? {
            if let state = fresh(path) { return state }
            guard let state = await ProjectProvider.gitState(path: path) else { return nil }
            states[path] = (state, ProjectProvider.fingerprint(path: path), Date())
            return state
        }

        /// Warms the top rows so arrowing down does not wait on git.
        func warm(_ paths: [String]) async {
            let stale = paths.filter { fresh($0) == nil }
            guard !stale.isEmpty else { return }
            await withTaskGroup(of: (String, GitState?).self) { group in
                for path in stale {
                    group.addTask { (path, await ProjectProvider.gitState(path: path)) }
                }
                for await (path, state) in group {
                    guard let state else { continue }
                    states[path] = (state, ProjectProvider.fingerprint(path: path), Date())
                }
            }
        }

        func invalidate() { states.removeAll() }
    }
    private let gitCache = GitCache()

    public init(launcher: LauncherService, bridge: HostBridge, terminal: String = "kitty") {
        self.launcher = launcher
        self.bridge = bridge
        self.terminal = terminal
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let cached = await cache.projects
        let at = await cache.at
        let projects: [Project]
        if Date().timeIntervalSince(at) < 60, !cached.isEmpty {
            projects = cached
        } else {
            projects = await Self.projects()
            await cache.update(projects)
        }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = projects.map { "\($0.name) \($0.path)" }
        let indices = await RowFilter.matchingIndices(query: query, candidates: candidates)
        // Relevance first, then the name: the registry order is not a ranking.
        let matched = indices.map { index -> (project: Project, score: Double) in
            let project = projects[index]
            let score = query.isEmpty ? 0 : (Ranking.score(query: query, candidate: candidates[index]) ?? 0)
            return (project, score)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.project.name.localizedCaseInsensitiveCompare(rhs.project.name) == .orderedAscending
        }
        // Rows never wait on git; a preview appears for rows already warm and
        // the host asks for the selected one through `AsyncPreviewProviding`.
        let warm = await gitCache.cached(for: matched.prefix(20).map { $0.project.path })
        let rows = matched.map { item($0.project, git: warm[$0.project.path]) }
        if !rows.isEmpty {
            let paths = matched.prefix(4).map { $0.project.path }
            Task { await gitCache.warm(paths) }
        }
        guard query.isEmpty else { return rows }
        return actionItems() + rows
    }

    /// The host asks for the selected row's preview after the list is shown.
    public func preview(for item: PaletteItem) async -> ItemPreview? {
        let path = item.actions.compactMap { $0.value.object?["path"] }.first
            ?? String(item.id.dropFirst("proj:".count))
        guard let state = await gitCache.state(for: path) else { return nil }
        return .text(state.preview)
    }

    /// Repository state also changes under us (a commit, a branch switch), so
    /// the fingerprint on the entry is what really decides freshness.
    static func fingerprint(path: String) -> String {
        func stamp(_ file: String) -> String {
            guard let date = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date else {
                return "-"
            }
            return String(Int(date.timeIntervalSince1970))
        }
        // shortcut: a linked worktree keeps HEAD/index in the main checkout, so
        // its fingerprint is constant and only the TTL refreshes it.
        return stamp(path + "/.git/HEAD") + ":" + stamp(path + "/.git/index")
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if action.id == "clone-repo" {
            try await cloneRepository()
            await invalidateCaches(delayed: true)
            return
        }
        if action.id == "new-project" {
            try await newProject()
            await invalidateCaches()
            return
        }
        guard let value = action.value.object, let name = value["name"], let path = value["path"] else { return }
        let devx = ToolLocator.shared.path(for: "devx")
        switch action.id {
        case "neovide":
            try await MainActor.run { try launcher.openPath(path, with: "neovide") }
        case "terminal":
            let quoted = Self.shellQuote(path)
            try await MainActor.run {
                try launcher.openTerminal(command: "cd \(quoted)", app: terminal)
            }
        case "workspace":
            guard let devx else {
                await bridge.notify("devx is not installed; opening a terminal instead")
                let quoted = Self.shellQuote(path)
                try await MainActor.run { try launcher.openTerminal(command: "cd \(quoted)", app: terminal) }
                return
            }
            try await MainActor.run {
                try launcher.openTerminal(command: "\(Self.shellQuote(devx)) open \(Self.shellQuote(name)) --profile workspace", app: terminal)
            }
        case "new-worktree":
            guard let devx else {
                await bridge.notify("Install devx to create worktrees")
                return
            }
            guard let branch = await bridge.prompt(kind: .text, title: "New worktree branch for \(name)", placeholder: "feature/name"),
                  !branch.isEmpty else { return }
            try await MainActor.run {
                try launcher.openTerminal(command: "\(Self.shellQuote(devx)) worktree create \(Self.shellQuote(name)) \(Self.shellQuote(branch))", app: terminal)
            }
            await invalidateCaches(delayed: true)
        case "remove-worktree":
            guard let devx else {
                await bridge.notify("Install devx to remove worktrees")
                return
            }
            guard await bridge.prompt(kind: .confirm, title: "Remove worktree \(name)?", placeholder: nil) != nil else { return }
            try await MainActor.run {
                try launcher.openTerminal(command: "\(Self.shellQuote(devx)) worktree remove \(Self.shellQuote(name))", app: terminal)
            }
            await invalidateCaches(delayed: true)
        case "apply-config":
            guard let devx else {
                await bridge.notify("Install devx to apply config overlays")
                return
            }
            try await MainActor.run {
                try launcher.openTerminal(command: "\(Self.shellQuote(devx)) config apply \(Self.shellQuote(name))", app: terminal)
            }
        case "devx-config":
            await MainActor.run { launcher.openPath(PathExpansion.expand("~/.config/devx/config.toml")) }
        case "reveal":
            await MainActor.run { launcher.reveal(path) }
        default:
            break
        }
    }

    private func actionItems() -> [PaletteItem] {
        [
            PaletteItem(
                id: "clone-repo",
                title: "Clone a repository…",
                subtitle: "devx project clone into a scan root",
                icon: .symbol("arrow.down.circle"),
                badge: "new",
                score: 9_000,
                actions: [PaletteAction(id: "clone-repo", title: "Clone a repository", kind: .custom)],
                providerID: descriptor.id,
                providerName: descriptor.name
            ),
            PaletteItem(
                id: "new-project",
                title: "New project…",
                subtitle: "Create a git repository and register it with devx",
                icon: .symbol("plus.circle"),
                badge: "new",
                score: 8_900,
                actions: [PaletteAction(id: "new-project", title: "New project", kind: .custom)],
                providerID: descriptor.id,
                providerName: descriptor.name
            ),
        ]
    }

    private func cloneRepository() async throws {
        guard let devx = ToolLocator.shared.path(for: "devx") else {
            await bridge.notify("Install devx to clone repositories")
            return
        }
        guard let entered = await bridge.prompt(
            kind: .text,
            title: "Clone a repository",
            placeholder: "github.com/owner/repo"
        ) else { return }
        let url = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            await bridge.notify("A repository URL is required")
            return
        }

        let roots = Self.devxRoots()
        guard let fallback = roots.first else {
            await bridge.notify("No devx scan roots configured; run devx project add-root")
            return
        }
        var selected = fallback.name
        if roots.count > 1 {
            guard let entered = await bridge.prompt(
                kind: .text,
                title: "Clone into which devx root?",
                placeholder: fallback.name
            ) else { return }
            selected = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard roots.contains(where: { $0.name == selected }) else {
                await bridge.notify("Unknown devx root \(selected)")
                return
            }
        }
        let root = selected

        try await MainActor.run {
            try launcher.openTerminal(
                command: "\(Self.shellQuote(devx)) project clone \(Self.shellQuote(root)) \(Self.shellQuote(url))",
                app: terminal
            )
        }
        await bridge.notify("Cloning \(url) into \(root)")
    }

    private func newProject() async throws {
        guard let devx = ToolLocator.shared.path(for: "devx") else {
            await bridge.notify("Install devx to create projects")
            return
        }
        guard let entered = await bridge.prompt(
            kind: .text,
            title: "New project name",
            placeholder: "my-new-project"
        ) else { return }
        guard let name = ProjectName.validate(entered) else {
            await bridge.notify("Use a single folder name without / or ..")
            return
        }
        guard let root = Self.devxRoots().first else {
            await bridge.notify("No devx scan roots configured; run devx project add-root")
            return
        }
        let path = PathExpansion.expand(root.path) + "/" + name

        do {
            let mkdir = try await ProcessRunner.run(["/bin/mkdir", "-p", path], timeout: 10)
            guard mkdir.status == 0 else {
                await bridge.notify("Could not create \(path): \(Self.firstLine(mkdir.stderrString))")
                return
            }
            let initResult = try await ProcessRunner.run(["git", "init", path], timeout: 20)
            guard initResult.status == 0 else {
                await bridge.notify("git init failed: \(Self.firstLine(initResult.stderrString))")
                return
            }
            let add = try await ProcessRunner.run([devx, "project", "add", path], timeout: 20)
            guard add.status == 0 else {
                await bridge.notify("devx project add failed: \(Self.firstLine(add.stderrString))")
                return
            }
        } catch {
            await bridge.notify("Could not create \(name): \(error.localizedDescription)")
            return
        }

        await bridge.notify("Created \(name) in \(path)")
    }

    /// A clone or worktree is created by another process, so the list is
    /// dropped now and again once the terminal command has had time to run.
    private func invalidateCaches(delayed: Bool = false) async {
        await cache.invalidate()
        await gitCache.invalidate()
        guard delayed else { return }
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await cache.invalidate()
            await gitCache.invalidate()
        }
    }

    static func devxRoots() -> [DevxConfig.Root] {
        let path = PathExpansion.expand("~/.config/devx/config.toml")
        guard let toml = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return DevxConfig.roots(from: toml)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "unknown error"
    }

    private func item(_ project: Project, git: GitState?) -> PaletteItem {
        let value = ["name": project.name, "path": project.path]
        var actions: [PaletteAction] = [
            PaletteAction(id: "neovide", title: "Open in Neovide", kind: .custom, value: .object(value)),
            PaletteAction(id: "terminal", title: "Open Terminal", kind: .custom, value: .object(value)),
            PaletteAction(id: "term-here", title: "Open in Embedded Terminal", kind: .custom, value: .object(value)),
            PaletteAction(id: "workspace", title: "Open devx Workspace", kind: .custom, value: .object(value)),
            PaletteAction(id: "apply-config", title: "Apply devx Config", kind: .custom, value: .object(value)),
            PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .custom, value: .object(value)),
            PaletteAction(id: "copy-path", title: "Copy Path", kind: .copyText, value: .text(project.path)),
        ]
        if project.isWorktree {
            actions.insert(PaletteAction(id: "remove-worktree", title: "Remove Worktree…", kind: .custom, value: .object(value)), at: 3)
        } else {
            actions.insert(PaletteAction(id: "new-worktree", title: "New Worktree…", kind: .custom, value: .object(value)), at: 3)
        }
        actions.append(PaletteAction(id: "devx-config", title: "Open devx Config", kind: .custom, value: .object(value)))
        return PaletteItem(
            id: "proj:\(project.path)",
            title: project.name,
            subtitle: PathsProvider.displayPath(project.path),
            icon: .symbol(project.isWorktree ? "arrow.triangle.branch" : "folder"),
            badge: project.isWorktree ? "WORKTREE" : "PROJECT",
            score: 1_000,
            actions: actions,
            preview: git.map { .text($0.preview) } ?? .files(paths: [project.path]),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    /// Branch, last commit, worktrees and dirty count in one round trip.
    static func gitState(path: String) async -> GitState? {
        let quoted = shellQuote(path)
        let script = [
            "echo B", "git -C \(quoted) rev-parse --abbrev-ref HEAD 2>/dev/null",
            "echo C", "git -C \(quoted) log -1 --format='%h %s (%cr)' 2>/dev/null",
            "echo W", "git -C \(quoted) worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'",
            "echo N", "git -C \(quoted) status --porcelain 2>/dev/null | wc -l",
        ].joined(separator: "; ")
        guard let result = try? await ProcessRunner.run(["/bin/sh", "-c", script], timeout: 6) else {
            return nil
        }
        return parseGitState(result.stdoutString)
    }

    static func parseGitState(_ output: String) -> GitState? {
        var branch = ""
        var lastCommit = ""
        var worktrees: [String] = []
        var changes = 0
        var section = ""
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch line {
            case "B": section = "branch"; continue
            case "C": section = "commit"; continue
            case "W": section = "worktree"; continue
            case "N": section = "changes"; continue
            default: break
            }
            switch section {
            case "branch": if branch.isEmpty { branch = line }
            case "commit": if lastCommit.isEmpty { lastCommit = line }
            case "worktree":
                if !line.isEmpty { worktrees.append((line as NSString).lastPathComponent) }
            case "changes": changes = Int(line) ?? changes
            default: break
            }
        }
        guard !branch.isEmpty else { return nil }
        return GitState(
            branch: branch,
            lastCommit: lastCommit,
            worktrees: worktrees,
            changes: changes
        )
    }

    private static func projects() async -> [Project] {
        if let devx = ToolLocator.shared.path(for: "devx"),
           let result = try? await ProcessRunner.run([devx, "project", "list"], timeout: 10),
           result.status == 0 {
            let projects = result.stdoutString
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•\t")) }
                .filter { !$0.isEmpty }
                .compactMap { line -> Project? in
                    let fields = line.split(separator: "\t").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    let name = fields.first ?? line
                    let candidate = PathExpansion.expand("~/dev/\(name)")
                    let reported = fields.count > 1 && fields[1].hasPrefix("/") ? fields[1] : candidate
                    let path = FileManager.default.fileExists(atPath: reported) ? reported : candidate
                    guard FileManager.default.fileExists(atPath: path) else { return nil }
                    return Project(
                        name: name,
                        path: path,
                        isWorktree: path.contains(".worktrees")
                    )
                }
            if !projects.isEmpty { return projects }
        }

        let root = PathExpansion.expand("~/dev")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let git = url.appendingPathComponent(".git").path
            guard FileManager.default.fileExists(atPath: git) else { return nil }
            return Project(name: url.lastPathComponent, path: url.path, isWorktree: false)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
