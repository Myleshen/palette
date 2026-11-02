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
        icon: "symbol:paintpalette"
    )

    private let themesDirectory: URL
    private let launcher: LauncherService
    private var onSelect: (@MainActor (String) -> Void)?
    private var currentName: (@MainActor () -> String)?

    public init(
        themesDirectory: URL,
        launcher: LauncherService,
        onSelect: (@MainActor (String) -> Void)? = nil,
        currentName: (@MainActor () -> String)? = nil
    ) {
        self.themesDirectory = themesDirectory
        self.launcher = launcher
        self.onSelect = onSelect
        self.currentName = currentName
    }

    public func setCallbacks(
        onSelect: @escaping @MainActor (String) -> Void,
        currentName: @escaping @MainActor () -> String
    ) {
        self.onSelect = onSelect
        self.currentName = currentName
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let catalog = ThemeLoader.catalog(themesDirectory: themesDirectory)
        let current = await MainActor.run { currentName?() ?? "" }
        var items: [PaletteItem] = catalog.compactMap { info in
            let score: Double
            if request.text.isEmpty {
                score = info.name == current ? 100 : 0
            } else if let value = Ranking.score(query: request.text, candidate: "\(info.displayName) \(info.name) \(info.appearance)") {
                score = value + (info.name == current ? 50 : 0)
            } else {
                return nil
            }
            return PaletteItem(
                id: info.name,
                title: info.displayName,
                subtitle: "\(info.isBuiltin ? "Built-in" : "User theme") · \(info.appearance)\(info.name == current ? " · current" : "")",
                icon: .symbol(info.appearance == "light" ? "sun.max" : "moon"),
                badge: info.name == current ? "active" : nil,
                score: score,
                actions: [
                    PaletteAction(id: "select", title: "Apply Theme", kind: .custom, value: .text(info.name)),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            )
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

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.value.text {
        case "open-folder":
            await MainActor.run { launcher.openPath(themesDirectory.path) }
        case let name?:
            await MainActor.run { onSelect?(name) }
        default:
            break
        }
    }
}
