import Foundation
import PaletteCore
import PalettePlatform

/// The `[[roots]]` blocks of devx's config, read without a TOML dependency.
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
        var roots: [Root] = []
        var current: Root?
        let finish: () -> Void = {
            if let current, !current.name.isEmpty, !current.path.isEmpty { roots.append(current) }
        }
        for line in toml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[[roots]]") {
                finish()
                current = Root(name: "", path: "")
            } else if trimmed.hasPrefix("[") {
                finish()
                current = nil
            } else if current != nil, let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if key == "name" { current?.name = value }
                if key == "path" { current?.path = value }
            }
        }
        finish()
        return roots
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

    public init(launcher: LauncherService, bridge: HostBridge, terminal: String = "kitty") {
        self.launcher = launcher
        self.bridge = bridge
        self.terminal = terminal
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let cached = await cache.projects
        let at = await cache.at
        let projects: [Project]
        if Date().timeIntervalSince(at) < 10, !cached.isEmpty {
            projects = cached
        } else {
            projects = await Self.projects()
            await cache.update(projects)
        }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows: [PaletteItem] = projects.compactMap { project in
            if !query.isEmpty,
               Ranking.score(query: query, candidate: "\(project.name) \(project.path)") == nil {
                return nil
            }
            return item(project)
        }
        guard query.isEmpty else { return rows }
        return actionItems() + rows
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if action.id == "clone-repo" {
            try await cloneRepository()
            return
        }
        if action.id == "new-project" {
            try await newProject()
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
        case "remove-worktree":
            guard let devx else {
                await bridge.notify("Install devx to remove worktrees")
                return
            }
            guard await bridge.prompt(kind: .confirm, title: "Remove worktree \(name)?", placeholder: nil) != nil else { return }
            try await MainActor.run {
                try launcher.openTerminal(command: "\(Self.shellQuote(devx)) worktree remove \(Self.shellQuote(name))", app: terminal)
            }
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

        await cache.invalidate()
        await bridge.notify("Created \(name) in \(path)")
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

    private func item(_ project: Project) -> PaletteItem {
        let value = ["name": project.name, "path": project.path]
        var actions: [PaletteAction] = [
            PaletteAction(id: "neovide", title: "Open in Neovide", kind: .custom, value: .object(value)),
            PaletteAction(id: "terminal", title: "Open Terminal", kind: .custom, value: .object(value)),
            PaletteAction(id: "term-here", title: "Open in Embedded Terminal", kind: .custom, value: .object(value)),
            PaletteAction(id: "workspace", title: "Open devx Workspace", kind: .custom, value: .object(value)),
            PaletteAction(id: "apply-config", title: "Apply devx Config", kind: .custom, value: .object(value)),
            PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .custom, value: .object(value)),
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
            subtitle: project.path,
            icon: .symbol(project.isWorktree ? "arrow.triangle.branch" : "folder"),
            badge: project.isWorktree ? "WORKTREE" : "PROJECT",
            score: 1_000,
            actions: actions,
            preview: .files(paths: [project.path]),
            providerID: descriptor.id,
            providerName: descriptor.name
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
