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

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let parsed = Self.parse(request.text)
        let entries = try await store.clipboardEntries(
            limit: min(500, max(1, request.limit)),
            query: parsed.query.isEmpty ? nil : parsed.query,
            kind: parsed.kind
        )
        let ordered = entries.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.kind != rhs.kind {
                return Self.kindOrder(lhs.kind) < Self.kindOrder(rhs.kind)
            }
            return lhs.createdAt > rhs.createdAt
        }
        return ordered.map { entry in
            switch entry.kind {
            case .image:
                return Self.imageItem(entry, provider: descriptor)
            case .files:
                return Self.filesItem(entry, provider: descriptor)
            case .text:
                return Self.textItem(entry, provider: descriptor)
            }
        }
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
