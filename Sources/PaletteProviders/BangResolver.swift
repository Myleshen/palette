import Foundation
import PaletteCore

/// Turns `!keyword query` into a direct web search. An engine is bangable only
/// once it has a keyword; name matching is a fallback for those engines.
public enum BangResolver {
    /// Rows for a raw launcher query. Empty when the query is not a bang.
    public static func items(for raw: String, engines: [WebSearchEngine]) -> [PaletteItem] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return [] }

        let body = trimmed.dropFirst()
        let token = String(body.prefix { !$0.isWhitespace })
        let query = String(body.dropFirst(token.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = token.lowercased()
        let candidates = engines.filter {
            !($0.keyword ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                && $0.urlTemplate.contains("{query}")
        }

        // Keyword first, then the engine name.
        if let engine = candidates.first(where: { ($0.keyword ?? "").lowercased() == lowered })
            ?? candidates.first(where: { $0.name.lowercased() == lowered }) {
            return [item(engine, query: query, discovery: false)].compactMap { $0 }
        }

        // Nothing exact yet: offer every engine the token is narrowing towards.
        return candidates.compactMap { engine -> PaletteItem? in
            let keyword = (engine.keyword ?? "").lowercased()
            let name = engine.name.lowercased()
            let matches = [keyword, name].contains {
                $0.hasPrefix(lowered) || $0.contains(lowered)
            }
            return matches ? item(engine, query: query, discovery: true) : nil
        }
    }

    private static func item(
        _ engine: WebSearchEngine,
        query: String,
        discovery: Bool
    ) -> PaletteItem? {
        guard let url = WebSearchProvider.url(for: engine, query: query) else { return nil }
        let keyword = (engine.keyword ?? "").trimmingCharacters(in: .whitespaces)
        let searching = !query.isEmpty

        // A normal browser window in the engine's own browser; no "mode".
        var value = ["url": url.absoluteString]
        if !engine.browser.isEmpty { value["browser"] = engine.browser }

        let title: String
        let subtitle: String
        if discovery {
            title = "!\(keyword) — \(engine.name)"
            subtitle = searching ? "Search for “\(query)”" : "Search \(engine.name)"
        } else if searching {
            title = "Search \(engine.name) for “\(query)”"
            subtitle = url.host ?? engine.name
        } else {
            title = "Search \(engine.name)"
            subtitle = "Type a query after !\(keyword)"
        }

        return PaletteItem(
            id: "bang:\(engine.id):\(query)",
            title: title,
            subtitle: subtitle,
            icon: .symbol("magnifyingglass"),
            badge: discovery ? "BANG" : nil,
            actions: [PaletteAction(id: "open", title: "Open in Browser", kind: .openURL, value: .object(value))],
            providerID: "bang",
            providerName: "Web Search"
        )
    }
}
