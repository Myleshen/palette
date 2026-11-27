import AppKit
import Foundation
import PaletteCore
import PalettePlatform

public final class ThemeProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "theme",
        name: "Themes",
        trigger: "theme",
        isGlobal: false,
        priority: 5,
        icon: "symbol:circle.lefthalf.filled"
    )

    private let themesDirectory: URL
    private let launcher: LauncherService
    private var onSelect: (@MainActor (String) -> Void)?
    private var currentName: (@MainActor () -> String)?
    private var paletteAvailable: (@MainActor () -> Bool)?
    private var onApplyPalette: (@MainActor (String) -> Void)?
    private var onShowCards: (@MainActor () -> Void)?
    /// Parsing hundreds of theme files per keystroke is the cost being avoided;
    /// the key is both directories' mtimes, and the TTL bounds content edits
    /// (which do not move a directory's mtime).
    private let catalogCache = ShortCache<[ThemeInfo]>(ttl: 30)

    public init(
        themesDirectory: URL,
        launcher: LauncherService,
        onSelect: (@MainActor (String) -> Void)? = nil,
        currentName: (@MainActor () -> String)? = nil,
        paletteAvailable: (@MainActor () -> Bool)? = nil,
        onApplyPalette: (@MainActor (String) -> Void)? = nil,
        onShowCards: (@MainActor () -> Void)? = nil
    ) {
        self.themesDirectory = themesDirectory
        self.launcher = launcher
        self.onSelect = onSelect
        self.currentName = currentName
        self.paletteAvailable = paletteAvailable
        self.onApplyPalette = onApplyPalette
        self.onShowCards = onShowCards
    }

    public func setCallbacks(
        onSelect: @escaping @MainActor (String) -> Void,
        currentName: @escaping @MainActor () -> String
    ) {
        self.onSelect = onSelect
        self.currentName = currentName
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let catalog = await catalog()
        let current = await MainActor.run { currentName?() ?? "" }
        let paletteEnabled = await MainActor.run { paletteAvailable?() ?? false }
        // `current` is the resolved theme's display name, so `.auto` and a live
        // preview both mark the theme that is actually on screen.
        var items: [PaletteItem] = catalog.compactMap { info in
            let isCurrent = info.name == current || info.displayName == current
            let port: String
            switch info.section {
            case .ghostty: port = "Ghostty port"
            case .omarchy: port = "Omarchy port"
            case .builtIn, .custom: port = ""
            }
            let score: Double
            if request.text.isEmpty {
                score = isCurrent ? 100 : 0
            } else if let value = Ranking.score(query: request.text, candidate: "\(info.displayName) \(info.name) \(info.appearance) \(port)") {
                score = value + (isCurrent ? 50 : 0)
            } else {
                return nil
            }
            var actions = [
                // The pick is written into `[theme]`, so it survives relaunch.
                PaletteAction(id: "select", title: "Use Theme", kind: .custom, value: .text(info.name)),
            ]
            if paletteEnabled {
                actions.append(PaletteAction(
                    id: "apply-palette",
                    title: "Apply Palette",
                    kind: .custom,
                    value: .text(info.name)
                ))
            }
            return PaletteItem(
                id: info.name,
                title: info.displayName,
                subtitle: "\(info.isBuiltin ? "Built-in" : "User theme")\(port.isEmpty ? "" : " · \(port)") · \(info.appearance)\(isCurrent ? " · current" : "")",
                icon: .symbol(info.appearance == "light" ? "sun.max" : "moon"),
                badge: isCurrent ? "ACTIVE" : nil,
                score: score,
                actions: actions,
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }

        if request.text.isEmpty {
            items.append(cardsItem(score: 10))
        } else if let score = Ranking.score(query: request.text, candidate: "theme cards gallery") {
            items.append(cardsItem(score: score + 5))
        }

        if !request.text.isEmpty,
           let score = Ranking.score(query: request.text, candidate: "themes folder custom create edit") {
            items.append(PaletteItem(
                id: "open-folder",
                title: "Open Themes Folder",
                subtitle: themesDirectory.path,
                icon: .symbol("folder"),
                score: score - 20,
                actions: [
                    PaletteAction(id: "open-folder", title: "Open Themes Folder", kind: .custom, value: .text("open-folder")),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            ))
        }
        return items
    }

    private func cardsItem(score: Double) -> PaletteItem {
        PaletteItem(
            id: "theme-cards",
            title: "Theme Cards",
            subtitle: "Large card gallery · wallpaper palette first",
            icon: .symbol("rectangle.on.rectangle"),
            score: score,
            actions: [
                PaletteAction(id: "cards", title: "Open Theme Cards", kind: .custom, value: .text("cards")),
            ],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func catalog() async -> [ThemeInfo] {
        let bundled = ThemeLoader.bundledThemesDirectory
        let key = [
            Self.modified(themesDirectory),
            bundled.map(Self.modified) ?? "-",
        ].joined(separator: "|")
        if let cached = await catalogCache.get(key) { return cached }
        let infos = ThemeLoader.catalog(themesDirectory: themesDirectory, bundledThemesDirectory: bundled)
        await catalogCache.set(infos, key: key)
        return infos
    }

    private static func modified(_ directory: URL) -> String {
        guard let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return "-" }
        return "\(directory.path)|\(Int(date.timeIntervalSince1970))"
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.value.text {
        case "cards":
            await MainActor.run { onShowCards?() }
        case "open-folder":
            await MainActor.run { launcher.openPath(themesDirectory.path) }
        case let name? where action.id == "apply-palette":
            await MainActor.run { onApplyPalette?(name) }
        case let name?:
            await MainActor.run { onSelect?(name) }
        default:
            break
        }
    }
}
