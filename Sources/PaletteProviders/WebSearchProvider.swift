import Foundation
import PaletteCore
import PalettePlatform

/// Global fallback rows that send the current query to a configured search
/// engine in the default browser.
public final class WebSearchProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "search",
        name: "Web Search",
        trigger: nil,
        isGlobal: true,
        priority: 80,
        icon: "magnifyingglass"
    )

    private let engines: [WebSearchEngine]
    private let enabled: Bool
    private let launcher: LauncherService

    public init(engines: [WebSearchEngine], enabled: Bool, launcher: LauncherService) {
        self.engines = engines.filter { $0.urlTemplate.contains("{query}") }
        self.enabled = enabled
        self.launcher = launcher
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        guard enabled, !request.text.isEmpty, !request.text.hasPrefix("/") else { return [] }
        let query = request.text
        var items: [PaletteItem] = []
        for (index, engine) in engines.enumerated() {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
            guard let url = URL(string: engine.urlTemplate.replacingOccurrences(of: "{query}", with: encoded)) else { continue }
            items.append(PaletteItem(
                id: "\(engine.id):\(query)",
                title: "Search \(engine.name) for “\(query)”",
                subtitle: url.host ?? engine.name,
                icon: .symbol("magnifyingglass"),
                score: -1_000 - Double(index),
                actions: [PaletteAction(id: "open", title: "Open in Browser", kind: .openURL, value: .text(url.absoluteString))],
                providerID: descriptor.id,
                providerName: descriptor.name
            ))
        }
        return items
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {}
}
