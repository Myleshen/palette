import Foundation
import PaletteCore

public final class EmojiProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "emoji",
        name: "Emoji",
        trigger: "emoji",
        isGlobal: false,
        priority: 15,
        icon: "symbol:face.smiling"
    )

    /// Every emoji macOS itself knows about, with the system names so searches
    /// like "crying" or "heart hands" land on the same pick as Character Viewer.
    private static let entries = EmojiCatalog.all

    public init() {}

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(request.limit, 5_000))

        if query.isEmpty {
            return Self.entries.prefix(limit).map { item(for: $0, score: 0) }
        }

        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [(EmojiCatalogEntry, Double)] = []
        for emoji in Self.entries {
            let haystack = emoji.searchText
            // Emoji names are literal; subsequence matching turns "dragon" into
            // "Red Triangle", so every term must appear verbatim somewhere.
            guard terms.allSatisfy({ haystack.contains($0.lowercased()) }) else { continue }
            let score = Ranking.score(query: query, candidate: emoji.name)
                ?? Ranking.score(query: query, candidate: emoji.appleName)
                ?? Ranking.score(query: query, candidate: emoji.group)
                ?? 1
            matches.append((emoji, score))
        }
        matches.sort { $0.1 > $1.1 }
        return matches.prefix(limit).map { item(for: $0.0, score: $0.1) }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {}

    private func item(for emoji: EmojiCatalogEntry, score: Double) -> PaletteItem {
        let label = (emoji.appleName.isEmpty ? emoji.name : emoji.appleName).capitalized
        let detail = emoji.group.isEmpty ? "Copy emoji" : emoji.group
        return PaletteItem(
            id: emoji.glyph,
            title: "\(emoji.glyph)  \(label)",
            subtitle: detail,
            icon: .symbol("face.smiling"),
            badge: emoji.group.isEmpty ? nil : emoji.group,
            score: score,
            actions: [
                PaletteAction(id: "copy-emoji", title: "Copy Emoji", kind: .copyText, value: .text(emoji.glyph)),
            ],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}
