import Foundation
import PaletteCore

/// Lists the user's cheatsheet folders (PDF, HTML, Markdown, text and images),
/// one level deep, and previews the selected file with QuickLook.
public final class CheatsheetProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "cheat",
        name: "Cheatsheets",
        trigger: "cheat",
        isGlobal: true,
        priority: 47,
        icon: "symbol:book",
        keywords: ["cheatsheet", "reference", "docs", "pdf", "html", "markdown"]
    )

    private let config: CheatsheetConfig
    private let cache = ShortCache<[Entry]>(ttl: 5)

    public init(config: CheatsheetConfig) {
        self.config = config
    }

    private struct Entry: Sendable {
        var url: URL
        var folder: String
        var bytes: Int
        var extensionName: String
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        // Global providers run on every search: only offer the setup row when
        // the user asked for cheatsheets explicitly.
        guard !config.folders.isEmpty else { return request.isBound ? [setupRow] : [] }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries: [Entry]
        let key = Self.cacheKey(config)
        if let cached = await cache.get(key) {
            entries = cached
        } else {
            entries = Self.entries(in: config)
            await cache.set(entries, key: key)
        }
        let matches = query.isEmpty
            ? entries
            : entries.compactMap { entry -> (Entry, Double)? in
                let candidate = "\(entry.url.lastPathComponent) \(entry.folder)"
                guard let score = Ranking.score(query: query, candidate: candidate) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        guard !matches.isEmpty else {
            guard request.isBound else { return [] }
            return [emptyRow(
                title: entries.isEmpty ? "No cheatsheets found" : "No cheatsheets match \"\(query)\"",
                subtitle: "Looked in \(config.folders.count) folder\(config.folders.count == 1 ? "" : "s") for \(config.extensions.joined(separator: ", "))"
            )]
        }
        return matches.prefix(80).map(row(for:))
    }

    private func row(for entry: Entry) -> PaletteItem {
        let name = entry.url.lastPathComponent
        let path = entry.url.path
        return PaletteItem(
            id: path,
            title: name,
            subtitle: "\(entry.folder) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))",
            icon: .file(path),
            group: entry.folder,
            score: 100,
            actions: [
                PaletteAction(id: "open", title: "Open \(name)", kind: .openPath, value: .text(path)),
                PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .reveal, value: .text(path)),
            ],
            preview: .document(url: path, kind: Self.kind(for: entry.extensionName)),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private var setupRow: PaletteItem {
        PaletteItem(
            id: "cheat:setup",
            title: "Set up cheatsheets",
            subtitle: "Add folders in Settings → Cheatsheets",
            icon: .symbol("doc.badge.plus"),
            badge: "SETUP",
            group: "Cheatsheets",
            score: 1_000,
            actions: [PaletteAction(id: "open-settings", title: "Open Settings", kind: .custom, value: .none)],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func emptyRow(title: String, subtitle: String) -> PaletteItem {
        PaletteItem(
            id: "cheat:empty",
            title: title,
            subtitle: subtitle,
            icon: .symbol("book"),
            badge: "EMPTY",
            group: "Cheatsheets",
            score: 1_000,
            actions: [],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    // MARK: - Files

    /// Folders, extensions and each folder's mtime: a new file or a settings
    /// change misses, an unchanged folder is not re-enumerated per keystroke.
    private static func cacheKey(_ config: CheatsheetConfig) -> String {
        var parts = config.extensions.map { $0.lowercased() }
        for folder in config.folders {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            parts.append("\(folder)#\(Int(date))")
        }
        return parts.joined(separator: "|")
    }

    private static func entries(in config: CheatsheetConfig) -> [Entry] {
        let allowed = Set(config.extensions.map { $0.lowercased() })
        var seen = Set<String>()
        var entries: [Entry] = []
        for folder in config.folders {
            let expanded = (folder as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            let folderName = url.lastPathComponent
            let files = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            )) ?? []
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard allowed.contains(ext) else { continue }
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile ?? true else { continue }
                let path = file.path
                guard seen.insert(path).inserted else { continue }
                entries.append(Entry(url: file, folder: folderName, bytes: values?.fileSize ?? 0, extensionName: ext))
            }
        }
        return entries.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    private static func kind(for ext: String) -> String {
        switch ext {
        case "pdf": return "pdf"
        case "html", "htm": return "html"
        case "md", "markdown": return "markdown"
        case "txt": return "text"
        default: return "image"
        }
    }
}
