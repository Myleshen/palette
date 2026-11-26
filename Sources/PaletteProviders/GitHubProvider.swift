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

    /// Accepts the clone forms git prints, e.g. `git@github.com:owner/repo.git`
    /// and `https://github.com/owner/repo.git`.
    public static func slug(fromRemote remote: String) -> String? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: ":", with: "/")
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return slug(from: parts.suffix(2).joined(separator: "/"))
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
    /// Workflow runs for the current repo or an explicit `owner/repo`.
    case actions
    /// The account's notification inbox.
    case notifications

    public var trigger: String {
        switch self {
        case .context: return "gh"
        case .repos: return "ghr"
        case .pulls: return "ghp"
        case .issues: return "ghi"
        case .actions: return "gha"
        case .notifications: return "ghn"
        }
    }

    public var name: String {
        switch self {
        case .context: return "GitHub"
        case .repos: return "GitHub Repositories"
        case .pulls: return "GitHub Pull Requests"
        case .issues: return "GitHub Issues"
        case .actions: return "GitHub Actions"
        case .notifications: return "GitHub Notifications"
        }
    }

    /// Strip label: the group name already says GitHub.
    public var shortName: String {
        switch self {
        case .context: return "Overview"
        case .repos: return "Repositories"
        case .pulls: return "PRs"
        case .issues: return "Issues"
        case .actions: return "Actions"
        case .notifications: return "Notifications"
        }
    }

    /// Strip order: the default overview, then the five trigger rows.
    var groupRank: Int {
        switch self {
        case .context: return 0
        case .pulls: return 1
        case .issues: return 2
        case .actions: return 3
        case .notifications: return 4
        case .repos: return 5
        }
    }

    public var icon: String {
        switch self {
        case .context: return "chevron.left.forwardslash.chevron.right"
        case .repos: return "folder"
        case .pulls: return "arrow.triangle.pull"
        case .issues: return "exclamationmark.circle"
        case .actions: return "play.rectangle"
        case .notifications: return "bell"
        }
    }

    /// Kind-specific terms, so `/gha` is findable by "workflow" and `/ghn` by
    /// "inbox" without advertising either from every other kind.
    var keywords: [String] {
        switch self {
        case .actions:
            return ["github", "actions", "workflow", "runs", "ci", trigger]
        case .notifications:
            return ["github", "notifications", "inbox", "unread", trigger]
        default:
            return ["github", "pr", "pull request", "issue", "review", trigger]
        }
    }

    /// The context provider keeps its historical id so frecency survives.
    var id: String { self == .context ? "github" : trigger }
}

/// Notification subject URLs come back as API URLs; the browser needs the web
/// one. Issues and pull requests share the `/issues/<n>` path, which GitHub
/// redirects to the pull request.
public enum GitHubNotification {
    public static func webURL(subjectType: String?, subjectURL: String?, repository: String?) -> String? {
        guard let repository, !repository.isEmpty else { return nil }
        guard let type = subjectType,
              type == "Issue" || type == "PullRequest",
              let number = trailingNumber(subjectURL) else { return nil }
        return "https://github.com/\(repository)/issues/\(number)"
    }

    /// `.../issues/42` and `.../pulls/42` both end in the number.
    public static func trailingNumber(_ url: String?) -> String? {
        guard let url else { return nil }
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let last = trimmed.split(separator: "/").last,
              !last.isEmpty,
              last.allSatisfy(\.isNumber) else { return nil }
        return String(last)
    }

    /// A failed notification call usually means the token needs the scope, not
    /// that GitHub is down. Match both gh's wording and the HTTP status.
    public static func isScopeError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("scope") || lower.contains("403") || lower.contains("forbidden")
    }
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
    private let cache = ResultCache()

    /// `gh` is spawned per keystroke otherwise. Results live for 20 s, and a
    /// cancelled search kills its child through `ProcessRunner`, so a newer
    /// query simply replaces the in-flight one.
    private actor ResultCache {
        private var entries: [String: (items: [PaletteItem], at: Date)] = [:]
        private let ttl: TimeInterval = 20

        func cached(_ key: String) -> [PaletteItem]? {
            guard let entry = entries[key], Date().timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.items
        }

        func store(_ items: [PaletteItem], key: String) {
            if entries.count > 40 { entries.removeAll() }
            entries[key] = (items, Date())
        }
    }

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
            priority: 44 - kind.groupRank,
            icon: "symbol:\(kind.icon)",
            keywords: kind.keywords,
            group: ProviderGroup(id: "github", name: "GitHub", order: 10),
            shortName: kind.shortName
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
                action: nil,
                trouble: ProviderRequirements.requirements(forProviderID: descriptor.id)
                    .first
                    .map(ItemTrouble.missingTool)
            )]
        }

        // The typed text is only a local filter, so keying on it spawned `gh`
        // for every keystroke. A full `owner/repo` changes what is fetched, so
        // it stays part of the key; partial phrases reuse the listing.
        let repo = GitHubRepoRef.slug(from: query) ?? ""
        let key = "\(kind.rawValue)|\(FileManager.default.currentDirectoryPath)|\(repo)"
        if let cached = await cache.cached(key) { return locallyFiltered(cached, query: query) }
        let items: [PaletteItem]
        switch kind {
        case .context: items = await contextItems(gh, query: query)
        case .repos: items = await repositoryItems(gh)
        case .pulls: items = await pullRequestItems(gh)
        case .issues: items = await issueItems(gh)
        case .actions: items = await actionRunItems(gh, query: query)
        case .notifications: items = await notificationItems(gh)
        }
        await cache.store(items, key: key)
        return locallyFiltered(items, query: query)
    }

    /// Filtering happens after the cache so the entry always holds the full
    /// listing. A full `owner/repo` picks the repository rather than filtering
    /// text, and setup/error rows must survive whatever is typed.
    private func locallyFiltered(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        guard !query.isEmpty else { return items }
        if kind == .context || kind == .actions, GitHubRepoRef.slug(from: query) != nil {
            return items
        }
        return items.filter { item in
            guard Self.listingPrefixes.contains(where: { item.id.hasPrefix($0) }) else { return true }
            return Ranking.score(query: query, candidate: "\(item.title) \(item.subtitle ?? "")") != nil
        }
    }

    private static let listingPrefixes = ["pr:", "issue:", "repo:", "run:", "notification:"]

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
        case "rerun":
            guard let gh = ghPath,
                  let id = action.value.object?["id"],
                  let repo = action.value.object?["repo"] else { return }
            guard await bridge.prompt(
                kind: .confirm,
                title: "Re-run failed jobs for “\(item.title)”?",
                placeholder: "Only the failed jobs run again."
            ) != nil else { return }
            await runGh(gh, ["run", "rerun", id, "--repo", repo, "--failed"], done: "Re-run started")
        case "cancel":
            guard let gh = ghPath,
                  let id = action.value.object?["id"],
                  let repo = action.value.object?["repo"] else { return }
            guard await bridge.prompt(
                kind: .confirm,
                title: "Cancel “\(item.title)”?",
                placeholder: "The running jobs are stopped."
            ) != nil else { return }
            await runGh(gh, ["run", "cancel", id, "--repo", repo], done: "Run cancelled")
        case "mark-done":
            guard let gh = ghPath, let id = action.value.text else { return }
            await runGh(gh, ["api", "-X", "DELETE", "notifications/threads/\(id)"], done: "Marked done")
        default:
            if let raw = action.value.text,
               raw.hasPrefix("url:"),
               let url = URL(string: String(raw.dropFirst(4))) {
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
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
            let attempt = await repositoryContext(gh, repo: slug, cwd: nil)
            if attempt.error == nil { return attempt.items }
            failures.append(attempt.error ?? "")
        }

        if let root = await repositoryRoot() {
            let attempt = await repositoryContext(gh, repo: nil, cwd: root)
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
        cwd: String?
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
            var actions = [openAction(url)]
            if let cwd {
                actions.append(PaletteAction(
                    id: "checkout",
                    title: "Check out locally",
                    kind: .custom,
                    value: .object(["number": "\(number)", "dir": cwd])
                ))
            }
            return PaletteItem(
                id: "pr:\(number)",
                title: title,
                subtitle: "PR #\(number) · \(draft ? "draft" : state.lowercased())",
                icon: .symbol("arrow.triangle.pull"),
                badge: draft ? "DRAFT" : state,
                group: "Pull requests",
                score: 9_000,
                actions: actions,
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

        return (items, nil)
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

    private func repositoryItems(_ gh: String) async -> [PaletteItem] {
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
            return items
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

    private func pullRequestItems(_ gh: String) async -> [PaletteItem] {
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
        return items
    }

    // MARK: - `ghi`: assigned issues

    private func issueItems(_ gh: String) async -> [PaletteItem] {
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
            return items
        }
    }

    // MARK: - `gha`: workflow runs

    private func actionRunItems(_ gh: String, query: String) async -> [PaletteItem] {
        let explicit = GitHubRepoRef.slug(from: query)
        let detected = explicit == nil ? await repositorySlug(gh) : nil
        guard let repo = explicit ?? detected else {
            return [infoRow(
                id: "gha-setup",
                title: "Pick a repository",
                subtitle: "Run /gha inside a repository, or type /gha owner/repo",
                action: nil
            )]
        }
        let args = [
            "run", "list", "--repo", repo, "--limit", "30",
            "--json", "databaseId,displayTitle,workflowName,headBranch,status,conclusion,createdAt,url",
        ]
        switch await json(gh, args) {
        case .failure(let error):
            return [infoRow(id: "gha-error", title: "Actions are not available", subtitle: error.message, action: nil)]
        case .success(let entries):
            let items: [PaletteItem] = entries.compactMap { entry in
                guard let id = entry["databaseId"] as? Int,
                      let url = entry["url"] as? String else { return nil }
                let workflow = entry["workflowName"] as? String ?? "Workflow"
                let branch = entry["headBranch"] as? String ?? ""
                let status = entry["status"] as? String ?? ""
                let conclusion = (entry["conclusion"] as? String ?? "")
                    .trimmingCharacters(in: .whitespaces)
                let title = (entry["displayTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? workflow
                var actions = [
                    openAction(url),
                    PaletteAction(
                        id: "cmd-run-panel",
                        title: "View Log",
                        kind: .custom,
                        value: .object([
                            "executable": gh,
                            "args": ["view", "\(id)", "--repo", repo, "--log"].joined(separator: "\u{1F}"),
                            "cwd": "",
                        ])
                    ),
                    PaletteAction(
                        id: "rerun",
                        title: "Re-run Failed Jobs",
                        kind: .custom,
                        value: .object(["id": "\(id)", "repo": repo])
                    ),
                ]
                if status != "completed" {
                    actions.append(PaletteAction(
                        id: "cancel",
                        title: "Cancel Run",
                        kind: .custom,
                        value: .object(["id": "\(id)", "repo": repo])
                    ))
                }
                let outcome = conclusion.isEmpty ? status : conclusion
                return PaletteItem(
                    id: "run:\(repo)#\(id)",
                    title: title,
                    subtitle: "\(workflow) · \(branch)",
                    icon: .symbol("play.rectangle"),
                    badge: outcome.isEmpty ? nil : outcome.uppercased(),
                    group: workflow,
                    score: 9_000,
                    actions: actions,
                    preview: .text("\(title)\n\n\(workflow) · \(branch)\n\(outcome.capitalized)\n\(url)"),
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )
            }
            return items
        }
    }

    /// `gh repo view` knows the current checkout; the origin remote covers a
    /// tree that is not a full clone.
    private func repositorySlug(_ gh: String) async -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        if let result = try? await ProcessRunner.run(
            [gh, "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            cwd: cwd,
            timeout: 5
        ), result.status == 0 {
            let slug = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if GitHubRepoRef.slug(from: slug) != nil { return slug }
        }
        guard let root = await repositoryRoot(),
              let remote = try? await ProcessRunner.run(
                ["git", "-C", root, "remote", "get-url", "origin"],
                timeout: 3
              ), remote.status == 0 else { return nil }
        return GitHubRepoRef.slug(fromRemote: remote.stdoutString)
    }

    private func runGh(_ gh: String, _ args: [String], done: String) async {
        guard let result = try? await ProcessRunner.run([gh] + args, timeout: 30) else {
            await bridge.notify("gh could not run")
            return
        }
        if result.status == 0 {
            await bridge.notify(done)
            return
        }
        let line = result.stderrString
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        await bridge.notify(line ?? "gh exited with status \(result.status)")
    }

    // MARK: - `ghn`: notifications

    private func notificationItems(_ gh: String) async -> [PaletteItem] {
        switch await jsonPages(gh, ["api", "notifications", "--paginate", "--slurp"]) {
        case .failure(let error):
            if GitHubNotification.isScopeError(error.message) {
                return [scopeItem(gh)]
            }
            // Never surface gh's JSON blob as a row subtitle.
            return [infoRow(
                id: "ghn-error",
                title: "Notifications are unavailable",
                subtitle: "gh could not read your notifications",
                action: nil
            )]
        case .success(let entries):
            guard !entries.isEmpty else {
                return [PaletteItem(
                    id: "ghn-empty",
                    title: "No notifications",
                    subtitle: "Your GitHub inbox is clear",
                    icon: .symbol("bell"),
                    badge: "EMPTY",
                    group: kind.name,
                    score: 1_000,
                    actions: [openAction("https://github.com/notifications")],
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )]
            }
            let items: [PaletteItem] = entries.compactMap { entry in
                guard let subject = entry["subject"] as? [String: Any] else { return nil }
                let title = subject["title"] as? String ?? "(untitled)"
                let reason = entry["reason"] as? String ?? "notification"
                let repository = entry["repository"] as? [String: Any]
                let repo = repository?["full_name"] as? String
                    ?? repository?["nameWithOwner"] as? String
                    ?? ""
                let unread = entry["unread"] as? Bool ?? false
                let threadID = (entry["id"] as? String) ?? (entry["id"] as? Int).map(String.init)
                let web = GitHubNotification.webURL(
                    subjectType: subject["type"] as? String,
                    subjectURL: subject["url"] as? String,
                    repository: repo.isEmpty ? nil : repo
                ) ?? (repository?["html_url"] as? String)
                    ?? (repo.isEmpty ? "https://github.com/notifications" : "https://github.com/\(repo)")
                var actions = [openAction(web)]
                if let threadID {
                    actions.append(PaletteAction(
                        id: "mark-done",
                        title: "Mark Done",
                        kind: .custom,
                        value: .text(threadID)
                    ))
                }
                return PaletteItem(
                    id: "notification:\(threadID ?? web)",
                    title: title,
                    subtitle: repo.isEmpty ? reason : "\(repo) · \(reason)",
                    icon: .symbol(unread ? "bell.badge" : "bell"),
                    badge: unread ? "UNREAD" : nil,
                    group: repo.isEmpty ? kind.name : repo,
                    score: 9_000,
                    actions: actions,
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )
            }
            return items
        }
    }

    /// A token without the `notifications` scope can be widened once, in the
    /// embedded terminal, without leaving the launcher.
    private func scopeItem(_ gh: String) -> PaletteItem {
        PaletteItem(
            id: "ghn-scope",
            title: "Notifications need the notifications scope",
            subtitle: "Authorise gh once to read your GitHub inbox",
            icon: .symbol("bell.slash"),
            badge: "SCOPE",
            group: kind.name,
            score: 10_000,
            actions: [PaletteAction(
                id: "cmd-run-panel",
                title: "Run gh auth refresh",
                kind: .custom,
                value: .object([
                    "executable": gh,
                    "args": ["auth", "refresh", "-s", "notifications"].joined(separator: "\u{1F}"),
                    "cwd": "",
                ])
            )],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
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

    /// `gh api --paginate --slurp` wraps every page in one array, so a response
    /// arrives as `[[object]]`; a single object list is accepted too.
    static func flattenPages(_ parsed: Any) -> [[String: Any]]? {
        if let entries = parsed as? [[String: Any]] { return entries }
        if let pages = parsed as? [[[String: Any]]] { return pages.flatMap { $0 } }
        return nil
    }

    private func jsonPages(_ gh: String, _ args: [String]) async -> Result<[[String: Any]], ErrorLine> {
        guard let result = try? await ProcessRunner.run([gh] + args, timeout: 20) else {
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
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let entries = Self.flattenPages(parsed) else {
            return .failure(ErrorLine(message: "Unexpected gh output"))
        }
        return .success(entries)
    }

    private func infoRow(
        id: String,
        title: String,
        subtitle: String,
        action: String?,
        trouble: ItemTrouble? = nil
    ) -> PaletteItem {
        PaletteItem(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: .symbol(kind.icon),
            badge: "SETUP",
            group: kind.name,
            score: 1_000,
            actions: action.map { [PaletteAction(id: "auth", title: "Run gh auth login", kind: .custom, value: .text($0))] } ?? [],
            trouble: trouble,
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}
