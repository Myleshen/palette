import Foundation
import PaletteCore
import PalettePlatform

/// Recently used projects and paths, based on Palette's own frecency table.
/// This is intentionally fast: no filesystem crawl, only items the user has
/// already opened.
public final class RecentProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "recent",
        name: "Recent",
        trigger: "recent",
        isGlobal: false,
        priority: 58,
        icon: "symbol:clock.arrow.circlepath"
    )

    private let store: PaletteStore
    private let launcher: LauncherService
    private let editor: String

    public init(store: PaletteStore, launcher: LauncherService, editor: String) {
        self.store = store
        self.launcher = launcher
        self.editor = editor
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uses = (try? await store.recentUses(
            providers: ["neo", "neof", "proj", "git", "cmd", "finder"],
            limit: 200
        )) ?? []

        var seen = Set<String>()
        var items: [PaletteItem] = []
        for use in uses {
            guard let path = path(for: use), FileManager.default.fileExists(atPath: path) else { continue }
            guard seen.insert(path).inserted else { continue }
            let title = (path as NSString).lastPathComponent
            if !query.isEmpty,
               Ranking.score(query: query, candidate: "\(title) \(path) \(use.provider)") == nil {
                continue
            }
            var actions: [PaletteAction] = [
                PaletteAction(
                    id: "open",
                    title: "Open with \(editor)",
                    kind: .openPathWith,
                    value: .object(["path": path, "app": editor])
                ),
                PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .reveal, value: .text(path)),
                PaletteAction(
                    id: "term-here",
                    title: "Open in Embedded Terminal",
                    kind: .custom,
                    value: .object(["path": isDirectory(path) ? path : (path as NSString).deletingLastPathComponent])
                ),
            ]
            actions.append(PaletteAction(
                id: "open-default",
                title: "Open",
                kind: .openPath,
                value: .text(path)
            ))
            items.append(PaletteItem(
                id: "recent:\(use.stableID)",
                title: title,
                subtitle: "\(use.provider) · \(relative(use.lastUsed)) · \(path)",
                icon: .symbol(isDirectory(path) ? "folder.fill" : "doc.text"),
                badge: "RECENT",
                score: 1_000 - Double(items.count),
                actions: actions,
                preview: .files(paths: [path]),
                providerID: descriptor.id,
                providerName: descriptor.name
            ))
            if items.count >= max(1, request.limit) { break }
        }
        return items
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        if action.id == "reveal", let path = action.value.text {
            await MainActor.run { launcher.reveal(path) }
        }
    }

    private func path(for use: RecentUse) -> String? {
        var value = use.itemID
        for prefix in ["proj:", "git:", "finder:"] {
            if value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) }
        }
        guard value.hasPrefix("/") || value.hasPrefix("~") else { return nil }
        return PathExpansion.expand(value)
    }

    private func isDirectory(_ path: String) -> Bool {
        var value: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &value)
        return value.boolValue
    }

    private func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        if seconds < 604_800 { return "\(seconds / 86_400)d ago" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}
