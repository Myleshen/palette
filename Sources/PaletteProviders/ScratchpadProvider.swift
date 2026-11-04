import Foundation
import PaletteCore

/// Entry point for the in-panel scratchpad. The editor itself lives in the app
/// layer so it can own keyboard focus and persistence.
public final class ScratchpadProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "scratch",
        name: "Scratchpad",
        trigger: "scratch",
        isGlobal: false,
        priority: 70,
        icon: "symbol:square.and.pencil"
    )

    public init() {}

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || Ranking.score(query: query, candidate: "scratchpad editor notes draft") != nil else {
            return []
        }
        return [PaletteItem(
            id: "scratchpad",
            title: "Scratchpad",
            subtitle: "Edit copied text, notes, or a draft",
            icon: .symbol("square.and.pencil"),
            badge: "EDITOR",
            score: 10_000,
            actions: [PaletteAction(id: "scratch-open", title: "Open Scratchpad", kind: .custom, value: .text("open"))],
            preview: .text("A persistent editor for pasted text and notes.\n\n⌘⏎ copies everything\n⌘S saves and closes\nesc saves and closes"),
            providerID: descriptor.id,
            providerName: descriptor.name
        )]
    }
}
