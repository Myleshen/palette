import Foundation
import TOMLKit

/// A bookmark opens a URL in a normal browser window, unlike a web app, which
/// gets its own app-mode window. Stored in `~/.config/palette/bookmarks.toml`.
public struct Bookmark: Identifiable, Equatable, Sendable {
    /// Row identity only. The file has no ids, so this is not stable across loads.
    public var id: UUID
    public var name: String
    public var url: String
    /// App name or path; empty means the system default browser.
    public var browser: String
    public var keywords: [String]

    public init(id: UUID = UUID(), name: String, url: String, browser: String = "", keywords: [String] = []) {
        self.id = id
        self.name = name
        self.url = url
        self.browser = browser
        self.keywords = keywords
    }
}

public enum BookmarkStore {
    public static func load(from url: URL) -> [Bookmark] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let table = try? TOMLTable(string: text),
              let entries = table["bookmark"]?.array else { return [] }
        return entries.compactMap { value in
            guard let row = value.table,
                  let name = row["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let bookmarkURL = row["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bookmarkURL.isEmpty else { return nil }
            return Bookmark(
                name: name,
                url: bookmarkURL,
                browser: row["browser"]?.string ?? "",
                keywords: row["keywords"]?.array?.compactMap { $0.string } ?? []
            )
        }
    }

    public static func save(_ bookmarks: [Bookmark], to url: URL) throws {
        var lines = ["# Palette bookmarks. Edited in Settings → Search → Bookmarks.", ""]
        for bookmark in bookmarks {
            lines.append("[[bookmark]]")
            lines.append("name = \(quote(bookmark.name))")
            lines.append("url = \(quote(bookmark.url))")
            if !bookmark.browser.isEmpty { lines.append("browser = \(quote(bookmark.browser))") }
            if !bookmark.keywords.isEmpty {
                lines.append("keywords = [\(bookmark.keywords.map(quote).joined(separator: ", "))]")
            }
            lines.append("")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
