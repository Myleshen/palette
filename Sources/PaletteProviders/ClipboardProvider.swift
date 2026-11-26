import Foundation
import PaletteCore
import PalettePlatform

/// Clipboard history with text, image, and Finder-file entries, newest first.
/// The query is ordinary search text: a leading `images` or `files` is matched
/// like any other word, not treated as a filter. The clipboard window uses the
/// same provider with the `clip` prefix and an empty query.
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
    /// Folded history, rebuilt when the store's clipboard revision moves.
    private let index = ClipboardSearchIndex()

    /// Custom action ids `activate` routes. The item builders below may only
    /// emit these plus `hostHandledCustomActions`; the routing test pins that.
    static let handledCustomActions: Set<String> = ["delete", "pin", "unpin", "ocr-copy"]
    /// Custom ids the host handles before the provider sees them.
    static let hostHandledCustomActions: Set<String> = ["clip-transform", "scratch-entry", "term-here"]

    public init(store: PaletteStore, bridge: HostBridge) {
        self.store = store
        self.bridge = bridge
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        if let entryID = Self.transformEntryID(request.text) {
            guard let entry = try await store.clipboardEntry(id: entryID), entry.kind == .text else { return [] }
            return Self.transformItems(entry: entry, provider: descriptor)
        }
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, request.limit)

        // Fuzzy search sees the whole recent history, because a non-contiguous
        // match ("qbf" -> "quick brown fox") cannot be a SQL LIKE pattern.
        let candidates = await index.entries(for: store)

        if query.isEmpty {
            // The snapshot is already in display order. The clipboard browser
            // never shows more than 500 rows, matching the old fetch cap.
            let ids = candidates.prefix(min(limit, 500)).map(\.id)
            let rows = try await store.clipboardEntries(ids: ids)
            let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let shown = ids.compactMap { byID[$0] }
            await Self.prefetchLinks(for: shown)
            return shown.map { Self.item(for: $0, provider: descriptor) }
        }

        let terms = query.split(whereSeparator: \.isWhitespace).map { Ranking.normalize(String($0)) }
        var matches: [(id: String, score: Double, createdAt: Date)] = []
        for entry in candidates {
            guard let score = Ranking.score(foldedTerms: terms, foldedCandidate: entry.folded) else { continue }
            // Keep typed results flat and ranked.
            matches.append((entry.id, score + (entry.pinned ? 25 : 0), entry.createdAt))
        }
        matches.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
            return lhs.createdAt > rhs.createdAt
        }

        let top = Array(matches.prefix(limit))
        let rows = try await store.clipboardEntries(ids: top.map(\.id), includeThumbnails: false)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [PaletteItem] = []
        for match in top {
            guard var entry = byID[match.id] else { continue }
            if entry.kind != .text && entry.thumbnailPNG == nil {
                entry.thumbnailPNG = try? await store.clipboardThumbnail(id: entry.id)
            }
            var item = Self.item(for: entry, provider: descriptor)
            item.score = match.score
            items.append(item)
        }
        return items
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

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        // Route on the action id: OCR carries the entry id in `value`, so
        // switching on the value made the action fall through to `default`.
        guard Self.handledCustomActions.contains(action.id) else { return }
        switch action.id {
        case "delete":
            try await store.deleteClipboard(id: item.id)
            await bridge.notify("Clipboard entry deleted")
        case "pin":
            try await store.setClipboardPinned(id: item.id, pinned: true)
            await bridge.notify("Clipboard entry pinned")
        case "unpin":
            try await store.setClipboardPinned(id: item.id, pinned: false)
            await bridge.notify("Clipboard entry unpinned")
        case "ocr-copy":
            try await Self.copyRecognizedText(entryID: item.id, store: store, bridge: bridge)
        default:
            break
        }
    }

    // MARK: - OCR

    /// Reads a clipboard image with Vision and copies the text. The full image
    /// is used here; only link detection reads the cheaper thumbnail.
    private static func copyRecognizedText(entryID: String, store: PaletteStore, bridge: HostBridge) async throws {
        guard let data = try await store.clipboardImage(id: entryID) else {
            await bridge.notify("No text found")
            return
        }
        do {
            let recognition = try await ImageTextRecognition.recognize(pngData: data)
            await ImageTextRecognition.copyText(recognition, using: bridge)
        } catch {
            await bridge.notify("Text recognition failed")
        }
    }

    /// Link detection for the images a search is about to show, so the row can
    /// offer Open Link without OCR running at click time. Cached per entry, so
    /// this is a one-off cost for a given image.
    private static func prefetchLinks(for entries: [ClipboardEntry]) async {
        let pending = entries.filter { entry in
            entry.kind == .image
                && entry.thumbnailPNG != nil
                && ImageTextRecognition.cached(cacheKey: entry.id) == nil
        }
        // A first clipboard paint must stay fast; the remaining rows get their
        // links on the next search.
        let limited = pending.prefix(4)
        guard !limited.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for entry in limited {
                guard let thumbnail = entry.thumbnailPNG else { continue }
                let id = entry.id
                group.addTask {
                    _ = try? await ImageTextRecognition.recognize(pngData: thumbnail, cacheKey: id)
                }
            }
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
        actions.append(PaletteAction(id: "clip-transform", title: "Transform Text…", kind: .custom, value: .text(entry.id)))
        actions.append(PaletteAction(id: "scratch-entry", title: "Open in Scratchpad", kind: .custom, value: .text(entry.id)))
        return PaletteItem(
            id: entry.id,
            title: title.isEmpty ? "(whitespace)" : title,
            subtitle: "\(relative(entry.createdAt)) · \(entry.text.count) \(entry.text.count == 1 ? "char" : "chars")",
            icon: .symbol(entry.pinned ? "pin.fill" : "doc.on.clipboard"),
            badge: entry.pinned ? "pinned" : nil,
            score: 0,
            actions: actions,
            preview: .text(entry.text),
            providerID: provider.id,
            providerName: provider.name
        )
    }

    private static func imageItem(_ entry: ClipboardEntry, provider: ProviderDescriptor) -> PaletteItem {
        var actions: [PaletteAction] = [
            PaletteAction(id: "paste-image", title: "Paste Image", kind: .pasteImage, value: .text(entry.id)),
            PaletteAction(id: "copy-image", title: "Copy Image", kind: .copyImage, value: .text(entry.id)),
            PaletteAction(id: "ocr-copy", title: "Copy Text (OCR)", kind: .custom, value: .text(entry.id)),
        ]
        if let link = ImageTextRecognition.cached(cacheKey: entry.id)?.firstLink,
           ImageTextRecognition.isOpenable(link) {
            actions.append(PaletteAction(id: "ocr-open-link", title: "Open Link", kind: .openURL, value: .text(link)))
        }
        actions.append(pinAction(entry))
        actions.append(PaletteAction(id: "delete", title: "Delete Entry", kind: .custom, value: .text("delete")))
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
        if let first = paths.first {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory)
            let terminalPath = isDirectory.boolValue ? first : (first as NSString).deletingLastPathComponent
            actions.append(PaletteAction(
                id: "term-here",
                title: "Open in Embedded Terminal",
                kind: .custom,
                value: .object(["path": terminalPath])
            ))
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

    static func transformEntryID(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("transform:") else { return nil }
        let id = String(trimmed.dropFirst("transform:".count)).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    private static func transformItems(entry: ClipboardEntry, provider: ProviderDescriptor) -> [PaletteItem] {
        ClipboardTransform.allCases.compactMap { transform in
            guard let output = transform.apply(to: entry.text), !output.isEmpty else { return nil }
            let preview = output
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return PaletteItem(
                id: "transform:\(entry.id):\(transform.rawValue)",
                title: transform.title,
                subtitle: String(preview.prefix(140)),
                icon: .symbol("wand.and.stars"),
                badge: "TRANSFORM",
                score: 1_000,
                actions: [
                    PaletteAction(id: "paste", title: "Paste Result", kind: .pasteText, value: .text(output)),
                    PaletteAction(id: "copy", title: "Copy Result", kind: .copyText, value: .text(output)),
                ],
                preview: .text(output),
                providerID: provider.id,
                providerName: provider.name
            )
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
