import AppKit
import Foundation
import PaletteCore
import PalettePlatform

/// An `owner/repo` query, used to look at a repository that is not the cwd.
public enum GitHubRepoRef {
    public static func slug(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(
            of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$",
            options: .regularExpression
        ) != nil else { return nil }
        return value
    }

    public static func name(from slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }

    public static func cloneURL(for slug: String) -> String {
        "https://github.com/\(slug).git"
    }
}

/// The GitHub family, one provider per trigger so `/ghr` never pays for a
/// `/ghp` lookup.
public enum GitHubKind: String, Sendable, CaseIterable {
    /// Current repo, explicit `owner/repo`, or the account's open PRs.
    case context
    case repos
    case pulls
    case issues

    public var trigger: String {
        switch self {
        case .context: return "gh"
        case .repos: return "ghr"
        case .pulls: return "ghp"
        case .issues: return "ghi"
        }
    }

    public var name: String {
        switch self {
        case .context: return "GitHub"
        case .repos: return "GitHub Repositories"
        case .pulls: return "GitHub Pull Requests"
        case .issues: return "GitHub Issues"
        }
    }

    public var icon: String {
        switch self {
        case .context: return "chevron.left.forwardslash.chevron.right"
        case .repos: return "folder"
        case .pulls: return "arrow.triangle.pull"
        case .issues: return "exclamationmark.circle"
        }
    }

    /// The context provider keeps its historical id so frecency survives.
    var id: String { self == .context ? "github" : trigger }
}

/// Pull requests and issues via the `gh` CLI, split by what the user is
/// looking for: the current repository, their repos, their PRs, or their
/// assigned issues.
public final class GitHubProvider: PaletteProvider, @unchecked Sendable {
    private let kind: GitHubKind
    public let descriptor: ProviderDescriptor

    private struct ErrorLine: Error {
        var message: String
    }

    private let launcher: LauncherService
    private let bridge: HostBridge
    private let terminalApp: String
    private let terminal: String

    public init(
        kind: GitHubKind = .context,
        launcher: LauncherService,
        bridge: HostBridge,
        terminalApp: String = "kitty",
        terminal: String = "kitty"
    ) {
        self.kind = kind
        self.launcher = launcher
        self.bridge = bridge
        self.terminalApp = terminalApp
        self.terminal = terminal
        self.descriptor = ProviderDescriptor(
            id: kind.id,
            name: kind.name,
            trigger: kind.trigger,
            isGlobal: false,
            priority: kind == .context ? 44 : 43,
            icon: "symbol:\(kind.icon)",
            keywords: ["github", "pr", "pull request", "issue", "review", kind.trigger]
        )
    }

    private var ghPath: String? { ToolLocator.shared.path(for: "gh") }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gh = ghPath else {
            return [infoRow(
                id: "gh-missing",
                title: "GitHub CLI not installed",
                subtitle: "Install with brew install gh, then reload",
                action: nil
            )]
        }

        switch kind {
        case .context: return await contextItems(gh, query: query)
        case .repos: return await repositoryItems(gh, query: query)
        case .pulls: return await pullRequestItems(gh, query: query)
        case .issues: return await issueItems(gh, query: query)
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.id {
        case "auth":
            try await openTerminal("gh auth login", app: terminalApp)
        case "clone":
            guard let slug = action.value.object?["slug"] else { return }
            try await clone(slug)
        case "copy-slug":
            guard let slug = action.value.object?["slug"] else { return }
            await bridge.copyToClipboard(slug, concealed: false, clearAfterMs: nil)
        case "checkout":
            guard let gh = ghPath,
                  let number = action.value.object?["number"] else { return }
            let dir = action.value.object?["dir"]
            let cd = dir.map { "cd \(ProjectProvider.shellQuote($0)) && " } ?? ""
            try await openTerminal("\(cd)\(ProjectProvider.shellQuote(gh)) pr checkout \(number)", app: terminal)
        default:
            if let raw = action.value.text,
               raw.hasPrefix("url:"),
               let url = URL(string: String(raw.dropFirst(4))) {
                await MainActor.run { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func openTerminal(_ command: String, app: String) async throws {
        try await MainActor.run { try launcher.openTerminal(command: command, app: app) }
    }

    // MARK: - `gh`: the current repository, a slug, or the account

    private func contextItems(_ gh: String, query: String) async -> [PaletteItem] {
        var failures: [String] = []

        if let slug = GitHubRepoRef.slug(from: query) {
            let attempt = await repositoryContext(gh, repo: slug, cwd: nil, query: "")
            if attempt.error == nil { return attempt.items }
            failures.append(attempt.error ?? "")
        }

        if let root = await repositoryRoot() {
            let attempt = await repositoryContext(gh, repo: nil, cwd: root, query: query)
            if attempt.error == nil { return attempt.items }
            failures.append(attempt.error ?? "")
        }

        let account = await accountItems(gh)
        if account.error == nil { return account.items }
        failures.append(account.error ?? "")

        let fallback = failures.first { !$0.isEmpty } ?? "gh could not list pull requests"
        return [infoRow(
            id: "gh-error",
            title: "GitHub is not available here",
            subtitle: await unavailableSubtitle(gh, fallback: fallback),
            action: "auth"
        )]
    }

    /// Pulls and issues for one repository, from the cwd's toplevel or `--repo`.
    /// A non-nil error means the PR listing itself failed; issues are best-effort.
    private func repositoryContext(
        _ gh: String,
        repo: String?,
        cwd: String?,
        query: String
    ) async -> (items: [PaletteItem], error: String?) {
        var prArgs = ["pr", "list"]
        var issueArgs = ["issue", "list"]
        if let repo {
            prArgs += ["--repo", repo]
            issueArgs += ["--repo", repo]
        }
        prArgs += ["--state", "all", "--limit", "20", "--json", "number,title,state,isDraft,url"]
        issueArgs += ["--state", "all", "--limit", "20", "--json", "number,title,state,url"]

        let pullRequests: [[String: Any]]
        switch await json(gh, prArgs, cwd: cwd) {
        case .success(let entries): pullRequests = entries
        case .failure(let error): return ([], error.message)
        }

        var items: [PaletteItem] = pullRequests.compactMap { entry in
            guard let number = entry["number"] as? Int,
                  let title = entry["title"] as? String,
                  let url = entry["url"] as? String else { return nil }
            let state = entry["state"] as? String ?? "OPEN"
            let draft = entry["isDraft"] as? Bool ?? false
            return PaletteItem(
                id: "pr:\(number)",
                title: title,
                subtitle: "PR #\(number) · \(draft ? "draft" : state.lowercased())",
                icon: .symbol("arrow.triangle.pull"),
                badge: draft ? "DRAFT" : state,
                group: "Pull requests",
                score: 9_000,
                actions: [
                    openAction(url),
                    PaletteAction(id: "checkout", title: "Check out locally", kind: .custom, value: .object(["number": "\(number)"])),
                ],
                preview: .text("\(title)\n\nPR #\(number) · \(state)\n\(url)"),
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }

        if case .success(let issues) = await json(gh, issueArgs, cwd: cwd) {
            items += issues.compactMap { entry in
                guard let number = entry["number"] as? Int,
                      let title = entry["title"] as? String,
                      let url = entry["url"] as? String else { return nil }
                return PaletteItem(
                    id: "issue:\(number)",
                    title: title,
                    subtitle: "Issue #\(number)",
                    icon: .symbol("exclamationmark.circle"),
                    group: "Issues",
                    score: 8_000,
                    actions: [openAction(url)],
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )
            }
        }

        guard !query.isEmpty else { return (items, nil) }
        return (items.filter { "\($0.title) \($0.subtitle ?? "")".lowercased().contains(query.lowercased()) }, nil)
    }

    /// The account's open PRs, which works with no repository and no cwd.
    private func accountItems(_ gh: String) async -> (items: [PaletteItem], error: String?) {
        let args = [
            "search", "prs", "--author=@me", "--state=open", "--limit", "20",
            "--json", "number,title,state,url,repository",
        ]
        switch await json(gh, args) {
        case .failure(let error):
            return ([], error.message)
        case .success(let entries):
            return (entries.compactMap { entry in
                guard let number = entry["number"] as? Int,
                      let title = entry["title"] as? String,
                      let url = entry["url"] as? String,
                      let repository = entry["repository"] as? [String: Any],
                      let name = repository["nameWithOwner"] as? String else { return nil }
                let state = entry["state"] as? String ?? "OPEN"
                return PaletteItem(
                    id: "pr:\(name)#\(number)",
                    title: title,
                    subtitle: "PR #\(number) · \(name)",
                    icon: .symbol("arrow.triangle.pull"),
                    badge: state,
                    group: name,
                    score: 9_000,
                    actions: [openAction(url)],
                    preview: .text("\(title)\n\nPR #\(number) · \(state)\n\(url)"),
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )
            }, nil)
        }
    }

    /// A Finder launch starts with cwd `/`, so ask git where this checkout is.
    private func repositoryRoot() async -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        guard let result = try? await ProcessRunner.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            timeout: 3
        ), result.status == 0 else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func unavailableSubtitle(_ gh: String, fallback: String) async -> String {
        if let status = try? await ProcessRunner.run([gh, "auth", "status"], timeout: 8),
           status.status != 0 {
            return "Run gh auth login"
        }
        return fallback
    }

    // MARK: - `ghr`: repositories

    private func repositoryItems(_ gh: String, query: String) async -> [PaletteItem] {
        let args = [
            "repo", "list", "--limit", "50",
            "--json", "nameWithOwner,description,isPrivate,updatedAt,url",
        ]
        switch await json(gh, args) {
        case .failure(let error):
            return [errorRow(error.message)]
        case .success(let entries):
            let cloneTitle = self.cloneTitle
            let items: [PaletteItem] = entries.compactMap { entry in
                guard let slug = entry["nameWithOwner"] as? String,
                      let url = entry["url"] as? String else { return nil }
                let description = (entry["description"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return PaletteItem(
                    id: "repo:\(slug)",
                    title: GitHubRepoRef.name(from: slug),
                    subtitle: Self.truncated(description),
                    icon: .symbol("folder"),
                    badge: entry["isPrivate"] as? Bool == true ? "PRIVATE" : nil,
                    group: "Repositories",
                    score: 1_000,
                    actions: [
                        openAction(url),
                        PaletteAction(id: "clone", title: cloneTitle, kind: .custom, value: .object(["slug": slug])),
                        PaletteAction(id: "copy-slug", title: "Copy slug", kind: .custom, value: .object(["slug": slug])),
                    ],
                    preview: .text("\(slug)\n\n\(description.isEmpty ? "No description" : description)\n\(url)"),
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )
            }
            return Self.filtered(items, query: query)
        }
    }

    /// "Clone into ~/dev" for the first configured devx root.
    private var cloneTitle: String {
        guard let root = ProjectProvider.devxRoots().first else { return "Clone into a devx root" }
        let home = NSHomeDirectory()
        let path = PathExpansion.expand(root.path)
        let display = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return "Clone into \(display)"
    }

    private func clone(_ slug: String) async throws {
        guard let devx = ToolLocator.shared.path(for: "devx") else {
            await bridge.notify("Install devx to clone repositories")
            return
        }
        guard let root = ProjectProvider.devxRoots().first else {
            await bridge.notify("No devx scan roots configured; run devx project add-root")
            return
        }
        try await openTerminal(
            "\(ProjectProvider.shellQuote(devx)) project clone \(ProjectProvider.shellQuote(root.name)) \(ProjectProvider.shellQuote(GitHubRepoRef.cloneURL(for: slug)))",
            app: terminal
        )
        await bridge.notify("Cloning \(slug) into \(root.name)")
    }

    // MARK: - `ghp`: pull requests

    private func pullRequestItems(_ gh: String, query: String) async -> [PaletteItem] {
        let groups: [(String, [String])] = [
            ("Authored", [
                "search", "prs", "--author=@me", "--state=open", "--limit", "30",
                "--json", "number,title,state,url,repository",
            ]),
            ("Review requested", [
                "search", "prs", "--review-requested=@me", "--state=open", "--limit", "30",
                "--json", "number,title,state,url,repository",
            ]),
        ]

        var items: [PaletteItem] = []
        var seen = Set<String>()
        var failures: [String] = []
        var anySuccess = false

        for (group, args) in groups {
            switch await json(gh, args) {
            case .failure(let error):
                failures.append(error.message)
            case .success(let entries):
                anySuccess = true
                for entry in entries {
                    guard let number = entry["number"] as? Int,
                          let title = entry["title"] as? String,
                          let url = entry["url"] as? String,
                          let repository = entry["repository"] as? [String: Any],
                          let slug = repository["nameWithOwner"] as? String,
                          seen.insert(url).inserted else { continue }
                    let state = entry["state"] as? String ?? "OPEN"
                    var actions = [openAction(url)]
                    // Only offer a checkout when the clone is already on disk.
                    if let dir = Self.localClone(for: slug) {
                        actions.append(PaletteAction(
                            id: "checkout",
                            title: "Check out locally",
                            kind: .custom,
                            value: .object(["number": "\(number)", "dir": dir])
                        ))
                    }
                    items.append(PaletteItem(
                        id: "pr:\(slug)#\(number)",
                        title: title,
                        subtitle: "#\(number) · \(slug)",
                        icon: .symbol("arrow.triangle.pull"),
                        badge: state,
                        group: group,
                        score: 9_000,
                        actions: actions,
                        preview: .text("\(title)\n\n#\(number) · \(state)\n\(url)"),
                        providerID: descriptor.id,
                        providerName: descriptor.name
                    ))
                }
            }
        }

        if !anySuccess, let failure = failures.first { return [errorRow(failure)] }
        return Self.filtered(items, query: query)
    }

    // MARK: - `ghi`: assigned issues

    private func issueItems(_ gh: String, query: String) async -> [PaletteItem] {
        let args = [
            "search", "issues", "--assignee=@me", "--state=open", "--limit", "30",
            "--json", "number,title,state,url,repository",
        ]
        switch await json(gh, args) {
        case .failure(let error):
            return [errorRow(error.message)]
        case .success(let entries):
            let items: [PaletteItem] = entries.compactMap { entry in
                guard let number = entry["number"] as? Int,
                      let title = entry["title"] as? String,
                      let url = entry["url"] as? String,
                      let repository = entry["repository"] as? [String: Any],
                      let slug = repository["nameWithOwner"] as? String else { return nil }
                return PaletteItem(
                    id: "issue:\(slug)#\(number)",
                    title: title,
                    subtitle: "#\(number) · \(slug)",
                    icon: .symbol("exclamationmark.circle"),
                    group: slug,
                    score: 8_000,
                    actions: [openAction(url)],
                    preview: .text("\(title)\n\n#\(number) · \(slug)\n\(url)"),
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )
            }
            return Self.filtered(items, query: query)
        }
    }

    // MARK: - Shared

    /// The first `<devx root>/<repo name>` that is an actual git clone.
    private static func localClone(for slug: String) -> String? {
        let name = GitHubRepoRef.name(from: slug)
        for root in ProjectProvider.devxRoots() {
            let path = PathExpansion.expand(root.path) + "/" + name
            if FileManager.default.fileExists(atPath: path + "/.git") { return path }
        }
        return nil
    }

    private static func filtered(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        guard !query.isEmpty else { return items }
        return items.filter {
            Ranking.score(query: query, candidate: "\($0.title) \($0.subtitle ?? "")") != nil
        }
    }

    private static func truncated(_ text: String, limit: Int = 100) -> String? {
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private func openAction(_ url: String) -> PaletteAction {
        PaletteAction(id: "open", title: "Open in browser", kind: .custom, value: .text("url:\(url)"))
    }

    private func errorRow(_ message: String) -> PaletteItem {
        infoRow(id: "gh-error", title: "GitHub is not available here", subtitle: message, action: "auth")
    }

    private func json(
        _ gh: String,
        _ args: [String],
        cwd: String? = nil
    ) async -> Result<[[String: Any]], ErrorLine> {
        guard let result = try? await ProcessRunner.run([gh] + args, cwd: cwd, timeout: 12) else {
            return .failure(ErrorLine(message: "gh could not run"))
        }
        guard result.status == 0 else {
            let line = result.stderrString
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return .failure(ErrorLine(message: line ?? "gh exited with status \(result.status)"))
        }
        guard let data = result.stdoutString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure(ErrorLine(message: "Unexpected gh output"))
        }
        return .success(parsed)
    }

    private func infoRow(id: String, title: String, subtitle: String, action: String?) -> PaletteItem {
        PaletteItem(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: .symbol(kind.icon),
            group: kind.name,
            score: 1_000,
            actions: action.map { [PaletteAction(id: "auth", title: "Run gh auth login", kind: .custom, value: .text($0))] } ?? [],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}
