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
        var literalMatches: [(EmojiCatalogEntry, Double)] = []
        var fuzzyMatches: [(EmojiCatalogEntry, Double)] = []
        for emoji in Self.entries {
            let fields = [emoji.name, emoji.appleName, emoji.group]
            var total: Double = 0
            var literal = true
            var matchedAll = true

            for term in terms {
                let lower = term.lowercased()
                var best: Double?
                for field in fields where !field.isEmpty {
                    if let score = Ranking.termScore(term, candidate: field) {
                        best = max(best ?? score, score)
                    }
                }
                guard let best else {
                    matchedAll = false
                    break
                }
                total += best
                if !emoji.searchText.contains(lower) { literal = false }
            }
            guard matchedAll else { continue }
            if literal {
                literalMatches.append((emoji, total))
            } else {
                fuzzyMatches.append((emoji, total))
            }
        }

        // "dragon" also happens to be a subsequence of "Red Triangle Pointed
        // Up". When literal names exist, they are the answer; fuzzy
        // abbreviations such as "drgn" are only used as a fallback.
        var matches = literalMatches.isEmpty ? fuzzyMatches : literalMatches
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
