import AppKit
import Foundation
import PaletteCore
import PalettePlatform

/// Browse what the capture directory holds: screenshots and recordings, newest
/// first, with open, annotate, copy and reveal.
public final class ShotsProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "shots",
        name: "Captures",
        trigger: "shots",
        isGlobal: false,
        priority: 48,
        icon: "symbol:photo.on.rectangle.angled",
        keywords: ["screenshot", "shots", "capture", "gallery", "recent", "recording"]
    )

    private let service: CaptureService

    public init(service: CaptureService) {
        self.service = service
    }

    private struct Entry: Sendable {
        var url: URL
        var date: Date
        var bytes: Int
        var isVideo: Bool
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let directory = await service.config.directory
        let entries = Self.entries(in: directory)
        guard !entries.isEmpty else {
            return [emptyRow(
                title: "No captures yet",
                subtitle: "Press ⌘⇧3 or run /shot; files land in \(directory)"
            )]
        }
        let filtered = query.isEmpty
            ? entries
            : entries.filter { $0.url.lastPathComponent.lowercased().contains(query) }
        guard !filtered.isEmpty else {
            return [emptyRow(title: "No captures match \"\(query)\"", subtitle: "\(entries.count) captures in \(directory)")]
        }
        return filtered.prefix(60).map { entry in
            let name = entry.url.lastPathComponent
            var actions: [PaletteAction] = [
                PaletteAction(id: "open", title: "Open \(name)", kind: .openPath, value: .text(entry.url.path)),
            ]
            if !entry.isVideo {
                actions.append(PaletteAction(id: "annotate", title: "Annotate \(name)", kind: .custom, value: .text("annotate:\(entry.url.path)")))
                actions.append(PaletteAction(id: "copy", title: "Copy image", kind: .custom, value: .text("copy:\(entry.url.path)")))
            }
            actions.append(PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .reveal, value: .text(entry.url.path)))

            return PaletteItem(
                id: "shot:\(entry.url.path)",
                title: name,
                subtitle: "\(Self.age(entry.date)) · \(Self.size(entry.bytes))",
                icon: .file(entry.url.path),
                badge: entry.isVideo ? "MOV" : "SHOT",
                group: Self.day(entry.date),
                score: 10_000 - Double(entry.date.timeIntervalSinceNow) / 3600,
                actions: actions,
                preview: .text("\(entry.url.path)\n\n\(Self.age(entry.date)) · \(Self.size(entry.bytes))"),
                providerID: descriptor.id,
                providerName: descriptor.name
            )
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        if raw.hasPrefix("annotate:") {
            let path = String(raw.dropFirst("annotate:".count))
            await MainActor.run {
                NotificationCenter.default.post(name: .paletteAnnotateRequest, object: path)
            }
            return
        }
        if raw.hasPrefix("copy:") {
            let path = String(raw.dropFirst("copy:".count))
            guard let image = NSImage(contentsOfFile: path) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            return
        }
        // openPath and reveal are executed by the host from the action kind.
    }

    private func emptyRow(title: String, subtitle: String) -> PaletteItem {
        PaletteItem(
            id: "shots:empty",
            title: title,
            subtitle: subtitle,
            icon: .symbol("photo.on.rectangle.angled"),
            group: "Captures",
            score: 1_000,
            actions: [],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    // MARK: - Files

    private static func entries(in directory: String) -> [Entry] {
        let expanded = (directory as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return names.compactMap { file -> Entry? in
            let ext = file.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "mov", "mp4"].contains(ext) else { return nil }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Entry(
                url: file,
                date: values?.contentModificationDate ?? .distantPast,
                bytes: values?.fileSize ?? 0,
                isVideo: ext == "mov" || ext == "mp4"
            )
        }
        .sorted { $0.date > $1.date }
    }

    private static func age(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}

extension Notification.Name {
    /// Posted with the file path when a capture row asks to annotate.
    public static let paletteAnnotateRequest = Notification.Name("palette.annotate.request")
}
