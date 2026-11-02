import Foundation
import PaletteCore
import PalettePlatform

/// Shared, in-memory Bitwarden session for the five vault providers. The
/// session key never touches disk and the master password is only handed to the
/// child process through its environment.
public actor BitwardenVault {
    private var session: String?
    private var lastStatus: String?
    private var lastStatusDate: Date?

    public init() {}

    public func currentSession() -> String? { session }

    public func clear() {
        session = nil
        lastStatusDate = nil
    }

    public func status(bw: String) async -> String {
        if let lastStatus, let lastStatusDate, Date().timeIntervalSince(lastStatusDate) < 5 {
            return lastStatus
        }
        guard let result = try? await ProcessRunner.run([bw, "status"], timeout: 10),
              result.status == 0,
              let data = result.stdoutString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            return "unknown"
        }
        lastStatus = status
        lastStatusDate = Date()
        return status
    }

    public func unlock(bw: String, bridge: HostBridge, environment: [String: String]) async {
        var password = environment["BW_PASSWORD"]
        if password == nil || password?.isEmpty == true {
            password = await bridge.prompt(
                kind: .secureText,
                title: "Unlock Bitwarden",
                placeholder: "Master password"
            )
        }
        guard let password, !password.isEmpty else { return }

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                [bw, "unlock", "--passwordenv", "BW_PASSWORD", "--raw"],
                environment: ["BW_PASSWORD": password, "BW_SESSION": ""],
                timeout: 60
            )
        } catch {
            await bridge.notify("Unlock failed: \(error.localizedDescription)")
            return
        }
        guard result.status == 0 else {
            await bridge.notify("Unlock failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        let key = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            await bridge.notify("Unlock returned no session key")
            return
        }
        session = key
        lastStatus = "unlocked"
        lastStatusDate = Date()
        await bridge.notify("Bitwarden unlocked")
    }
}

public enum BitwardenKind: String, Sendable, CaseIterable {
    case passwords
    case usernames
    case totp
    case notes
    case urls

    public var trigger: String {
        switch self {
        case .passwords: return "bw"
        case .usernames: return "bwu"
        case .totp: return "bwt"
        case .notes: return "bwn"
        case .urls: return "bwo"
        }
    }

    public var name: String {
        switch self {
        case .passwords: return "Bitwarden Passwords"
        case .usernames: return "Bitwarden Usernames"
        case .totp: return "Bitwarden TOTP"
        case .notes: return "Bitwarden Notes"
        case .urls: return "Bitwarden URLs"
        }
    }

    public var icon: String {
        switch self {
        case .passwords: return "key.fill"
        case .usernames: return "person.fill"
        case .totp: return "clock.badge.checkmark"
        case .notes: return "note.text"
        case .urls: return "globe"
        }
    }

    public var actionTitle: String {
        switch self {
        case .passwords: return "Copy Password"
        case .usernames: return "Copy Username"
        case .totp: return "Copy TOTP"
        case .notes: return "Copy Note"
        case .urls: return "Open Website"
        }
    }

    public var command: String {
        switch self {
        case .passwords: return "copy-password"
        case .usernames: return "copy-username"
        case .totp: return "copy-totp"
        case .notes: return "copy-notes"
        case .urls: return "open-url"
        }
    }
}

public actor BitwardenProvider: PaletteProvider {
    private let kind: BitwardenKind
    private let vault: BitwardenVault
    private let bridge: HostBridge
    private let launcher: LauncherService
    private let terminalApp: String
    private let environment: [String: String]

    public nonisolated let descriptor: ProviderDescriptor

    public init(
        kind: BitwardenKind,
        vault: BitwardenVault,
        bridge: HostBridge,
        launcher: LauncherService,
        terminalApp: String = "kitty",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.kind = kind
        self.vault = vault
        self.bridge = bridge
        self.launcher = launcher
        self.terminalApp = terminalApp
        self.environment = environment
        self.descriptor = ProviderDescriptor(
            id: kind.trigger,
            name: kind.name,
            trigger: kind.trigger,
            isGlobal: false,
            priority: kind == .passwords ? 34 : 30,
            icon: "symbol:\(kind.icon)"
        )
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        guard let bw = ToolLocator.shared.path(for: "bw") else {
            return [installRow()]
        }

        let session = await vault.currentSession()
        if session == nil {
            switch await vault.status(bw: bw) {
            case "unauthenticated":
                return [loginRow()]
            case "locked":
                return [unlockRow(message: "The vault is locked")]
            default:
                break
            }
            return [unlockRow(message: "Unlock to search your vault")]
        }

        guard let session else { return [] }

        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [bw, "list", "items"]
        if !query.isEmpty { arguments.append(contentsOf: ["--search", query]) }

        let result = try await ProcessRunner.run(arguments, environment: ["BW_SESSION": session], timeout: 20)
        guard result.status == 0 else {
            // A stale session is the most common failure; ask for unlock again.
            await vault.clear()
            return [unlockRow(message: "Session expired — unlock again")]
        }
        guard let data = result.stdoutString.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let items: [PaletteItem] = raw.compactMap { entry in
            guard let item = Self.makeItem(entry, kind: kind, descriptor: descriptor) else { return nil }
            return item
        }
        return Array(items.prefix(max(1, request.limit)))
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if let command = action.value.text, ["install", "login", "unlock"].contains(command) {
            try await runRowCommand(command)
            return
        }
        guard let bw = ToolLocator.shared.path(for: "bw"),
              let session = await vault.currentSession() else {
            await bridge.notify("Unlock Bitwarden first")
            return
        }
        guard let command = action.value.text else { return }

        if command == "open-url" {
            let result = try await ProcessRunner.run(
                [bw, "get", "item", item.id],
                environment: ["BW_SESSION": session],
                timeout: 15
            )
            if let url = Self.firstURL(from: result.stdoutString) {
                await MainActor.run { launcher.openURL(url) }
            }
            return
        }

        let entryResult = try await ProcessRunner.run(
            [bw, "get", "item", item.id],
            environment: ["BW_SESSION": session],
            timeout: 15
        )
        guard entryResult.status == 0,
              let data = entryResult.stdoutString.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            await vault.clear()
            await bridge.notify("Could not read the item; session may have expired")
            return
        }

        let value: String?
        if command == "copy-totp" {
            let totp = try await ProcessRunner.run(
                [bw, "get", "totp", item.id],
                environment: ["BW_SESSION": session],
                timeout: 15
            )
            value = totp.status == 0
                ? totp.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        } else if command == "copy-notes" {
            value = entry["notes"] as? String
        } else if let login = entry["login"] as? [String: Any] {
            value = login[command == "copy-username" ? "username" : "password"] as? String
        } else {
            value = nil
        }

        guard let value, !value.isEmpty else {
            await bridge.notify("That item has no \(kind.rawValue.dropLast())")
            return
        }
        let concealed = command != "copy-username"
        await bridge.copyToClipboard(value, concealed: concealed, clearAfterMs: concealed ? 30_000 : nil)
        await bridge.notify(concealed ? "Copied; clipboard clears in 30 seconds" : "Copied username")
    }

    // MARK: - Vault rows

    private func runRowCommand(_ command: String) async throws {
        guard let bw = ToolLocator.shared.path(for: "bw") else { return }
        switch command {
        case "install":
            try await MainActor.run {
                try launcher.openTerminal(command: "brew install bitwarden-cli", app: terminalApp)
            }
        case "login":
            try await MainActor.run {
                try launcher.openTerminal(command: "bw login", app: terminalApp)
            }
        case "unlock":
            await vault.unlock(bw: bw, bridge: bridge, environment: environment)
        default:
            break
        }
    }

    private func installRow() -> PaletteItem {
        PaletteItem(
            id: "install",
            title: "Install Bitwarden CLI",
            subtitle: "Run brew install bitwarden-cli, then /\(kind.trigger) again",
            icon: .symbol("exclamationmark.triangle"),
            score: 10_000,
            actions: [PaletteAction(id: "install", title: "Open Terminal", kind: .custom, value: .text("install"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func loginRow() -> PaletteItem {
        PaletteItem(
            id: "login",
            title: "Log in to Bitwarden",
            subtitle: "Vaultwarden · opens bw login in \(terminalApp)",
            icon: .symbol("person.badge.key"),
            score: 10_000,
            actions: [PaletteAction(id: "login", title: "Open bw login", kind: .custom, value: .text("login"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func unlockRow(message: String) -> PaletteItem {
        PaletteItem(
            id: "unlock",
            title: "Unlock Bitwarden",
            subtitle: "\(message) · master password is never stored",
            icon: .symbol("lock.open"),
            score: 10_000,
            actions: [PaletteAction(id: "unlock", title: "Unlock Vault", kind: .custom, value: .text("unlock"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    // MARK: - Item mapping

    private static func makeItem(
        _ entry: [String: Any],
        kind: BitwardenKind,
        descriptor: ProviderDescriptor
    ) -> PaletteItem? {
        guard let id = entry["id"] as? String,
              let name = entry["name"] as? String else { return nil }
        let login = entry["login"] as? [String: Any]
        let username = login?["username"] as? String ?? ""
        let uris = login?["uris"] as? [[String: Any]]
        let url = uris?.compactMap { $0["uri"] as? String }.first
        let notes = entry["notes"] as? String ?? ""

        switch kind {
        case .usernames where username.isEmpty: return nil
        case .notes where notes.isEmpty: return nil
        case .urls where (url ?? "").isEmpty: return nil
        case .passwords where (login?["password"] as? String ?? "").isEmpty: return nil
        case .totp where login == nil: return nil
        default: break
        }

        var actions: [PaletteAction] = [
            PaletteAction(id: "primary", title: kind.actionTitle, kind: .custom, value: .text(kind.command)),
        ]
        if kind != .urls, let url, !url.isEmpty {
            actions.append(PaletteAction(id: "open-url", title: "Open Website", kind: .custom, value: .text("open-url")))
        }

        let subtitleParts: [String]
        if kind == .notes {
            subtitleParts = [username, notes.split(separator: "\n").first.map(String.init) ?? ""]
        } else {
            subtitleParts = [username, url ?? ""]
        }

        return PaletteItem(
            id: id,
            title: name,
            subtitle: subtitleParts.filter { !$0.isEmpty }.joined(separator: " · "),
            icon: .symbol(kind.icon),
            badge: kind.rawValue.capitalized,
            actions: actions,
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private static func firstURL(from stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = entry["login"] as? [String: Any],
              let uris = login["uris"] as? [[String: Any]] else { return nil }
        return uris.compactMap { $0["uri"] as? String }.first
    }
}
