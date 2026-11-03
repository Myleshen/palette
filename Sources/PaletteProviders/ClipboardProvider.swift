import Foundation
import PaletteCore
import PalettePlatform

/// Clipboard history with text, image, and Finder-file entries. A leading
/// category token (`text`, `images`, `files`) filters the list; everything else
/// is a normal search query. The clipboard window uses the same provider with
/// the `clip` prefix and an empty query.
public final class ClipboardProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "clip",
        name: "Clipboard History",
        trigger: "clip",
        isGlobal: false,
        priority: 40,
        icon: "symbol:doc.on.clipboard"
    )

    private let store: PaletteStore
    private let bridge: HostBridge

    public init(store: PaletteStore, bridge: HostBridge) {
        self.store = store
        self.bridge = bridge
    }

    // A hard safety cap for pathological histories. Normal configured limits
    // (including the 5,000 default and 6,000 here) are scanned in full.
    // shortcut: histories above 50k entries are capped; add a ranked index if
    // that becomes a real use case.
    private static let maxSearchEntries = 50_000

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let parsed = Self.parse(request.text)
        let query = parsed.query
        // Fuzzy search has to see the whole recent history, because a
        // non-contiguous match ("qbf" -> "quick brown fox") cannot be expressed
        // as a SQL LIKE pattern.
        let fetchLimit: Int
        if query.isEmpty {
            fetchLimit = min(500, max(1, request.limit))
        } else {
            let total = (try? await store.clipboardCount()) ?? 0
            fetchLimit = max(1, min(Self.maxSearchEntries, max(request.limit, total)))
        }
        let entries = try await store.clipboardEntries(
            limit: fetchLimit,
            query: nil,
            kind: parsed.kind,
            // Thumbnails are only fetched for the handful of rows we show.
            includeThumbnails: query.isEmpty
        )
        let ordered = entries.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.kind != rhs.kind {
                return Self.kindOrder(lhs.kind) < Self.kindOrder(rhs.kind)
            }
            return lhs.createdAt > rhs.createdAt
        }

        if query.isEmpty {
            return ordered.prefix(max(1, request.limit)).map { entry in
                Self.item(for: entry, provider: descriptor)
            }
        }

        var matches: [(entry: ClipboardEntry, score: Double)] = []
        for entry in ordered {
            guard let score = Self.searchScore(entry, query: query) else { continue }
            // Keep typed results flat and ranked; group headers only help the
            // unfiltered clipboard browser.
            matches.append((entry, score + (entry.pinned ? 25 : 0)))
        }
        matches.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
            return lhs.entry.createdAt > rhs.entry.createdAt
        }

        let limit = max(1, request.limit)
        var top = Array(matches.prefix(limit))
        for index in top.indices where top[index].entry.kind != .text && top[index].entry.thumbnailPNG == nil {
            if let thumbnail = try? await store.clipboardThumbnail(id: top[index].entry.id) {
                top[index].entry.thumbnailPNG = thumbnail
            }
        }
        return top.map { match in
            var item = Self.item(for: match.entry, provider: descriptor)
            item.group = nil
            item.score = match.score
            return item
        }
    }

    private static func item(for entry: ClipboardEntry, provider: ProviderDescriptor) -> PaletteItem {
        switch entry.kind {
        case .image:
            return imageItem(entry, provider: provider)
        case .files:
            return filesItem(entry, provider: provider)
        case .text:
            return textItem(entry, provider: provider)
        }
    }

    /// The searchable form of an entry, capped so a huge text clipboard does
    /// not make every keystroke crawl.
    private static func searchScore(_ entry: ClipboardEntry, query: String) -> Double? {
        let candidate: String
        switch entry.kind {
        case .text:
            candidate = String(entry.text.prefix(4_000))
        case .files:
            candidate = String(entry.paths.joined(separator: " ").prefix(4_000))
        case .image:
            candidate = "Image \(entry.imageWidth)×\(entry.imageHeight) PNG image"
        }
        return Ranking.score(query: query, candidate: candidate)
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        let command = action.value.text ?? action.id
        switch command {
        case "delete":
            try await store.deleteClipboard(id: item.id)
            await bridge.notify("Clipboard entry deleted")
        case "pin":
            try await store.setClipboardPinned(id: item.id, pinned: true)
            await bridge.notify("Clipboard entry pinned")
        case "unpin":
            try await store.setClipboardPinned(id: item.id, pinned: false)
            await bridge.notify("Clipboard entry unpinned")
        default:
            break
        }
    }

    // MARK: - Rows

    private static func textItem(_ entry: ClipboardEntry, provider: ProviderDescriptor) -> PaletteItem {
        let preview = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let title = String(preview.prefix(160))
        // Enter on a clipboard row pastes immediately; Copy stays available as
        // the secondary action for people who want to stage it.
        var actions: [PaletteAction] = [
            PaletteAction(id: "paste", title: "Paste", kind: .pasteText, value: .text(entry.text)),
            PaletteAction(id: "copy", title: "Copy", kind: .copyText, value: .text(entry.text)),
            pinAction(entry),
            PaletteAction(id: "delete", title: "Delete Entry", kind: .custom, value: .text("delete")),
        ]
        if entry.text.count > 120 {
            actions.append(PaletteAction(id: "copy-all", title: "Copy Full Text", kind: .copyText, value: .text(entry.text)))
        }
        return PaletteItem(
            id: entry.id,
            title: title.isEmpty ? "(whitespace)" : title,
            subtitle: "\(relative(entry.createdAt)) · \(entry.text.count) \(entry.text.count == 1 ? "char" : "chars")",
            icon: .symbol(entry.pinned ? "pin.fill" : "doc.on.clipboard"),
            badge: entry.pinned ? "pinned" : nil,
            group: entry.pinned ? "Pinned" : "Text",
            score: 0,
            actions: actions,
            preview: .text(entry.text),
            providerID: provider.id,
            providerName: provider.name
        )
    }

    private static func imageItem(_ entry: ClipboardEntry, provider: ProviderDescriptor) -> PaletteItem {
        let actions: [PaletteAction] = [
            PaletteAction(id: "paste-image", title: "Paste Image", kind: .pasteImage, value: .text(entry.id)),
            PaletteAction(id: "copy-image", title: "Copy Image", kind: .copyImage, value: .text(entry.id)),
            pinAction(entry),
            PaletteAction(id: "delete", title: "Delete Entry", kind: .custom, value: .text("delete")),
        ]
        let thumbnail = entry.thumbnailPNG
        let icon: IconSpec? = thumbnail.map { .base64($0.base64EncodedString()) } ?? .symbol("photo")
        let preview: ItemPreview? = thumbnail.map {
            .image(base64: $0.base64EncodedString(), width: entry.imageWidth, height: entry.imageHeight)
        }
        return PaletteItem(
            id: entry.id,
            title: "Image \(entry.imageWidth)×\(entry.imageHeight)",
            subtitle: "\(relative(entry.createdAt)) · PNG image",
            icon: icon,
            badge: entry.pinned ? "pinned" : "image",
            group: entry.pinned ? "Pinned" : "Images",
            score: 0,
            actions: actions,
            preview: preview,
            providerID: provider.id,
            providerName: provider.name
        )
    }

    private static func filesItem(_ entry: ClipboardEntry, provider: ProviderDescriptor) -> PaletteItem {
        let paths = entry.paths
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let title: String
        if names.count == 1 {
            title = names[0]
        } else if names.isEmpty {
            title = "Files"
        } else {
            title = "\(names.count) items"
        }
        let parent = ((paths.first ?? "") as NSString).deletingLastPathComponent
        let shownParent = parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let detail = names.count > 1
            ? names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
            : shownParent
        var actions: [PaletteAction] = [
            PaletteAction(id: "paste-files", title: "Paste Files", kind: .pasteFiles, value: .list(paths)),
            PaletteAction(id: "copy-files", title: "Copy Files", kind: .copyFiles, value: .list(paths)),
        ]
        if paths.count == 1 {
            actions.append(PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .reveal, value: .text(paths[0])))
        }
        actions.append(pinAction(entry))
        actions.append(PaletteAction(id: "delete", title: "Delete Entry", kind: .custom, value: .text("delete")))

        let icon: IconSpec? = entry.thumbnailPNG.map { .base64($0.base64EncodedString()) } ?? .symbol("doc")
        return PaletteItem(
            id: entry.id,
            title: title,
            subtitle: "\(relative(entry.createdAt)) · \(detail)",
            icon: icon,
            badge: entry.pinned ? "pinned" : "files",
            group: entry.pinned ? "Pinned" : "Files",
            score: 0,
            actions: actions,
            preview: .files(paths: paths),
            providerID: provider.id,
            providerName: provider.name
        )
    }

    private static func pinAction(_ entry: ClipboardEntry) -> PaletteAction {
        PaletteAction(
            id: entry.pinned ? "unpin" : "pin",
            title: entry.pinned ? "Unpin" : "Pin",
            kind: .custom,
            value: .text(entry.pinned ? "unpin" : "pin")
        )
    }

    // MARK: - Query parsing

    static func parse(_ text: String) -> (kind: ClipboardKind?, query: String) {
        let fields = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = fields.first?.lowercased() else { return (nil, "") }
        let kind: ClipboardKind?
        switch first {
        case "text": kind = .text
        case "image", "images": kind = .image
        case "file", "files": kind = .files
        default: return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let rest = fields.count > 1 ? String(fields[1]) : ""
        return (kind, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func kindOrder(_ kind: ClipboardKind) -> Int {
        switch kind {
        case .text: return 0
        case .image: return 1
        case .files: return 2
        }
    }

    private static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case 0..<5: return "just now"
        case 5..<60: return "\(seconds)s ago"
        case 60..<3600: return "\(seconds / 60)m ago"
        case 3600..<86400: return "\(seconds / 3600)h ago"
        case 86400..<604800: return "\(seconds / 86400)d ago"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}
