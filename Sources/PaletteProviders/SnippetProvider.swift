import AppKit
import Foundation
import PaletteCore
import PalettePlatform
import TOMLKit

/// User snippets with safe, deterministic placeholder expansion. Snippets live
/// in `~/.config/palette/snippets.toml`; nothing is executed.
public final class SnippetProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "snip",
        name: "Snippets",
        trigger: "snip",
        isGlobal: false,
        priority: 59,
        icon: "symbol:text.badge"
    )

    public struct Snippet: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var keywords: [String]
        public var text: String
    }

    private let bridge: HostBridge
    private let fileURL: URL

    public init(bridge: HostBridge, fileURL: URL = PalettePaths.resolve().configDir.appendingPathComponent("snippets.toml")) {
        self.bridge = bridge
        self.fileURL = fileURL
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let snippets = Self.load(from: fileURL)
        guard !snippets.isEmpty else { return [setupItem()] }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippets.compactMap { snippet in
            let haystack = ([snippet.title] + snippet.keywords + [snippet.text]).joined(separator: " ")
            if !query.isEmpty, Ranking.score(query: query, candidate: haystack) == nil { return nil }
            return item(snippet)
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        let expanded = SnippetExpansion.expand(
            raw,
            clipboard: NSPasteboard.general.string(forType: .string) ?? ""
        )
        switch action.id {
        case "snippet-copy", "snippet-raw":
            let value = action.id == "snippet-copy" ? expanded : raw
            await bridge.copyToClipboard(value, concealed: false, clearAfterMs: nil)
            await bridge.notify("Snippet copied")
        default:
            break
        }
    }

    private func setupItem() -> PaletteItem {
        PaletteItem(
            id: "snip:setup",
            title: "Add a snippet",
            subtitle: "Create \(fileURL.path)",
            icon: .symbol("doc.badge.plus"),
            badge: "SETUP",
            score: 10_000,
            actions: [PaletteAction(id: "open", title: "Open Snippets File", kind: .openPath, value: .text(fileURL.path))],
            preview: .text(Self.example),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func item(_ snippet: Snippet) -> PaletteItem {
        let preview = SnippetExpansion.expand(
            snippet.text,
            clipboard: NSPasteboard.general.string(forType: .string) ?? ""
        )
        return PaletteItem(
            id: "snip:\(snippet.id)",
            title: snippet.title,
            subtitle: String(snippet.text.replacingOccurrences(of: "\n", with: " ").prefix(120)),
            icon: .symbol("text.badge"),
            badge: "SNIPPET",
            score: 1_000,
            actions: [
                PaletteAction(id: "snippet-copy", title: "Copy Expanded", kind: .custom, value: .text(snippet.text)),
                PaletteAction(id: "snippet-raw", title: "Copy Raw", kind: .custom, value: .text(snippet.text)),
                PaletteAction(id: "snippet-scratch", title: "Open Expanded in Scratchpad", kind: .custom, value: .text(snippet.text)),
            ],
            preview: .text(preview),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    public static func load(from url: URL) -> [Snippet] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let table = try? TOMLTable(string: text),
              let entries = table["snippet"]?.array else { return [] }
        return entries.enumerated().compactMap { index, value in
            guard let row = value.table,
                  let title = row["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let body = row["text"]?.string else { return nil }
            let keywords = row["keywords"]?.array?.compactMap { $0.string } ?? []
            return Snippet(
                id: "\(index)-\(title)",
                title: title,
                keywords: keywords,
                text: body
            )
        }
    }

    public static let example = """
    # ~/.config/palette/snippets.toml
    #
    # [[snippet]]
    # title = "Email signature"
    # keywords = ["mail", "signature"]
    # text = "Best,\nMyles\n{{date}}"
    #
    # Placeholders:
    #   {{date}} {{time}} {{datetime}} {{clipboard}} {{uuid}} {{home}} {{user}}
    """
}
