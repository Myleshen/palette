import AppKit
import Foundation
import PaletteCore
import PalettePlatform

/// `/ocr` reads text and links from the clipboard image (or the last
/// screenshot) and offers the result as rows, so recognition is discoverable
/// without knowing which clipboard entry has an image.
public final class OCRProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "ocr",
        name: "Image Text (OCR)",
        trigger: "ocr",
        isGlobal: false,
        priority: 45,
        icon: "symbol:text.viewfinder",
        keywords: ["ocr", "text", "image", "screenshot", "qr", "barcode", "recognize"]
    )

    private let store: PaletteStore
    private let bridge: HostBridge
    private let lastScreenshot: @MainActor () -> URL?

    public init(store: PaletteStore, bridge: HostBridge, lastScreenshot: @escaping @MainActor () -> URL?) {
        self.store = store
        self.bridge = bridge
        self.lastScreenshot = lastScreenshot
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = try await imageSource(argument: query)
        guard let source else {
            return [emptyRow(
                title: "No image to read",
                subtitle: "Copy an image or take a screenshot, then run /ocr"
            )]
        }
        let recognition: RecognizedImageText
        do {
            recognition = try await source.recognition()
        } catch {
            return [emptyRow(title: "Text recognition failed", subtitle: source.label)]
        }
        if recognition.isEmpty {
            return [emptyRow(title: "No text found", subtitle: source.label)]
        }
        return items(for: recognition, source: source)
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        guard action.id == "ocr-copy-text", let text = action.value.text else { return }
        await bridge.copyToClipboard(text, concealed: false, clearAfterMs: nil)
        await bridge.notify("Text copied (\(text.count) chars)")
    }

    // MARK: - Rows

    private func items(for recognition: RecognizedImageText, source: Source) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let text = recognition.text
        if !text.isEmpty {
            let flat = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            var actions: [PaletteAction] = [
                PaletteAction(id: "ocr-copy-text", title: "Copy Text", kind: .custom, value: .text(text)),
            ]
            if let search = Self.searchURL(text) {
                actions.append(PaletteAction(id: "search-web", title: "Search the Web", kind: .openURL, value: .text(search)))
            }
            items.append(PaletteItem(
                id: "ocr:text",
                title: String(flat.prefix(160)),
                subtitle: "\(text.count) chars · \(recognition.lines.count) lines · \(source.label)",
                icon: .symbol("text.viewfinder"),
                badge: "OCR",
                group: "Recognized Text",
                score: 10_000,
                actions: actions,
                preview: .text(text),
                providerID: descriptor.id,
                providerName: descriptor.name
            ))
        }
        for (index, link) in recognition.links.enumerated() {
            items.append(PaletteItem(
                id: "ocr:link:\(index)",
                title: link,
                subtitle: "Detected link",
                icon: .symbol("link"),
                badge: "LINK",
                group: "Links",
                score: 9_000 - Double(index),
                actions: [
                    PaletteAction(id: "open", title: "Open Link", kind: .openURL, value: .text(link)),
                    PaletteAction(id: "copy", title: "Copy Link", kind: .copyText, value: .text(link)),
                ],
                providerID: descriptor.id,
                providerName: descriptor.name
            ))
        }
        return items
    }

    private func emptyRow(title: String, subtitle: String) -> PaletteItem {
        PaletteItem(
            id: "ocr:empty",
            title: title,
            subtitle: subtitle,
            icon: .symbol("text.viewfinder"),
            badge: "OCR",
            group: "Image Text",
            score: 1_000,
            actions: [],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    // MARK: - Source

    private enum Source {
        case clipboard(id: String, data: Data)
        case file(URL)

        var label: String {
            switch self {
            case .clipboard: return "clipboard image"
            case .file(let url): return url.lastPathComponent
            }
        }

        /// Repeated keystrokes inside /ocr must not re-read the same image.
        var cacheKey: String {
            switch self {
            case .clipboard(let id, _): return "clip:\(id)"
            case .file(let url): return "file:\(url.path)"
            }
        }

        func recognition() async throws -> RecognizedImageText {
            switch self {
            case .clipboard(_, let data):
                return try await ImageTextRecognition.recognize(pngData: data, cacheKey: cacheKey)
            case .file(let url):
                guard let image = NSImage(contentsOf: url) else { throw ImageTextError.unreadableImage }
                return try await ImageTextRecognition.recognize(image, cacheKey: cacheKey)
            }
        }
    }

    /// A path argument wins; otherwise the newest clipboard image, then the
    /// last screenshot.
    private func imageSource(argument: String) async throws -> Source? {
        if !argument.isEmpty {
            let path = (argument as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return .file(URL(fileURLWithPath: path))
            }
        }
        if let entry = try await store.clipboardEntries(limit: 1, query: nil, kind: .image, includeThumbnails: false).first,
           let data = try await store.clipboardImage(id: entry.id) {
            return .clipboard(id: entry.id, data: data)
        }
        if let url = await MainActor.run(body: { lastScreenshot() }),
           FileManager.default.fileExists(atPath: url.path) {
            return .file(url)
        }
        return nil
    }

    private static func searchURL(_ text: String) -> String? {
        let query = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return "https://duckduckgo.com/?q=\(encoded)"
    }
}
