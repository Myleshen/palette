import AppKit
import Foundation
import PaletteCore
import PalettePlatform

/// Pull requests and issues for the current repository, via the `gh` CLI.
public final class GitHubProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "github",
        name: "GitHub",
        trigger: "gh",
        isGlobal: false,
        priority: 44,
        icon: "symbol:chevron.left.forwardslash.chevron.right",
        keywords: ["github", "pr", "pull request", "issue", "review", "gh"]
    )

    private let launcher: LauncherService
    private let terminalApp: String

    public init(launcher: LauncherService, terminalApp: String) {
        self.launcher = launcher
        self.terminalApp = terminalApp
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

        let cwd = FileManager.default.currentDirectoryPath
        guard let pullRequests = await json(gh, ["pr", "list", "--state", "all", "--limit", "20", "--json", "number,title,state,isDraft,url"], cwd: cwd) else {
            return [infoRow(
                id: "gh-error",
                title: "GitHub is not available here",
                subtitle: "Run gh auth login, or open Palette inside a repository",
                action: "auth"
            )]
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
                    PaletteAction(id: "open", title: "Open in browser", kind: .custom, value: .text("url:\(url)")),
                    PaletteAction(id: "checkout", title: "Check out locally", kind: .custom, value: .text("checkout:\(number)")),
                ],
                preview: .text("\(title)\n\nPR #\(number) · \(state)\n\(url)"),
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }

        if let issues = await json(gh, ["issue", "list", "--state", "all", "--limit", "20", "--json", "number,title,state,url"], cwd: cwd) {
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
                    actions: [PaletteAction(id: "open", title: "Open in browser", kind: .custom, value: .text("url:\(url)"))],
                    providerID: descriptor.id,
                    providerName: descriptor.name
                )
            }
        }

        guard !query.isEmpty else { return items }
        return items.filter { "\($0.title) \($0.subtitle ?? "")".lowercased().contains(query.lowercased()) }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        if raw == "auth" {
            let app = terminalApp
            try await MainActor.run { try launcher.openTerminal(command: "gh auth login", app: app) }
        } else if raw.hasPrefix("url:"), let url = URL(string: String(raw.dropFirst(4))) {
            await MainActor.run { NSWorkspace.shared.open(url) }
        } else if raw.hasPrefix("checkout:"), let gh = ghPath {
            let number = String(raw.dropFirst("checkout:".count))
            let app = terminalApp
            try await MainActor.run { try launcher.openTerminal(command: "\(gh) pr checkout \(number)", app: app) }
        }
    }

    private func json(_ gh: String, _ args: [String], cwd: String) async -> [[String: Any]]? {
        guard let result = try? await ProcessRunner.run([gh] + args, timeout: 12),
              result.status == 0,
              let data = result.stdoutString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return parsed
    }

    private func infoRow(id: String, title: String, subtitle: String, action: String?) -> PaletteItem {
        PaletteItem(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: .symbol("chevron.left.forwardslash.chevron.right"),
            group: "GitHub",
            score: 1_000,
            actions: action.map { [PaletteAction(id: "auth", title: "Run gh auth login", kind: .custom, value: .text($0))] } ?? [],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}
