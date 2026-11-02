import Foundation
import PaletteCore
import PalettePlatform

public final class PinProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "pins",
        name: "Pinned",
        isGlobal: true,
        priority: 200,
        icon: "symbol:pin.fill"
    )

    private let store: PaletteStore
    private let bridge: HostBridge

    public init(store: PaletteStore, bridge: HostBridge) {
        self.store = store
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        var items = (try? await store.pinnedItems()) ?? []
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { item in
                Ranking.score(query: query, candidate: item.title) != nil
                    || Ranking.score(query: query, candidate: item.subtitle ?? "") != nil
            }
        }
        return items.map { original in
            var item = original
            let match = query.isEmpty ? 900 : (Ranking.score(query: query, candidate: original.title) ?? 850)
            item.score = 900 + match
            item.badge = "pinned"
            if !item.actions.contains(where: { $0.id == "unpin-item" }) {
                item.actions.append(PaletteAction(
                    id: "unpin-item",
                    title: "Unpin from Palette",
                    kind: .custom,
                    value: .text("unpin")
                ))
            }
            return item
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard action.id == "unpin-item" else {
            throw ProviderError.failed("Pinned items are opened through their original provider")
        }
        try await store.unpinItem(id: item.stableID)
        await bridge.notify("Unpinned \(item.title)")
    }
}
