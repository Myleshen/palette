import Foundation
import PaletteCore

public final class TerminalProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "term",
        name: "Terminal",
        trigger: "term",
        isGlobal: false,
        priority: 72,
        icon: "symbol:terminal.fill"
    )

    public init() {}

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || Ranking.score(query: query, candidate: "terminal shell command run scratch") != nil else {
            return []
        }
        return [PaletteItem(
            id: "terminal",
            title: "Open Terminal",
            subtitle: "An interactive shell inside the Palette panel",
            icon: .symbol("terminal.fill"),
            badge: "SHELL",
            score: 10_000,
            actions: [PaletteAction(id: "term-open", title: "Open Terminal", kind: .custom, value: .text("open"))],
            preview: .text("Opens a real login shell in the content panel.\n\n⌘W closes the panel and terminates the shell."),
            providerID: descriptor.id,
            providerName: descriptor.name
        )]
    }
}
