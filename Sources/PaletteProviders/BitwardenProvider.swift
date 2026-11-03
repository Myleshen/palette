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
    private var email: String?
    private var listCache: (date: Date, data: Data)?
    private var itemCache: [String: (date: Date, data: Data)] = [:]
    private var listTask: Task<ListResult, Never>?
    private var generation = 0
    private let persistCache: Bool
    private let cacheScope: String

    private static let cacheTTL = SecureVaultCache.ttl
    private static let maxItemCache = 128

    public init(
        persistCache: Bool = true,
        cacheScope: String = SecureVaultCache.scope()
    ) {
        self.persistCache = persistCache
        self.cacheScope = cacheScope
        if persistCache, let snapshot = SecureVaultCache.load(scope: cacheScope) {
            listCache = (snapshot.date, snapshot.data)
            email = snapshot.email
        }
    }

    public func currentSession() -> String? { session }

    public func accountEmail() -> String? { email }

    /// Full logout: drop the session and every cached copy.
    public func clear() {
        session = nil
        lastStatusDate = nil
        listCache = nil
        itemCache.removeAll()
        listTask = nil
        generation += 1
        if persistCache { SecureVaultCache.remove(scope: cacheScope) }
    }

    /// The CLI session went stale, but the encrypted vault snapshot is still
    /// useful once the user unlocks again.
    public func sessionExpired() {
        session = nil
        lastStatusDate = nil
        itemCache.removeAll()
        listTask = nil
        generation += 1
    }

    /// Force the next search to read the vault again, keeping the session.
    public func refresh() {
        listCache = nil
        itemCache.removeAll()
        listTask = nil
        generation += 1
        if persistCache { SecureVaultCache.remove(scope: cacheScope) }
        Log.shared.info("Bitwarden cache refreshed", source: "bitwarden")
    }

    public struct ListResult: Sendable {
        public var data: Data?
        public var status: Int32
        public var stderr: String
        public var timedOut: Bool
        public var fromCache: Bool
    }

    /// One `bw list items` call is reused for every prefix and keystroke.
    /// Switching `/bw` → `/bwn` → `/bwu` should not spawn the CLI again.
    public func list(bw: String, session: String) async -> ListResult {
        if let listCache, Date().timeIntervalSince(listCache.date) < Self.cacheTTL {
            return ListResult(
                data: listCache.data, status: 0, stderr: "",
                timedOut: false, fromCache: true
            )
        }
        // Coalesce simultaneous searches for the same vault instead of spawning
        // two `bw list` processes.
        if let listTask {
            return await listTask.value
        }
        let startedAt = Date()
        let activeGeneration = generation
        let task = Task<ListResult, Never> {
            do {
                let result = try await ProcessRunner.run(
                    [bw, "list", "items"],
                    environment: ["BW_SESSION": session],
                    timeout: 60
                )
                guard result.status == 0, !result.stdout.isEmpty else {
                    return ListResult(
                        data: nil, status: result.status,
                        stderr: result.stderrString, timedOut: result.timedOut,
                        fromCache: false
                    )
                }
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                Log.shared.info("Bitwarden list fetched in \(ms) ms", source: "bitwarden")
                return ListResult(
                    data: result.stdout, status: 0, stderr: "",
                    timedOut: false, fromCache: false
                )
            } catch {
                return ListResult(
                    data: nil, status: -1, stderr: error.localizedDescription,
                    timedOut: false, fromCache: false
                )
            }
        }
        listTask = task
        let result = await task.value
        listTask = nil
        if let data = result.data, generation == activeGeneration {
            listCache = (Date(), data)
            itemCache.removeAll()
            if persistCache { SecureVaultCache.save(data: data, email: email, scope: cacheScope) }
        }
        return result
    }

    /// Reuse the JSON from the cached list for copy/open actions instead of a
    /// second `bw get item` process.
    public func entryData(id: String) -> Data? {
        if let cached = itemCache[id], Date().timeIntervalSince(cached.date) < Self.cacheTTL {
            return cached.data
        }
        guard let listCache, Date().timeIntervalSince(listCache.date) < Self.cacheTTL,
              let entries = try? JSONSerialization.jsonObject(with: listCache.data) as? [[String: Any]],
              let entry = entries.first(where: { $0["id"] as? String == id }),
              let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
        itemCache[id] = (Date(), data)
        if itemCache.count > Self.maxItemCache {
            itemCache.removeAll()
        }
        return data
    }

    public func cacheEntry(id: String, data: Data) {
        itemCache[id] = (Date(), data)
    }

    public func status(bw: String) async -> String {
        if let lastStatus, let lastStatusDate, Date().timeIntervalSince(lastStatusDate) < 30 {
            return lastStatus
        }
        guard let result = try? await ProcessRunner.run([bw, "status"], timeout: 10),
              result.status == 0,
              let data = result.stdoutString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            return "unknown"
        }
        if let email = object["userEmail"] as? String, !email.isEmpty {
            self.email = email
        }
        lastStatus = status
        lastStatusDate = Date()
        return status
    }

    public func login(bw: String, bridge: HostBridge, environment: [String: String]) async {
        var email = environment["BW_EMAIL"]
        if email == nil || email?.isEmpty == true {
            email = await bridge.prompt(
                kind: .text,
                title: "Bitwarden email",
                placeholder: "you@example.com"
            )
        }
        guard let account = email, !account.isEmpty else { return }
        self.email = account

        var password = environment["BW_PASSWORD"]
        if password == nil || password?.isEmpty == true {
            password = await bridge.prompt(
                kind: .secureText,
                title: "Bitwarden password for \(account)",
                placeholder: "Master password"
            )
        }
        guard let password, !password.isEmpty else { return }

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                [bw, "login", account, "--passwordenv", "BW_PASSWORD", "--raw"],
                environment: ["BW_PASSWORD": password, "BW_SESSION": ""],
                timeout: 60
            )
        } catch {
            await bridge.notify("Login failed: \(error.localizedDescription)")
            return
        }
        guard result.status == 0 else {
            await bridge.notify("Login failed: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        let key = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            await bridge.notify("Login returned no session key")
            return
        }
        session = key
        lastStatus = "unlocked"
        lastStatusDate = Date()
        // Login may be a different account, so do not reuse another vault's
        // cached payload.
        listCache = nil
        itemCache.removeAll()
        if persistCache { SecureVaultCache.remove(scope: cacheScope) }
        await bridge.notify("Bitwarden unlocked")
    }

    public func unlock(bw: String, bridge: HostBridge, environment: [String: String]) async {
        let account = email ?? "your account"
        var password = environment["BW_PASSWORD"]
        if password == nil || password?.isEmpty == true {
            password = await bridge.prompt(
                kind: .secureText,
                title: "Unlock Bitwarden \(account)",
                placeholder: "Master password for \(account)"
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
        // Reuse a fresh six-hour snapshot so unlocking feels instant; use the
        // menu-bar refresh when the vault has changed on another device.
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
            let status = await vault.status(bw: bw)
            let email = await vault.accountEmail()
            switch status {
            case "unauthenticated":
                return [loginRow(email: email)]
            case "locked":
                return [unlockRow(message: "The vault is locked", email: email)]
            default:
                break
            }
            return [unlockRow(message: "Unlock to search your vault", email: email)]
        }

        guard let session else { return [] }

        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = await vault.list(bw: bw, session: session)
        if let data = list.data {
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                Log.shared.warn("Bitwarden returned an unreadable item list", source: "bitwarden")
                return [errorRow(message: "Could not read the vault response.")]
            }
            let matched = query.isEmpty ? raw : raw.filter { Self.matches($0, query: query) }
            let items: [PaletteItem] = matched.compactMap { entry in
                Self.makeItem(entry, kind: kind, descriptor: descriptor)
            }
            return Array(items.prefix(max(1, request.limit)))
        }

        let stderr = list.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.shared.warn(
            "Bitwarden list failed (status \(list.status), timedOut=\(list.timedOut)): \(stderr.prefix(300))",
            source: "bitwarden"
        )
        if list.timedOut {
            // A slow vault is not a locked vault. Keep the session so the
            // next query can retry without asking for the password again.
            return [errorRow(message: "Bitwarden did not answer in time. Press \u{23CE} to retry.")]
        }
        if Self.looksLikeSessionFailure(stderr) {
            await vault.sessionExpired()
            return [unlockRow(message: "Session expired — unlock again", email: await vault.accountEmail())]
        }
        // Network or server errors must not throw the session away.
        let detail = stderr.isEmpty ? "bw list items failed" : String(stderr.prefix(200))
        return [errorRow(message: detail)]
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if let command = action.value.text, ["install", "login", "unlock", "retry"].contains(command) {
            try await runRowCommand(command)
            return
        }
        guard let bw = ToolLocator.shared.path(for: "bw"),
              let session = await vault.currentSession() else {
            await bridge.notify("Unlock Bitwarden first")
            return
        }
        guard let command = action.value.text else { return }

        // TOTP is time-based, so it always comes from the CLI.
        if command == "copy-totp" {
            let totp = try await ProcessRunner.run(
                [bw, "get", "totp", item.id],
                environment: ["BW_SESSION": session],
                timeout: 15
            )
            guard totp.status == 0 else {
                await bridge.notify("Could not read the TOTP code")
                return
            }
            let value = totp.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                await bridge.notify("That item has no TOTP code")
                return
            }
            await copy(value)
            return
        }

        // Everything else is already in the cached `bw list items` payload.
        let entry: [String: Any]
        if let cached = await vault.entryData(id: item.id),
           let object = try? JSONSerialization.jsonObject(with: cached) as? [String: Any] {
            entry = object
        } else {
            let result = try await ProcessRunner.run(
                [bw, "get", "item", item.id],
                environment: ["BW_SESSION": session],
                timeout: 15
            )
            guard result.status == 0,
                  let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
                let stderr = result.stderrString
                Log.shared.warn("Bitwarden get item failed: \(stderr.prefix(300))", source: "bitwarden")
                if Self.looksLikeSessionFailure(stderr) {
                    await vault.sessionExpired()
                    await bridge.notify("Session expired — unlock Bitwarden again")
                } else {
                    await bridge.notify("Could not read the item: \(stderr.prefix(120))")
                }
                return
            }
            await vault.cacheEntry(id: item.id, data: result.stdout)
            entry = object
        }

        if command == "open-url" {
            if let url = Self.firstURL(from: entry) {
                await MainActor.run { launcher.openURL(url) }
            }
            return
        }

        let value: String?
        if command == "copy-notes" {
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
        await copy(value)
    }

    private func copy(_ value: String) async {
        // Every vault value is concealed: Palette's monitor ignores concealed
        // pasteboard writes, so nothing copied from the vault enters history.
        await bridge.copyToClipboard(value, concealed: true, clearAfterMs: 30_000)
        await bridge.notify("Copied securely; clipboard clears in 30 seconds")
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
            await vault.login(bw: bw, bridge: bridge, environment: environment)
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

    private func loginRow(email: String?) -> PaletteItem {
        PaletteItem(
            id: "login",
            title: "Log in to Bitwarden",
            subtitle: "\(email ?? "No account") · sign in without leaving Palette",
            icon: .symbol("person.badge.key"),
            score: 10_000,
            actions: [PaletteAction(id: "login", title: "Log In", kind: .custom, value: .text("login"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func unlockRow(message: String, email: String?) -> PaletteItem {
        PaletteItem(
            id: "unlock",
            title: email.map { "Unlock Bitwarden — \($0)" } ?? "Unlock Bitwarden",
            subtitle: "\(message) · master password is never stored",
            icon: .symbol("lock.open"),
            score: 10_000,
            actions: [PaletteAction(id: "unlock", title: "Unlock Vault", kind: .custom, value: .text("unlock"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func errorRow(message: String) -> PaletteItem {
        PaletteItem(
            id: "error",
            title: "Bitwarden error",
            subtitle: message,
            icon: .symbol("exclamationmark.triangle"),
            score: 10_000,
            actions: [PaletteAction(id: "retry", title: "Retry", kind: .custom, value: .text("retry"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    /// Only clear the cached session when the CLI actually says it is stale.
    static func looksLikeSessionFailure(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("session")
            || text.contains("not logged in")
            || text.contains("unauthorized")
            || text.contains("401")
            || text.contains("vault is locked")
    }

    // MARK: - Item mapping

    static func matches(_ entry: [String: Any], query: String) -> Bool {
        let name = entry["name"] as? String ?? ""
        let notes = entry["notes"] as? String ?? ""
        let login = entry["login"] as? [String: Any]
        let username = login?["username"] as? String ?? ""
        let uris = (login?["uris"] as? [[String: Any]])?.compactMap { $0["uri"] as? String }.joined(separator: " ") ?? ""
        let haystack = "\(name) \(username) \(uris) \(notes)".lowercased()
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.contains($0.lowercased())
        }
    }

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

    private static func firstURL(from entry: [String: Any]) -> String? {
        let login = entry["login"] as? [String: Any]
        let uris = login?["uris"] as? [[String: Any]]
        return uris?.compactMap { $0["uri"] as? String }.first
    }

    private static func firstURL(from stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = entry["login"] as? [String: Any],
              let uris = login["uris"] as? [[String: Any]] else { return nil }
        return uris.compactMap { $0["uri"] as? String }.first
    }
}
