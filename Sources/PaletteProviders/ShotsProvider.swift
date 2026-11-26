import AppKit
import AVFoundation
import Foundation
import PaletteCore
import PalettePlatform

/// Browse what the capture directory holds: screenshots and recordings, newest
/// first, with a thumbnail preview, open, annotate, copy and reveal.
public final class ShotsProvider: PaletteProvider, AsyncPreviewProviding, @unchecked Sendable {
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
    private let bridge: HostBridge
    private let cache = ShortCache<[Entry]>(ttl: 5)

    public init(service: CaptureService, bridge: HostBridge) {
        self.service = service
        self.bridge = bridge
    }

    private struct Entry: Sendable {
        var url: URL
        var date: Date
        var bytes: Int
        var isVideo: Bool
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let config = await service.config
        let directory = config.directory
        // The directory's own mtime changes with every new capture, so a fresh
        // screenshot appears immediately and an unchanged folder is not
        // re-enumerated per keystroke.
        let key = "\(directory)|\(config.gallery)|\(Self.modified(directory))"
        var entries: [Entry]
        if let cached = await cache.get(key) {
            entries = cached
        } else {
            entries = Self.entries(in: directory)
            await cache.set(entries, key: key)
        }
        if config.gallery == "palette" {
            entries = entries.filter { Self.isPaletteCapture($0.url) }
        }
        guard !entries.isEmpty else {
            guard request.isBound else { return [] }
            return [emptyRow(
                title: "No captures yet",
                subtitle: "Press ⌘⇧3 or run /shot; files land in \(directory)"
            )]
        }
        let filtered = query.isEmpty
            ? entries
            : entries.compactMap { entry -> (Entry, Double)? in
                guard let score = Ranking.score(query: query, candidate: entry.url.lastPathComponent) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        guard !filtered.isEmpty else {
            guard request.isBound else { return [] }
            return [emptyRow(title: "No captures match \"\(query)\"", subtitle: "\(entries.count) captures in \(directory)")]
        }
        // Rows come back at once with the file's own icon. The first ten warm
        // their thumbnails in the background, and the selected row is filled by
        // the host through `AsyncPreviewProviding`. Everything hits the cache.
        let items = filtered.prefix(60).map { row(for: $0) }
        let warm = filtered.prefix(10).filter { Self.cachedPreview(for: $0) == nil }
        if !warm.isEmpty {
            Task.detached(priority: .utility) {
                for entry in warm { _ = await Self.preview(for: entry) }
            }
        }
        return items
    }

    private func row(for entry: Entry) -> PaletteItem {
        let name = entry.url.lastPathComponent
        var actions: [PaletteAction] = [
            PaletteAction(id: "open", title: "Open \(name)", kind: .openPath, value: .text(entry.url.path)),
        ]
        if !entry.isVideo {
            actions.append(PaletteAction(id: "pin", title: "Pin to Screen", kind: .custom, value: .text("pin:\(entry.url.path)")))
            actions.append(PaletteAction(id: "annotate", title: "Annotate \(name)", kind: .custom, value: .text("annotate:\(entry.url.path)")))
            actions.append(PaletteAction(id: "copy", title: "Copy image", kind: .custom, value: .text("copy:\(entry.url.path)")))
            actions.append(PaletteAction(id: "paste", title: "Paste \(name)", kind: .pasteImage, value: .text(entry.url.path)))
        }
        actions.append(PaletteAction(id: "reveal", title: "Reveal in Finder", kind: .reveal, value: .text(entry.url.path)))

        let preview = Self.cachedPreview(for: entry)
            ?? .text("\(entry.url.path)\n\n\(Self.age(entry.date)) · \(Self.size(entry.bytes))")
        var icon = IconSpec.file(entry.url.path)
        if case let .image(base64, _, _) = preview { icon = .base64(base64) }

        let details = "\(Self.age(entry.date)) · \(Self.size(entry.bytes))"
        return PaletteItem(
            id: "shot:\(entry.url.path)",
            title: name,
            // Pins are click-through; say how to move one where users meet them.
            subtitle: entry.isVideo ? details : "\(details) · ⌥ moves pins",
            icon: icon,
            badge: entry.isVideo ? "MOV" : "SHOT",
            group: Self.day(entry.date),
            score: 10_000 - Double(entry.date.timeIntervalSinceNow) / 3600,
            actions: actions,
            preview: preview,
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    /// The host asks for the selected row's preview after the list is on screen.
    public func preview(for item: PaletteItem) async -> ItemPreview? {
        guard item.id.hasPrefix("shot:") else { return nil }
        let url = URL(fileURLWithPath: String(item.id.dropFirst("shot:".count)))
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate else { return nil }
        let entry = Entry(
            url: url,
            date: date,
            bytes: values.fileSize ?? 0,
            isVideo: ["mov", "mp4"].contains(url.pathExtension.lowercased())
        )
        return await Self.preview(for: entry)
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard let raw = action.value.text else { return }
        if raw.hasPrefix("pin:") {
            let path = String(raw.dropFirst("pin:".count))
            await MainActor.run {
                NotificationCenter.default.post(name: .palettePinRequest, object: path)
            }
            return
        }
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
            // Images cannot ride the text bridge; confirm here instead of
            // copying silently.
            await bridge.notify("Copied \(item.title)")
        }
        // openPath and reveal are executed by the host from the action kind.
    }

    private func emptyRow(title: String, subtitle: String) -> PaletteItem {
        PaletteItem(
            id: "shots:empty",
            title: title,
            subtitle: subtitle,
            icon: .symbol("photo.on.rectangle.angled"),
            badge: "EMPTY",
            group: "Captures",
            score: 1_000,
            actions: [],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    // MARK: - Thumbnails

    private static var thumbnails: [String: (base64: String, width: Int, height: Int)] = [:]
    /// Background warming made the dictionary shared between tasks.
    private static let thumbnailLock = NSLock()

    private static func thumbnailKey(_ entry: Entry) -> String {
        "\(entry.url.path)|\(entry.date.timeIntervalSince1970)|\(entry.bytes)"
    }

    private static func cachedPreview(for entry: Entry) -> ItemPreview? {
        let cached = thumbnailLock.withLock { thumbnails[thumbnailKey(entry)] }
        guard let cached else { return nil }
        return .image(base64: cached.base64, width: cached.width, height: cached.height)
    }

    /// A downscaled thumbnail per capture, cached by path and modification
    /// date. Videos get a poster frame, so the pane previews without relying
    /// on QuickLook.
    private static func preview(for entry: Entry) async -> ItemPreview {
        if let cached = cachedPreview(for: entry) { return cached }
        let image: NSImage?
        if entry.isVideo {
            image = await posterFrame(for: entry.url)
        } else {
            image = NSImage(contentsOf: entry.url)
        }
        guard let image, let thumb = downscale(image, maxWidth: 520),
              let data = thumb.representation(using: .png, properties: [:]) else {
            return .text("\(entry.url.path)\n\n\(age(entry.date)) · \(size(entry.bytes))")
        }
        let value = (
            base64: data.base64EncodedString(),
            width: Int(image.size.width),
            height: Int(image.size.height)
        )
        thumbnailLock.withLock {
            if thumbnails.count > 120 { thumbnails.removeAll() }
            thumbnails[thumbnailKey(entry)] = value
        }
        return .image(base64: value.base64, width: value.width, height: value.height)
    }

    private static func posterFrame(for url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 520)
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
    }

    private static func downscale(_ image: NSImage, maxWidth: CGFloat) -> NSBitmapImageRep? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, maxWidth / source.width)
        let width = max(1, Int(source.width * scale))
        let height = max(1, Int(source.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - Files

    private static func modified(_ directory: String) -> String {
        let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return "-" }
        return String(Int(date.timeIntervalSince1970))
    }

    /// Palette names its own captures `shot-*.png` and `rec-*.mov`; anything
    /// else in the folder came from Shottr, CleanShot, the system, or the user.
    private static func isPaletteCapture(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("shot-") || name.hasPrefix("rec-")
    }

    private static func entries(in directory: String) -> [Entry] {
        let expanded = (directory as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
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
    /// Posted with the file path when a capture row asks to pin it on screen.
    public static let palettePinRequest = Notification.Name("palette.pin.request")
    /// Posted with a tab index to open Settings on that tab (used by tests).
    public static let paletteSettingsTab = Notification.Name("palette.settings.tab")
}
