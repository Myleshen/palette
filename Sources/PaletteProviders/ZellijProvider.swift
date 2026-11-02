import Foundation
import PaletteCore
import PalettePlatform

public final class ZellijProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "zj",
        name: "Zellij Sessions",
        trigger: "zj",
        isGlobal: true,
        priority: 20,
        icon: "symbol:terminal"
    )

    private let launcher: LauncherService
    private let bridge: HostBridge
    private let terminal: String

    public init(terminal: String, launcher: LauncherService, bridge: HostBridge) {
        self.terminal = terminal
        self.launcher = launcher
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        guard ToolLocator.shared.path(for: "zellij") != nil else {
            return [PaletteItem(
                id: "install",
                title: "Install zellij",
                subtitle: "Run brew install zellij",
                icon: .symbol("exclamationmark.triangle"),
                score: 10_000,
                actions: [PaletteAction(id: "install", title: "Open Terminal", kind: .custom, value: .text("install"))],
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }
        guard ToolLocator.shared.path(for: terminal) != nil || ToolLocator.shared.appPath(named: terminal) != nil else {
            return [PaletteItem(
                id: "install-terminal",
                title: "Install \(terminal)",
                subtitle: "The terminal is required to open zellij sessions",
                icon: .symbol("exclamationmark.triangle"),
                score: 10_000,
                actions: [PaletteAction(id: "install", title: "Open Terminal", kind: .custom, value: .text("install"))],
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }

        let sessions = await listSessions()
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Global results are for finding a running session. Creation belongs to
        // /zj; otherwise an empty palette or a lone "/" offers to create one.
        if !request.isBound {
            guard !query.isEmpty else { return [] }
            return sessions.compactMap { session in
                guard Ranking.score(query: query, candidate: session.name) != nil else { return nil }
                return sessionItem(session, query: query)
            }
        }

        let hasWork = sessions.contains { $0.name.caseInsensitiveCompare("Work") == .orderedSame }
        var fixed: [PaletteItem] = [
            PaletteItem(
                id: "new",
                title: "New Zellij session",
                subtitle: "Start a fresh session in \(terminal)",
                icon: .symbol("plus.rectangle"),
                score: 600,
                actions: [
                    PaletteAction(
                        id: "create",
                        title: "New Session",
                        kind: .custom,
                        value: .text("create:session-\(Int(Date().timeIntervalSince1970))")
                    ),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            ),
        ]
        if !hasWork {
            fixed.append(PaletteItem(
                id: "work",
                title: "Work",
                subtitle: "Attach or create the work session",
                icon: .symbol("briefcase"),
                score: 500,
                actions: [
                    PaletteAction(id: "create", title: "Open Work", kind: .custom, value: .text("create:Work")),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            ))
        }
        if !query.isEmpty {
            fixed = fixed.filter { Ranking.score(query: query, candidate: $0.title) != nil }
        }

        var items: [PaletteItem] = fixed
        items.append(contentsOf: sessions.compactMap { session in
            if !query.isEmpty, Ranking.score(query: query, candidate: session.name) == nil { return nil }
            return sessionItem(session, query: query)
        })

        let validName = query.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil
        if validName, !sessions.contains(where: { $0.name == query }) {
            items.insert(PaletteItem(
                id: "create:\(query)",
                title: "Create session “\(query)”",
                subtitle: "Start a new zellij session in \(terminal)",
                icon: .symbol("plus.rectangle"),
                score: 2_000,
                actions: [
                    PaletteAction(id: "create", title: "Create Session", kind: .custom, value: .text("create:\(query)")),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            ), at: 0)
        }
        return items
    }

    private func sessionItem(_ session: Session, query: String) -> PaletteItem {
        let score = query.isEmpty ? (session.current ? 100 : 0) : (Ranking.score(query: query, candidate: session.name) ?? 0)
        return PaletteItem(
            id: "session:\(session.name)",
            title: session.name,
            subtitle: session.current ? "Current session · attach in \(terminal)" : "Attach in \(terminal)",
            icon: .symbol("rectangle.split.3x1"),
            badge: session.current ? "current" : nil,
            score: score,
            actions: [
                PaletteAction(id: "attach", title: "Attach", kind: .custom, value: .text("attach:\(session.name)")),
            ],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let value = action.value.text else { return }
        if value == "install" {
            try await MainActor.run {
                try launcher.openTerminal(command: "brew install zellij", app: terminal)
            }
            return
        }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let mode = parts[0]
        let name = parts[1]
        let create = mode == "create"

        guard let zellij = ToolLocator.shared.path(for: "zellij") else {
            await bridge.notify("zellij is not installed")
            return
        }
        guard let executable = ToolLocator.shared.path(for: terminal) ?? ToolLocator.shared.appPath(named: terminal).map({ $0 + "/Contents/MacOS/" + terminal }) else {
            await bridge.notify("\(terminal) is not installed")
            return
        }

        var arguments = [executable, "--detach", zellij, "attach"]
        if create { arguments.append("--create") }
        arguments.append(name)
        do {
            try ProcessRunner.launch(arguments, cwd: NSHomeDirectory())
        } catch {
            await bridge.notify("Could not open zellij: \(error.localizedDescription)")
        }
    }

    private struct Session {
        var name: String
        var current: Bool
    }

    private func listSessions() async -> [Session] {
        do {
            let result = try await ProcessRunner.run(
                ["zellij", "list-sessions", "--no-formatting"],
                timeout: 5
            )
            guard result.status == 0 else { return [] }
            return result.stdoutString.split(separator: "\n").compactMap { line in
                let text = String(line)
                guard !text.isEmpty, !text.hasPrefix("No active zellij sessions") else { return nil }
                let current = text.contains("(current)")
                var name = text
                if let range = text.range(of: " [Created") {
                    name = String(text[..<range.lowerBound])
                } else if let range = text.range(of: " (current)") {
                    name = String(text[..<range.lowerBound])
                }
                name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return Session(name: name, current: current)
            }
        } catch {
            return []
        }
    }
}
