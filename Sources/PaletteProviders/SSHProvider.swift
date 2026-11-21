import Foundation
import PaletteCore
import PalettePlatform

/// Hosts from `~/.ssh/config`, opened in the configured terminal.
public final class SSHProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "ssh",
        name: "SSH",
        trigger: "ssh",
        isGlobal: false,
        priority: 48,
        icon: "symbol:lock.shield",
        keywords: ["ssh", "host", "server", "remote", "shell", "config"]
    )

    private let launcher: LauncherService
    private let terminalApp: String

    public init(launcher: LauncherService, terminalApp: String) {
        self.launcher = launcher
        self.terminalApp = terminalApp
    }

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let hosts = SSHConfig.parse(text)

        guard !hosts.isEmpty else {
            return [PaletteItem(
                id: "ssh-none",
                title: "No SSH hosts found",
                subtitle: "Add a Host block to ~/.ssh/config",
                icon: .symbol("network.slash"),
                group: "SSH",
                score: 1_000,
                actions: [PaletteAction(id: "open-config", title: "Open ~/.ssh/config", kind: .custom, value: .text("open-config"))],
                providerID: descriptor.id,
                providerName: descriptor.name
            )]
        }

        let items = hosts.map { host in
            PaletteItem(
                id: "ssh:\(host.alias)",
                title: host.alias,
                subtitle: host.subtitle,
                icon: .symbol("terminal"),
                group: "Hosts",
                score: 9_000,
                actions: [
                    PaletteAction(
                        id: "connect-panel",
                        title: "Connect in Panel",
                        kind: .custom,
                        value: .object([
                            "executable": "ssh",
                            "args": host.alias,
                            "cwd": "",
                            "session": "ssh-" + Self.sessionName(for: host.alias),
                        ])
                    ),
                    PaletteAction(id: "connect", title: "Open in \(terminalApp)", kind: .custom, value: .text("ssh:\(host.alias)")),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
        guard !query.isEmpty else { return items }
        return items.filter { "\($0.title) \($0.subtitle ?? "")".lowercased().contains(query.lowercased()) }
    }

    /// zellij and tmux reject `:` and other punctuation in session names.
    static func sessionName(for alias: String) -> String {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        let cleaned = String(alias.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "host" : cleaned
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        if raw == "open-config" {
            let path = configURL.path
            await MainActor.run { launcher.openPath(path) }
        } else if raw.hasPrefix("ssh:") {
            let alias = String(raw.dropFirst("ssh:".count))
            let app = terminalApp
            try await MainActor.run { try launcher.openTerminal(command: "ssh \(alias)", app: app) }
        }
    }
}
