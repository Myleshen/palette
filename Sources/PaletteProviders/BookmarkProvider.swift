import Foundation
import PaletteCore
import PalettePlatform

/// User bookmarks from `~/.config/palette/bookmarks.toml`. They open in a normal
/// browser window (no app mode), optionally in a chosen browser.
public final class BookmarkProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "bookmark",
        name: "Bookmarks",
        trigger: "bookmark",
        isGlobal: true,
        priority: 44,
        icon: "symbol:bookmark"
    )

    private let fileURL: URL

    public init(fileURL: URL = PalettePaths.resolve().bookmarksFile) {
        self.fileURL = fileURL
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let bookmarks = BookmarkStore.load(from: fileURL)
        // Global providers run on every search: only offer the setup row when
        // the user asked for bookmarks explicitly.
        guard !bookmarks.isEmpty else { return request.isBound ? [setupItem()] : [] }
        return bookmarks.compactMap { bookmark in
            let haystack = ([bookmark.name] + bookmark.keywords).joined(separator: " ")
            if !request.terms.isEmpty,
               Ranking.score(terms: request.terms, candidate: haystack) == nil { return nil }
            return item(bookmark)
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        // .openURL is performed by the host, which builds the window from the
        // action value; nothing to do here.
    }

    /// The host reads "url" plus an optional "browser"; an absent or empty
    /// browser falls back to the system default. No "mode": this is a normal
    /// browser window, not a web app.
    static func openAction(for bookmark: Bookmark) -> PaletteAction {
        var value = ["url": bookmark.url]
        if !bookmark.browser.isEmpty { value["browser"] = bookmark.browser }
        return PaletteAction(id: "open", title: "Open Bookmark", kind: .openURL, value: .object(value))
    }

    private func setupItem() -> PaletteItem {
        PaletteItem(
            id: "bookmark:setup",
            title: "Add a bookmark",
            subtitle: "Create \(fileURL.path) with [[bookmark]] entries",
            icon: .symbol("doc.badge.plus"),
            badge: "SETUP",
            score: 10_000,
            actions: [PaletteAction(id: "open", title: "Open Bookmarks File", kind: .openPath, value: .text(fileURL.path))],
            preview: .text(Self.example),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func item(_ bookmark: Bookmark) -> PaletteItem {
        PaletteItem(
            id: "bookmark:\(bookmark.url)",
            title: bookmark.name,
            subtitle: bookmark.browser.isEmpty ? bookmark.url : "\(bookmark.url) · \(bookmark.browser)",
            icon: .symbol("bookmark"),
            badge: "BOOKMARK",
            score: 1_000,
            actions: [Self.openAction(for: bookmark)],
            preview: .text(bookmark.url),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    public static let example = """
    # ~/.config/palette/bookmarks.toml
    # Bookmark rows are also editable in Settings → Search → Bookmarks.
    #
    # [[bookmark]]
    # name = "GitHub"
    # url = "https://github.com"
    # browser = "Safari"
    # keywords = ["code", "repos"]
    """
}
