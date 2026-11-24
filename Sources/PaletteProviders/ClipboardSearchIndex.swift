import Foundation
import PaletteCore
import PalettePlatform

/// A folded copy of the clipboard history. Each keystroke scores this
/// memory-resident snapshot instead of re-reading and re-folding up to 50k
/// rows; the display rows are fetched afterwards, by id.
actor ClipboardSearchIndex {
    struct Entry: Sendable {
        let id: String
        let kind: ClipboardKind
        /// Searchable text, folded once at build time: the capped body plus a
        /// kind label (and the file name for file entries).
        let folded: String
        let pinned: Bool
        let createdAt: Date
    }

    /// Same pathological cap the old per-keystroke scan had.
    private static let maxEntries = 50_000
    /// Backstop for writes that bypass the store actor, such as a restored
    /// database file. The revision check covers the normal path.
    static let maxAge: TimeInterval = 60

    private var entries: [Entry] = []
    private var revision: Int?
    private var builtAt = Date.distantPast
    /// Test-visible: proves a run of keystrokes reuses one build.
    private(set) var buildCount = 0

    func entries(for store: PaletteStore) async -> [Entry] {
        #if DEBUG
        // Reading 50k rows and folding them runs off the main actor; a main
        // thread build would freeze the panel for as long as the query takes.
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let current = await store.clipboardRevision()
        guard current != revision || Date().timeIntervalSince(builtAt) >= Self.maxAge else {
            return entries
        }
        let rows = (try? await store.clipboardSearchRows(limit: Self.maxEntries)) ?? []
        entries = rows.map(Self.entry(for:))
        revision = current
        builtAt = Date()
        buildCount += 1
        return entries
    }

    /// The folded search text for a row. For text entries the title is the
    /// text's own prefix, so folding it again would only double the per-query
    /// scan; files and images get a label the body does not contain.
    private static func entry(for row: ClipboardSearchRow) -> Entry {
        let folded: String
        switch row.kind {
        case .text:
            folded = Ranking.normalize("\(row.textPrefix) text")
        case .files:
            let first = row.textPrefix.split(separator: "\n").first.map(String.init)
            let title = first.map { ($0 as NSString).lastPathComponent } ?? "Files"
            folded = Ranking.normalize("\(title) \(row.textPrefix) files")
        case .image:
            folded = Ranking.normalize("Image \(row.imageWidth)×\(row.imageHeight) PNG image")
        }
        return Entry(
            id: row.id,
            kind: row.kind,
            folded: folded,
            pinned: row.pinned,
            createdAt: row.createdAt
        )
    }
}
