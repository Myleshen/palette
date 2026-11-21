import AppKit
import Foundation
import PaletteCore

/// Colour picker backed by the system sampler, plus typed hex values and the
/// colours picked during this session so they can be copied again without
/// re-picking.
public final class ColorProvider: PaletteProvider, @unchecked Sendable {
    public let descriptor = ProviderDescriptor(
        id: "color",
        name: "Colours",
        trigger: "color",
        isGlobal: false,
        priority: 45,
        icon: "symbol:paintpalette",
        keywords: ["color", "colour", "picker", "hex", "rgb", "eyedropper", "sample"]
    )

    private static var recent: [(hex: String, rgb: String)] = []

    private let bridge: HostBridge

    public init(bridge: HostBridge) {
        self.bridge = bridge
    }

    private func copy(_ text: String) async {
        await bridge.copyToClipboard(text, concealed: false, clearAfterMs: nil)
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [PaletteItem] = []

        if let hex = Self.parseHex(query) {
            items.append(hexRow(hex))
        }
        items.append(pickRow())
        for entry in Self.recent.prefix(12) {
            items.append(recentRow(entry))
        }

        guard !query.isEmpty else { return items }
        return items.filter {
            Ranking.score(
                query: query,
                candidate: "\($0.title) \($0.subtitle ?? "") \($0.group ?? "")"
            ) != nil
        }
    }

    /// `#5b7cfa` or `5b7cfa`, case-insensitive.
    static func parseHex(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + value.uppercased()
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        switch action.value.text {
        case "pick":
            guard let picked = await Self.pick() else { return }
            Self.recent.removeAll { $0.hex == picked.hex }
            Self.recent.insert(picked, at: 0)
            await copy(picked.hex)
        case let raw? where raw.hasPrefix("copy:"):
            await copy(String(raw.dropFirst("copy:".count)))
        default:
            break
        }
    }

    @MainActor
    private static func pick() async -> (hex: String, rgb: String)? {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { colour in
                guard let colour = colour?.usingColorSpace(.sRGB) else {
                    continuation.resume(returning: nil)
                    return
                }
                let r = Int((colour.redComponent * 255).rounded())
                let g = Int((colour.greenComponent * 255).rounded())
                let b = Int((colour.blueComponent * 255).rounded())
                let hex = String(format: "#%02X%02X%02X", r, g, b)
                continuation.resume(returning: (hex, "rgb(\(r), \(g), \(b))"))
            }
        }
    }

    private func hexRow(_ hex: String) -> PaletteItem {
        PaletteItem(
            id: "hex:\(hex)",
            title: hex,
            subtitle: "Copy this colour",
            icon: .symbol("paintbrush"),
            group: "Typed",
            score: 10_500,
            actions: [PaletteAction(id: "copy-hex", title: "Copy \(hex)", kind: .custom, value: .text("copy:\(hex)"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func pickRow() -> PaletteItem {
        PaletteItem(
            id: "pick",
            title: "Pick a colour",
            subtitle: "Sample any pixel on screen · copies the hex value",
            icon: .symbol("eyedropper"),
            badge: "PICK",
            group: "Colour",
            score: 10_000,
            actions: [PaletteAction(id: "pick", title: "Pick", kind: .custom, value: .text("pick"))],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }

    private func recentRow(_ entry: (hex: String, rgb: String)) -> PaletteItem {
        PaletteItem(
            id: "recent:\(entry.hex)",
            title: entry.hex,
            subtitle: "\(entry.rgb) · copies the hex",
            icon: .symbol("circle.fill"),
            group: "Recent",
            score: 9_000,
            actions: [
                PaletteAction(id: "copy-hex", title: "Copy \(entry.hex)", kind: .custom, value: .text("copy:\(entry.hex)")),
                PaletteAction(id: "copy-rgb", title: "Copy \(entry.rgb)", kind: .custom, value: .text("copy:\(entry.rgb)")),
            ],
            providerID: descriptor.id,
            providerName: descriptor.name
        )
    }
}
