import Foundation
import PaletteCore
import PalettePlatform

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
        return projects.compactMap { project in
            if !query.isEmpty,
               Ranking.score(query: query, candidate: "\(project.name) \(project.path)") == nil {
                return nil
            }
            return item(project)
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
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

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
