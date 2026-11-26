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

    /// Custom action ids `activate` routes; the OCR rows belong to the host.
    static let handledCustomActions: Set<String> = ["unpin-item"]
    static let hostHandledCustomActions: Set<String> = ["ocr-pin-copy", "ocr-pin-open"]

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
            // Image pins can be read even when they were pinned before OCR
            // actions existed. The host resolves the pixels, full resolution
            // where the original provider still has them.
            if case .image = item.preview {
                if !item.actions.contains(where: { $0.id == "ocr-copy" || $0.id == "ocr-pin-copy" }) {
                    item.actions.append(PaletteAction(
                        id: "ocr-pin-copy",
                        title: "Copy Text (OCR)",
                        kind: .custom
                    ))
                }
                if !item.actions.contains(where: { $0.id == "ocr-open-link" || $0.id == "ocr-pin-open" }) {
                    item.actions.append(PaletteAction(
                        id: "ocr-pin-open",
                        title: "Open Detected Link",
                        kind: .custom
                    ))
                }
            }
            return item
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard Self.handledCustomActions.contains(action.id) else {
            throw ProviderError.failed("Pinned items are opened through their original provider")
        }
        try await store.unpinItem(id: item.stableID)
        await bridge.notify("Unpinned \(item.title)")
    }
}
