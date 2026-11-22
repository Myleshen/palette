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
    public enum StoreError: LocalizedError, Equatable {
        case unreadable(String)
        case malformed(String)
        case backup(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let message):
                return "Could not read bookmarks.toml: \(message)"
            case .malformed(let message):
                return "bookmarks.toml is not valid TOML: \(message)"
            case .backup(let message):
                return "Could not back up bookmarks.toml, so it was left untouched: \(message)"
            }
        }
    }

    /// A missing file is an empty list. A file that exists but cannot be
    /// parsed throws: the caller must report it and must not save over it.
    public static func load(from url: URL) throws -> [Bookmark] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch {
            throw StoreError.malformed(String(describing: error))
        }
        guard let entries = table["bookmark"]?.array else { return [] }
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
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Keep the bytes that were on disk before this write. A hand edit that
        // broke the file, or a file Palette failed to parse, survives in
        // bookmarks.toml.bak instead of being lost on the next save.
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? manager.removeItem(at: backup)
            do {
                try manager.copyItem(at: url, to: backup)
            } catch {
                throw StoreError.backup(error.localizedDescription)
            }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// TOML basic strings only accept escapes for `\`, `"` and control
    /// characters; a pasted CR used to produce a file that would not parse.
    private static func quote(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }
}
