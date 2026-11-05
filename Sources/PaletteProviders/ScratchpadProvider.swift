import Foundation
import PaletteCore
import PalettePlatform

/// Entry point for the in-panel scratchpad. Notes are persisted in Palette's
/// state database so the editor is a small, searchable notebook rather than a
/// single overwritten buffer.
public final class ScratchpadProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "scratch",
        name: "Scratchpad",
        trigger: "scratch",
        isGlobal: false,
        priority: 70,
        icon: "symbol:square.and.pencil"
    )

    private let store: PaletteStore

    public init(store: PaletteStore) {
        self.store = store
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (try? await store.scratchNotes(limit: 500)) ?? []

        var items: [PaletteItem] = [newNoteItem()]
        for note in notes {
            let haystack = "\(note.title) \(note.text)"
            if !query.isEmpty, Ranking.score(query: query, candidate: haystack) == nil { continue }
            let score = query.isEmpty
                ? 900 - Double(items.count)
                : (Ranking.score(query: query, candidate: haystack) ?? 0)
            items.append(noteItem(note, score: score))
        }
        return Array(items.prefix(max(1, request.limit)))
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard action.id == "scratch-delete",
              let id = action.value.text else { return }
        try await store.deleteScratchNote(id: id)
    }

    private func newNoteItem() -> PaletteItem {
        PaletteItem(
            id: "scratchpad:new",
            title: "New Scratch Note",
            subtitle: "Start a fresh note",
            icon: .symbol("square.and.pencil"),
            badge: "NEW",
            score: 10_000,
            actions: [
                PaletteAction(id: "scratch-open", title: "New Note", kind: .custom, value: .text("new")),
            ],
            preview: .text("A persistent editor for notes and drafts.\n\n⌘⏎ copies everything\n⌘S saves and closes\nesc saves and closes"),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func noteItem(_ note: ScratchNote, score: Double) -> PaletteItem {
        let preview = note.text.isEmpty ? "Empty note" : String(note.text.prefix(4_000))
        return PaletteItem(
            id: "scratchpad:\(note.id)",
            title: note.title,
            subtitle: "\(relative(note.updatedAt)) · \(note.text.count) chars",
            icon: .symbol("note.text"),
            badge: "NOTE",
            score: score,
            actions: [
                PaletteAction(
                    id: "scratch-edit",
                    title: "Edit Note",
                    kind: .custom,
                    value: .object(["id": note.id])
                ),
                PaletteAction(
                    id: "scratch-delete",
                    title: "Delete Note",
                    kind: .custom,
                    value: .text(note.id)
                ),
            ],
            preview: .text(preview),
            providerID: descriptor.id,
            providerName: descriptor.name
        )
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
