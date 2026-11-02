import AppKit
import PaletteCore

@MainActor
public final class IconProvider {
    public static let shared = IconProvider()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    public func image(for spec: IconSpec?, size: CGFloat = 20) -> NSImage? {
        guard let spec else { return nil }
        let key: String
        switch spec {
        case .symbol(let name): key = "symbol:\(name)"
        case .file(let path): key = "file:\(path)"
        case .url(let url): key = "url:\(url)"
        case .base64(let value): key = "base64:\(value.hashValue)"
        }
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let image: NSImage?
        switch spec {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        case .file(let path):
            image = NSWorkspace.shared.icon(forFile: PathExpansion.expand(path))
        case .url:
            image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        case .base64(let value):
            if let data = Data(base64Encoded: value) {
                image = NSImage(data: data)
            } else {
                image = nil
            }
        }

        if let image {
            image.size = NSSize(width: size, height: size)
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}
