import Foundation
import PaletteCore
import PalettePlatform

public enum WebAppURL {
    /// Accepts `example.com`, `https://example.com`, and full URLs with paths.
    /// Rejects free text so a provider name is not mistaken for a domain.
    public static func normalize(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if !value.contains("://") { value = "https://\(value)" }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else { return nil }
        let isLocal = host == "localhost"
            || host == "::1"
            || host.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", options: .regularExpression) != nil
        guard isLocal || host.contains(".") else { return nil }
        if !isLocal {
            guard let suffix = host.split(separator: ".").last,
                  suffix.count >= 2,
                  suffix.allSatisfy(\.isLetter) else { return nil }
        }
        return url
    }

    public static func defaultName(for url: URL) -> String {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        guard let first = host.split(separator: ".").first, !first.isEmpty else { return host }
        let words = first.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// User-managed web app shortcuts. Add rows are created from a URL-like query;
/// names are asked for once, and every open feeds the normal frecency store.
public actor WebAppProvider: PaletteProvider {
    private static let descriptorValue = ProviderDescriptor(
        id: "web",
        name: "Web Apps",
        trigger: "web",
        isGlobal: true,
        priority: 45,
        icon: "symbol:globe"
    )

    public nonisolated var descriptor: ProviderDescriptor { Self.descriptorValue }

    private let store: PaletteStore
    private let bridge: HostBridge
    private let browser: String
    private let favicons: Bool
    private let onChange: @Sendable () async -> Void

    public init(
        store: PaletteStore,
        bridge: HostBridge,
        browser: String = "Helium",
        favicons: Bool = true,
        onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.bridge = bridge
        self.browser = browser
        self.favicons = favicons
        self.onChange = onChange
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let addQuery = Self.addQuery(from: trimmed)
        let searchText = addQuery == nil ? trimmed : ""
        let apps = try await store.webApps()

        var items: [PaletteItem] = []
        for app in apps {
            let score = searchText.isEmpty
                ? 0
                : max(
                    Ranking.score(query: searchText, candidate: app.name) ?? -1,
                    Ranking.score(query: searchText, candidate: app.url) ?? -1
                )
            guard searchText.isEmpty || score >= 0 else { continue }

            let actions: [PaletteAction] = [
                PaletteAction(id: "open", title: "Open Web App", kind: .openURL, value: .object(["url": app.url, "browser": browser, "mode": "app"])),
                PaletteAction(id: "copy-url", title: "Copy URL", kind: .copyText, value: .text(app.url)),
                PaletteAction(id: "shortcut", title: app.shortcut == nil ? "Set Shortcut…" : "Change Shortcut…", kind: .custom, value: .text(app.id)),
                PaletteAction(id: "clear-shortcut", title: "Clear Shortcut", kind: .custom, value: .text(app.id)),
                PaletteAction(id: "remove", title: "Remove Web App", kind: .custom, value: .text(app.id)),
            ].filter { $0.id != "clear-shortcut" || app.shortcut != nil }

            let subtitle = app.shortcut.map { "\(app.url) · \($0)" } ?? app.url
            items.append(PaletteItem(
                id: app.id,
                title: app.name,
                subtitle: subtitle,
                icon: .symbol("globe"),
                badge: "web",
                score: score,
                actions: actions,
                providerID: Self.descriptorValue.id,
                providerName: Self.descriptorValue.name
            ))
        }

        if !searchText.isEmpty {
            let boosts = try await store.frecencyBoosts(for: items.map(\.stableID))
            for index in items.indices {
                items[index].score += boosts[items[index].stableID] ?? 0
            }
        }

        let urls = items.map { $0.subtitle?.components(separatedBy: " · ").first ?? "" }
        // Rows are returned with the globe immediately. Cached icons are
        // applied now and new ones are fetched in the background, so the next
        // search fills them in without this one waiting on the network.
        for (index, url) in urls.enumerated() {
            if let base64 = await FaviconStore.shared.cachedIcon(for: url) {
                items[index].icon = .base64(base64)
            }
        }
        if favicons {
            for url in urls where !url.isEmpty {
                guard await FaviconStore.shared.needsFetch(for: url) else { continue }
                Task.detached(priority: .utility) {
                    _ = await FaviconStore.shared.icon(for: url)
                }
            }
        }

        items.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        if let addQuery {
            let name = WebAppURL.defaultName(for: addQuery)
            items.insert(PaletteItem(
                id: "add-\(addQuery.absoluteString)",
                title: "Add Web App “\(name)”",
                subtitle: addQuery.absoluteString,
                icon: .symbol("plus.circle"),
                badge: "new",
                score: 10_000,
                actions: [PaletteAction(id: "add", title: "Add Web App", kind: .custom, value: .text(addQuery.absoluteString))],
                providerID: Self.descriptorValue.id,
                providerName: Self.descriptorValue.name
            ), at: 0)
        } else if request.isBound, trimmed.isEmpty {
            items.insert(PaletteItem(
                id: "add-new",
                title: "Add Web App…",
                subtitle: "Enter a domain, or type /web example.com",
                icon: .symbol("plus.circle"),
                badge: "new",
                score: 9_000,
                actions: [PaletteAction(id: "add", title: "Add Web App", kind: .custom, value: .text(""))],
                providerID: Self.descriptorValue.id,
                providerName: Self.descriptorValue.name
            ), at: 0)
        }

        return Array(items.prefix(max(1, request.limit)))
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.id {
        case "add":
            var raw = action.value.text ?? ""
            if raw.isEmpty {
                guard let entered = await bridge.prompt(
                    kind: .text,
                    title: "Add Web App",
                    placeholder: "example.com"
                ) else { return }
                raw = entered
            }
            guard let url = WebAppURL.normalize(raw) else {
                await bridge.notify("That does not look like a web address")
                return
            }
            let fallback = WebAppURL.defaultName(for: url)
            guard let entered = await bridge.prompt(
                kind: .text,
                title: "Name this web app",
                placeholder: fallback
            ) else { return }
            let name = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortcut = await requestShortcut(for: nil)
            let app = try await store.addWebApp(
                name: name.isEmpty ? fallback : name,
                url: url.absoluteString,
                shortcut: shortcut
            )
            await onChange()
            if let shortcut {
                await bridge.notify("Added \(app.name) · \(shortcut)")
            } else {
                await bridge.notify("Added \(app.name)")
            }

        case "shortcut":
            guard let id = action.value.text,
                  let app = try await store.webApps().first(where: { $0.id == id }) else { return }
            guard let entered = await bridge.prompt(
                kind: .text,
                title: "Shortcut for \(app.name)",
                placeholder: app.shortcut ?? "ctrl+alt+\(app.name.prefix(1).lowercased())"
            ) else { return }

            let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try await store.updateWebAppShortcut(id: id, shortcut: nil)
                await onChange()
                await bridge.notify("Cleared the shortcut for \(app.name)")
                return
            }
            guard let shortcut = WebAppShortcut.parse(trimmed) else {
                await bridge.notify("Use at least two modifiers, e.g. ctrl+alt+f")
                return
            }
            if try await shortcutIsTaken(shortcut.canonical, excluding: id) {
                await bridge.notify("That shortcut is already used by another web app")
                return
            }
            try await store.updateWebAppShortcut(id: id, shortcut: shortcut.canonical)
            await onChange()
            await bridge.notify("Shortcut \(shortcut.canonical) → \(app.name)")

        case "clear-shortcut":
            guard let id = action.value.text else { return }
            try await store.updateWebAppShortcut(id: id, shortcut: nil)
            await onChange()
            await bridge.notify("Cleared the shortcut for \(item.title)")

        case "remove":
            guard let id = action.value.text else { return }
            guard await bridge.prompt(
                kind: .confirm,
                title: "Remove “\(item.title)”?",
                placeholder: "This removes the web app and its keyboard shortcut."
            ) == "true" else { return }
            try await store.deleteWebApp(id: id)
            await onChange()
            await bridge.notify("Removed \(item.title)")

        default:
            return
        }
    }

    private func requestShortcut(for existing: String?) async -> String? {
        guard let entered = await bridge.prompt(
            kind: .text,
            title: "Shortcut (optional)",
            placeholder: existing ?? "ctrl+alt+f"
        ) else { return nil }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let shortcut = WebAppShortcut.parse(trimmed) else {
            await bridge.notify("Shortcut ignored: use at least two modifiers")
            return nil
        }
        do {
            if try await shortcutIsTaken(shortcut.canonical, excluding: nil) {
                await bridge.notify("Shortcut \(shortcut.canonical) is already used; none set")
                return nil
            }
        } catch {
            return nil
        }
        return shortcut.canonical
    }

    private func shortcutIsTaken(_ shortcut: String, excluding id: String?) async throws -> Bool {
        let apps = try await store.webApps()
        return apps.contains { app in
            app.id != id && app.shortcut?.caseInsensitiveCompare(shortcut) == .orderedSame
        }
    }

    private static func addQuery(from text: String) -> URL? {
        let value: String
        if text.lowercased().hasPrefix("add ") {
            value = String(text.dropFirst(4))
        } else {
            value = text
        }
        return WebAppURL.normalize(value)
    }
}
