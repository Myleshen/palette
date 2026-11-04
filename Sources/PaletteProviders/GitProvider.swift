import Foundation
import PaletteCore
import PalettePlatform

/// Narrow, safe Git actions. Anything complicated stays in LazyGit.
public final class GitProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "git",
        name: "Git Repositories",
        trigger: "git",
        isGlobal: false,
        priority: 58,
        icon: "symbol:arrow.triangle.branch"
    )

    private struct Repo {
        var path: String
        var name: String
        var branch: String
        var changes: Int
    }

    private struct Output {
        var path: String
        var title: String
        var text: String
    }

    private actor Cache {
        var repos: [Repo] = []
        var at = Date.distantPast
        var output: Output?

        func update(_ repos: [Repo]) {
            self.repos = repos
            at = Date()
        }

        func setOutput(_ output: Output?) {
            self.output = output
        }
    }

    private let launcher: LauncherService
    private let bridge: HostBridge
    private let cache = Cache()

    public init(launcher: LauncherService, bridge: HostBridge) {
        self.launcher = launcher
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let cached = await cache.repos
        let at = await cache.at
        let repos: [Repo]
        if Date().timeIntervalSince(at) < 15, !cached.isEmpty {
            repos = cached
        } else {
            repos = await Self.repositories()
            await cache.update(repos)
        }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [PaletteItem] = []
        if let output = await cache.output,
           query.isEmpty || Ranking.score(query: query, candidate: "\(output.path) \(output.title)") != nil {
            items.append(outputItem(output))
        }
        items.append(contentsOf: repos.compactMap { repo in
            if !query.isEmpty,
               Ranking.score(query: query, candidate: "\(repo.name) \(repo.branch) \(repo.path)") == nil {
                return nil
            }
            return item(repo)
        })
        return items
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if action.id == "clear-output" {
            await cache.setOutput(nil)
            await bridge.notify("Git output cleared")
            return
        }
        guard let value = action.value.object, let path = value["path"] else { return }
        let repo = (path as NSString).lastPathComponent
        switch action.id {
        case "status":
            await run(["status", "--short", "--branch"], path: path, title: "Status · \(repo)", timeout: 20)
        case "log":
            await run(["log", "--oneline", "-30"], path: path, title: "Recent Log · \(repo)", timeout: 20)
        case "stage":
            await run(["add", "-A"], path: path, title: "Stage All · \(repo)", timeout: 20)
        case "commit":
            guard let message = await bridge.prompt(
                kind: .text,
                title: "Commit message for \(repo)",
                placeholder: "Describe the change"
            ), !message.isEmpty else { return }
            await run(["commit", "-m", message], path: path, title: "Commit · \(repo)", timeout: 60)
        case "pull":
            await run(["pull", "--ff-only"], path: path, title: "Pull · \(repo)", timeout: 120)
        case "push":
            await run(["push"], path: path, title: "Push · \(repo)", timeout: 120)
        case "lazygit":
            try await MainActor.run {
                try launcher.openTerminal(command: "cd \(Self.shellQuote(path)) && lazygit", app: "kitty")
            }
        case "reveal":
            await MainActor.run { launcher.reveal(path) }
        default:
            break
        }
    }

    private func run(_ arguments: [String], path: String, title: String, timeout: TimeInterval) async {
        let command = (["git", "-C", path] + arguments).joined(separator: " ")
        do {
            let result = try await ProcessRunner.run(["git", "-C", path] + arguments, timeout: timeout)
            let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = "$ \(command)\n\nexit \(result.status)"
            if !stdout.isEmpty { text += "\n\n\(stdout)" }
            if !stderr.isEmpty { text += "\n\n\(stderr)" }
            await cache.setOutput(Output(path: path, title: title, text: text))
            await bridge.notify(result.status == 0 ? "\(title): done" : "\(title): exit \(result.status)")
        } catch {
            await cache.setOutput(Output(
                path: path,
                title: title,
                text: "$ \(command)\n\n\(error.localizedDescription)"
            ))
            await bridge.notify("\(title): \(error.localizedDescription)")
        }
    }

    private func outputItem(_ output: Output) -> PaletteItem {
        PaletteItem(
            id: "git-output:\(output.path)",
            title: output.title,
            subtitle: output.path,
            icon: .symbol("terminal"),
            badge: "OUTPUT",
            score: 10_000,
            actions: [
                PaletteAction(id: "copy-output", title: "Copy Output", kind: .copyText, value: .text(output.text)),
                PaletteAction(id: "clear-output", title: "Dismiss Output", kind: .custom, value: .text(output.path)),
            ],
            preview: .text(output.text),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func item(_ repo: Repo) -> PaletteItem {
        let value: [String: String] = ["path": repo.path]
        let actions: [PaletteAction] = [
            PaletteAction(id: "status", title: "Show Status", kind: .custom, value: .object(value)),
            PaletteAction(id: "stage", title: "Stage All Changes", kind: .custom, value: .object(value)),
            PaletteAction(id: "commit", title: "Commit…", kind: .custom, value: .object(value)),
            PaletteAction(id: "pull", title: "Pull (Fast-Forward Only)", kind: .custom, value: .object(value)),
            PaletteAction(id: "push", title: "Push", kind: .custom, value: .object(value)),
            PaletteAction(id: "log", title: "Recent Log", kind: .custom, value: .object(value)),
            PaletteAction(id: "lazygit", title: "Open in LazyGit", kind: .custom, value: .object(value)),
            PaletteAction(id: "copy-branch", title: "Copy Branch", kind: .copyText, value: .text(repo.branch)),
            PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .custom, value: .object(value)),
        ]
        return PaletteItem(
            id: "git:\(repo.path)",
            title: repo.name,
            subtitle: "\(repo.branch) · \(repo.changes == 0 ? "clean" : "\(repo.changes) change\(repo.changes == 1 ? "" : "s")") · \(repo.path)",
            icon: .symbol("arrow.triangle.branch"),
            badge: repo.changes == 0 ? "GIT" : "DIRTY",
            score: 1_000,
            actions: actions,
            preview: .files(paths: [repo.path]),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private static func repositories() async -> [Repo] {
        let home = NSHomeDirectory()
        let roots = ["\(home)/dev", "\(home)/dot-files"]
        var paths: [String] = []
        let manager = FileManager.default
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: nil
            ) else { continue }
            var depth = 0
            while let url = enumerator.nextObject() as? URL {
                depth = enumerator.level
                guard depth <= 3 else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                if manager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    paths.append(url.path)
                    enumerator.skipDescendants()
                }
            }
        }
        let unique = Array(Set(paths)).sorted().prefix(60)
        return await withTaskGroup(of: Repo?.self) { group in
            for path in unique {
                group.addTask { await inspect(path: path) }
            }
            var repos: [Repo] = []
            for await repo in group {
                if let repo { repos.append(repo) }
            }
            return repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private static func inspect(path: String) async -> Repo? {
        guard let result = try? await ProcessRunner.run(
            ["git", "-C", path, "status", "--porcelain=v1", "--branch"],
            timeout: 5
        ), result.status == 0 else { return nil }
        let lines = result.stdoutString.split(separator: "\n", omittingEmptySubsequences: false)
        var branch = "detached"
        if let first = lines.first {
            let head = String(first).replacingOccurrences(of: "## ", with: "")
            branch = head.components(separatedBy: "...").first ?? "detached"
        }
        let changes = lines.dropFirst().filter { !$0.isEmpty }.count
        return Repo(path: path, name: (path as NSString).lastPathComponent, branch: branch, changes: changes)
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
